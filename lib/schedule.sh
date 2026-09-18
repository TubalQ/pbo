# shellcheck shell=bash
# lib/schedule.sh: step 9: run-schedule (scheduled sequential backup) + status.
#
# ONE timer, not one per container: run-schedule works through BACKUP_ORDER one CT
# at a time. Each CT runs as its own `backup --queue` call → queues on the global
# lock (so manual runs can't collide). One CT's failure doesn't stop
# the rest; the whole run alerts via ntfy if anything went wrong.

# do_run_schedule, run backup for each vmid in BACKUP_ORDER, sequentially.
do_run_schedule() {
    # Ransomware protection: SFTP provides no append-only. Remind about Storage Box snapshots.
    [[ "${STORAGE_BOX_SNAPSHOTS_CONFIRMED:-false}" == "true" ]] || \
        log_warn "run-schedule: Storage Box snapshots NOT confirmed, a compromised host can delete offsite. Enable Hetzner's snapshots and set STORAGE_BOX_SNAPSHOTS_CONFIRMED=true."
    local self="${PBO_SELF_BIN:-${SELF_DIR}/pbo}"
    # The guests that live on THIS node: BACKUP_ORDER=auto → all local; an explicit
    # list → the listed vmids that live here (cluster-aware, no-op on one node).
    local ids=(); mapfile -t ids < <(_backup_set)
    if (( ${#ids[@]} == 0 )); then
        log_warn "run-schedule: no guests to back up on node '$(_local_node)' (BACKUP_ORDER=${BACKUP_ORDER:-auto}), nothing to do."
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "ok" "true" "backups_ok" 0 "backups_failed" 0 "note" "no local guests"
        return "$EX_OK"
    fi

    # BATCH mode: dump all → upload all, the SAME repo. Fallback→stream on space shortage.
    if [[ "${BACKUP_MODE:-stream}" == "batch" ]]; then
        local brc=0; rdo_run_batch "${ids[@]}" || brc=$?
        (( brc == 2 )) || return "$brc"   # 2 = didn't fit → continue with stream below
        log_info "run-schedule: batch didn't fit in the cache → running stream (one-by-one) instead"
    fi

    local start okc=0 failc=0; start="$(date +%s)"
    local failed=() first_reason="" id out
    for id in "${ids[@]}"; do
        [[ -n "$id" ]] || continue
        log_info "run-schedule: → backup $id"
        # Capture output so a failure carries WHY into the log and the alert,
        # instead of just "$id FAILED" with the reason buried in the job file.
        if out="$("$self" backup --queue "$id" 2>&1)"; then
            okc=$((okc+1))
        else
            failc=$((failc+1)); failed+=("$id")
            local reason; reason="$(printf '%s\n' "$out" | grep -iE '\[ERROR\]|failed|denied|locked' | tail -1 || true)"
            [[ -n "$reason" ]] || reason="$(printf '%s\n' "$out" | tail -1 || true)"
            [[ -n "$first_reason" ]] || first_reason="$id: $reason"
            log_warn "run-schedule: backup $id FAILED (continuing) - ${reason:-see job log}"
        fi
    done
    local dur=$(( $(date +%s) - start ))

    if (( failc > 0 )); then
        notify_failure "run-schedule: ${failc}/$((okc+failc)) failed (${failed[*]}) in ${dur}s. ${first_reason}"
    else
        notify_success "run-schedule: ${okc} backups OK in ${dur}s"
    fi

    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "$( ((failc==0)) && echo ok || echo partial )" "$( ((failc==0)) && echo true || echo false )" \
            "backups_ok" "$okc" "backups_failed" "$failc" "duration_s" "$dur" "failed_vmids" "${failed[*]:-}"
    else
        log_info "run-schedule: done, ${okc} ok, ${failc} failed, ${dur}s"
    fi
    (( failc == 0 )) || return "$EX_SOFTWARE"
}

# do_status, global lock holder (+ pid liveness) and latest jobs.
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
