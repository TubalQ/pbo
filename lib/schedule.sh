# shellcheck shell=bash
# lib/schedule.sh — steg 9: run-schedule (schemalagd sekventiell backup) + status.
#
# EN timer, inte en per container: run-schedule betar av BACKUP_ORDER en CT i
# taget. Varje CT körs som ett eget `backup --queue`-anrop → köar på globala
# låset (manuella körningar kan alltså inte kollidera). En CT:s fel stoppar inte
# resten; hela körningen larmar via ntfy om något gick fel.

# do_run_schedule — kör backup för varje vmid i BACKUP_ORDER, sekventiellt.
do_run_schedule() {
    [[ -n "${BACKUP_ORDER:-}" ]] || die "$EX_CONFIG" "BACKUP_ORDER är tom — inget att schemalägga."
    # Ransomware-skydd: SFTP ger ingen append-only. Påminn om Storage Box-snapshots.
    [[ "${STORAGE_BOX_SNAPSHOTS_CONFIRMED:-false}" == "true" ]] || \
        log_warn "run-schedule: Storage Box-snapshots EJ bekräftade — en komprometterad host kan radera offsite. Slå på Hetzners snapshots och sätt STORAGE_BOX_SNAPSHOTS_CONFIRMED=true."
    local self="${LXCO_SELF_BIN:-${SELF_DIR}/lxc-offsite}"
    local ids=(); IFS=', ' read -ra ids <<<"$BACKUP_ORDER"

    # BATCH-läge (restic): dumpa alla → ladda upp alla, SAMMA repo. Fallback→stream vid platsbrist.
    if [[ "${ENGINE:-tar}" == "restic" && "${BACKUP_MODE:-stream}" == "batch" ]]; then
        local brc=0; rdo_run_batch "${ids[@]}" || brc=$?
        (( brc == 2 )) || return "$brc"   # 2 = rymdes ej → fortsätt med stream nedan
        log_info "run-schedule: batch rymdes ej i cachen → kör stream (1-och-1) i stället"
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
            log_warn "run-schedule: backup $id MISSLYCKADES (fortsätter med nästa)"
        fi
    done
    local dur=$(( $(date +%s) - start ))

    if (( failc > 0 )); then
        notify_failure "run-schedule: ${failc}/$((okc+failc)) misslyckades (${failed[*]}) på ${dur}s"
    else
        notify_success "run-schedule: ${okc} backuper OK på ${dur}s"
    fi

    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "$( ((failc==0)) && echo ok || echo partial )" "$( ((failc==0)) && echo true || echo false )" \
            "backups_ok" "$okc" "backups_failed" "$failc" "duration_s" "$dur" "failed_vmids" "${failed[*]:-}"
    else
        log_info "run-schedule: klart — ${okc} ok, ${failc} fel, ${dur}s"
    fi
    (( failc == 0 )) || return "$EX_SOFTWARE"
}

# do_status — globala låsets hållare (+ pid-liveness) och senaste jobb.
do_status() {
    local holder pid alive="ledigt" hstr
    hstr="$(read_global_holder)"
    if [[ -n "$hstr" ]]; then
        pid="$(sed -n 's/.*pid=\([0-9]\+\).*/\1/p' <<<"$hstr")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then alive="aktiv"; else alive="inaktuell (död pid)"; fi
    fi
    local jobs; jobs="$(ls -1t "$JOBS_DIR" 2>/dev/null | head -5 | paste -sd',' - || true)"

    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "ok" "true" "global_lock" "${hstr:-ledigt}" "lock_state" "$alive" "recent_jobs" "${jobs:-}"
    else
        log_info "Globalt lås: ${hstr:-ledigt} [${alive}]"
        log_info "Senaste jobb: ${jobs:-inga}"
    fi
}
