# shellcheck shell=bash
# lib/guest.sh: guest type awareness (LXC container vs QEMU VM).
#
# The tool was born LXC-only. VMs (qemu) differ in a few concrete ways that this
# layer isolates so the rest of the engine can branch on a single `type` value:
#   - backup archive:   .tar (lxc)          vs .vma (qemu), both via vzdump --compress 0
#   - restore verb:     pct restore <id> <archive> --unprivileged <n>
#                       vs qmrestore <archive> <id>   (reversed args, no --unprivileged)
#   - liveness:         pct exec <id> -- true         vs qm agent <id> ping
#   - config fields:    hostname:/rootfs:/unprivileged (lxc-only) vs name:/scsiN:/...
#
# Phase 1 (ADR 0002): LOCAL node only, detection is `qm config` / `pct config`
# on the host the tool runs on. Cross-node routing comes in Phase 2.

# _guest_type <vmid> → "qemu" | "lxc" on stdout; returns 1 if neither exists locally.
# qm is tried first; when qm is absent (e.g. the test sandbox) this falls through
# to pct, so LXC-only environments keep behaving exactly as before.
_guest_type() {
    local vmid="$1"
    if qm config "$vmid"  >/dev/null 2>&1; then printf 'qemu'; return 0; fi
    if pct config "$vmid" >/dev/null 2>&1; then printf 'lxc';  return 0; fi
    return 1
}

# _guest_type_from_archive <archive-path> → "qemu" | "lxc" (by name/extension).
# Used on restore, where the live guest does not exist yet, the type travels with
# the archive (vzdump-qemu-*.vma vs vzdump-lxc-*.tar).
_guest_type_from_archive() {
    case "$1" in
        *vzdump-qemu-*|*.vma|*.vma.*) printf 'qemu' ;;
        *)                            printf 'lxc'  ;;
    esac
}

# _g_config <type> <vmid>, config dump (qm/pct).
_g_config()  { [[ "$1" == qemu ]] && qm config "$2" || pct config "$2"; }

# _g_exists <vmid>, does a guest with this id exist locally (either type)?
_g_exists()  { qm config "$1" >/dev/null 2>&1 || pct config "$1" >/dev/null 2>&1; }

# _g_start / _g_stop <type> <vmid>
_g_start()   { [[ "$1" == qemu ]] && qm start "$2" || pct start "$2"; }
_g_stop()    { [[ "$1" == qemu ]] && qm stop  "$2" || pct stop  "$2"; }

# _g_alive <type> <vmid>, is the guest responsive?
#   qemu: guest-agent ping; if no agent is configured, accept `running` (crash-consistent).
#   lxc:  a command runs inside it.
_g_alive() {
    local t="$1" id="$2"
    if [[ "$t" == qemu ]]; then
        qm agent "$id" ping >/dev/null 2>&1 && return 0
        qm config "$id" 2>/dev/null | grep -Eq '^agent:.*1' && return 1   # agent expected → ping is the truth
        [[ "$(qm status "$id" 2>/dev/null)" == *running* ]]               # no agent → boot is the best we can prove
    else
        pct exec "$id" -- true >/dev/null 2>&1
    fi
}

# --- the guest's name in a snapshot (0.6.2) ---------------------------------
# Each new snapshot records the name the guest had when it was backed up, as a
# restic tag, so the Proxmox storage view, `pbo list` and the menu can show it,
# also once the guest is renamed or gone. It comes from the config that is
# backed up (the .conf sidecar: hostname: for a CT, name: for a VM). restic
# splits --tag values on commas and a tag ends at no blank, and only the
# Proxmox API checks a name as a DNS name (a hand-edited config can hold
# anything), so the tag is
#   name=<name>       when the name is made of [A-Za-z0-9._-] only (any DNS name)
#   nameb64=<base64>  otherwise: standard base64 of its UTF-8 bytes (no comma, no blank)
# Before that the name loses its control and invisible formatting characters
# and the blanks around it, and is cut to GUEST_NAME_MAX characters; empty
# then means no tag. Reading it back (PBO_JQ_NAME) undoes the encoding and
# cleans it again: a tag comes from whoever can write the repo.
# The tag is display data only. Retention groups by paths (or by '' with a
# vmid= filter), copy and restore select by vmid= and ts=, so no tag decides
# which snapshots belong together: a renamed guest stays one guest, and a
# guest whose older snapshots have no name tag keeps one history.
GUEST_NAME_MAX=128
# jq definitions: pbo_clean (a string → the cleaned, capped name, maybe "") and
# pbo_name (a restic snapshot → its decoded name, or null). An undecodable
# nameb64= counts as no name.
PBO_JQ_NAME='def pbo_clean: gsub("[\u0000-\u001f\u007f-\u009f​-‏ -‮⁠-⁯﻿]"; "")
                | sub("^\\s+"; "") | sub("\\s+$"; "") | .['"0:$GUEST_NAME_MAX"'];
             def pbo_name: (.tags // []) as $t
                | ( [ $t[]? | strings | select(startswith("name=")) | .[5:] ][0]
                    // [ $t[]? | strings | select(startswith("nameb64=")) | (.[8:] | try @base64d catch null) ][0] )
                | if type == "string" then (pbo_clean | if . == "" then null else . end) else null end;'

# _conf_guest_name <lxc|qemu> <config file> → the name in the file's main
# section (hostname: for a CT, name: for a VM; a snapshot section [..] below it
# keeps an older one), raw; empty when there is none.
_conf_guest_name() {
    local key=hostname
    [[ "$1" == qemu ]] && key=name
    [[ -f "$2" && -r "$2" ]] || return 0
    sed -n -e '/^\[/q' -e "/^${key}:/{s/^${key}:[[:space:]]*//p;q}" -- "$2" 2>/dev/null | tr -d '\r' || true
}

# _guest_name_tag <name>: GNT_TAG = the restic tag for it (name= or nameb64=,
# empty: no tag), GNT_NAME = the cleaned name. Never fails: a name is never
# worth a failed backup.
GNT_TAG="" GNT_NAME=""
_guest_name_tag() {
    GNT_TAG="" GNT_NAME=""
    [[ -n "${1:-}" ]] || return 0
    local out=()
    mapfile -t out < <(jq -rn --arg n "$1" "$PBO_JQ_NAME"'
        $n | pbo_clean | select(. != "")
        | (if test("^[A-Za-z0-9._-]+$") then "name=" + . else "nameb64=" + @base64 end), .' 2>/dev/null || true)
    (( ${#out[@]} == 2 )) || return 0
    GNT_TAG="${out[0]}" GNT_NAME="${out[1]}"
    return 0
}

# _guest_current_name <vmid> <lxc|qemu> → the name in the guest's config as it
# is now, for a snapshot that records none (taken before 0.6.2). Read from
# pmxcfs files only (no pct/qm, no API call): this node's config directory
# (PBO_PVE_LXC_DIR, PBO_PVE_QEMU_DIR), then each cluster node's
# (<pmxcfs>/nodes/<node>/lxc|qemu-server, the nodes from the member list), since
# the guest may live on another node now. Only a guest of the same type
# counts; empty when there is none, and always on a janitor (its Proxmox
# configs, if any, are not the backed-up hosts'). A vmid that was reused for
# another guest of the same type gives that guest's name: there is no way to
# tell from the snapshot.
_GN_NODES=() _GN_NODES_LOADED=0
_guest_current_name() {
    local id="$1" t="$2" sub dir f="" n
    _is_janitor && return 0
    [[ "$id" =~ ^[0-9]{1,9}$ ]] || return 0
    case "$t" in
        lxc)  sub=lxc;         dir="${PBO_PVE_LXC_DIR:-/etc/pve/lxc}" ;;
        qemu) sub=qemu-server; dir="${PBO_PVE_QEMU_DIR:-/etc/pve/qemu-server}" ;;
        *) return 0 ;;
    esac
    if [[ -f "$dir/$id.conf" ]]; then
        f="$dir/$id.conf"
    else
        if (( ! _GN_NODES_LOADED )); then
            _GN_NODES_LOADED=1
            mapfile -t _GN_NODES < <(_cluster_node_names)
        fi
        for n in "${_GN_NODES[@]+"${_GN_NODES[@]}"}"; do
            [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || continue
            if [[ -f "${PBO_PVE_CFS_DIR:-/etc/pve}/nodes/$n/$sub/$id.conf" ]]; then
                f="${PBO_PVE_CFS_DIR:-/etc/pve}/nodes/$n/$sub/$id.conf"; break
            fi
        done
    fi
    [[ -n "$f" ]] && _conf_guest_name "$t" "$f"
    return 0
}

# _guest_names_fallback <archives-json> → {"<vmid>/<type>": name} for each
# guest (lxc or qemu) that has an archive without a recorded name, from its
# current config (_guest_current_name); guests with no current name are left
# out. {} when there is nothing to look up.
_guest_names_fallback() {
    local pairs=() p n fbm='{}'
    mapfile -t pairs < <(jq -r '[ .[]? | select(.name == null and (.type == "lxc" or .type == "qemu")
                                           and ((.vmid // "") | tostring | test("^[0-9]{1,9}$")))
                                  | "\(.vmid)/\(.type)" ] | unique | .[]' <<<"$1" 2>/dev/null || true)
    for p in "${pairs[@]+"${pairs[@]}"}"; do
        n="$(_guest_current_name "${p%%/*}" "${p#*/}")"
        [[ -n "$n" ]] || continue
        fbm="$(jq -c --arg k "$p" --arg n "$n" "$PBO_JQ_NAME"' ($n | pbo_clean) as $c | if $c == "" then . else . + {($k): $c} end' <<<"$fbm" 2>/dev/null)" || fbm='{}'
    done
    printf '%s' "$fbm"
}
