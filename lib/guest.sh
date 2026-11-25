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
