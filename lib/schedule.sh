# shellcheck shell=bash
# lib/schedule.sh: step 9: run-schedule (scheduled sequential backup) + status.
#
# ONE timer, not one per container: run-schedule works through BACKUP_ORDER one CT
# at a time. Each CT runs as its own `backup --queue` call → queues on the global
# lock (so manual runs can't collide). One CT's failure doesn't stop
# the rest; the whole run alerts (ntfy and/or Proxmox notifications) if anything went wrong.

# do_run_schedule, run backup for each vmid in BACKUP_ORDER, sequentially.
do_run_schedule() {
    _guest_meta_load   # guest tags/names once for the whole run (lib/policy.sh)
    [[ "${DRY_RUN:-0}" == 1 ]] || _cache_dir_protect   # plaintext dumps: CACHE_DIR closed to local users
    # Ransomware protection: SFTP provides no append-only. Remind about Storage Box snapshots.
    [[ "${STORAGE_BOX_SNAPSHOTS_CONFIRMED:-false}" == "true" || "${OFFSITE_APPEND_ONLY:-false}" == "true" ]] || \
        log_warn "run-schedule: Storage Box snapshots NOT confirmed, a compromised host can delete offsite. Enable Hetzner's snapshots and set STORAGE_BOX_SNAPSHOTS_CONFIRMED=true."
    local self="${PBO_SELF_BIN:-${SELF_DIR}/pbo}"
    # The guests that live on THIS node: BACKUP_ORDER=auto → all local; an explicit
    # list → the listed vmids that live here (cluster-aware, no-op on one node).
    # With the Proxmox integration on, guests a PVE backup job owns are left to
    # that job (lib/ownership.sh). Loaded here, once: the <(...) below inherit it.
    _pve_jobs_load
    local mode; mode="$(_integration_mode)"
    # integration on: spool leftovers of PVE jobs first (lib/ingest.sh; a failure is a warning)
    [[ "$mode" == standalone || "${DRY_RUN:-0}" == 1 ]] || _ingest_pending_hook run-schedule
    local ids=(); mapfile -t ids < <(_timer_set)
    local skipped=(); mapfile -t skipped < <(_backup_set_skipped)
    (( ${#skipped[@]} )) && log_info "run-schedule: skipping ${skipped[*]} (Proxmox tag pbo-skip)"
    if [[ "$mode" != standalone ]] && _pve_owner_known; then
        local oid
        while read -r oid; do
            [[ -n "$oid" ]] && log_info "run-schedule: skipping $oid (owned by PVE job $(_pve_owner_job "$oid"))"
        done < <(_pve_owned_guests)
        while read -r oid; do
            [[ -n "$oid" ]] && log_warn "run-schedule: guest $oid has no owner: no PVE job that targets pbo selects it (PBO_INTEGRATION=integrated)"
        done < <(_backup_set_unowned)
    fi
    # --dry-run: say what would be backed up and stop. The per-guest `backup --queue`
    # children are separate processes that never saw --dry-run, so running the loop
    # would take REAL backups (and stop stop-mode guests).
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] run-schedule would back up: ${ids[*]:-nothing} (mode ${BACKUP_MODE:-stream})"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "would_backup" "${ids[*]:-}" "backups_ok:n" 0 "backups_failed:n" 0
        return "$EX_OK"
    fi
    if (( ${#ids[@]} == 0 )); then
        if [[ "$mode" == integrated ]]; then
            log_info "run-schedule: PBO_INTEGRATION=integrated, PVE jobs back up the guests on node '$(_local_node)', nothing to do."
            _catalog_refresh_hook run-schedule
            [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "ok" "true" "backups_ok:n" 0 "backups_failed:n" 0 "note" "integrated: PVE jobs back up the guests"
            return "$EX_OK"
        fi
        log_warn "run-schedule: no guests to back up on node '$(_local_node)' (BACKUP_ORDER=${BACKUP_ORDER:-auto}), nothing to do."
        _catalog_refresh_hook run-schedule
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "ok" "true" "backups_ok:n" 0 "backups_failed:n" 0 "note" "no local guests"
        return "$EX_OK"
    fi

    # BATCH mode: dump all → upload all, the SAME repo. Fallback→stream on space shortage.
    if [[ "${BACKUP_MODE:-stream}" == "batch" ]]; then
        local brc=0; rdo_run_batch "${ids[@]}" || brc=$?
        (( brc == 2 )) || { _catalog_refresh_hook run-schedule; return "$brc"; }   # 2 = didn't fit → continue with stream below
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
            "backups_ok:n" "$okc" "backups_failed:n" "$failc" "duration_s:n" "$dur" "failed_vmids" "${failed[*]:-}"
    else
        log_info "run-schedule: done, ${okc} ok, ${failc} failed, ${dur}s"
    fi
    RS_FAILED="$failc"   # for the run_schedule metrics (pbo _pbo_on_exit)
    # with the Proxmox integration on, the PVE storage view shows the new snapshots
    _catalog_refresh_hook run-schedule
    (( failc == 0 )) || return "$EX_SOFTWARE"
}

# do_status, global lock holder (+ pid liveness) and latest jobs.
# _lock_json <holder-file> <fields> → {state, vmid?, op, pid, since_s} or {state:"free"}
# The holder file is "vmid|op|pid|since" (global) or "op|pid|since" (schedule).
_lock_json() {
    local f="$1" fields="$2" line vmid="" op pid since state
    [[ -f "$f" ]] || { printf '{"state":"free"}'; return 0; }
    line="$(<"$f")"
    if [[ "$fields" == global ]]; then IFS='|' read -r vmid op pid since <<<"$line"
    else IFS='|' read -r op pid since <<<"$line"; fi
    [[ "$pid" =~ ^[0-9]+$ ]] || pid=0; [[ "$since" =~ ^[0-9]+$ ]] || since="$(date +%s)"
    if (( pid > 0 )) && kill -0 "$pid" 2>/dev/null; then state=held; else state=stale; fi
    jq -cn --arg st "$state" --arg vmid "$vmid" --arg op "$op" --argjson pid "$pid" \
        --argjson since "$since" --argjson now "$(date +%s)" \
        '{state:$st, op:$op, pid:$pid, since:($since|todate), held_s:($now - $since)}
         + (if $vmid != "" then {vmid:$vmid} else {} end)'
}

# status --json: locks + the newest job logs (the job model extends this).
_status_json() {
    local jobs; jobs="$(ls -1t "$JOBS_DIR" 2>/dev/null | head -10 || true)"
    local active='' id
    while read -r id; do
        [[ -n "$id" && ! -e "$(_job_dir "$id")/result.json" ]] || continue
        active+="$(_job_json "$id" 2>/dev/null | jq -c 'select(.state | IN("running","queued","starting")) | {id, command, args, state, started_by, created}')"$'\n'
    done < <(find "$(_runs_dir)" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' -printf '%f\n' 2>/dev/null | sort -n)
    active="$(printf '%s' "$active" | jq -cs '.')"
    jq -cn --argjson active "$active" --argjson g "$(_lock_json "$GLOBAL_HOLDER_FILE" global)" --argjson s "$(_lock_json "$SCHED_HOLDER_FILE" schedule)" \
        --arg jobs "$jobs" --arg node "$(_local_node)" --arg role "${PBO_ROLE:-host}" --arg integ "$(_integration_mode)" \
        '{status:"ok", ok:true, node:$node, role:$role, integration:$integ, locks:{global:$g, schedule:$s},
          recent_job_logs: ($jobs | split("\n") | map(select(length > 0))), jobs_active: $active}' | json_emit
}

do_status() {
    local holder pid alive="free" hstr
    hstr="$(read_global_holder)"
    if [[ -n "$hstr" ]]; then
        pid="$(sed -n 's/.*pid=\([0-9]\+\).*/\1/p' <<<"$hstr")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then alive="active"; else alive="stale (dead pid)"; fi
    fi
    local jobs; jobs="$(ls -1t "$JOBS_DIR" 2>/dev/null | head -5 | paste -sd',' - || true)"

    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        _status_json
    else
        log_info "Global lock: ${hstr:-free} [${alive}]"
        log_info "Latest jobs: ${jobs:-none}"
    fi
}
