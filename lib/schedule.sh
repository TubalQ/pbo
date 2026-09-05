# shellcheck shell=bash
# lib/schedule.sh — step 9: run-schedule (scheduled sequential backup) + status.
#
# ONE timer, not one per container: run-schedule works through BACKUP_ORDER one CT
# at a time. Each CT runs as its own `backup --queue` call → queues on the global
# lock (so manual runs can't collide). One CT's failure doesn't stop
# the rest; the whole run alerts via ntfy if anything went wrong.

# do_run_schedule — run backup for each vmid in BACKUP_ORDER, sequentially.
do_run_schedule() {
    [[ -n "${BACKUP_ORDER:-}" ]] || die "$EX_CONFIG" "BACKUP_ORDER is empty — nothing to schedule."
    # Ransomware protection: SFTP provides no append-only. Remind about Storage Box snapshots.
    [[ "${STORAGE_BOX_SNAPSHOTS_CONFIRMED:-false}" == "true" ]] || \
        log_warn "run-schedule: Storage Box snapshots NOT confirmed — a compromised host can delete offsite. Enable Hetzner's snapshots and set STORAGE_BOX_SNAPSHOTS_CONFIRMED=true."
    local self="${PBO_SELF_BIN:-${SELF_DIR}/pbo}"
    local ids=(); IFS=', ' read -ra ids <<<"$BACKUP_ORDER"

    # BATCH mode (restic): dump all → upload all, the SAME repo. Fallback→stream on space shortage.
    if [[ "${ENGINE:-tar}" == "restic" && "${BACKUP_MODE:-stream}" == "batch" ]]; then
        local brc=0; rdo_run_batch "${ids[@]}" || brc=$?
        (( brc == 2 )) || return "$brc"   # 2 = didn't fit → continue with stream below
        log_info "run-schedule: batch didn't fit in the cache → running stream (one-by-one) instead"
    fi

    local start okc=0 failc=0; start="$(date +%s)"
    local failed=() id
    for id in "${ids[@]}"; do
        [[ -n "$id" ]] || continue
        log_info "run-schedule: → backup $id"
        if "$self" backup --queue "$id" >/dev/null 2>&1; then
            okc=$((okc+1))
        else
            failc=$((failc+1)); failed+=("$id")
            log_warn "run-schedule: backup $id FAILED (continuing with next)"
        fi
    done
    local dur=$(( $(date +%s) - start ))

    if (( failc > 0 )); then
        notify_failure "run-schedule: ${failc}/$((okc+failc)) failed (${failed[*]}) in ${dur}s"
    else
        notify_success "run-schedule: ${okc} backups OK in ${dur}s"
    fi

    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "$( ((failc==0)) && echo ok || echo partial )" "$( ((failc==0)) && echo true || echo false )" \
            "backups_ok" "$okc" "backups_failed" "$failc" "duration_s" "$dur" "failed_vmids" "${failed[*]:-}"
    else
        log_info "run-schedule: done — ${okc} ok, ${failc} failed, ${dur}s"
    fi
    (( failc == 0 )) || return "$EX_SOFTWARE"
}

# do_status — global lock holder (+ pid liveness) and latest jobs.
do_status() {
    local holder pid alive="free" hstr
    hstr="$(read_global_holder)"
    if [[ -n "$hstr" ]]; then
        pid="$(sed -n 's/.*pid=\([0-9]\+\).*/\1/p' <<<"$hstr")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then alive="active"; else alive="stale (dead pid)"; fi
    fi
    local jobs; jobs="$(ls -1t "$JOBS_DIR" 2>/dev/null | head -5 | paste -sd',' - || true)"

    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "ok" "true" "global_lock" "${hstr:-free}" "lock_state" "$alive" "recent_jobs" "${jobs:-}"
    else
        log_info "Global lock: ${hstr:-free} [${alive}]"
        log_info "Latest jobs: ${jobs:-none}"
    fi
}
