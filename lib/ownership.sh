# shellcheck shell=bash
# lib/ownership.sh: which guests a PVE backup job owns (ADR 0007).
#
# PBO_INTEGRATION=standalone (default): pbo.timer owns every guest and nothing
# here calls pvesh. In `both` and `integrated` a guest on this node is owned by
# PVE when an enabled backup job that targets a `pbo` storage selects it; every
# other guest belongs to the pbo timer (`both`) or to nobody (`integrated`, a
# doctor FAIL).
#
# A pbo job is an entry from `pvesh get /cluster/backup` that
#   - is enabled (the `enabled` field absent or true; PVE's scheduler skips only
#     an explicit false),
#   - has no `dumpdir`,
#   - runs here (`node` unset or this node),
#   - has an effective storage of type pbo: the job's `storage`, else the
#     `storage:` line of vzdump.conf, else `local` (no storage at all when
#     vzdump.conf has only a `dumpdir:`), as vzdump resolves it.
# Selection follows vzdump's get_included_guests: `pool`, else `vmid`, else
# `all` minus `exclude`, else nothing; then intersected with this node's guests.
# A guest selected by several jobs belongs to the first one (the overlap is
# recorded for doctor).
#
# Fail open: when ownership cannot be computed (pvesh fails, unreadable output,
# no storage list, a pool job without a resource view) no guest is PVE-owned,
# so the timer backs up every guest. The worst case is a guest backed up twice,
# never one with no backup.
#
# Results are cached per process. Load them in the main shell
# (`_pve_jobs_load`) before calling the helpers from a $(...) or <(...):
# a subshell's cache dies with it.

declare -A _PVE_OWNER=() _PVE_OVERLAP=()
_PVE_JOBS_LOADED=0
_PVE_OWNER_OK=1          # 0 = ownership unknown, fail open
_PVE_OWNER_ERR=""        # why it is unknown
_PVE_PBO_STORAGES=""     # pbo storage ids, one per line
_PVE_DEFAULT_STORAGE=""  # vzdump.conf storage for jobs without one ("" = none, a dumpdir)
_PVE_PBO_JOBS='[]'       # every job that targets pbo here (enabled or not), with its local guests

# _integration_mode → standalone | both | integrated (an invalid value counts as
# standalone; doctor names it, lib/common.sh _config_check).
_integration_mode() {
    local m="${PBO_INTEGRATION:-standalone}"
    case "$m" in both|integrated) printf '%s' "$m" ;; *) printf standalone ;; esac
}
_integration_standalone() { [[ "$(_integration_mode)" == standalone ]]; }

# _vzdump_default_storage <vzdump.conf> → the storage vzdump uses for a job without
# storage/dumpdir: `storage:` from vzdump.conf, else nothing when it sets a
# `dumpdir:`, else `local`. The last line wins, as in PVE's parser.
_vzdump_default_storage() {
    local f="$1" s="" d=""
    if [[ -r "$f" ]]; then
        s="$(sed -nE 's/^storage:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$f" | tail -1)"
        d="$(sed -nE 's/^dumpdir:[[:space:]]*([^[:space:]].*)$/\1/p' "$f" | tail -1)"
    fi
    if [[ -n "$s" ]]; then printf '%s' "$s"
    elif [[ -n "$d" ]]; then printf ''
    else printf local; fi
}

# _pve_pbo_storage_ids → ids of storages of type pbo, one per line. From the API;
# when that fails, from the `pbo: <id>` stanzas of storage.cfg. Returns 1 when
# neither can be read.
_pve_pbo_storage_ids() {
    local j
    if j="$(pvesh get /storage --output-format json 2>/dev/null)" && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$j"; then
        jq -r '.[] | select(type == "object" and .type == "pbo") | .storage // empty' <<<"$j"
        return 0
    fi
    local cfg="${PVE_STORAGE_CFG:-/etc/pve/storage.cfg}"
    [[ -r "$cfg" ]] || return 1
    sed -nE 's/^pbo:[[:space:]]+([A-Za-z0-9][A-Za-z0-9._-]*)[[:space:]]*$/\1/p' "$cfg"
    return 0
}

# _pve_local_guests_json → [{vmid, pool}] for the guests on this node: from the
# resource view (lib/policy.sh), else from pct/qm list (no pools then).
_pve_local_guests_json() {
    local id
    if (( ${#_GM_TYPE[@]} )); then
        for id in "${!_GM_TYPE[@]}"; do printf '%s\t%s\n' "$id" "${_GM_POOL[$id]:-}"; done
    else
        _all_local_vmids | while read -r id; do printf '%s\t\n' "$id"; done
    fi | jq -R -c 'split("\t") | {vmid: .[0], pool: (.[1] // "")}' | jq -cs 'map(select(.vmid | test("^[0-9]+$"))) | sort_by(.vmid | tonumber)'
}

# _pve_owner_fail <reason>: ownership unknown → fail open.
_pve_owner_fail() {
    _PVE_OWNER_OK=0; _PVE_OWNER_ERR="$1"; _PVE_OWNER=(); _PVE_OVERLAP=()
    log_warn "ownership: $1; treating every guest as owned by pbo.timer (fail open)"
}

# _pve_jobs_load: compute ownership once per process. Standalone: no calls.
_pve_jobs_load() {
    (( _PVE_JOBS_LOADED )) && return 0
    _PVE_JOBS_LOADED=1
    _integration_standalone && return 0
    command -v pvesh >/dev/null 2>&1 || { _pve_owner_fail "pvesh not found"; return 0; }
    _guest_meta_load

    local stores
    if ! stores="$(_pve_pbo_storage_ids)"; then
        _pve_owner_fail "cannot list the PVE storages (pvesh get /storage failed, ${PVE_STORAGE_CFG:-/etc/pve/storage.cfg} unreadable)"
        return 0
    fi
    _PVE_PBO_STORAGES="$stores"
    local jobs
    if ! jobs="$(pvesh get /cluster/backup --output-format json 2>/dev/null)" \
       || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$jobs"; then
        _pve_owner_fail "cannot read the PVE backup jobs (pvesh get /cluster/backup failed)"
        return 0
    fi
    _PVE_DEFAULT_STORAGE="$(_vzdump_default_storage "${VZDUMP_CONF:-/etc/vzdump.conf}")"
    local guests; guests="$(_pve_local_guests_json)" || guests='[]'
    [[ -n "$guests" ]] || guests='[]'

    local sel
    sel="$(jq -c --arg node "$(_local_node)" --arg def "$_PVE_DEFAULT_STORAGE" \
        --argjson stores "$(printf '%s\n' "$stores" | jq -R . | jq -cs 'map(select(length > 0))')" \
        --argjson guests "$guests" '
        # PVE::ParseUtils::split_list: , ; and whitespace separate
        def list: if . == null then [] else (tostring | gsub("[,;]"; " ") | split(" ") | map(select(length > 0))) end;
        # perl truth: absent, "", "0" and false are false
        def truthy: . != null and . != false and ((tostring) as $e | $e != "" and $e != "0");
        def str: if . == null then "" else tostring end;
        ($guests | map({key: .vmid, value: true}) | from_entries) as $here
        | ($stores | map({key: ., value: true}) | from_entries) as $isPbo
        | [ .[] | select(type == "object")
            | select((.dumpdir | str) == "")
            | select((.node | str) as $n | $n == "" or $n == $node)
            | ((.storage | str) as $s | if $s != "" then $s else $def end) as $st
            | select($st != "" and ($isPbo[$st] // false))
            | . as $j
            | (if (.pool | truthy) then "pool" elif (.vmid | truthy) then "vmid" elif (.all | truthy) then "all" else "none" end) as $how
            | (if $how == "pool" then [ $guests[] | select(.pool == ($j.pool | tostring)) | .vmid ]
               elif $how == "vmid" then [ $j.vmid | list | .[] | select(test("^[0-9]+$")) | select($here[.] // false) ]
               elif $how == "all" then ($j.exclude | list | map({key: ., value: true}) | from_entries) as $ex
                    | [ $guests[].vmid | select(($ex[.] // false) | not) ]
               else [] end) as $g
            | { id: (.id | str), enabled: (if .enabled == null then true else (.enabled | truthy) end),
                storage: $st, selection: $how, pool: (if $how == "pool" then (.pool | tostring) else null end),
                mode: (.mode // null), schedule: (.schedule // .starttime // null),
                next_run: (.["next-run"] // null), compress: (.compress // null), script: (.script // null),
                prune_backups: (.["prune-backups"] // null), protected: (.protected // null),
                notification_mode: (.["notification-mode"] // null),
                guests: ($g | unique_by(tonumber) | sort_by(tonumber)) } ]' <<<"$jobs" 2>/dev/null)" || sel=""
    if [[ -z "$sel" ]]; then _pve_owner_fail "cannot parse the PVE backup jobs"; return 0; fi
    # A pool job needs the resource view for pool membership: without it the
    # selection is unknown, not empty.
    if (( ! _GM_OK )) && jq -e 'any(.[]; .enabled and .selection == "pool")' >/dev/null 2>&1 <<<"$sel"; then
        _pve_owner_fail "a pbo job selects a pool but the cluster resource view is unreadable"
        return 0
    fi
    _PVE_PBO_JOBS="$sel"

    local id jid
    while IFS=$'\t' read -r jid id; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        if [[ -z "${_PVE_OWNER[$id]:-}" ]]; then _PVE_OWNER[$id]="$jid"; _PVE_OVERLAP[$id]="$jid"
        else _PVE_OVERLAP[$id]+=" $jid"; fi
    done < <(jq -r '.[] | select(.enabled) | .id as $j | .guests[] | "\(if $j == "" then "(no id)" else $j end)\t\(.)"' <<<"$sel")
    # only guests in two or more jobs stay in the overlap list
    for id in "${!_PVE_OVERLAP[@]}"; do [[ "${_PVE_OVERLAP[$id]}" == *" "* ]] || unset '_PVE_OVERLAP[$id]'; done
    return 0
}

# _pve_jobs_reset: forget the cached ownership (tests, a long-running caller).
_pve_jobs_reset() {
    _PVE_OWNER=(); _PVE_OVERLAP=(); _PVE_JOBS_LOADED=0; _PVE_OWNER_OK=1; _PVE_OWNER_ERR=""
    _PVE_PBO_STORAGES=""; _PVE_DEFAULT_STORAGE=""; _PVE_PBO_JOBS='[]'
}

# _pve_owner_known: 0 when ownership was computed (always in standalone).
_pve_owner_known() { _pve_jobs_load; (( _PVE_OWNER_OK )); }

# _pve_owner_job <vmid> → the id of the PVE job that owns the guest, empty if none.
_pve_owner_job() { _pve_jobs_load; printf '%s' "${_PVE_OWNER[$1]:-}"; }

# _pve_owned_guests → the PVE-owned vmids on this node, numeric order.
_pve_owned_guests() {
    _pve_jobs_load
    (( ${#_PVE_OWNER[@]} )) || return 0
    printf '%s\n' "${!_PVE_OWNER[@]}" | sort -n
}

# _pve_overlap_guests → "<vmid>\t<job> <job>..." for guests in more than one pbo job.
_pve_overlap_guests() {
    _pve_jobs_load
    local id
    for id in $(printf '%s\n' "${!_PVE_OVERLAP[@]}" | sort -n); do printf '%s\t%s\n' "$id" "${_PVE_OVERLAP[$id]}"; done
    return 0
}

# _pve_jobs_json → every job that targets a pbo storage on this node, enabled
# or not: [{id, enabled, storage, selection, pool, mode, schedule, next_run,
# compress, script, prune_backups, protected, notification_mode, guests}]
# (the job's own values, null when it leaves them to vzdump.conf).
_pve_jobs_json() { _pve_jobs_load; printf '%s' "$_PVE_PBO_JOBS"; }

# _guest_owner <vmid> → pve:<jobid> | pbo | none
#   pve:<jobid>  an enabled pbo job backs it up (pbo-skip does not matter: the job wins)
#   pbo          pbo.timer backs it up
#   none         nobody on a schedule: tagged pbo-skip, or `integrated` without a job
_guest_owner() {
    local id="$1" j
    _pve_jobs_load
    j="${_PVE_OWNER[$id]:-}"
    if [[ -n "$j" ]]; then printf 'pve:%s' "$j"; return 0; fi
    if _guest_skipped "$id"; then printf none; return 0; fi
    if [[ "$(_integration_mode)" == integrated ]] && (( _PVE_OWNER_OK )); then printf none; return 0; fi
    printf pbo
}

# _doctor_integration <ok> <bad> <warn>: the Proxmox integration section of
# doctor. Fills DI_LINES, DI_PROBLEMS, DI_WARNS (the AO_* pattern). Host only.
#   FAIL  integrated: a guest nothing backs up
#   WARN  ownership unknown (fail open), pbo-skip on a PVE-owned guest, a guest
#         in two pbo jobs
# plus, with lib/integrate.sh loaded, _doctor_integration_setup.
_doctor_integration() {
    local ok="$1" bad="$2" warn="$3" mode id j
    DI_LINES=(); DI_PROBLEMS=0; DI_WARNS=0
    mode="$(_integration_mode)"
    if [[ "$mode" == standalone ]]; then
        DI_LINES+=("$ok  integration: standalone (pbo.timer backs up every guest)")
        _doctor_integration_more "$ok" "$bad" "$warn"
        return 0
    fi
    _pve_jobs_load
    if ! _pve_owner_known; then
        DI_LINES+=("$warn  integration: $mode, guest ownership unknown (${_PVE_OWNER_ERR}): pbo.timer backs up every guest (fail open)")
        DI_WARNS=$((DI_WARNS+1))
        _doctor_integration_more "$ok" "$bad" "$warn"
        return 0
    fi
    local owned njobs
    owned="$(_pve_owned_guests | paste -sd' ' -)"
    njobs="$(jq '[.[] | select(.enabled)] | length' <<<"$_PVE_PBO_JOBS" 2>/dev/null)" || njobs=0
    DI_LINES+=("$ok  integration: $mode, ${njobs} enabled PVE job(s) to pbo, PVE owns: ${owned:-no guest}")
    while IFS=$'\t' read -r id j; do
        [[ -n "$id" ]] || continue
        DI_LINES+=("$warn  guest $id is selected by more than one PVE job to pbo (${j// /, }); ${j%% *} owns it")
        DI_WARNS=$((DI_WARNS+1))
    done < <(_pve_overlap_guests)
    while read -r id; do
        [[ -n "$id" ]] || continue
        _guest_skipped "$id" || continue
        DI_LINES+=("$warn  guest $id is tagged pbo-skip but PVE job $(_pve_owner_job "$id") backs it up (the job's selection wins)")
        DI_WARNS=$((DI_WARNS+1))
    done < <(_pve_owned_guests)
    while read -r id; do
        [[ -n "$id" ]] || continue
        DI_LINES+=("$bad  guest $id has no owner: PBO_INTEGRATION=integrated and no enabled PVE job to pbo selects it (add it to a job, or tag it pbo-skip)")
        DI_PROBLEMS=$((DI_PROBLEMS+1))
    done < <(_backup_set_unowned)
    _doctor_integration_more "$ok" "$bad" "$warn"
    return 0
}

# _doctor_integration_more <ok> <bad> <warn>: the setup checks of lib/integrate.sh
# (plugin, storage, hook, jobs, spool, catalogue), when that library is loaded.
_doctor_integration_more() {
    declare -F _doctor_integration_setup >/dev/null || return 0
    _doctor_integration_setup "$@"
}
