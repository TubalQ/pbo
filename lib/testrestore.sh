# shellcheck shell=bash
# lib/testrestore.sh — steg 8: test-restore. Full kedja mot ett ENGÅNGS-vmid:
# hämta FRÅN OFFSITE (inte cache) → verifiera → pct restore → starta → vänta på
# att containern svarar → stoppa → destroy. Rapport via ntfy (tyst vid framgång
# om inte NTFY_ON_SUCCESS=true; larm vid fel).
#
# Detta är det enda kommandot som verkligen bevisar att en offsite-backup går att
# återställa OCH boota — resten verifierar bara bytes.

_tr_destroy() {
    local id="$1"
    [[ -n "$id" ]] || return 0
    pct stop "$id" >/dev/null 2>&1 || true
    pct destroy "$id" --purge >/dev/null 2>&1 || true
}

# Vänta tills CT:n svarar på exec (eller timeout).
_tr_wait() {
    local id="$1" i
    for (( i=0; i < ${TR_WAIT_TRIES:-30}; i++ )); do
        pct exec "$id" -- true >/dev/null 2>&1 && return 0
        sleep "${TR_WAIT_SLEEP:-2}"
    done
    return 1
}

# Välj högsta lediga engångs-vmid i 9000–9099.
_tr_pick_target() {
    local n
    for (( n=9099; n >= 9000; n-- )); do
        pct config "$n" >/dev/null 2>&1 || { printf '%s' "$n"; return 0; }
    done
    return 1
}

# do_test_restore <vmid>
do_test_restore() {
    local vmid="$1"
    if [[ "${ENGINE:-tar}" == "restic" ]]; then rdo_test_restore "$vmid"; return $?; fi
    local remote="${RCLONE_REMOTE}:${REMOTE_PATH}/${vmid}"

    # Senaste offsite-arkivet för vmid:en.
    local base ts
    base="$(rclone lsf "$remote" 2>/dev/null | grep -E '\.tar\.zst$' | sort -r | head -1 || true)"
    [[ -n "$base" ]] || die "$EX_DATAERR" "test-restore: inga offsite-arkiv för vmid $vmid"
    ts="$(_archive_ts "$base")"

    local target; target="$(_tr_pick_target)" \
        || die "$EX_UNAVAILABLE" "test-restore: inget ledigt vmid i 9000–9099"
    local jobfile="${JOBS_DIR}/testrestore-${vmid}-$(date +%Y%m%d-%H%M%S).log"
    mkdir -p "$JOBS_DIR"
    audit_log "test-restore vmid=$vmid ts=$ts throwaway=$target"
    log_info "test-restore: vmid $vmid ($ts) → engångs-vmid $target"

    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] skulle hämta $vmid ($ts), restore→$target, boota, destroy"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$vmid" "throwaway" "$target"
        return "$EX_OK"
    fi

    # 1. hämta FRÅN OFFSITE (+ sha256). die städar inget — target ej skapad än.
    _fetch_core "$vmid" "$ts"
    local archive="$FETCHED_ARCHIVE"

    # unprivileged + storage ur sidecar/meta.
    local unpriv=1
    if [[ -f "${archive}.conf" ]]; then
        unpriv="$(awk -F': ' '/^unprivileged:/{print $2; exit}' "${archive}.conf")"
        [[ "$unpriv" =~ ^[01]$ ]] || unpriv=1
    fi
    local storage
    storage="$(jq -r '.source_volumes[0] // empty' "${archive}.meta.json" 2>/dev/null | cut -d'|' -f1)"
    [[ -n "$storage" && "$storage" != "null" ]] || storage="nvmepool"

    # 2–4. restore → start → svara. Från och med nu: städa target vid varje fel.
    local ok=1 stage=""
    if ! run_stream "$jobfile" "pct-restore[$target]" -- \
            pct restore "$target" "$archive" --storage "$storage" --unprivileged "$unpriv"; then
        ok=0; stage="restore"
    fi
    if (( ok )) && ! run_stream "$jobfile" "pct-start[$target]" -- pct start "$target"; then
        ok=0; stage="start"
    fi
    if (( ok )); then
        log_info "test-restore: väntar på att CT $target svarar…"
        _tr_wait "$target" || { ok=0; stage="respond"; }
    fi

    # 5. städa alltid.
    _tr_destroy "$target"

    if (( ok )); then
        notify_success "test-restore OK: vmid $vmid ($ts) återställd och bootad på engångs-$target"
        if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
            json_result "test_ok" "true" "vmid" "$vmid" "ts" "$ts" "throwaway" "$target"
        else
            log_info "test-restore: ✅ vmid $vmid bootade från offsite (engångs-$target, städad)"
        fi
        return "$EX_OK"
    fi
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "test_failed" "false" "vmid" "$vmid" "stage" "$stage" "throwaway" "$target"
    die "$EX_SOFTWARE" "test-restore MISSLYCKADES i steg '$stage' för vmid $vmid (engångs-$target städad)"
}
