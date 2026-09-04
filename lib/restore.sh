# shellcheck shell=bash
# lib/restore.sh — steg 6: restore (fetch + pct restore till NYTT vmid).
#
# Hårda regler (PLAN.md §2/§6):
#   - Återställ ALLTID till ett nytt vmid; skriv aldrig över ett existerande.
#   - Läs `unprivileged` ur arkivets config och sätt flaggan EXPLICIT (förlita
#     dig inte på pct-default).
#   - Kräv --yes för att faktiskt köra; utan den, skriv ut kommandot.
#   - Bind-mounts finns inte i arkivet → varna att de måste återskapas manuellt
#     (pct set); visa config-sidecaren.
# Tar per-vmid-lås på MÅL-vmid, aldrig globalt lås.

# do_restore <src_vmid> <ts> <new_vmid> <storage|""> <yes:0|1>
do_restore() {
    local src="$1" ts="$2" newid="$3" storage="$4" yes="$5"
    if [[ "${ENGINE:-tar}" == "restic" ]]; then rdo_restore "$src" "$ts" "$newid" "$storage" "$yes"; return $?; fi

    # Mål-vmid får inte finnas.
    if pct config "$newid" >/dev/null 2>&1; then
        die "$EX_USAGE" "mål-vmid $newid finns redan — restore vägrar skriva över"
    fi

    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] skulle hämta $src ($ts) och pct restore → nytt vmid $newid"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$src" "target_vmid" "$newid"
        return "$EX_OK"
    fi

    # Säkra arkivet lokalt (hämtar + verifierar sha256 om ej redan i cache).
    _fetch_core "$src" "$ts"
    local archive="$FETCHED_ARCHIVE"

    # Läs unprivileged ur config-sidecaren (default 1 om okänd).
    local unpriv=1
    if [[ -f "${archive}.conf" ]]; then
        unpriv="$(awk -F': ' '/^unprivileged:/{print $2; exit}' "${archive}.conf")"
        [[ "$unpriv" =~ ^[01]$ ]] || unpriv=1
    fi

    # Standard-storage: rootfs-poolen ur meta, annars nvmepool.
    if [[ -z "$storage" ]]; then
        storage="$(jq -r '.source_volumes[0] // empty' "${archive}.meta.json" 2>/dev/null | cut -d'|' -f1)"
        [[ -n "$storage" && "$storage" != "null" ]] || storage="nvmepool"
    fi

    # Bind-mount-varning (de finns inte i arkivet).
    local bm
    bm="$(jq -r '.bind_mounts_skipped[]?' "${archive}.meta.json" 2>/dev/null | paste -sd' ' -)"
    [[ -n "$bm" ]] && log_warn "restore: bind-mounts fanns EJ i arkivet och måste återskapas manuellt med 'pct set $newid ...': $bm (se ${archive}.conf)"

    local cmd=(pct restore "$newid" "$archive" --storage "$storage" --unprivileged "$unpriv")

    # Utan --yes: visa kommandot, kör inte.
    if [[ "$yes" != "1" ]]; then
        log_info "restore (visning, kör med --yes): ${cmd[*]}"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "planned" "true" \
            "vmid" "$src" "target_vmid" "$newid" "storage" "$storage" \
            "unprivileged" "$unpriv" "restore_command" "${cmd[*]}"
        return "$EX_OK"
    fi

    # Kör.
    local job_id="restore-${newid}-$(date +%Y%m%d-%H%M%S)"
    local jobfile="${JOBS_DIR}/${job_id}.log"
    audit_log "restore src=$src ts=$ts target=$newid storage=$storage unprivileged=$unpriv"
    log_info "restore: ${cmd[*]}"
    if ! run_stream "$jobfile" "pct-restore[$newid]" -- "${cmd[@]}"; then
        die "$EX_SOFTWARE" "pct restore misslyckades för mål $newid (se $jobfile)"
    fi

    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "restored" "true" "vmid" "$src" "target_vmid" "$newid" \
            "storage" "$storage" "unprivileged" "$unpriv" "job" "$jobfile"
    else
        log_info "restore: KLART → CT $newid (unprivileged=$unpriv, storage=$storage). Kontrollera ev. bind-mounts."
    fi
    return "$EX_OK"
}
