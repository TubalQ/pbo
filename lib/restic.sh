# shellcheck shell=bash
# lib/restic.sh: the backup engine (ADR 0001, Path A). restic is the only engine.
#
# The vzdump archive (UNCOMPRESSED) is stored IN restic instead of being pushed as
# tar.zst via rclone. restore goes via `restic restore` → `pct restore`.
#
# Repo model:
#   LOCAL_REPO=true  (cached)      : backup → RESTIC_CACHE_REPO → copy → RESTIC_OFFSITE_REPO
#   LOCAL_REPO=false (offsite-only): backup → RESTIC_OFFSITE_REPO directly (dumpdir transient)
#
# Grouping trick: we back up the DIRECTORY $CACHE_DIR/<vmid> (stable path per
# guest) → the snapshot's .paths stays stable → `forget --group-by paths` gives
# keep-per-guest. ts is added as a TAG (ts=YYYY_MM_DD-HH_MM_SS) for selection, vmid as
# a tag for migration safety. The sidecar (.conf) is included in the snapshot.

# --- restic wrapper: repo + password + own metadata cache + optional native-sftp command ---
# Used by ALL restic calls (also via run_stream) so sftp.command is set in ONE
# place. Runs as a function in run_stream's subshell (functions are inherited).
_restic() {                    # _restic <repo> <args...>
    local opts=()
    [[ -n "${RESTIC_SFTP_COMMAND:-}" ]] && opts=(-o "sftp.command=${RESTIC_SFTP_COMMAND}")
    [[ -n "${RESTIC_SFTP_CONNECTIONS:-}" ]] && opts+=(-o "sftp.connections=${RESTIC_SFTP_CONNECTIONS}")
    # The env prefixes below re-export config vars for the restic child; the RHS
    # references the outer (config) values, not the sibling prefixes. Intended.
    # shellcheck disable=SC2097,SC2098
    RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
    RESTIC_FROM_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
    RESTIC_CACHE_DIR="$RESTIC_CACHE_DIR" \
        "$RESTIC_BIN" -r "$1" "${opts[@]}" "${@:2}"
}

# Newest vzdump archive for a vmid in a dumpdir, .tar (lxc) or .vma (qemu).
# Uses find (returns 0 on no match) instead of a two-glob `ls` (which returns
# non-zero when one glob misses → trips set -e/pipefail on the assignment).
_newest_dump() {               # <dir> <vmid> → path (empty if none)
    find "$1" -maxdepth 1 -type f \
        \( -name "vzdump-*-$2-*.tar" -o -name "vzdump-*-$2-*.vma" \) \
        -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-
}

# Primary READ repo (list/restore/prune): offsite if enabled, otherwise cache.
# PBO_REPO=cache|offsite overrides the pick (used by `status` to query each tier
# separately); it is an env var, not a config key, so it survives load_config.
_restic_read_repo() {
    case "${PBO_REPO:-}" in
        cache)   printf '%s' "$RESTIC_CACHE_REPO";   return ;;
        offsite) printf '%s' "$RESTIC_OFFSITE_REPO"; return ;;
    esac
    if [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        printf '%s' "$RESTIC_OFFSITE_REPO"
    else
        printf '%s' "$RESTIC_CACHE_REPO"
    fi
}

# Primary WRITE repo (backup): cache in cached mode, otherwise offsite directly.
_restic_write_repo() {
    if [[ "${LOCAL_REPO:-true}" == "true" ]]; then printf '%s' "$RESTIC_CACHE_REPO"
    else printf '%s' "$RESTIC_OFFSITE_REPO"; fi
}

# Ensure repo (init if not present). Extra args → init.
_restic_ensure() {             # _restic_ensure <repo> [init-args...]
    local repo="$1"; shift
    _restic "$repo" cat config >/dev/null 2>&1 && return 0
    log_info "restic: init repo $repo"
    _restic "$repo" init "$@"
}

# restic_init, init cache and/or offsite repo (onboarding, idempotent).
restic_init() {
    [[ -r "$RESTIC_PASSWORD_FILE" ]] || die "$EX_CONFIG" "restic: missing password file $RESTIC_PASSWORD_FILE (0600)"
    if [[ "${LOCAL_REPO:-true}" == "true" ]]; then
        _restic_ensure "$RESTIC_CACHE_REPO" || die "$EX_SOFTWARE" "restic: cache repo init failed"
    fi
    if [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        if [[ "${LOCAL_REPO:-true}" == "true" ]]; then
            _restic_ensure "$RESTIC_OFFSITE_REPO" --copy-chunker-params --from-repo "$RESTIC_CACHE_REPO" \
                || die "$EX_SOFTWARE" "restic: offsite repo init failed"
        else
            _restic_ensure "$RESTIC_OFFSITE_REPO" || die "$EX_SOFTWARE" "restic: offsite repo init failed"
        fi
    fi
}

# ---------------------------------------------------------------------------
# backup
# ---------------------------------------------------------------------------
rdo_backup() {
    local vmid="$1"
    local mode; mode="$(_effective_mode "$vmid")"
    local gtype; gtype="$(_guest_type "$vmid")" || gtype="lxc"   # lxc | qemu
    local dumpdir="${CACHE_DIR}/${vmid}"
    local job_id; job_id="backup-${vmid}-$(date +%Y%m%d-%H%M%S)"
    local jobfile="${JOBS_DIR}/${job_id}.log"

    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] restic backup vmid $vmid (mode $mode)"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$vmid" "engine" "restic"
        return "$EX_OK"
    fi

    restic_init
    # A killed previous run can leave a stale restic lock; clear it if no live
    # pbo run holds it, so one crash doesn't wedge every future backup.
    _restic_stale_unlock "$(_restic_write_repo)"
    [[ "${LOCAL_REPO:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]] && _restic_stale_unlock "$RESTIC_OFFSITE_REPO"
    # Clean dumpdir → snapshot content = exactly this run's archive+sidecar.
    rm -f "${dumpdir}"/vzdump-* 2>/dev/null || true
    mkdir -p "$dumpdir" "$JOBS_DIR"

    # 1. vzdump UNCOMPRESSED (restic compresses itself → dedup works)
    log_info "backup $vmid: vzdump ($mode, uncompressed) → $dumpdir"
    if ! run_stream "$jobfile" "vzdump[$vmid]" -- \
            vzdump "$vmid" --mode "$mode" --compress 0 --dumpdir "$dumpdir"; then
        die "$EX_SOFTWARE" "vzdump failed for vmid $vmid (see $jobfile)"
    fi
    # lxc → .tar, qemu → .vma (both uncompressed via --compress 0)
    local archive; archive="$(_newest_dump "$dumpdir" "$vmid")"
    [[ -n "$archive" && -f "$archive" ]] || die "$EX_SOFTWARE" "no uncompressed vzdump archive (.tar/.vma) in $dumpdir"
    local base; base="$(basename "$archive")"
    local ts; ts="$(_archive_ts "$base")"; [[ -n "$ts" ]] || ts="$(date +%Y_%m_%d-%H_%M_%S)"
    # config sidecar for restore (lxc: unprivileged/bind-mounts; qemu: disks)
    _g_config "$gtype" "$vmid" > "${archive}.conf" 2>/dev/null || true

    # 2. restic backup of the DIRECTORY (stable path → grouping-friendly)
    local wrepo; wrepo="$(_restic_write_repo)"
    log_info "backup $vmid: restic backup → $wrepo (tags vmid=$vmid,ts=$ts)"
    if ! run_stream "$jobfile" "restic-backup[$vmid]" -- \
            _restic "$wrepo" backup "$dumpdir" \
                --tag "vmid=$vmid" --tag "ts=$ts" --tag "type=$gtype" --host "$(_local_node)"; then
        die "$EX_SOFTWARE" "restic backup failed for $base (see $jobfile)"
    fi

    # 3. cached mode: copy the new snapshot → offsite
    if [[ "${LOCAL_REPO:-true}" == "true" && "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        log_info "backup $vmid: restic copy cache → offsite"
        if ! run_stream "$jobfile" "restic-copy[$vmid]" -- \
                _restic "$RESTIC_OFFSITE_REPO" copy --from-repo "$RESTIC_CACHE_REPO" --tag "vmid=$vmid,ts=$ts"; then
            die "$EX_UNAVAILABLE" "restic copy → offsite failed for vmid $vmid"
        fi
    fi

    # 4. clean up loose tar (now lives in the repo)
    rm -f "${dumpdir}"/vzdump-* 2>/dev/null || true

    local rrepo; rrepo="$(_restic_read_repo)"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "uploaded" "true" "vmid" "$vmid" "ts" "$ts" "engine" "restic" \
            "archive" "$base" "repo" "$rrepo" "job" "$jobfile"
    else
        log_info "backup $vmid: DONE (restic), ts=$ts"
    fi
    return "$EX_OK"
}

# ---------------------------------------------------------------------------
# list, emit the SAME envelope as the tar engine ({archives:[...]}) so the UI is untouched.
# ---------------------------------------------------------------------------
rdo_list() {
    local only="${1:-}"
    local repo; repo="$(_restic_read_repo)"
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for list"
    local snaps; snaps="$(_restic "$repo" snapshots --json 2>/dev/null || echo '[]')"
    [[ -n "$snaps" ]] || snaps='[]'
    local now; now="$(date +%s)"
    local archives
    archives="$(printf '%s' "$snaps" | jq -c --arg only "$only" '
        [ .[]
          | ((.tags // []) | map(select(startswith("vmid="))) | .[0] // "" | sub("vmid=";"")) as $vmid
          | ((.tags // []) | map(select(startswith("ts=")))   | .[0] // "" | sub("ts=";""))   as $ts
          | ((.tags // []) | map(select(startswith("type="))) | .[0] // "type=lxc" | sub("type=";"")) as $typ
          | select($vmid != "" and ($only == "" or $vmid == $only))
          | { vmid:$vmid,
              archive:("vzdump-\($typ)-\($vmid)-\($ts)." + (if $typ=="qemu" then "vma" else "tar" end)),
              size_bytes:((.summary.total_bytes_processed) // (.summary.data_added) // 0),
              modtime:.time, age_seconds:0, snapshot:.short_id } ]' 2>/dev/null || echo '[]')"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        printf '{"command":"list","status":"ok","ok":true,"dry_run":false,"archives":%s}\n' "$archives"
    else
        printf '%-6s  %-42s  %12s  %s\n' VMID ARCHIVE SIZE SNAP
        printf '%s' "$archives" | jq -r '.[] | "\(.vmid)  \(.archive)  \(.size_bytes)  \(.snapshot)"'
    fi
}

# ---------------------------------------------------------------------------
# extraction: fetch+verify a snapshot to <target>, echo the tar path.
# ---------------------------------------------------------------------------
# Sets the GLOBAL RX_TAR (NOT via stdout, log_info goes to stdout in non-json
# mode and would pollute command substitution → broken pct-restore path).
RX_TAR=""
_restic_extract() {            # _restic_extract <vmid> <ts> <target> → RX_TAR
    local vmid="$1" ts="$2" target="$3"
    RX_TAR=""
    local repo; repo="$(_restic_read_repo)"
    mkdir -p "$target"
    local id
    id="$(_restic "$repo" snapshots --json --tag "vmid=$vmid,ts=$ts" 2>/dev/null | jq -r '.[-1].short_id // empty')"
    [[ -n "$id" ]] || { log_error "restic: no snapshot vmid=$vmid ts=$ts in $repo"; return 1; }
    log_info "restic restore snapshot $id → $target (verifies on read-out)"
    _restic "$repo" restore "$id" --target "$target" >/dev/null 2>&1 \
        || { log_error "restic restore failed (snap $id)"; return 1; }
    RX_TAR="$(find "$target" -type f \( -name 'vzdump-*.tar' -o -name 'vzdump-*.vma' \) | head -1)"
    [[ -n "$RX_TAR" ]] || { log_error "restic: no vzdump archive (.tar/.vma) in restored snapshot $id"; return 1; }
    return 0
}

# Read unprivileged from the .conf sidecar next to the tar (default 1).
_conf_unpriv() {               # _conf_unpriv <tar>
    local conf="${1}.conf" u=1
    [[ -f "$conf" ]] && { u="$(awk -F': ' '/^unprivileged:/{print $2; exit}' "$conf")"; [[ "$u" =~ ^[01]$ ]] || u=1; }
    printf '%s' "$u"
}

# ---------------------------------------------------------------------------
# restore, restic → pct restore to a NEW vmid (never overwrite).
# ---------------------------------------------------------------------------
rdo_restore() {
    local src="$1" ts="$2" newid="$3" storage="$4" yes="$5"
    _g_exists "$newid" && die "$EX_USAGE" "target vmid $newid already exists, refusing"
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] restic restore $src ($ts) → new vmid $newid"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$src" "target_vmid" "$newid"
        return "$EX_OK"
    fi
    local rdir="${CACHE_DIR}/restore-${newid}"; rm -rf "$rdir"
    _restic_extract "$src" "$ts" "$rdir" || die "$EX_DATAERR" "restic extraction failed"
    local tar="$RX_TAR"
    local gtype; gtype="$(_guest_type_from_archive "$tar")"
    [[ -n "$storage" ]] || storage="$(_default_storage "$gtype")"
    [[ -n "$storage" ]] || die "$EX_USAGE" "no --storage given and no $([[ "$gtype" == qemu ]] && echo images || echo rootdir)-capable storage found"
    local cmd=() unpriv=""
    if [[ "$gtype" == qemu ]]; then
        cmd=(qmrestore "$tar" "$newid" --storage "$storage")            # <archive> <vmid>; no --unprivileged
    else
        unpriv="$(_conf_unpriv "$tar")"
        cmd=(pct restore "$newid" "$tar" --storage "$storage" --unprivileged "$unpriv")
    fi
    if [[ "$yes" != "1" ]]; then
        log_info "restore (preview, run with --yes): ${cmd[*]}"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "planned" "true" "vmid" "$src" \
            "target_vmid" "$newid" "storage" "$storage" "restore_command" "${cmd[*]}"
        rm -rf "$rdir" 2>/dev/null || true
        return "$EX_OK"
    fi
    local jobfile; jobfile="${JOBS_DIR}/restore-${newid}-$(date +%Y%m%d-%H%M%S).log"
    audit_log "restore src=$src ts=$ts target=$newid storage=$storage unprivileged=$unpriv engine=restic"
    if ! run_stream "$jobfile" "${gtype}-restore[$newid]" -- "${cmd[@]}"; then
        die "$EX_SOFTWARE" "${gtype} restore failed for target $newid (see $jobfile)"
    fi
    rm -rf "$rdir" 2>/dev/null || true
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "restored" "true" "vmid" "$src" "target_vmid" "$newid" "storage" "$storage" "type" "$gtype" "engine" "restic"
    else
        log_info "restore: DONE → $( [[ "$gtype" == qemu ]] && echo VM || echo CT ) $newid (restic, $gtype, storage=$storage)"
    fi
    return "$EX_OK"
}

# ---------------------------------------------------------------------------
# test-restore, full chain against a throwaway vmid (reuses _tr_* from testrestore.sh).
# ---------------------------------------------------------------------------
rdo_test_restore() {
    local vmid="$1"
    local repo; repo="$(_restic_read_repo)"
    local ts
    ts="$(_restic "$repo" snapshots --json --tag "vmid=$vmid" 2>/dev/null \
        | jq -r '[ .[] | (.tags // []) | map(select(startswith("ts=")))[0] // empty | sub("ts=";"") ] | sort | last // empty')"
    [[ -n "$ts" ]] || die "$EX_DATAERR" "test-restore: no restic snapshots for vmid $vmid"
    local target; target="$(_tr_pick_target)" || die "$EX_UNAVAILABLE" "no free throwaway vmid 9000-9099"
    audit_log "test-restore vmid=$vmid ts=$ts throwaway=$target engine=restic"
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] test-restore $vmid ($ts) → throwaway-$target"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$vmid" "throwaway" "$target"
        return "$EX_OK"
    fi
    local rdir="${CACHE_DIR}/restore-${target}"; rm -rf "$rdir"
    local jobfile; jobfile="${JOBS_DIR}/testrestore-${vmid}-$(date +%Y%m%d-%H%M%S).log"
    _restic_extract "$vmid" "$ts" "$rdir" || die "$EX_DATAERR" "restic extraction failed"
    local tar="$RX_TAR"
    local gtype; gtype="$(_guest_type_from_archive "$tar")"
    local storage="${TR_STORAGE:-$(_default_storage "$gtype")}"
    [[ -n "$storage" ]] || die "$EX_UNAVAILABLE" "test-restore: no $([[ "$gtype" == qemu ]] && echo images || echo rootdir)-capable storage (set TR_STORAGE)"
    local ok=1 stage="" rcmd=()
    if [[ "$gtype" == qemu ]]; then rcmd=(qmrestore "$tar" "$target" --storage "$storage")
    else rcmd=(pct restore "$target" "$tar" --storage "$storage" --unprivileged "$(_conf_unpriv "$tar")"); fi
    if ! run_stream "$jobfile" "${gtype}-restore[$target]" -- "${rcmd[@]}"; then ok=0; stage="restore"; fi
    if (( ok )) && ! run_stream "$jobfile" "${gtype}-start[$target]" -- _g_start "$gtype" "$target"; then ok=0; stage="start"; fi
    if (( ok )); then log_info "test-restore: waiting for $gtype $target to respond…"; _tr_wait "$target" "$gtype" || { ok=0; stage="respond"; }; fi
    _tr_destroy "$target"; rm -rf "$rdir" 2>/dev/null || true
    if (( ok )); then
        notify_success "test-restore OK: vmid $vmid ($ts) booted on throwaway-$target (restic)"
        if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_result "test_ok" "true" "vmid" "$vmid" "ts" "$ts" "throwaway" "$target"
        else log_info "test-restore: ✅ vmid $vmid booted from restic (throwaway-$target cleaned up)"; fi
        return "$EX_OK"
    fi
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "test_failed" "false" "vmid" "$vmid" "stage" "$stage" "throwaway" "$target"
    die "$EX_SOFTWARE" "test-restore FAILED at step '$stage' for vmid $vmid"
}

# ---------------------------------------------------------------------------
# prune, restic forget/prune. Envelope {cache_deleted,offsite_deleted} like the UI.
# offsite_deleted = removed snapshot ids (offsite/read repo). --group-by paths
# gives keep-per-guest (stable dumpdir path).
# ---------------------------------------------------------------------------
# _restic_forget_json <repo> <keep-flags...> → JSON array of removed short_id.
# --group-by paths gives keep-per-guest (stable dumpdir path).
_restic_forget_json() {
    local repo="$1"; shift
    # `forget --json` ALONE gives a clean remove list (one json value). Do NOT run
    # --prune here (it restructures the output); reclaim space separately below.
    local fflags=(forget --group-by paths "$@" --json)
    [[ "${DRY_RUN:-0}" == 1 ]] && fflags+=(--dry-run)
    local out; out="$(_restic "$repo" "${fflags[@]}" 2>/dev/null || echo '[]')"
    local removed; removed="$(printf '%s' "$out" | jq -cs '[ (.[0] // []) | .[]? | .remove[]?.short_id ]' 2>/dev/null || echo '[]')"
    # Real run that actually removed snapshots → reclaim pack files separately.
    if [[ "${DRY_RUN:-0}" != 1 && "$(printf '%s' "$removed" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]]; then
        _restic "$repo" prune >/dev/null 2>&1 || log_warn "restic prune ($repo) returned an error, space not fully reclaimed"
    fi
    printf '%s' "$removed"
}

# prune, the cache repo is pruned keep-last, offsite is pruned PURE GFS. In cached mode
# BOTH are pruned. Envelope {cache_deleted, offsite_deleted} = removed ids per repo.
rdo_prune() {
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for prune"
    local cache_removed='[]' offsite_removed='[]'
    # Local cache repo: keep-last (fast restore tier).
    if [[ "${LOCAL_REPO:-true}" == "true" ]]; then
        _restic_stale_unlock "$RESTIC_CACHE_REPO"
        cache_removed="$(_restic_forget_json "$RESTIC_CACHE_REPO" --keep-last "${RESTIC_KEEP_LAST}")"
    fi
    # Offsite: pure GFS (daily/weekly/monthly), no keep-last (a cache concept).
    if [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        _restic_stale_unlock "$RESTIC_OFFSITE_REPO"
        offsite_removed="$(_restic_forget_json "$RESTIC_OFFSITE_REPO" \
            --keep-daily "${KEEP_OFFSITE_DAILY}" --keep-weekly "${KEEP_OFFSITE_WEEKLY}" \
            --keep-monthly "${KEEP_OFFSITE_MONTHLY}")"
    fi
    local dry; dry="$( [[ "${DRY_RUN:-0}" == 1 ]] && echo true || echo false )"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        printf '{"command":"prune","status":"ok","ok":true,"dry_run":%s,"cache_deleted":%s,"offsite_deleted":%s}\n' \
            "$dry" "$cache_removed" "$offsite_removed"
    else
        local nc no; nc="$(printf '%s' "$cache_removed" | jq 'length')"; no="$(printf '%s' "$offsite_removed" | jq 'length')"
        log_info "prune (restic): cache removed $nc, offsite removed $no$( [[ "${DRY_RUN:-0}" == 1 ]] && echo ' (dry-run)')"
    fi
    return "$EX_OK"
}

# rotate-key: rotate the repo password (the DR key) on ALL configured repos to a
# new value. restic keys are wrapped copies of the master key, so this is instant
# and re-encrypts nothing. Adds the new key, verifies it opens the repo, then
# removes the old key, per repo, and finally repoints RESTIC_PASSWORD_FILE.
rdo_rotate_key() {
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for rotate-key"
    local newfile="$1" oldfile="$RESTIC_PASSWORD_FILE"
    [[ -r "$oldfile" ]] || die "$EX_CONFIG" "rotate-key: current password file $oldfile unreadable"
    [[ -r "$newfile" ]] || die "$EX_CONFIG" "rotate-key: new password file $newfile unreadable"
    [[ -s "$newfile" ]] || die "$EX_CONFIG" "rotate-key: new password file is empty"
    local repos=()
    [[ "${LOCAL_REPO:-true}" == "true" ]] && repos+=("$RESTIC_CACHE_REPO")
    [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]] && repos+=("$RESTIC_OFFSITE_REPO")
    (( ${#repos[@]} )) || die "$EX_CONFIG" "rotate-key: no repos configured"
    local opts=(); [[ -n "${RESTIC_SFTP_COMMAND:-}" ]] && opts=(-o "sftp.command=${RESTIC_SFTP_COMMAND}")
    [[ -n "${RESTIC_SFTP_CONNECTIONS:-}" ]] && opts+=(-o "sftp.connections=${RESTIC_SFTP_CONNECTIONS}")
    local repo oldid
    for repo in "${repos[@]}"; do
        oldid="$(RESTIC_PASSWORD_FILE="$oldfile" RESTIC_CACHE_DIR="$RESTIC_CACHE_DIR" "$RESTIC_BIN" -r "$repo" "${opts[@]}" key list --json 2>/dev/null | jq -r '.[]|select(.current==true)|.id' 2>/dev/null)"
        [[ -n "$oldid" ]] || die "$EX_SOFTWARE" "rotate-key: cannot read current key id for $repo (wrong password?)"
        RESTIC_PASSWORD_FILE="$oldfile" RESTIC_CACHE_DIR="$RESTIC_CACHE_DIR" "$RESTIC_BIN" -r "$repo" "${opts[@]}" key add --new-password-file "$newfile" >/dev/null 2>&1 \
            || die "$EX_SOFTWARE" "rotate-key: 'key add' failed on $repo (old key still valid)"
        RESTIC_PASSWORD_FILE="$newfile" RESTIC_CACHE_DIR="$RESTIC_CACHE_DIR" "$RESTIC_BIN" -r "$repo" "${opts[@]}" cat config >/dev/null 2>&1 \
            || die "$EX_SOFTWARE" "rotate-key: the new key does not open $repo (aborted, old key still valid)"
        RESTIC_PASSWORD_FILE="$newfile" RESTIC_CACHE_DIR="$RESTIC_CACHE_DIR" "$RESTIC_BIN" -r "$repo" "${opts[@]}" key remove "$oldid" >/dev/null 2>&1 \
            || log_warn "rotate-key: could not remove old key $oldid on $repo (new key works; remove it by hand)"
        log_info "rotate-key: $repo rotated (removed old key $oldid)"
    done
    install -m 0600 "$newfile" "$oldfile"
    log_info "rotate-key: DONE. Export the new DR key and update your password manager."
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "ok" "true" "repos" "${repos[*]}"
    return "$EX_OK"
}

# usage, repo size/dedup from `restic stats` (for the Metrics tab/dashboard).
rdo_usage() {
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for usage"
    local repo raw rest
    repo="$(_restic_read_repo)"
    raw="$(_restic "$repo" stats --mode raw-data --json 2>/dev/null || echo '{}')"
    rest="$(_restic "$repo" stats --mode restore-size --json 2>/dev/null || echo '{}')"
    [[ "$raw" == \{* ]] || raw='{}'; [[ "$rest" == \{* ]] || rest='{}'
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        jq -cn --argjson raw "$raw" --argjson rest "$rest" --arg repo "$repo" '
          {command:"usage",status:"ok",ok:true,dry_run:false,repo:$repo,
           physical_bytes:($raw.total_size//0),
           logical_bytes:($rest.total_size//0),
           uncompressed_bytes:($raw.total_uncompressed_size//0),
           compression_ratio:(($raw.compression_ratio//1)*1000|floor/1000),
           snapshots:($raw.snapshots_count//0),
           files:($rest.total_file_count//0)}'
    else
        log_info "usage: physical $(jq -r '.total_size//0' <<<"$raw") B, logical $(jq -r '.total_size//0' <<<"$rest") B, snapshots $(jq -r '.snapshots_count//0' <<<"$raw")"
    fi
    return "$EX_OK"
}

# verify: restic check on BOTH tiers (cache + offsite), so a silent cache
# corruption is caught too. Structure-only by default; VERIFY_READ_DATA=1 reads
# every pack (expensive over SFTP), VERIFY_SUBSET=<n%|size> reads a cheap sample
# (e.g. VERIFY_SUBSET=5% for an affordable periodic deep check).
_rdo_verify_one() {                # <repo> → 0 ok, 1 fail (empty repo = skip, ok)
    local repo="$1"
    _restic "$repo" cat config >/dev/null 2>&1 || { log_warn "verify: $repo unreachable/absent, skipped"; return 0; }
    local args=(check)
    if [[ "${VERIFY_READ_DATA:-0}" == 1 ]]; then args+=(--read-data)
    elif [[ -n "${VERIFY_SUBSET:-}" ]]; then args+=(--read-data-subset "${VERIFY_SUBSET}"); fi
    if _restic "$repo" "${args[@]}" >/dev/null 2>&1; then
        log_info "verify: OK ($repo)"; return 0
    fi
    log_error "verify: restic check FAILED for $repo"; return 1
}
rdo_verify() {
    local fail=0 checked=()
    if [[ "${LOCAL_REPO:-true}" == "true" ]]; then
        _rdo_verify_one "$RESTIC_CACHE_REPO" || fail=1; checked+=("cache")
    fi
    if [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        _rdo_verify_one "$RESTIC_OFFSITE_REPO" || fail=1; checked+=("offsite")
    fi
    if (( fail == 0 )); then
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "ok" "true" "engine" "restic" "tiers" "${checked[*]:-none}" || log_info "verify: OK (${checked[*]:-nothing to check})"
        return "$EX_OK"
    fi
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "failed" "false" "engine" "restic" "tiers" "${checked[*]:-none}"
    die "$EX_DATAERR" "restic check FAILED (see log)"
}

# fetch: extract+verify one snapshot into the cache WITHOUT restoring. Proves the
# snapshot restores to bytes on disk (restic verifies on read-out). No global lock.
rdo_fetch() {
    local vmid="$1" ts="$2"
    local target="${CACHE_DIR}/fetch-${vmid}"; rm -rf "$target"
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] would extract snapshot vmid=$vmid ts=$ts → $target"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$vmid"
        return "$EX_OK"
    fi
    _restic_extract "$vmid" "$ts" "$target" || die "$EX_DATAERR" "fetch failed for vmid $vmid ts $ts"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "fetched" "true" "vmid" "$vmid" "ts" "$ts" "archive" "$RX_TAR" "verified" "restic"
    else
        log_info "fetch $vmid: DONE, $RX_TAR (restic-verified on read-out)"
    fi
    return "$EX_OK"
}

# unlock: clear a stale restic lock left by a killed backup/prune. restic locks
# are held for the life of a process; a SIGKILL/OOM/reboot leaves one behind and
# the next run fails "repository is already locked". `unlock` removes stale (non-
# live) locks only; a genuinely concurrent run keeps its lock.
rdo_unlock() {
    local rc=0 repo repos=()
    [[ "${LOCAL_REPO:-true}" == "true" ]] && repos+=("$RESTIC_CACHE_REPO")
    [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]] && repos+=("$RESTIC_OFFSITE_REPO")
    for repo in "${repos[@]}"; do
        if [[ "${DRY_RUN:-0}" == 1 ]]; then log_info "[dry-run] restic unlock $repo"; continue; fi
        if _restic "$repo" unlock >/dev/null 2>&1; then log_info "unlock: cleared stale locks on $repo"
        else log_warn "unlock: could not unlock $repo (unreachable?)"; rc=1; fi
    done
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "$( ((rc==0)) && echo ok || echo partial )" "$( ((rc==0)) && echo true || echo false )" "repos" "${repos[*]:-none}"
    return "$EX_OK"
}

# _restic_stale_unlock <repo>: auto-clear a lock ONLY if no pbo backup/prune is
# actually running (our own global lock is free). Called before backup/prune so a
# crashed previous run doesn't wedge every future run.
_restic_stale_unlock() {
    local repo="$1"
    _restic "$repo" list locks 2>/dev/null | grep -q . || return 0   # no locks, nothing to do
    # If pbo itself is mid-operation the lock is legitimate; leave it.
    if [[ -f "$GLOBAL_HOLDER_FILE" ]]; then
        local pid; pid="$(cut -d'|' -f3 "$GLOBAL_HOLDER_FILE" 2>/dev/null)"
        [[ -n "$pid" && "$pid" != "$$" ]] && kill -0 "$pid" 2>/dev/null && return 0
    fi
    log_warn "restic: stale lock on $repo (no live pbo run) → unlocking"
    _restic "$repo" unlock >/dev/null 2>&1 || true
}

# doctor: a fast health check that surfaces the things that silently rot, repo
# reachability, the DR key's permissions, the timer, provider snapshots, and, per
# guest, how old the newest snapshot is (catches a guest that quietly stopped
# being backed up, e.g. one whose data lives on a backup=0 mountpoint).
rdo_doctor() {
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for doctor"
    local problems=0 warns=0 lines=()
    local ok="  ${C_G:-}OK${C_0:-}" bad="  ${C_R:-}FAIL${C_0:-}" warn="  ${C_Y:-}WARN${C_0:-}"

    # DR key present + 0600.
    local pf="${RESTIC_PASSWORD_FILE:-/etc/pbo/restic-pass}"
    if [[ -r "$pf" ]]; then
        local perm; perm="$(stat -c '%a' "$pf" 2>/dev/null)"
        if [[ "$perm" == "600" || "$perm" == "400" ]]; then lines+=("$ok  DR key $pf ($perm)")
        else lines+=("$warn  DR key $pf is $perm, should be 0600"); warns=$((warns+1)); fi
    else lines+=("$bad  DR key $pf missing or unreadable"); problems=$((problems+1)); fi

    # Repo reachable.
    local repo; repo="$(_restic_read_repo)"
    if _restic "$repo" cat config >/dev/null 2>&1; then lines+=("$ok  repo $repo reachable")
    else lines+=("$bad  repo $repo not reachable"); problems=$((problems+1)); fi

    # Timer enabled.
    if systemctl is-enabled pbo.timer >/dev/null 2>&1; then lines+=("$ok  pbo.timer enabled")
    else lines+=("$warn  pbo.timer not enabled (no nightly backup)"); warns=$((warns+1)); fi

    # Ransomware backstop.
    if [[ "${STORAGE_BOX_SNAPSHOTS_CONFIRMED:-false}" == "true" ]]; then lines+=("$ok  provider snapshots confirmed")
    else lines+=("$warn  STORAGE_BOX_SNAPSHOTS_CONFIRMED=false (no ransomware backstop)"); warns=$((warns+1)); fi

    # Per-guest freshness: newest snapshot age vs DOCTOR_MAX_AGE, for every guest
    # on this node. A live guest with NO snapshot at all is a hard finding.
    local now; now="$(date +%s)"
    local snaps; snaps="$(_restic "$repo" snapshots --json 2>/dev/null || echo '[]')"
    local id newest age hrs guests; guests="$(_backup_set || true)"
    while read -r id; do
        [[ -n "$id" ]] || continue
        newest="$(printf '%s' "$snaps" | jq -r --arg v "$id" '[ .[] | select((.tags//[])|any(.=="vmid=\($v)")) | .time ] | sort | last // empty' 2>/dev/null)"
        if [[ -z "$newest" ]]; then lines+=("$bad  guest $id has NO snapshot in the repo"); problems=$((problems+1)); continue; fi
        age=$(( now - $(date -d "$newest" +%s 2>/dev/null || echo "$now") )); hrs=$(( age/3600 ))
        if (( age > ${DOCTOR_MAX_AGE:-172800} )); then lines+=("$warn  guest $id newest snapshot ${hrs}h old (> $(( ${DOCTOR_MAX_AGE:-172800}/3600 ))h)"); warns=$((warns+1))
        else lines+=("$ok  guest $id newest snapshot ${hrs}h old"); fi
    done <<<"$guests"

    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "$( ((problems==0)) && echo ok || echo problems )" "$( ((problems==0)) && echo true || echo false )" \
            "problems" "$problems" "warnings" "$warns"
    else
        printf '%s\n' "${lines[@]}"
        log_info "doctor: ${problems} problem(s), ${warns} warning(s)"
    fi
    (( problems == 0 )) || return "$EX_UNAVAILABLE"
    return "$EX_OK"
}

# ---------------------------------------------------------------------------
# BATCH mode: dump ALL guests to cache first, then upload all → the SAME repo.
# (BACKUP_MODE=batch). Fuse downtime is clumped in phase 1; a single upload phase in phase 2.
# Falls back to stream if the dumps don't fit in CACHE_DIR.
# ---------------------------------------------------------------------------

# Estimated tar size for a guest (ZFS used if possible, otherwise config size).
_guest_bytes() {
    local vmid="$1" spec volid ds used szg gt total=0 line
    gt="$(_guest_type "$vmid")" || gt="lxc"
    if [[ "$gt" == qemu ]]; then                 # sum VM disk sizes (skip cdrom/cloudinit)
        while IFS= read -r line; do
            [[ "$line" =~ ^(scsi|virtio|sata|ide|efidisk|tpmstate)[0-9]*: ]] || continue
            [[ "$line" == *media=cdrom* || "$line" == *cloudinit* ]] && continue
            szg="$(sed -n 's/.*size=\([0-9]\+\)G.*/\1/p' <<<"$line")"
            [[ "$szg" =~ ^[0-9]+$ ]] && total=$(( total + szg * 1073741824 ))
        done < <(qm config "$vmid" 2>/dev/null)
        (( total > 0 )) || total=$(( 8 * 1073741824 ))
        printf '%s' "$total"; return
    fi
    # LXC: sum rootfs + every mpN that is actually backed up (skip bind mounts and
    # backup=0). A big data mountpoint on mp0 counts, so batch-fit doesn't undershoot.
    while IFS= read -r line; do
        [[ "$line" =~ ^(rootfs|mp[0-9]+): ]] || continue
        spec="${line#*: }"; volid="${spec%%,*}"
        [[ "$volid" == /* ]] && continue                       # bind mount, never in the archive
        [[ ",${spec#*,}," == *",backup=0,"* ]] && continue     # excluded volume
        ds="${volid/:/\/}"                                     # storeid:volume → storeid/volume
        used="$(zfs list -Hpo used "$ds" 2>/dev/null)"
        if [[ "$used" =~ ^[0-9]+$ ]]; then
            total=$(( total + used ))
        else
            szg="$(sed -n 's/.*size=\([0-9]\+\)G.*/\1/p' <<<"$spec")"
            total=$(( total + ${szg:-4} * 1073741824 ))
        fi
    done < <(pct config "$vmid" 2>/dev/null)
    (( total > 0 )) || total=$(( 4 * 1073741824 ))
    printf '%s' "$total"
}

# Do all dumps fit in the cache? (requires 85% margin.)
_batch_fits() {
    local free need=0 v
    free="$(df -PB1 "$CACHE_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
    [[ "$free" =~ ^[0-9]+$ ]] || return 1
    for v in "$@"; do need=$(( need + $(_guest_bytes "$v") )); done
    (( need > 0 && free > need * 100 / 85 ))
}

# rdo_run_batch <vmid...> → 0 ok/partial, 2 = doesn't fit (ask caller to run stream).
rdo_run_batch() {
    local vmids=("$@")
    restic_init
    if ! _batch_fits "${vmids[@]}"; then
        log_warn "batch: dumps don't fit in CACHE_DIR ($CACHE_DIR) → falling back to stream (one-by-one)"
        return 2
    fi
    acquire_global_lock "queue" "batch" "all"
    local start; start="$(date +%s)"

    # --- PHASE 1: dump all → cache ---
    log_info "batch: PHASE 1, dumping ${#vmids[@]} guests to cache…"
    local dumped=() v mode dumpdir base ts jobfile gt
    declare -A TS_OF=() GT_OF=()
    for v in "${vmids[@]}"; do
        [[ -n "$v" ]] || continue
        if ! run_preflight "$v"; then log_warn "batch: preflight failed for $v, skipping"; continue; fi
        mode="$(_effective_mode "$v")"; dumpdir="${CACHE_DIR}/${v}"
        gt="$(_guest_type "$v")" || gt="lxc"
        rm -f "$dumpdir"/vzdump-* 2>/dev/null; mkdir -p "$dumpdir" "$JOBS_DIR"
        jobfile="${JOBS_DIR}/batch-dump-${v}-$(date +%Y%m%d-%H%M%S).log"
        log_info "batch: vzdump $v ($mode, $gt)…"
        if run_stream "$jobfile" "vzdump[$v]" -- vzdump "$v" --mode "$mode" --compress 0 --dumpdir "$dumpdir"; then
            base="$(_newest_dump "$dumpdir" "$v")"
            if [[ -n "$base" && -f "$base" ]]; then
                ts="$(_archive_ts "$(basename "$base")")"; [[ -n "$ts" ]] || ts="$(date +%Y_%m_%d-%H_%M_%S)"
                _g_config "$gt" "$v" > "${base}.conf" 2>/dev/null || true
                dumped+=("$v"); TS_OF[$v]="$ts"; GT_OF[$v]="$gt"
            else
                log_warn "batch: no tar found for $v after vzdump, skipping"
            fi
        else
            log_warn "batch: vzdump $v FAILED, skipping"
        fi
    done

    # --- PHASE 2: upload all dumps → ONE repo ---
    log_info "batch: PHASE 2, uploading ${#dumped[@]} dumps → $(_restic_read_repo)…"
    local okc=0 failc=0 failed=() wrepo; wrepo="$(_restic_write_repo)"
    for v in "${dumped[@]}"; do
        ts="${TS_OF[$v]}"; dumpdir="${CACHE_DIR}/${v}"
        jobfile="${JOBS_DIR}/backup-${v}-$(date +%Y%m%d-%H%M%S).log"
        if ! run_stream "$jobfile" "restic-backup[$v]" -- \
                _restic "$wrepo" backup "$dumpdir" --tag "vmid=$v" --tag "ts=$ts" --tag "type=${GT_OF[$v]:-lxc}" --host "$(_local_node)"; then
            failc=$((failc+1)); failed+=("$v"); log_warn "batch: restic backup $v FAILED"; continue
        fi
        if [[ "${LOCAL_REPO:-true}" == "true" && "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
            run_stream "$jobfile" "restic-copy[$v]" -- \
                _restic "$RESTIC_OFFSITE_REPO" copy --from-repo "$RESTIC_CACHE_REPO" --tag "vmid=$v,ts=$ts" \
                || { failc=$((failc+1)); failed+=("$v"); log_warn "batch: copy→offsite $v FAILED"; continue; }
        fi
        rm -f "$dumpdir"/vzdump-* 2>/dev/null
        okc=$((okc+1))
    done
    local dur=$(( $(date +%s) - start ))

    if (( failc > 0 )); then notify_failure "batch: ${failc} failed (${failed[*]}) in ${dur}s"
    else notify_success "batch: ${okc} backups OK in ${dur}s"; fi
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "$( ((failc==0)) && echo ok || echo partial )" "$( ((failc==0)) && echo true || echo false )" \
            "mode" "batch" "backups_ok" "$okc" "backups_failed" "$failc" "duration_s" "$dur" "failed_vmids" "${failed[*]:-}"
    else
        log_info "batch: done, ${okc} ok, ${failc} failed, ${dur}s (all in one repo)"
    fi
    (( failc == 0 )) || return "$EX_SOFTWARE"
    return "$EX_OK"
}
