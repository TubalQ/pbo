# shellcheck shell=bash
# lib/restore.sh — step 6: restore (fetch + pct restore to a NEW vmid).
#
# Hard rules (PLAN.md §2/§6):
#   - ALWAYS restore to a new vmid; never overwrite an existing one.
#   - Read `unprivileged` from the archive's config and set the flag EXPLICITLY (don't
#     rely on the pct default).
#   - Require --yes to actually run; without it, print the command.
#   - Bind-mounts are not in the archive → warn that they must be recreated manually
#     (pct set); show the config sidecar.
# Takes a per-vmid lock on the TARGET vmid, never the global lock.

# do_restore <src_vmid> <ts> <new_vmid> <storage|""> <yes:0|1>
do_restore() {
    local src="$1" ts="$2" newid="$3" storage="$4" yes="$5"
    if [[ "${ENGINE:-tar}" == "restic" ]]; then rdo_restore "$src" "$ts" "$newid" "$storage" "$yes"; return $?; fi

    # Target vmid must not exist.
    if pct config "$newid" >/dev/null 2>&1; then
        die "$EX_USAGE" "target vmid $newid already exists — restore refuses to overwrite"
    fi

    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] would fetch $src ($ts) and pct restore → new vmid $newid"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$src" "target_vmid" "$newid"
        return "$EX_OK"
    fi

    # Secure the archive locally (fetches + verifies sha256 if not already in cache).
    _fetch_core "$src" "$ts"
    local archive="$FETCHED_ARCHIVE"

    # Read unprivileged from the config sidecar (default 1 if unknown).
    local unpriv=1
    if [[ -f "${archive}.conf" ]]; then
        unpriv="$(awk -F': ' '/^unprivileged:/{print $2; exit}' "${archive}.conf")"
        [[ "$unpriv" =~ ^[01]$ ]] || unpriv=1
    fi

    # Default storage: the rootfs pool from meta, otherwise nvmepool.
    if [[ -z "$storage" ]]; then
        storage="$(jq -r '.source_volumes[0] // empty' "${archive}.meta.json" 2>/dev/null | cut -d'|' -f1)"
        [[ -n "$storage" && "$storage" != "null" ]] || storage="nvmepool"
    fi

    # Bind-mount warning (they are not in the archive).
    local bm
    bm="$(jq -r '.bind_mounts_skipped[]?' "${archive}.meta.json" 2>/dev/null | paste -sd' ' -)"
    [[ -n "$bm" ]] && log_warn "restore: bind-mounts were NOT in the archive and must be recreated manually with 'pct set $newid ...': $bm (see ${archive}.conf)"

    local cmd=(pct restore "$newid" "$archive" --storage "$storage" --unprivileged "$unpriv")

    # Without --yes: show the command, don't run.
    if [[ "$yes" != "1" ]]; then
        log_info "restore (preview, run with --yes): ${cmd[*]}"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "planned" "true" \
            "vmid" "$src" "target_vmid" "$newid" "storage" "$storage" \
            "unprivileged" "$unpriv" "restore_command" "${cmd[*]}"
        return "$EX_OK"
    fi

    # Run.
    local job_id="restore-${newid}-$(date +%Y%m%d-%H%M%S)"
    local jobfile="${JOBS_DIR}/${job_id}.log"
    audit_log "restore src=$src ts=$ts target=$newid storage=$storage unprivileged=$unpriv"
    log_info "restore: ${cmd[*]}"
    if ! run_stream "$jobfile" "pct-restore[$newid]" -- "${cmd[@]}"; then
        die "$EX_SOFTWARE" "pct restore failed for target $newid (see $jobfile)"
    fi

    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "restored" "true" "vmid" "$src" "target_vmid" "$newid" \
            "storage" "$storage" "unprivileged" "$unpriv" "job" "$jobfile"
    else
        log_info "restore: DONE → CT $newid (unprivileged=$unpriv, storage=$storage). Check any bind-mounts."
    fi
    return "$EX_OK"
}
