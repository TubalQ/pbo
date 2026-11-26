# shellcheck shell=bash
# lib/integrate.sh: the one switch for the Proxmox integration (ADR 0006/0007).
#
#   pbo integrate status [--json]
#   pbo integrate enable <both|integrated> [--catalog-only] [--yes]
#   pbo integrate disable [--yes]
#
# install.sh puts the plugin, the hook and the units in place; it never creates
# the storage. This does, because the repo must exist first. install.sh, the
# setup wizard and the operator all use these commands. Every command is
# idempotent (a second run changes nothing), honours the global --dry-run (the
# planned commands and file diffs, nothing changed) and is audited.
#
# enable, in this order:
#   1. preflight (all read-only): PVE versions, the plugin present and loadable,
#      the repo(s) readable, spool and staging on CACHE_DIR's filesystem, no
#      storage with that id of another type; unless --catalog-only also the hook
#      executable and no foreign `script:` in vzdump.conf
#   2. catalogue refresh (must succeed: the plugin lists nothing without it)
#   3. the spool (<spool>/dump, 0755: vzdump of an unprivileged CT runs tar as
#      the CT's mapped root with its tmpdir inside the dump dir) and staging (0700)
#   4. `pvesm add pbo <id> --content backup --nodes <this node> [--path <spool>]`,
#      or `pvesm set` to converge an existing pbo storage's path
#   5. the hook line in vzdump.conf, after a marker comment (--catalog-only:
#      our line is removed instead; a foreign line is never touched)
#   6. systemctl enable --now pbo-catalog.timer
#   7. a warning when a non-root principal has Datastore.* on the storage
#   8. PBO_INTEGRATION=<mode> in the config, LAST: a failed step leaves pbo in
#      the mode it was in
# disable, in this order:
#   1. refuse while an enabled PVE job writes to a pbo storage (pbo never edits
#      jobs.cfg)
#   2. PBO_INTEGRATION=standalone, FIRST: from here pbo.timer backs up every guest
#   3. ingest --pending; refuse while spool archives remain
#   4. remove our hook line(s) only
#   5. stop pbo-mount.service, empty the staging directory
#   6. pvesm remove <id>
#   7. systemctl disable --now pbo-catalog.timer
#   8. say how to remove the plugin
#
# Test hooks (env or config): PBO_PVE_PLUGIN_PATH, PBO_PVE_PLUGIN_CHECK (a shell
# command that must succeed when the plugin loads), PBO_VZDUMP_HOOK, VZDUMP_CONF,
# PVE_STORAGE_CFG; PBO_INTEGRATE_ALLOW_NONROOT=1 lets enable/disable run without
# root (the test suite only, like PBO_JANITOR_ALLOW_ROOT).

readonly INTEG_MIN_PVE_MANAGER=9.2.29
readonly INTEG_MIN_LIBPVE_STORAGE=9.1.18
# The set the plugin was tested with: keep in sync with %TESTED in
# pve-plugin/PboPlugin.pm (tests/integrate.sh compares them).
readonly INTEG_TESTED="pve-manager=9.3.1 libpve-storage-perl=9.1.26 qemu-server=9.2.24 pve-container=6.1.28"
readonly INTEG_PACKAGES="pve-manager libpve-storage-perl qemu-server pve-container"
readonly INTEG_HOOK_MARKER="# pbo: added by 'pbo integrate enable' (remove with 'pbo integrate disable')"
readonly PBO_CATALOG_TIMER=pbo-catalog.timer
# doctor's spool age limit (PVE_SPOOL_MAX_AGE) and job window (PVE_JOB_WINDOW_MIN)
# are config keys since 0.6. The pbo timers a PVE job is compared with for the
# window warning: their schedules are config keys too (SCHEDULE_*, lib/timers.sh).
readonly INTEG_NEAR_TIMERS="pbo.timer pbo-prune.timer pbo-verify.timer"
declare -gA _INTEG_TM=()   # timer -> the minutes of the day it runs (once per process)

INTEG_STEPS=()     # what enable/disable changed (with --dry-run: would change)
INTEG_DIFFS=()     # unified diffs of file changes
INTEG_WARNINGS=()
INTEG_LOCK_FD=""

# --- small helpers ------------------------------------------------------------
# _integ_pkg_version <package> → the installed version, empty when not installed.
_integ_pkg_version() {
    local v
    v="$(dpkg-query -W -f='${Version}' "$1" 2>/dev/null)" || v=""
    printf '%s' "$v"
}

# _integ_ver_ge <a> <b>: a >= b in Debian version order.
_integ_ver_ge() {
    if command -v dpkg >/dev/null 2>&1; then dpkg --compare-versions "$1" ge "$2"
    else [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]; fi
}

# _integ_tested_version <package> → the version in INTEG_TESTED, or empty.
_integ_tested_version() {
    local kv
    for kv in $INTEG_TESTED; do [[ "${kv%%=*}" == "$1" ]] && { printf '%s' "${kv#*=}"; return 0; }; done
    return 0
}

# _integ_min_version <package> → the minimum pbo needs, empty when none.
_integ_min_version() {
    case "$1" in
        pve-manager) printf '%s' "$INTEG_MIN_PVE_MANAGER" ;;
        libpve-storage-perl) printf '%s' "$INTEG_MIN_LIBPVE_STORAGE" ;;
    esac
}

# _integ_versions_json → [{package, installed, minimum, ok, tested, newer_than_tested}]
_integ_versions_json() {
    local p v min t ok newer out=''
    for p in $INTEG_PACKAGES; do
        v="$(_integ_pkg_version "$p")"; min="$(_integ_min_version "$p")"; t="$(_integ_tested_version "$p")"
        ok=null
        if [[ -n "$min" ]]; then
            if [[ -n "$v" ]] && _integ_ver_ge "$v" "$min"; then ok=true; else ok=false; fi
        fi
        newer=false
        [[ -n "$v" && -n "$t" ]] && ! _integ_ver_ge "$t" "$v" && newer=true
        out+="$(jq -cn --arg p "$p" --arg v "$v" --arg min "$min" --arg t "$t" --argjson ok "$ok" --argjson newer "$newer" \
            'def nz: if . == "" then null else . end;
             {package:$p, installed:($v|nz), minimum:($min|nz), ok:$ok, tested:($t|nz), newer_than_tested:$newer}')"$'\n'
    done
    printf '%s' "$out" | jq -cs .
}

# _integ_versions_refusal <versions-json> → the refusal text, empty when the minimums hold.
_integ_versions_refusal() {
    jq -e '[.[] | select(.minimum != null) | .ok] | all' >/dev/null 2>&1 <<<"$1" && return 0
    local pm ls
    pm="$(jq -r '.[] | select(.package == "pve-manager") | .installed // "not installed"' <<<"$1")"
    ls="$(jq -r '.[] | select(.package == "libpve-storage-perl") | .installed // "not installed"' <<<"$1")"
    printf 'Proxmox integration needs pve-manager >= %s and libpve-storage-perl >= %s (installed: %s, %s)' \
        "$INTEG_MIN_PVE_MANAGER" "$INTEG_MIN_LIBPVE_STORAGE" "$pm" "$ls"
}

_integ_plugin_path() { printf '%s' "${PBO_PVE_PLUGIN_PATH:-/usr/share/perl5/PVE/Storage/Custom/PboPlugin.pm}"; }

# _integ_plugin_loads: PVE::Storage knows the storage type pbo (the plugin loaded).
_integ_plugin_loads() {
    if [[ -n "${PBO_PVE_PLUGIN_CHECK:-}" ]]; then
        bash -c "$PBO_PVE_PLUGIN_CHECK" >/dev/null 2>&1; return
    fi
    command -v perl >/dev/null 2>&1 || return 1
    local t=(); command -v timeout >/dev/null 2>&1 && t=(timeout 120)
    "${t[@]}" perl -MPVE::Storage -e 'PVE::Storage::Plugin->lookup("pbo") or die' >/dev/null 2>&1
}

# _integ_id_valid ID: a storage id PVE takes: PVE::JSONSchema::parse_id (the
# check behind the pve-storage-id format): at least 2 characters, a letter
# first, then letters, digits, '-', '_' and '.', and a letter or digit last,
# in either case (so pbo.node1 is one, pbo- and pbo. are not).
readonly INTEG_ID_RULE='at least 2 characters: a letter, then letters, digits, - _ or ., and a letter or digit last'
_integ_id_valid() { [[ ${#1} -ge 2 && "$1" =~ ^[A-Za-z][A-Za-z0-9_.-]*[A-Za-z0-9]$ ]]; }

# _integ_layout → how this pbo is installed, from where it runs: deb (the
# package, /usr/lib/pbo), install.sh (/usr/local/lib/pbo), or source (a
# checkout). The next steps pbo prints are the ones of that layout.
_integ_layout() {
    case "${SELF_DIR:-}" in
        */usr/lib/pbo) printf deb ;;
        */usr/local/lib/pbo) printf install.sh ;;
        *) printf source ;;
    esac
}
# _integ_install_hint MODE → how to install the integration's files (the
# storage plugin, the vzdump hook, the units) on this layout
_integ_install_hint() {
    case "$(_integ_layout)" in
        deb) printf 'apt install pbo-pve-storage' ;;
        install.sh) printf 'run install.sh --integration %s from the pbo source tree' "$1" ;;
        *) printf '%s/install.sh --integration %s' "${SELF_DIR:-.}" "$1" ;;
    esac
}
# _integ_remove_hint → how to remove the storage plugin on this layout
_integ_remove_hint() {
    case "$(_integ_layout)" in
        deb) printf 'apt remove pbo-pve-storage' ;;
        install.sh) printf 'run install.sh --integration standalone from the pbo source tree' ;;
        *) printf '%s/install.sh --integration standalone' "${SELF_DIR:-.}" ;;
    esac
}

# _integ_hook_path → the hook vzdump.conf should name: PBO_VZDUMP_HOOK, else the
# one next to this pbo (install.sh: /usr/local/lib/pbo, package: /usr/lib/pbo),
# else the repo's lib/vzdump-hook.
_integ_hook_path() {
    if [[ -n "${PBO_VZDUMP_HOOK:-}" ]]; then printf '%s' "$PBO_VZDUMP_HOOK"
    elif [[ -e "${SELF_DIR}/vzdump-hook" ]]; then printf '%s' "${SELF_DIR}/vzdump-hook"
    else printf '%s' "${SELF_DIR}/lib/vzdump-hook"; fi
}

# _integ_is_our_hook <path>: one of pbo's hook paths.
_integ_is_our_hook() {
    local p
    for p in "$(_integ_hook_path)" /usr/lib/pbo/vzdump-hook /usr/local/lib/pbo/vzdump-hook; do
        [[ "$1" == "$p" ]] && return 0
    done
    return 1
}

# _integ_is_our_line <line>: the marker, or a `script:` line naming one of our hooks.
_integ_is_our_line() {
    [[ "$1" == "$INTEG_HOOK_MARKER" ]] && return 0
    [[ "$1" =~ ^script:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] && _integ_is_our_hook "${BASH_REMATCH[1]}"
}

# _integ_conf_get <key> → the last value of <key> in vzdump.conf (as PVE parses it).
_integ_conf_get() {
    local f="${VZDUMP_CONF:-/etc/vzdump.conf}"
    [[ -r "$f" ]] || return 0
    sed -nE "s/^${1}:[[:space:]]*(.*[^[:space:]])[[:space:]]*\$/\\1/p" "$f" | tail -1
}

# _integ_conf_scripts → every `script:` value in vzdump.conf, in file order.
_integ_conf_scripts() {
    local f="${VZDUMP_CONF:-/etc/vzdump.conf}"
    [[ -r "$f" ]] || return 0
    sed -nE 's/^script:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$f"
}

# _integ_conf_strip <file>: print <file> without our lines, byte for byte
# otherwise (a last line without a newline stays without one).
_integ_conf_strip() {
    local f="$1" line nl
    [[ -f "$f" ]] || return 0
    while true; do
        if IFS= read -r line; then nl=$'\n'
        else [[ -n "$line" ]] || break; nl=""; fi
        if ! _integ_is_our_line "$line"; then printf '%s%s' "$line" "$nl"; fi
        [[ -n "$nl" ]] || break
    done < "$f"
}

# _integ_conf_with_hook <file> <hook>: <file> with exactly one marker + script
# line for <hook>: appended, or put first when the file does not end in a
# newline (so `disable` gives back the same bytes).
_integ_conf_with_hook() {
    local f="$1" hook="$2" tmp
    tmp="$(mktemp)"
    _integ_conf_strip "$f" > "$tmp"
    if [[ ! -s "$tmp" || -z "$(tail -c1 "$tmp")" ]]; then
        cat "$tmp"; printf '%s\nscript: %s\n' "$INTEG_HOOK_MARKER" "$hook"
    else
        printf '%s\nscript: %s\n' "$INTEG_HOOK_MARKER" "$hook"; cat "$tmp"
    fi
    rm -f "$tmp"
}

# _integ_fs_dev <path> → the device of <path>, or of its nearest existing parent.
_integ_existing() {
    local p="$1"
    while [[ -n "$p" && ! -e "$p" ]]; do p="$(dirname -- "$p")"; done
    printf '%s' "${p:-/}"
}
_integ_fs_dev() { stat -c %d -- "$(_integ_existing "$1")" 2>/dev/null; }
_integ_same_fs() { local a b; a="$(_integ_fs_dev "$1")"; b="$(_integ_fs_dev "$2")"; [[ -n "$a" && "$a" == "$b" ]]; }

# _integ_storage_json <id> → {id, present, type, nodes, path, content, disabled, stanza}
# straight from storage.cfg (no pvesh: it is also read in standalone mode, and it
# still shows the stanza when the plugin does not load).
_integ_storage_json() {
    local id="$1" cfg="${PVE_STORAGE_CFG:-/etc/pve/storage.cfg}" st=""
    [[ -r "$cfg" ]] && st="$(awk -v id="$id" '
        /^[A-Za-z][A-Za-z0-9_-]*:[ \t]+[^ \t]+[ \t]*$/ { on = ($2 == id); if (on) print; next }
        on && /^[ \t]+[^ \t]/ { print; next }
        { on = 0 }' "$cfg" 2>/dev/null)"
    jq -cn --arg id "$id" --arg st "$st" '
        ($st | split("\n") | map(select(test("\\S")))) as $l
        | if ($l | length) == 0 then
            {id:$id, present:false, type:null, nodes:null, path:null, content:null, disabled:false, stanza:null}
          else ($l[0] | sub(":.*$"; "")) as $t
            | ($l[1:] | map(sub("^\\s+"; "") | capture("^(?<k>\\S+)(\\s+(?<v>.*\\S))?\\s*$") | {key:.k, value:(.v // "")}) | from_entries) as $o
            | {id:$id, present:true, type:$t, nodes:($o.nodes // null), path:($o.path // null),
               content:($o.content // null), disabled:(($o | has("disable")) and $o.disable != "0"), stanza:($l | join("\n"))}
          end'
}

# _integ_cfg_pbo_ids → ids of the pbo storages in storage.cfg (no pvesh).
_integ_cfg_pbo_ids() {
    local cfg="${PVE_STORAGE_CFG:-/etc/pve/storage.cfg}"
    [[ -r "$cfg" ]] || return 0
    sed -nE 's/^pbo:[[:space:]]+([A-Za-z0-9][A-Za-z0-9._-]*)[[:space:]]*$/\1/p' "$cfg"
}

# _integ_hook_json → {configured, path, expected, ours, current, foreign_script, executable}
_integ_hook_json() {
    local cur s last="" foreign="" n=0
    cur="$(_integ_hook_path)"
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        n=$((n+1)); last="$s"
        _integ_is_our_hook "$s" || [[ -n "$foreign" ]] || foreign="$s"
    done < <(_integ_conf_scripts)
    local ours=false exe=false
    [[ -n "$last" ]] && _integ_is_our_hook "$last" && ours=true
    [[ -n "$last" && -x "$last" ]] && exe=true
    jq -cn --arg conf "${VZDUMP_CONF:-/etc/vzdump.conf}" --arg p "$last" --arg cur "$cur" --arg f "$foreign" \
        --argjson ours "$ours" --argjson exe "$exe" --argjson n "$n" '
        {conf:$conf, configured:($n > 0), path:(if $p == "" then null else $p end), expected:$cur,
         ours:$ours, current:($p == $cur), foreign_script:(if $f == "" then null else $f end), executable:$exe}'
}

# _integ_spool_json → {dir, dump_dir, exists, same_fs_as_cache, staging_dir, staging_same_fs,
#                      files, oldest_age, free_bytes}
_integ_spool_json() {
    local dir="${PVE_SPOOL_DIR%/}" dump now files=0 oldest="" t free same=false ssame=false ex=false
    dump="$dir/dump"; now="$(date +%s)"
    _integ_same_fs "$dir" "$CACHE_DIR" && same=true
    _integ_same_fs "$PVE_STAGING_DIR" "$CACHE_DIR" && ssame=true
    if [[ -d "$dump" ]]; then
        ex=true
        while read -r t; do
            [[ -n "$t" ]] || continue
            files=$((files+1)); t="${t%%.*}"
            [[ -z "$oldest" ]] || (( t < oldest )) && oldest="$t"
        done < <(find "$dump" -maxdepth 1 -type f -name 'vzdump-*' ! -name '*.log' ! -name '*.notes' -printf '%T@\n' 2>/dev/null)
    fi
    free="$(df -B1 --output=avail -- "$(_integ_existing "$dir")" 2>/dev/null | tail -1 | tr -dc '0-9')"
    jq -cn --arg d "$dir" --arg dd "$dump" --arg sd "$PVE_STAGING_DIR" --argjson ex "$ex" --argjson same "$same" --argjson ssame "$ssame" \
        --argjson files "$files" --arg oldest "$oldest" --arg free "$free" --argjson now "$now" '
        {dir:$d, dump_dir:$dd, exists:$ex, same_fs_as_cache:$same, staging_dir:$sd, staging_same_fs_as_cache:$ssame,
         files:$files, oldest_age:(if $oldest == "" then null else ($now - ($oldest | tonumber)) end),
         free_bytes:(if $free == "" then null else ($free | tonumber) end)}'
}

# _integ_catalog_json → {path, present, age_s, entries, largest_bytes}
_integ_catalog_json() {
    if _catalog_valid "$PBO_CATALOG"; then
        jq -c --arg p "$PBO_CATALOG" --argjson now "$(date +%s)" \
            '{path:$p, present:true, age_s:($now - (.generated // $now)), entries:(.entries | length),
              largest_bytes:([.entries[].size // 0] | max // 0)}' "$PBO_CATALOG"
    else
        jq -cn --arg p "$PBO_CATALOG" '{path:$p, present:false, age_s:null, entries:null, largest_bytes:null}'
    fi
}

# _integ_minute_of_day <job> → the minute of the day the job runs (from next_run,
# else the HH:MM in its schedule), empty when unknown.
_integ_minute_of_day() {
    local nr sch hm
    nr="$(jq -r '.next_run // empty' <<<"$1")"
    if [[ "$nr" =~ ^[0-9]+$ ]]; then hm="$(date -d "@$nr" +%H:%M 2>/dev/null)"
    else
        sch="$(jq -r '.schedule // empty' <<<"$1")"
        [[ "$sch" =~ (^|[[:space:]])([0-9]{1,2}):([0-9]{2})$ ]] && hm="${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
    fi
    [[ "${hm:-}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 0
    printf '%s' $(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))
}

# _integ_near_timers <minute> → "pbo.timer (HH:MM)" etc. for every pbo timer
# (INTEG_NEAR_TIMERS) that runs within PVE_JOB_WINDOW_MIN minutes of <minute>
# (around midnight too), at the run closest to it. The times come from the
# configured schedule (SCHEDULE_BACKUP, ...: lib/timers.sh _sched_minutes_r);
# a schedule whose times cannot be worked out is left out. Minutes of the local
# day, as a job's next run is compared (the weekday is not: a weekly prune
# still meets a daily job on its day).
_integ_near_timers() {
    local m="$1" u row ck v tm d best bd out=() win e all rest
    _cfg_int_r PVE_JOB_WINDOW_MIN; win="$_CI_R"
    _sched_ensure
    for u in $INTEG_NEAR_TIMERS; do
        if [[ -z "${_INTEG_TM[$u]+x}" ]]; then
            # what systemd runs, when it says (an override.conf, a pending
            # reload can make it differ from the config), else the config
            _sched_effective_r "$u"
            if [[ -n "$_SE_R" ]]; then
                all='' rest="$_SE_R"
                while [[ -n "$rest" ]]; do
                    e="${rest%%; *}"; [[ "$rest" == *"; "* ]] && rest="${rest#*; }" || rest=''
                    _sched_minutes_r "$e"; all+="${all:+ }$_SM_R"
                done
                _INTEG_TM[$u]="$all"
            else
                row="$(_sched_row_of "$u")"; ck="${row#*|}"; ck="${ck%%|*}"
                _sched_val_r "$ck"; v="$_CS_R"; _SM_R=''
                # a value pbo refuses runs nowhere (the drop-in is not written): no guess
                _cs_validate "$ck" "$v" >/dev/null && _sched_minutes_r "$v"
                _INTEG_TM[$u]="$_SM_R"
            fi
        fi
        best='' bd=''
        for tm in ${_INTEG_TM[$u]}; do
            d=$(( m > tm ? m - tm : tm - m )); (( d > 720 )) && d=$(( 1440 - d ))
            (( d < win )) && [[ -z "$bd" || "$d" -lt "$bd" ]] && { best="$tm"; bd="$d"; }
        done
        [[ -n "$best" ]] && out+=("$u ($(_sched_hm "$best"))")
    done
    (( ${#out[@]} )) && printf '%s' "${out[*]}"
    return 0
}

# _integ_stop_spool_need <vmid...> → bytes: the newest archive of each vmid in the
# catalogue, summed (unknown vmids count 0). A stop-mode job keeps every guest's
# archive in the spool until job-end, so this is what its spool must hold.
_integ_stop_spool_need() {
    (( $# )) && [[ -r "$PBO_CATALOG" ]] || { echo 0; return 0; }
    local ids sz sum=0; ids="$(printf '%s\n' "$@" | jq -Rc 'tonumber? // empty' | jq -cs .)"
    # one size per vmid, summed here: jq prints a large sum as 4e+18, which bash cannot add
    while IFS= read -r sz; do
        [[ "$sz" =~ ^[0-9]+$ ]] && sum=$(( sum + sz ))
    done < <(jq -r --argjson ids "$ids" '[.entries[] | select(.vmid as $v | $ids | index($v))]
        | group_by(.vmid) | .[] | (max_by(.ts).size // 0)' "$PBO_CATALOG" 2>/dev/null)
    echo "$sum"
}

# _integ_jobs_json → the PVE jobs that target a pbo storage on this node, with
# what is wrong with them:
#   [{id, enabled, storage, schedule, next_run, mode, compress, notification_mode,
#     guests[], owns[], problems[], warnings[]}]
# Needs _pve_jobs_load (and _guest_meta_load) in the calling shell. Values a job
# leaves out come from vzdump.conf, then vzdump's defaults.
_integ_jobs_json() {
    local raw dmode dcomp dnm own='{}' id j jout='' mode g stopg near min win
    raw="$(_pve_jobs_json)"
    _cfg_int_r PVE_JOB_WINDOW_MIN; win="$_CI_R"
    dmode="$(_integ_conf_get mode)"; dcomp="$(_integ_conf_get compress)"; dnm="$(_integ_conf_get notification-mode)"
    for id in "${!_PVE_OWNER[@]}"; do own="$(jq -c --arg k "$id" --arg v "${_PVE_OWNER[$id]}" '. + {($k): $v}' <<<"$own")"; done
    while IFS= read -r j; do
        [[ -n "$j" ]] || continue
        mode="$(jq -r --arg d "$dmode" '.mode // (if $d == "" then "snapshot" else $d end)' <<<"$j")"
        stopg=""
        if [[ "$mode" != stop ]]; then
            for g in $(jq -r '.guests[]' <<<"$j"); do [[ "$(_effective_mode "$g")" == stop ]] && stopg+="${stopg:+ }$g"; done
        fi
        near=""; min="$(_integ_minute_of_day "$j")"; [[ -n "$min" ]] && near="$(_integ_near_timers "$min")"
        jout+="$(jq -c --arg mode "$mode" --arg dc "$dcomp" --arg dn "$dnm" --arg stopg "$stopg" --arg near "$near" --arg win "$win" --argjson own "$own" '
            def truthy: . != null and . != false and ((tostring) as $e | $e != "" and $e != "0");
            ((.compress // (if $dc == "" then "0" else $dc end)) | tostring) as $comp
            # GET /cluster/backup returns prune-backups as an object (API2/Backup.pm:158-173);
            # a property string is accepted too. keep-all=1 alone is harmless (vzdump prunes nothing).
            | (.prune_backups | if type == "object" then (to_entries | map("\(.key)=\(.value | if type == "boolean" then (if . then 1 else 0 end) else . end)") | join(","))
                              elif . == null then "" else tostring end) as $pb
            | (.notification_mode // (if $dn == "" then "auto" else $dn end)) as $nm
            | . as $j
            | {id, enabled, storage, schedule, next_run, mode:$mode, compress:$comp, notification_mode:$nm,
               guests, owns:[.guests[] | select($own[.] == $j.id)],
               problems:[
                 (if (.script // "") != "" then "its own hook script (script: \(.script)) replaces pbo'"'"'s vzdump hook: nothing it writes is ingested" else empty end),
                 (if ($comp | IN("0", "none")) | not then "compression \($comp): pbo needs compression none (the hook refuses every guest)" else empty end),
                 (if $pb != "" and $pb != "keep-all=1" then "prune-backups \($pb): retention belongs to pbo (remove it from the job)" else empty end),
                 (if .protected | truthy then "protected: the pbo storage cannot protect a backup (pbo-keep-* tags do)" else empty end),
                 (if $stopg != "" then "guest(s) \($stopg) must be backed up in stop mode (fuse, VZDUMP_STOP_VMIDS or pbo-stop), the job runs \($mode) mode: the hook refuses them" else empty end)],
               warnings:[
                 (if .enabled | not then "disabled" else empty end),
                 (if $nm == "none" then "notification-mode none: nobody hears about a failed job" else empty end),
                 (if $near != "" then "runs within \($win) min of \($near) (PVE_JOB_WINDOW_MIN, SCHEDULE_*): they share the vzdump and repo locks" else empty end)]}' <<<"$j")"$'\n'
    done < <(jq -c '.[]' <<<"$raw")
    printf '%s' "$jout" | jq -cs .
}

# _integ_jobs_json_any → _integ_jobs_json in any mode, in a subshell: standalone
# computes nothing on its own, so the job list is read as if the integration
# were on, without touching this shell's ownership cache.
_integ_jobs_json_any() {
    (
        if _integration_standalone; then _pve_jobs_reset; PBO_INTEGRATION=both _pve_jobs_load; fi
        _pve_jobs_load
        _pve_owner_known || { printf 'null'; exit 0; }
        _integ_jobs_json
    )
}

# _integ_acl_lines <storage id> → one line per ACL entry that gives a principal
# other than root@pam a role with Datastore.* privileges on the storage (on
# /storage/<id>, or propagated from / or /storage). A role pbo cannot look up
# counts. Empty when pveum is missing or fails.
_integ_acl_lines() {
    command -v pveum >/dev/null 2>&1 || return 0
    local acl roles
    acl="$(pveum acl list --output-format json 2>/dev/null)" || return 0
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$acl" || return 0
    roles="$(pveum role list --output-format json 2>/dev/null)" || roles='[]'
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$roles" || roles='[]'
    jq -r --arg id "$1" --argjson roles "$roles" '
        ($roles | map(select(type == "object")) | map({key:(.roleid // ""), value:(.privs // "" | tostring)}) | from_entries) as $rp
        | .[] | select(type == "object") | select((.ugid // "") != "root@pam")
        | select(.path == "/storage/\($id)" or ((.path == "/" or .path == "/storage") and (((.propagate // 1) | tostring) != "0")))
        | select(($rp[.roleid] // null) as $p | $p == null or ($p | test("Datastore\\.")))
        | "\(.type // "user") \(.ugid) has role \(.roleid) on \(.path)"' <<<"$acl" 2>/dev/null || true
}

# _integ_recipe_json <storage-json> → {storage_cfg, vzdump_conf, source}: what the
# host's recipe (kept in version control) should hold. The live stanza when
# there is one, else the one `enable` writes.
_integ_recipe_json() {
    jq -c --arg node "$(_local_node)" --arg spool "${PVE_SPOOL_DIR%/}" --arg hook "$(_integ_hook_path)" '
        (if .present and .type == "pbo" then {storage_cfg: .stanza, source: "storage.cfg"}
         else {storage_cfg: ("pbo: \(.id)\n\tcontent backup\n\tnodes \($node)\n\tpath \($spool)"), source: "planned"} end)
        + {vzdump_conf: "script: \($hook)"}' <<<"$1"
}

# --- status ---------------------------------------------------------------------
integrate_status() {
    case "${1:-}" in
        "") ;;
        --json) [[ $# -eq 1 ]] || die "$EX_USAGE" "integrate status [--json]"
                [[ "${JSON_OUTPUT:-0}" == 1 ]] || { JSON_OUTPUT=1; json_open; } ;;
        *) die "$EX_USAGE" "integrate status [--json]" ;;
    esac
    AUDIT_RO_OVERRIDE=1
    _guest_meta_load
    local mode id vj pj sj hj spj cj jj oj rj acl
    mode="$(_integration_mode)"; id="$(_pve_storage_id)"
    vj="$(_integ_versions_json)"
    local present=false loaded=false pp; pp="$(_integ_plugin_path)"
    [[ -f "$pp" ]] && present=true
    _integ_plugin_loads && loaded=true
    pj="$(jq -cn --arg p "$pp" --argjson pr "$present" --argjson l "$loaded" '{path:$p, present:$pr, loaded:$l}')"
    sj="$(_integ_storage_json "$id")"
    hj="$(_integ_hook_json)"
    spj="$(_integ_spool_json)"
    cj="$(_integ_catalog_json)"
    _pve_jobs_load      # here first: the subshell below inherits it (no second pvesh call)
    jj="$(_integ_jobs_json_any)"; [[ -n "$jj" ]] || jj=null
    # ownership as pbo applies it in this mode (standalone: pbo.timer or nobody)
    local g ol=''
    while read -r g; do
        [[ "$g" =~ ^[0-9]+$ ]] || continue
        ol+="$(jq -cn --arg g "$g" --arg o "$(_guest_owner "$g")" '{($g): $o}')"$'\n'
    done < <( { _backup_set_all; _integration_standalone || _pve_owned_guests; } | awk 'NF && !seen[$0]++')
    oj="$(printf '%s' "$ol" | jq -cs 'add // {}')"
    rj="$(_integ_recipe_json "$sj")"
    acl="$(_integ_acl_lines "$id" | jq -R . | jq -cs .)"
    local out
    out="$(jq -cn --arg mode "$mode" --argjson v "$vj" --argjson p "$pj" --argjson s "$sj" --argjson h "$hj" \
        --argjson sp "$spj" --argjson c "$cj" --argjson j "$jj" --argjson o "$oj" --argjson r "$rj" --argjson acl "$acl" \
        --argjson known "$( _pve_owner_known && echo true || echo false )" --arg err "${_PVE_OWNER_ERR:-}" --arg node "$(_local_node)" \
        --argjson timer "$(systemctl is-enabled "$PBO_CATALOG_TIMER" >/dev/null 2>&1 && echo true || echo false)" '
        {status:"ok", ok:true, mode:$mode, node:$node,
         versions:$v, versions_ok:([$v[] | select(.minimum != null) | .ok] | all),
         plugin:$p, storage:($s | del(.stanza)), hook:$h, spool:$sp, catalog:$c, catalog_timer_enabled:$timer,
         jobs:$j, jobs_known:($j != null), ownership:$o, ownership_known:$known,
         ownership_error:(if $err == "" then null else $err end), acl:$acl, recipe:$r}')" \
        || die "$EX_SOFTWARE" "integrate status: could not build the view"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_emit "$out"; return "$EX_OK"; fi
    jq -r '
        def yn: if . then "yes" else "no" end;
        "mode:      \(.mode)  (node \(.node))",
        "versions:  " + ([.versions[] | "\(.package) \(.installed // "-")\(if .minimum then (if .ok then " (>= \(.minimum) ok)" else " (NEEDS >= \(.minimum))" end) else "" end)\(if .newer_than_tested then " (newer than tested \(.tested))" else "" end)"] | join(", ")),
        "plugin:    \(.plugin.path): present \(.plugin.present | yn), loaded \(.plugin.loaded | yn)",
        "storage:   \(.storage.id): " + (if .storage.present then "type \(.storage.type), nodes \(.storage.nodes // "all"), path \(.storage.path // "none (catalogue only)"), content \(.storage.content // "-")\(if .storage.disabled then ", DISABLED" else "" end)" else "not configured" end),
        "hook:      " + (if .hook.configured then "script: \(.hook.path) (\(if .hook.ours then "pbo" else "FOREIGN" end), executable \(.hook.executable | yn))" else "no script: line in \(.hook.conf)" end),
        "spool:     \(.spool.dump_dir): \(.spool.files) archive(s)\(if .spool.oldest_age then ", oldest \(.spool.oldest_age)s" else "" end), free \(.spool.free_bytes // "?") bytes, same filesystem as the cache \(.spool.same_fs_as_cache | yn)",
        "catalogue: " + (if .catalog.present then "\(.catalog.entries) archive(s), \(.catalog.age_s)s old" else "none at \(.catalog.path)" end) + ", pbo-catalog.timer enabled \(.catalog_timer_enabled | yn)",
        "jobs:      " + (if .jobs == null then "unknown (\(.ownership_error // "pvesh failed"))" elif (.jobs | length) == 0 then "no PVE job targets a pbo storage" else "" end),
        (.jobs // [] | .[] | "  \(.id) \(if .enabled then "enabled" else "disabled" end), \(.schedule // "-"), mode \(.mode), compress \(.compress), owns \(.owns | join(" ") | if . == "" then "-" else . end)"
            + ([.problems[] | "\n    PROBLEM: \(.)"] | join("")) + ([.warnings[] | "\n    warning: \(.)"] | join(""))),
        "owners:    " + ([.ownership | to_entries[] | "\(.key)=\(.value)"] | join(" ")),
        (.acl[] | "acl:       \(.) (GUI restores are not isolated: keep the storage admin-only)"),
        "",
        "recipe (\(.recipe.source)), /etc/pve/storage.cfg:",
        (.recipe.storage_cfg | split("\n")[] | "  \(.)"),
        "recipe, \(.hook.conf):",
        "  \(.recipe.vzdump_conf)"' <<<"$out"
}

# --- enable / disable ------------------------------------------------------------
# _integ_require_change_rights <what>: host role and root.
_integ_require_change_rights() {
    _is_janitor && die "$EX_CONFIG" "integrate $1: a janitor has no Proxmox (PBO_ROLE=janitor)"
    [[ "$(id -u)" == 0 || "${PBO_INTEGRATE_ALLOW_NONROOT:-0}" == 1 ]] \
        || die "$EX_USAGE" "integrate $1 changes PVE configuration: run it as root"
}

# _integ_lock: one enable/disable at a time.
_integ_lock() {
    [[ -n "$INTEG_LOCK_FD" ]] && return 0
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    exec {INTEG_LOCK_FD}>>"${LOCK_DIR}/pbo.integrate" || die "$EX_CANTCREAT" "integrate: cannot open ${LOCK_DIR}/pbo.integrate"
    flock -n "$INTEG_LOCK_FD" || die "$EX_TEMPFAIL" "integrate: another 'pbo integrate' is running"
}

# _integ_confirm <question>: --yes, --dry-run, or a yes on a terminal.
_integ_confirm() {
    [[ "${INTEG_YES:-0}" == 1 || "${DRY_RUN:-0}" == 1 ]] && return 0
    [[ -t 0 ]] || die "$EX_USAGE" "integrate: not a terminal, add --yes to confirm ($1)"
    local a; read -r -p "$1 [y/N] " a
    [[ "$a" == [yYjJ]* ]] || die "$EX_USAGE" "integrate: cancelled, nothing was changed"
}

# _integ_run <command...>: run one change, or with --dry-run only say it.
_integ_run() {
    local text; text="$(printf '%q ' "$@")"; text="${text% }"
    INTEG_STEPS+=("run: $text")
    if [[ "${DRY_RUN:-0}" == 1 ]]; then log_info "[dry-run] would run: $text"; return 0; fi
    log_info "integrate: $text"
    "$@"
}

# _integ_write_file <file> <new-content-file>: replace <file> atomically (temp
# file in the same directory, mode and owner kept; a new file is 0644), or with
# --dry-run print the diff. No-op when the content is the same.
_integ_write_file() {
    local f="$1" new="$2" dir tmp old d
    if [[ -f "$f" ]] && cmp -s "$f" "$new"; then return 0; fi
    old="$f"; [[ -f "$f" ]] || old=/dev/null
    d="$(diff -u --label "$f" --label "$f (pbo)" "$old" "$new" 2>/dev/null || true)"
    INTEG_STEPS+=("edit: $f"); INTEG_DIFFS+=("$d")
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] would change $f:"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] || printf '%s\n' "$d"
        return 0
    fi
    dir="$(dirname -- "$f")"
    tmp="$(mktemp "$dir/.$(basename -- "$f").pbo.XXXXXX")" || die "$EX_CANTCREAT" "integrate: cannot write in $dir"
    cat "$new" > "$tmp" || { rm -f "$tmp"; die "$EX_CANTCREAT" "integrate: cannot write $tmp"; }
    if [[ -e "$f" ]]; then
        chmod --reference="$f" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
        chown --reference="$f" "$tmp" 2>/dev/null || true
    else
        chmod 0644 "$tmp"
    fi
    mv -f -- "$tmp" "$f" || { rm -f "$tmp"; die "$EX_CANTCREAT" "integrate: cannot replace $f"; }
    log_info "integrate: $f changed"
}

# _integ_set_mode <mode> [<storage id>]: PBO_INTEGRATION in the local config
# file (and in memory), through the config writer (_cfg_write, lib/config.sh):
# the key is managed by this command, so it is written here and `pbo config
# set` refuses it. The local file (PBO_CONFIG_LOCAL): the mode is per node, and
# the cluster-shared file is never written. With a storage id,
# PVE_STORAGE_ID=<id> goes into the same transaction (_integ_pin_id).
_integ_set_mode() {
    local m="$1" pin="${2:-}" cfg="${PBO_CONFIG_LOCAL:-${PBO_CONFIG:-/etc/pbo/config}}" cur rc=0 ops=()
    _cfg_write_ensure
    # the value the local file sets, as the strict reader reads it
    cur="$(_cfg_file_value "$cfg" PBO_INTEGRATION)"
    # already so (a config without the key is standalone)
    if [[ "$cur" != "$m" ]] && ! [[ -z "$cur" && "$m" == standalone && "$(_integration_mode)" == standalone ]]; then
        ops+=(set PBO_INTEGRATION "$m")
    fi
    [[ -z "$pin" ]] || ops+=(set PVE_STORAGE_ID "$pin")
    if (( ${#ops[@]} == 0 )); then PBO_INTEGRATION="$m"; return 0; fi
    local what='' i
    for (( i = 0; i < ${#ops[@]}; i += 3 )); do what+="${what:+, }${ops[i+1]}=${ops[i+2]}"; done
    INTEG_STEPS+=("config: $what in $cfg")
    if [[ "${DRY_RUN:-0}" == 1 ]]; then log_info "[dry-run] would set $what in $cfg"; return 0; fi
    _cfg_write "${ops[@]}" || rc=$?
    (( rc == 0 )) || die "$rc" "integrate: cannot write $what to $cfg: $CFGW_ERR"
    PBO_INTEGRATION="$m"; [[ -z "$pin" ]] || PVE_STORAGE_ID="$pin"
    log_info "integrate: $what written to $cfg"
}

# _integ_pin_id <id> → <id> when enable should write it to the local config:
# a per-node id (`pbo-<node>`) that set_defaults derived (lib/config_schema.sh
# _cfgdef_PVE_STORAGE_ID) and no config file or the environment sets. Pinned,
# the node keeps it whatever pmxcfs shows later (a node that leaves the
# cluster, a start while /etc/pve is not mounted), and `pbo config list` shows
# it as configured. `pbo` is never pinned: a single node's config stays as it
# was.
_integ_pin_id() {
    [[ "$1" != pbo ]] || return 0
    [[ "$(_cfg_key_source PVE_STORAGE_ID)" == default ]] || return 0
    printf '%s' "$1"
}

# _integ_nodes_shared <nodes> <node>: a pbo entry whose `nodes` value (blanks
# stripped) is <nodes> serves more nodes than <node> in this cluster: it has no
# `nodes` (every node), or its list names another node. On a single node no
# entry is shared. storage.cfg is one file for the cluster, so a change to such
# an entry (its path, removing it) changes it for those other nodes too.
_integ_nodes_shared() {
    local nodes="$1" node="$2" n
    (( $(_cluster_node_count) > 1 )) || return 1
    [[ -n "$nodes" ]] || return 0
    local IFS=,
    for n in $nodes; do [[ -z "$n" || "$n" == "$node" ]] || return 0; done
    return 1
}

# _integ_sid_hint <id> <node> → how this node gets a storage of its own instead
# of <id>. Unsetting PVE_STORAGE_ID helps only when the derived default is this
# node's own pbo-<node> and not <id>: while a shared entry serves the node, the
# default keeps that entry's id (lib/config_schema.sh _cfgdef_PVE_STORAGE_ID),
# and the unset would change nothing.
_integ_sid_hint() {
    local id="$1" node="$2"
    _cs_default_r PVE_STORAGE_ID
    if [[ "$_CS_R" == "pbo-$node" && "$id" != "pbo-$node" ]]; then
        printf "unset PVE_STORAGE_ID (pbo config unset PVE_STORAGE_ID) for the per-node default pbo-%s, or set a free id" "$node"
    elif [[ "$id" != "pbo-$node" ]]; then
        printf "set PVE_STORAGE_ID=pbo-%s (pbo config set PVE_STORAGE_ID pbo-%s), or another free id" "$node" "$node"
    else
        printf "set PVE_STORAGE_ID to a free id (pbo config set PVE_STORAGE_ID <id>)"
    fi
}

# _integ_storage_other_node <storage-json> <node> <spool> <catalog-only 0|1>
# → why enable must not take over an existing pbo entry, empty when it may. The
# entry's `nodes` leave this node out: it is another node's storage (PVE runs no
# job of this node on it), and converging its path would repoint it. An entry
# that serves other nodes too (no `nodes`, or a list with more than this node,
# in a cluster) may be used as it is, but step 4 must not change its path: the
# path is the same on every node it serves, so setting it to this node's spool
# repoints the others, and --catalog-only deleting it takes their backup target
# away.
_integ_storage_other_node() {
    local sj="$1" node="$2" spool="$3" co="$4" nodes path id
    [[ "$(jq -r '.present and .type == "pbo"' <<<"$sj")" == true ]] || return 0
    id="$(jq -r .id <<<"$sj")"
    nodes="$(jq -r '.nodes // ""' <<<"$sj")"; nodes="${nodes//[[:space:]]/}"
    path="$(jq -r '.path // ""' <<<"$sj")"; path="${path%/}"
    if [[ -n "$nodes" && ",$nodes," != *",$node,"* ]]; then
        printf "storage '%s' belongs to node(s) %s (storage.cfg: nodes %s), not to %s: enabling it here would point it at this node's spool; %s" \
            "$id" "$nodes" "$nodes" "$node" "$(_integ_sid_hint "$id" "$node")"
        return 0
    fi
    _integ_nodes_shared "$nodes" "$node" || return 0
    local who="every node of the cluster"; [[ -z "$nodes" ]] || who="node(s) $nodes"
    if [[ "$co" == 1 && -n "$path" ]]; then
        printf "storage '%s' serves %s with path %s: --catalog-only would delete that path for all of them, and their PVE jobs would lose their backup target; %s" \
            "$id" "$who" "$path" "$(_integ_sid_hint "$id" "$node")"
    elif [[ "$co" == 0 && "$path" != "$spool" ]]; then
        printf "storage '%s' serves %s with path %s, this node's spool is %s: one path cannot be every node's, and changing it would repoint the others; %s" \
            "$id" "$who" "${path:-(none, catalogue only)}" "$spool" "$(_integ_sid_hint "$id" "$node")"
    fi
    return 0
}

# _integ_timer_on / _integ_timer_off: pbo-catalog.timer enabled and running, or neither.
_integ_timer_on() {
    if systemctl is-enabled "$PBO_CATALOG_TIMER" >/dev/null 2>&1 && systemctl is-active --quiet "$PBO_CATALOG_TIMER" 2>/dev/null; then return 0; fi
    _integ_run systemctl enable --now "$PBO_CATALOG_TIMER" || die "$EX_UNAVAILABLE" "integrate: could not enable $PBO_CATALOG_TIMER (is it installed? $(_integ_install_hint "${mode:-both}"))"
}
_integ_timer_off() {
    if ! systemctl is-enabled "$PBO_CATALOG_TIMER" >/dev/null 2>&1 && ! systemctl is-active --quiet "$PBO_CATALOG_TIMER" 2>/dev/null; then return 0; fi
    _integ_run systemctl disable --now "$PBO_CATALOG_TIMER" || log_warn "integrate: could not disable $PBO_CATALOG_TIMER"
}

# _integ_result <action> <mode>: the outcome (JSON with --json).
_integ_result() {
    local action="$1" mode="$2" steps diffs warns
    steps="$(printf '%s\n' "${INTEG_STEPS[@]+"${INTEG_STEPS[@]}"}" | jq -R . | jq -cs 'map(select(length > 0))')"
    diffs="$(for d in "${INTEG_DIFFS[@]+"${INTEG_DIFFS[@]}"}"; do jq -cn --arg d "$d" '$d'; done | jq -cs .)"
    warns="$(printf '%s\n' "${INTEG_WARNINGS[@]+"${INTEG_WARNINGS[@]}"}" | jq -R . | jq -cs 'map(select(length > 0))')"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_emit "$(jq -cn --arg a "$action" --arg m "$mode" --argjson s "$steps" --argjson d "$diffs" --argjson w "$warns" \
            --argjson co "${INTEG_CATALOG_ONLY:-false}" --arg sid "$(_pve_storage_id)" \
            '{status:(if ($s | length) == 0 then "unchanged" else "ok" end), ok:true, action:$a, mode:$m,
              storage_id:$sid, catalog_only:$co, changed:(($s | length) > 0), steps:$s, diffs:$d, warnings:$w}')"
    elif (( ${#INTEG_STEPS[@]} == 0 )); then
        log_info "integrate $action: nothing to change (mode $mode)"
    elif [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "integrate $action: dry run, ${#INTEG_STEPS[@]} change(s) planned, nothing changed"
    else
        log_info "integrate $action: done, mode $mode (${#INTEG_STEPS[@]} change(s))"
    fi
}

# integrate enable <both|integrated> [--catalog-only] [--yes]
integrate_enable() {
    local mode="" co=0
    INTEG_YES=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            both|integrated) [[ -z "$mode" ]] || die "$EX_USAGE" "integrate enable takes one mode"; mode="$1"; shift ;;
            --catalog-only) co=1; shift ;;
            --yes|-y) INTEG_YES=1; shift ;;
            standalone) die "$EX_USAGE" "integrate enable standalone: use 'pbo integrate disable'" ;;
            *) die "$EX_USAGE" "integrate enable <both|integrated> [--catalog-only] [--yes] (got '$1')" ;;
        esac
    done
    [[ -n "$mode" ]] || die "$EX_USAGE" "integrate enable <both|integrated> [--catalog-only] [--yes]"
    # integrated = only PVE jobs back up, and a catalogue-only storage cannot be a job's target
    [[ "$mode" == integrated && "$co" == 1 ]] && die "$EX_USAGE" "integrate enable integrated --catalog-only: in integrated mode only PVE jobs back up, and a catalogue-only storage is no backup target; use 'both --catalog-only'"
    INTEG_CATALOG_ONLY=false; (( co )) && INTEG_CATALOG_ONLY=true
    _integ_require_change_rights enable
    local id spool="${PVE_SPOOL_DIR%/}" conf="${VZDUMP_CONF:-/etc/vzdump.conf}" node
    # an id PVE refuses stops here, before the lock file, a directory or the
    # catalogue is made
    id="$(_pve_storage_id)"
    _integ_id_valid "$id" || die "$EX_CONFIG" "PVE_STORAGE_ID '$id' is not a valid PVE storage id ($INTEG_ID_RULE)"
    [[ "$spool" == /* ]] || die "$EX_CONFIG" "PVE_SPOOL_DIR must be an absolute path (got '$spool')"
    _integ_lock
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for integrate"
    node="$(_local_node)"

    # 1. preflight: read only, every failure at once
    local fails=() vj why sj hj
    vj="$(_integ_versions_json)"
    why="$(_integ_versions_refusal "$vj")"; [[ -z "$why" ]] || fails+=("$why")
    local pp; pp="$(_integ_plugin_path)"
    if [[ ! -f "$pp" ]]; then
        fails+=("the storage plugin $pp is not installed ($(_integ_install_hint "$mode"))")
    elif ! _integ_plugin_loads; then
        fails+=("the storage plugin $pp does not load into PVE::Storage (perl -MPVE::Storage -e 'PVE::Storage::Plugin->lookup(\"pbo\")')")
    fi
    [[ -r "$RESTIC_PASSWORD_FILE" ]] || fails+=("the DR key $RESTIC_PASSWORD_FILE is missing (run 'pbo setup' first)")
    if [[ -r "$RESTIC_PASSWORD_FILE" ]]; then
        if _catalog_cache_on && ! _restic "$RESTIC_CACHE_REPO" --no-lock cat config >/dev/null 2>&1; then
            fails+=("the cache repo $(_mask_url "$RESTIC_CACHE_REPO") is not readable (pbo init)")
        fi
        if _catalog_offsite_on && ! _restic "$RESTIC_OFFSITE_REPO" --no-lock cat config >/dev/null 2>&1; then
            fails+=("the offsite repo $(_mask_url "$RESTIC_OFFSITE_REPO") is not readable")
        fi
    fi
    if (( ! co )) && ! _integ_same_fs "$spool" "$CACHE_DIR"; then
        fails+=("PVE_SPOOL_DIR $spool is not on the filesystem of CACHE_DIR $CACHE_DIR (ingest renames archives into the cache)")
    fi
    _integ_same_fs "$PVE_STAGING_DIR" "$CACHE_DIR" || fails+=("PVE_STAGING_DIR $PVE_STAGING_DIR is not on the filesystem of CACHE_DIR $CACHE_DIR")
    sj="$(_integ_storage_json "$id")"
    if [[ "$(jq -r '.present and .type != "pbo"' <<<"$sj")" == true ]]; then
        fails+=("PVE already has a storage '$id' of type $(jq -r .type <<<"$sj"): set PVE_STORAGE_ID to a free id")
    fi
    # storage.cfg is cluster-wide: converging an entry another node uses would
    # point it at this node's spool
    local why_other; why_other="$(_integ_storage_other_node "$sj" "$node" "$spool" "$co")"
    [[ -z "$why_other" ]] || fails+=("$why_other")
    # a script: line naming a missing hook fails every vzdump on the node
    if (( ! co )) && [[ ! -x "$(_integ_hook_path)" ]]; then
        fails+=("the vzdump hook $(_integ_hook_path) is missing or not executable ($(_integ_install_hint "$mode"))")
    fi
    hj="$(_integ_hook_json)"
    local foreign; foreign="$(jq -r '.foreign_script // empty' <<<"$hj")"
    if (( ! co )) && [[ -n "$foreign" ]]; then
        fails+=("$conf already runs a hook script (script: $foreign). vzdump runs only one, so pbo's hook would replace it; merge them by hand, or use --catalog-only (no backup target)")
    fi
    if (( ${#fails[@]} )); then
        local f; for f in "${fails[@]}"; do log_warn "integrate enable: $f"; done
        die "$EX_UNAVAILABLE" "integrate enable $mode refused, nothing was changed: $(IFS=';'; printf '%s' "${fails[*]}" | sed 's/;/; /g')"
    fi
    if (( co )); then
        # step 5 strips our hook line (a downgrade from a full enable); say so only then
        local cnote="$conf is not touched"
        if [[ -f "$conf" ]] && ! cmp -s -- "$conf" <(_integ_conf_strip "$conf"); then
            cnote="pbo's hook line is removed from $conf (a foreign one stays)"
        fi
        _integ_confirm "Turn on the Proxmox integration ($mode, catalogue only): storage '$id' (browse and restore, no backup target), $PBO_CATALOG_TIMER? $cnote"
    else
        _integ_confirm "Turn on the Proxmox integration ($mode): storage '$id' (backup target, spool $spool), the hook line in $conf, $PBO_CATALOG_TIMER?"
    fi
    [[ "${DRY_RUN:-0}" == 1 ]] || audit_log "integrate enable mode=$mode storage=$id catalog_only=$INTEG_CATALOG_ONLY"

    # 2. the catalogue first: without it the storage lists nothing
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] would run: pbo catalog refresh → $PBO_CATALOG"
    else
        local rc=0
        ( _close_lock_fds; "${SELF_DIR}/pbo" catalog refresh ) >&2 || rc=$?
        (( rc == 0 )) || die "$EX_UNAVAILABLE" "integrate enable: the catalogue refresh failed (exit $rc), nothing in PVE was changed"
    fi

    # 3. directories (before the storage: activate_storage needs its path)
    if (( ! co )) && [[ ! -d "$spool/dump" ]]; then
        _integ_run install -d -m 0755 "$spool" "$spool/dump" || die "$EX_CANTCREAT" "integrate: cannot create $spool/dump"
        [[ "${DRY_RUN:-0}" == 1 ]] || _cache_dir_protect
    fi
    if [[ ! -d "$PVE_STAGING_DIR" ]]; then
        _integ_run install -d -m 0700 "$PVE_STAGING_DIR" || die "$EX_CANTCREAT" "integrate: cannot create $PVE_STAGING_DIR"
    fi

    # 4. the storage
    local want_path=""; (( co )) || want_path="$spool"
    if [[ "$(jq -r .present <<<"$sj")" != true ]]; then
        local args=(--content backup --nodes "$node"); [[ -n "$want_path" ]] && args+=(--path "$want_path")
        _integ_run pvesm add pbo "$id" "${args[@]}" || die "$EX_UNAVAILABLE" "integrate: pvesm add pbo $id failed"
    else
        local have_path have_content
        have_path="$(jq -r '.path // ""' <<<"$sj")"; have_path="${have_path%/}"
        have_content="$(jq -r '.content // ""' <<<"$sj")"
        if [[ -n "$want_path" && "$have_path" != "$want_path" ]]; then
            _integ_run pvesm set "$id" --path "$want_path" || die "$EX_UNAVAILABLE" "integrate: pvesm set $id --path failed"
        elif [[ -z "$want_path" && -n "$have_path" ]]; then
            _integ_run pvesm set "$id" --delete path || die "$EX_UNAVAILABLE" "integrate: pvesm set $id --delete path failed"
        fi
        if [[ ",$have_content," != *,backup,* ]]; then
            _integ_run pvesm set "$id" --content backup || die "$EX_UNAVAILABLE" "integrate: pvesm set $id --content failed"
        fi
        if [[ "$(jq -r .disabled <<<"$sj")" == true ]]; then
            _integ_run pvesm set "$id" --delete disable || die "$EX_UNAVAILABLE" "integrate: pvesm set $id --delete disable failed"
        fi
    fi

    # 5. the hook line (--catalog-only: ours goes, a foreign one stays)
    local new; new="$(mktemp)"
    if (( co )); then _integ_conf_strip "$conf" > "$new"
    else _integ_conf_with_hook "$conf" "$(_integ_hook_path)" > "$new"; fi
    if [[ -f "$conf" || -s "$new" ]]; then _integ_write_file "$conf" "$new"; fi
    rm -f "$new"

    # 6. the catalogue timer
    _integ_timer_on

    # 7. who else can restore from the GUI (not isolated)
    local l
    while IFS= read -r l; do
        [[ -n "$l" ]] || continue
        INTEG_WARNINGS+=("$l on storage '$id': GUI restores are not isolated, keep the storage admin-only")
        log_warn "integrate: ${INTEG_WARNINGS[-1]}"
    done < <(_integ_acl_lines "$id")

    # 8. the mode, last (with a derived per-node storage id pinned beside it)
    _integ_set_mode "$mode" "$(_integ_pin_id "$id")"
    _integ_result enable "$mode"
}

# integrate disable [--yes]
integrate_disable() {
    INTEG_YES=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) INTEG_YES=1; shift ;;
            *) die "$EX_USAGE" "integrate disable [--yes] (got '$1')" ;;
        esac
    done
    _integ_require_change_rights disable
    _integ_lock
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for integrate"
    local id spool="${PVE_SPOOL_DIR%/}" conf="${VZDUMP_CONF:-/etc/vzdump.conf}" sj node snodes
    id="$(_pve_storage_id)"; node="$(_local_node)"
    sj="$(_integ_storage_json "$id")"
    snodes="$(jq -r '.nodes // ""' <<<"$sj")"; snodes="${snodes//[[:space:]]/}"
    # another node's storage (a config copied from that node names its pinned
    # id): its jobs are not counted below (they do not serve this node), and
    # `pvesm remove` would delete it for the whole cluster. Refused before any
    # change, so disable stays all-or-nothing, as enable is.
    if [[ "$(jq -r '.present and .type == "pbo"' <<<"$sj")" == true && -n "$snodes" && ",$snodes," != *",$node,"* ]]; then
        die "$EX_CONFIG" "integrate disable: storage '$id' belongs to node(s) $snodes, not $node: removing it here would delete it for the whole cluster. Unset PVE_STORAGE_ID on this node (pbo config unset PVE_STORAGE_ID) and run 'pbo integrate disable' again; nothing was changed"
    fi

    # 1. no enabled PVE job may still write to pbo
    _guest_meta_load
    _pve_jobs_reset; PBO_INTEGRATION=both _pve_jobs_load
    if ! _pve_owner_known; then
        die "$EX_UNAVAILABLE" "integrate disable: cannot tell whether a PVE backup job still uses the pbo storage (${_PVE_OWNER_ERR}); nothing was changed"
    fi
    local busy
    busy="$(jq -r '[.[] | select(.enabled) | "\(if .id == "" then "(no id)" else .id end) (storage \(.storage), guests \(.guests | join(" ") | if . == "" then "none here" else . end))"] | join(", ")' <<<"$_PVE_PBO_JOBS")"
    if [[ -n "$busy" ]]; then
        die "$EX_UNAVAILABLE" "integrate disable: enabled PVE backup job(s) still write to a pbo storage: $busy. Disable them or point them at another storage in Datacenter -> Backup, then run 'pbo integrate disable' again. Nothing was changed."
    fi
    local off; off="$(jq -r '[.[] | select(.enabled | not) | .id] | join(", ")' <<<"$_PVE_PBO_JOBS")"
    _pve_jobs_reset
    _integ_confirm "Turn off the Proxmox integration: storage '$id', $conf, $PBO_CATALOG_TIMER?"
    [[ "${DRY_RUN:-0}" == 1 ]] || audit_log "integrate disable storage=$id"

    # 2. standalone first: from here pbo.timer backs up every guest again
    _integ_set_mode standalone

    # 3. the spool must be empty
    local left=()
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] would run: pbo ingest --pending"
    elif [[ -d "$spool/dump" ]]; then
        local rc=0
        ( _close_lock_fds; "${SELF_DIR}/pbo" ingest --pending ) >&2 || rc=$?
        (( rc == 0 )) || log_warn "integrate disable: ingest --pending ended with exit $rc"
    fi
    if [[ -d "$spool/dump" ]]; then
        mapfile -t left < <(find "$spool/dump" -maxdepth 1 -type f -name 'vzdump-*' ! -name '*.log' ! -name '*.notes' -printf '%f\n' 2>/dev/null | sort)
    fi
    if (( ${#left[@]} )); then
        if [[ "${DRY_RUN:-0}" == 1 ]]; then
            INTEG_WARNINGS+=("the spool holds ${#left[@]} archive(s) (${left[*]}): disable stops here unless 'pbo ingest --pending' takes them")
            log_warn "integrate: ${INTEG_WARNINGS[-1]}"
        else
            die "$EX_TEMPFAIL" "integrate disable: ${#left[@]} archive(s) are still in the spool $spool/dump (${left[*]}): 'pbo ingest --pending' takes archives older than ${INGEST_PENDING_MIN:-10} minutes; run 'pbo integrate disable' again after that. PBO_INTEGRATION is already standalone; the storage and the hook stay until then."
        fi
    fi

    # 4. our hook line(s) only
    if [[ -f "$conf" ]]; then
        local new; new="$(mktemp)"
        _integ_conf_strip "$conf" > "$new"
        _integ_write_file "$conf" "$new"
        rm -f "$new"
    fi

    # 5. the restore side: mount off, staging empty
    if _catalog_mount_active; then
        _integ_run systemctl stop "$PBO_MOUNT_UNIT" || log_warn "integrate: could not stop $PBO_MOUNT_UNIT"
    fi
    if [[ -d "$PVE_STAGING_DIR" && ! -L "$PVE_STAGING_DIR" ]]; then
        local staged=()
        mapfile -t staged < <(find "$PVE_STAGING_DIR" -maxdepth 1 -mindepth 1 \( -type f -o -type l \) -name 'vzdump-*' 2>/dev/null | sort)
        (( ${#staged[@]} )) && { _integ_run rm -f -- "${staged[@]}" || log_warn "integrate: could not empty $PVE_STAGING_DIR"; }
    fi

    # 6. the storage. One that serves other nodes too (no `nodes`, or a list
    # with others, in a cluster) is cluster-wide: removing it would take it from
    # them while they still run in integration mode. This node is taken off its
    # `nodes` instead, so only the last node removes it.
    local others=''
    if [[ "$(jq -r '.present and .type == "pbo"' <<<"$sj")" == true ]] && _integ_nodes_shared "$snodes" "$node"; then
        local n
        if [[ -n "$snodes" ]]; then
            for n in ${snodes//,/ }; do [[ "$n" == "$node" ]] || others+="${others:+,}$n"; done
        else
            while IFS= read -r n; do [[ -z "$n" || "$n" == "$node" ]] || others+="${others:+,}$n"; done < <(_cluster_node_names)
        fi
    fi
    if [[ -n "$others" ]]; then
        _integ_run pvesm set "$id" --nodes "$others" || die "$EX_UNAVAILABLE" "integrate disable: pvesm set $id --nodes $others failed (PBO_INTEGRATION is standalone, the hook line is gone; run 'pbo integrate disable' again)"
        INTEG_WARNINGS+=("storage '$id' serves other nodes too: it stays for node(s) $others (storage.cfg: nodes $others), this node is no longer one of them")
        log_warn "integrate: ${INTEG_WARNINGS[-1]}"
    elif [[ "$(jq -r '.present and .type == "pbo"' <<<"$sj")" == true ]] && _integ_nodes_shared "$snodes" "$node"; then
        # shared, but the member list names no other node: not removed blind
        INTEG_WARNINGS+=("storage '$id' serves every node of the cluster and the member list names no other node: left in storage.cfg; remove it with 'pvesm remove $id' once no node uses it")
        log_warn "integrate: ${INTEG_WARNINGS[-1]}"
    elif [[ "$(jq -r '.present and .type == "pbo"' <<<"$sj")" == true ]]; then
        _integ_run pvesm remove "$id" || die "$EX_UNAVAILABLE" "integrate disable: pvesm remove $id failed (PBO_INTEGRATION is standalone, the hook line is gone; run 'pbo integrate disable' again)"
    elif [[ "$(jq -r .present <<<"$sj")" == true ]]; then
        log_warn "integrate disable: storage '$id' is of type $(jq -r .type <<<"$sj"), not pbo: left alone"
    fi
    [[ -n "$off" ]] && { INTEG_WARNINGS+=("disabled PVE job(s) $off still name a pbo storage: delete them or point them elsewhere in Datacenter -> Backup"); log_warn "integrate: ${INTEG_WARNINGS[-1]}"; }

    # 7. the catalogue timer
    _integ_timer_off

    _integ_result disable standalone
    if [[ "${JSON_OUTPUT:-0}" != 1 && "${DRY_RUN:-0}" != 1 ]]; then
        printf '%s\n' "The storage plugin is still installed (harmless while no storage uses it). To remove it: $(_integ_remove_hint)"
    fi
}

# --- doctor ----------------------------------------------------------------------
# _doctor_integration_setup <ok> <bad> <warn>: the setup half of doctor's
# integration section (lib/ownership.sh _doctor_integration calls it). Appends to
# DI_LINES / DI_PROBLEMS / DI_WARNS.
#   standalone: WARN when storage.cfg still has a pbo storage (no pvesh call)
#   otherwise:
#     FAIL  PVE older than the minimum; plugin missing or not loadable; storage
#           missing or of another type; with a spool path: the hook missing,
#           foreign or not executable, the path not PVE_SPOOL_DIR, the spool on
#           another filesystem than the cache, spool archives or failed offsite
#           copies of ingested snapshots older than 24 h;
#           an enabled pbo job with its own script, compression, prune-backups or
#           protected, or a stop-mode guest in a job of another mode
#     WARN  PVE newer than the tested set; no catalogue or an old one; a disabled
#           pbo job; notification-mode none; a job within an hour of a pbo timer;
#           ACLs for others than root; less spool space than the largest archive,
#           or than a stop-mode job's guests together
_doctor_integration_setup() {
    local ok="$1" bad="$2" warn="$3" mode id
    mode="$(_integration_mode)"; id="$(_pve_storage_id)"
    _di_bad()  { DI_LINES+=("$bad  $1"); DI_PROBLEMS=$((DI_PROBLEMS+1)); }
    _di_warn() { DI_LINES+=("$warn  $1"); DI_WARNS=$((DI_WARNS+1)); }
    if [[ "$mode" == standalone ]]; then
        local ids; ids="$(_integ_cfg_pbo_ids | paste -sd' ' -)"
        [[ -z "$ids" ]] || _di_warn "storage.cfg has a pbo storage ($ids) but PBO_INTEGRATION=standalone: pbo.timer backs up every guest anyway ('pbo integrate enable both', or 'pbo integrate disable')"
        return 0
    fi

    # versions and the plugin
    local vj; vj="$(_integ_versions_json)"
    local why; why="$(_integ_versions_refusal "$vj")"
    [[ -z "$why" ]] || _di_bad "$why"
    local nv; nv="$(jq -r '[.[] | select(.newer_than_tested) | "\(.package) \(.installed) (tested \(.tested))"] | join(", ")' <<<"$vj")"
    [[ -z "$nv" ]] || _di_warn "PVE is newer than the set the plugin was tested with: $nv; run tests/integration/pve-storage.sh --load-only"
    local pp; pp="$(_integ_plugin_path)"
    if [[ ! -f "$pp" ]]; then _di_bad "storage plugin $pp missing ($(_integ_install_hint "$mode"))"
    elif ! _integ_plugin_loads; then _di_bad "storage plugin $pp does not load into PVE::Storage (journalctl -u pvedaemon)"
    else DI_LINES+=("$ok  storage plugin loaded ($pp)"); fi

    # the storage
    local sj path=""
    sj="$(_integ_storage_json "$id")"
    if [[ "$(jq -r .present <<<"$sj")" != true ]]; then
        _di_bad "storage '$id' is not in ${PVE_STORAGE_CFG:-/etc/pve/storage.cfg} ('pbo integrate enable $mode')"
    elif [[ "$(jq -r .type <<<"$sj")" != pbo ]]; then
        _di_bad "storage '$id' is of type $(jq -r .type <<<"$sj"), not pbo"
    else
        path="$(jq -r '.path // ""' <<<"$sj")"; path="${path%/}"
        local snodes node; snodes="$(jq -r '.nodes // ""' <<<"$sj")"; snodes="${snodes//[[:space:]]/}"; node="$(_local_node)"
        if [[ -n "$snodes" && ",$snodes," != *",$node,"* ]]; then
            _di_bad "storage '$id' is limited to node(s) $snodes, not $node: PVE runs no backup of this node on it ($(_integ_sid_hint "$id" "$node"), then 'pbo integrate enable $mode')"
            path=""
        else
            DI_LINES+=("$ok  storage '$id' (pbo, $( [[ -n "$path" ]] && echo "backup target, spool $path" || echo "catalogue only"))")
        fi
        [[ "$(jq -r .disabled <<<"$sj")" == true ]] && _di_warn "storage '$id' is disabled in PVE"
        # a cluster that still has the one shared id of before 0.6. Only an
        # entry that serves more than this node: one made before 0.6 with
        # `nodes <this node>` is already this node's own storage, and the id
        # rule keeps it.
        local nn; nn="$(_cluster_node_count)"
        if [[ "$id" == pbo ]] && (( nn > 1 )) && _integ_nodes_shared "$snodes" "$node"; then
            _di_warn "storage 'pbo' in a cluster of $nn nodes serves $( [[ -z "$snodes" ]] && echo "every node" || echo "node(s) $snodes"): storage.cfg holds one path for every node it serves, so each node should have its own storage (pbo-$node). To move, on each node in turn: disable or retarget this node's PVE jobs that use 'pbo' (Datacenter -> Backup), 'pbo integrate disable' (it takes this node off the entry's nodes; the last node removes it), 'pbo config set PVE_STORAGE_ID pbo-$node', 'pbo integrate enable $mode', then recreate the jobs for this node with storage pbo-$node by hand (pbo never edits jobs.cfg)"
        fi
    fi

    # the backup target: hook and spool
    local hj spj
    hj="$(_integ_hook_json)"; spj="$(_integ_spool_json)"
    if [[ -n "$path" ]]; then
        if [[ "$(jq -r .configured <<<"$hj")" != true ]]; then
            _di_bad "no hook in ${VZDUMP_CONF:-/etc/vzdump.conf}: PVE jobs to '$id' are never ingested ('pbo integrate enable $mode')"
        elif [[ "$(jq -r .ours <<<"$hj")" != true ]]; then
            _di_bad "${VZDUMP_CONF:-/etc/vzdump.conf} runs a foreign hook (script: $(jq -r .path <<<"$hj")): PVE jobs to '$id' are never ingested"
        elif [[ "$(jq -r .executable <<<"$hj")" != true ]]; then
            _di_bad "the hook $(jq -r .path <<<"$hj") is missing or not executable: every vzdump on this node fails"
        else
            DI_LINES+=("$ok  vzdump hook $(jq -r .path <<<"$hj")")
        fi
        [[ "$path" == "${PVE_SPOOL_DIR%/}" ]] || _di_bad "storage '$id' has path $path, PVE_SPOOL_DIR is ${PVE_SPOOL_DIR%/}: ingest refuses its archives ('pbo integrate enable $mode' converges it)"
    fi
    if [[ -n "$path" || "$(jq -r .files <<<"$spj")" != 0 ]]; then
        [[ "$(jq -r .same_fs_as_cache <<<"$spj")" == true ]] || _di_bad "the spool ${PVE_SPOOL_DIR%/} is not on CACHE_DIR's filesystem: ingest cannot rename archives into the cache"
        local age n maxage; n="$(jq -r .files <<<"$spj")"; age="$(jq -r '.oldest_age // 0' <<<"$spj")"
        _cfg_int_r PVE_SPOOL_MAX_AGE; maxage="$_CI_R"
        if (( n > 0 && age > maxage )); then
            _di_bad "$n archive(s) in the spool, the oldest $(( age / 3600 ))h old: ingest failed ('pbo ingest --pending', see the PVE task log)"
        elif (( n > 0 )); then
            _di_warn "$n archive(s) waiting in the spool (ingest --pending takes them)"
        fi
    fi
    # ingested snapshots whose offsite copy failed (recorded for ingest --pending)
    local nc oldc smax
    nc="$(_ingest_copy_list | wc -l)"
    _cfg_int_r PVE_SPOOL_MAX_AGE; smax="$_CI_R"
    if (( nc > 0 )); then
        oldc="$(find "$(_ingest_copy_dir)" -maxdepth 1 -type f -name '*_*' -mmin +$(( smax / 60 )) 2>/dev/null | wc -l)"
        if (( oldc > 0 )); then
            _di_bad "$nc ingested snapshot(s) are in the cache repo but not offsite, $oldc for more than $(( smax / 3600 ))h: run 'pbo ingest --pending' (records in $(_ingest_copy_dir))"
        else
            _di_warn "$nc ingested snapshot(s) wait for their offsite copy (ingest --pending takes them)"
        fi
    fi

    # the catalogue
    local cj; cj="$(_integ_catalog_json)"
    if [[ "$(jq -r .present <<<"$cj")" != true ]]; then
        _di_warn "no catalogue at $PBO_CATALOG: the PVE storage view fails ('pbo catalog refresh')"
    else
        local cage; cage="$(jq -r .age_s <<<"$cj")"
        if (( cage > ${CATALOG_MAX_AGE:-7200} )); then _di_warn "catalogue is $(( cage / 60 )) min old (> $(( ${CATALOG_MAX_AGE:-7200} / 60 )) min): is pbo-catalog.timer running?"
        else DI_LINES+=("$ok  catalogue $(jq -r .entries <<<"$cj") archive(s), $(( cage / 60 )) min old"); fi
        local big free
        big="$(jq -r '.largest_bytes // 0' <<<"$cj")"; free="$(jq -r '.free_bytes // empty' <<<"$spj")"
        if [[ -n "$path" && -n "$free" ]] && (( free < big )); then
            _di_warn "spool filesystem has $free bytes free, the largest archive is $big bytes: a PVE job may run out of space"
        fi
    fi

    # the jobs (ownership is already loaded by doctor)
    local sfree; sfree="$(jq -r '.free_bytes // empty' <<<"$spj")"
    if _pve_owner_known; then
        local jj j jid
        jj="$(_integ_jobs_json)"
        while IFS= read -r j; do
            [[ -n "$j" ]] || continue
            jid="$(jq -r '.id' <<<"$j")"
            if [[ "$(jq -r .enabled <<<"$j")" == true ]]; then
                while IFS= read -r l; do [[ -n "$l" ]] && _di_bad "PVE job $jid: $l"; done < <(jq -r '.problems[]' <<<"$j")
                # stop mode: every guest's archive waits in the spool until job-end
                if [[ "$(jq -r .mode <<<"$j")" == stop && -n "$path" && -n "$sfree" ]]; then
                    local need gl; gl="$(jq -r '.guests | join(" ")' <<<"$j")"
                    # shellcheck disable=SC2086  # gl is a list of vmids
                    need="$(_integ_stop_spool_need $gl)"
                    (( need > sfree )) && _di_warn "PVE job $jid runs in stop mode: its archives wait in the spool until job-end, about $need bytes for guest(s) $gl (their newest archives), the spool has $sfree bytes free"
                fi
            fi
            while IFS= read -r l; do [[ -n "$l" ]] && _di_warn "PVE job $jid: $l"; done < <(jq -r '.warnings[]' <<<"$j")
        done < <(jq -c '.[]' <<<"$jj" 2>/dev/null)
    fi

    # who can restore from the GUI
    local l
    while IFS= read -r l; do [[ -n "$l" ]] && _di_warn "$l on storage '$id': GUI restores are not isolated, keep the storage admin-only"; done < <(_integ_acl_lines "$id")
    return 0
}

# rdo_integrate <status|enable|disable> ...: the `pbo integrate` dispatcher.
rdo_integrate() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        status)  _is_janitor && die "$EX_CONFIG" "integrate: a janitor has no Proxmox (PBO_ROLE=janitor)"; integrate_status "$@" ;;
        enable)  integrate_enable "$@" ;;
        disable) integrate_disable "$@" ;;
        *) die "$EX_USAGE" "integrate status | enable <both|integrated> [--catalog-only] [--yes] | disable [--yes]" ;;
    esac
}
