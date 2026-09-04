# shellcheck shell=bash
# lib/restic.sh — restic-motorn (ADR 0001, Väg A). Aktiveras med ENGINE=restic.
#
# vzdump-arkivet (OKOMPRIMERAT) lagras I restic i stället för att pushas som
# tar.zst via rclone. restore går via `restic restore` → `pct restore`.
#
# Repo-modell:
#   LOCAL_REPO=true  (cached)      : backup → RESTIC_CACHE_REPO → copy → RESTIC_OFFSITE_REPO
#   LOCAL_REPO=false (offsite-only): backup → RESTIC_OFFSITE_REPO direkt (dumpdir transient)
#
# Grupperingsknep: vi backar upp KATALOGEN $CACHE_DIR/<vmid> (stabil path per
# gäst) → snapshotens .paths blir stabil → `forget --group-by paths` ger
# behåll-per-gäst. ts läggs som TAGG (ts=YYYY_MM_DD-HH_MM_SS) för urval, vmid som
# tagg för migrations-säkerhet. Sidecaren (.conf) följer med i snapshoten.

# --- restic-wrapper: repo + lösen + egen metadata-cache + ev. native-sftp-kommando ---
# Används av ALLA restic-anrop (även via run_stream) så sftp.command sätts på ETT
# ställe. Kör som funktion i run_streams subshell (funktioner ärvs).
_restic() {                    # _restic <repo> <args...>
    local opts=()
    [[ -n "${RESTIC_SFTP_COMMAND:-}" ]] && opts=(-o "sftp.command=${RESTIC_SFTP_COMMAND}")
    [[ -n "${RESTIC_SFTP_CONNECTIONS:-}" ]] && opts+=(-o "sftp.connections=${RESTIC_SFTP_CONNECTIONS}")
    RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
    RESTIC_FROM_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
    RESTIC_CACHE_DIR="$RESTIC_CACHE_DIR" \
        "$RESTIC_BIN" -r "$1" "${opts[@]}" "${@:2}"
}

# Primärt LÄS-repo (list/restore/prune): offsite om aktiverat, annars cache.
_restic_read_repo() {
    if [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        printf '%s' "$RESTIC_OFFSITE_REPO"
    else
        printf '%s' "$RESTIC_CACHE_REPO"
    fi
}

# Primärt SKRIV-repo (backup): cache i cached-läge, annars offsite direkt.
_restic_write_repo() {
    if [[ "${LOCAL_REPO:-true}" == "true" ]]; then printf '%s' "$RESTIC_CACHE_REPO"
    else printf '%s' "$RESTIC_OFFSITE_REPO"; fi
}

# Säkerställ repo (init om ej). Extra args → init.
_restic_ensure() {             # _restic_ensure <repo> [init-args...]
    local repo="$1"; shift
    _restic "$repo" cat config >/dev/null 2>&1 && return 0
    log_info "restic: init repo $repo"
    _restic "$repo" init "$@"
}

# restic_init — init cache- och/eller offsite-repo (onboarding, idempotent).
restic_init() {
    [[ -r "$RESTIC_PASSWORD_FILE" ]] || die "$EX_CONFIG" "restic: saknar lösenfil $RESTIC_PASSWORD_FILE (0600)"
    if [[ "${LOCAL_REPO:-true}" == "true" ]]; then
        _restic_ensure "$RESTIC_CACHE_REPO" || die "$EX_SOFTWARE" "restic: init cache-repo misslyckades"
    fi
    if [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        if [[ "${LOCAL_REPO:-true}" == "true" ]]; then
            _restic_ensure "$RESTIC_OFFSITE_REPO" --copy-chunker-params --from-repo "$RESTIC_CACHE_REPO" \
                || die "$EX_SOFTWARE" "restic: init offsite-repo misslyckades"
        else
            _restic_ensure "$RESTIC_OFFSITE_REPO" || die "$EX_SOFTWARE" "restic: init offsite-repo misslyckades"
        fi
    fi
}

# ---------------------------------------------------------------------------
# backup
# ---------------------------------------------------------------------------
rdo_backup() {
    local vmid="$1"
    local mode; mode="$(_effective_mode "$vmid")"
    local gtype="lxc"                     # TODO qemu (ADR 0002): qm config-detektering
    local dumpdir="${CACHE_DIR}/${vmid}"
    local job_id="backup-${vmid}-$(date +%Y%m%d-%H%M%S)"
    local jobfile="${JOBS_DIR}/${job_id}.log"

    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] restic backup vmid $vmid (mode $mode)"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$vmid" "engine" "restic"
        return "$EX_OK"
    fi

    restic_init
    # Ren dumpdir → snapshotens innehåll = exakt denna körnings arkiv+sidecar.
    rm -f "${dumpdir}"/vzdump-* 2>/dev/null || true
    mkdir -p "$dumpdir" "$JOBS_DIR"

    # 1. vzdump OKOMPRIMERAT (restic komprimerar själv → dedup fungerar)
    log_info "backup $vmid: vzdump ($mode, okomprimerad) → $dumpdir"
    if ! run_stream "$jobfile" "vzdump[$vmid]" -- \
            vzdump "$vmid" --mode "$mode" --compress 0 --dumpdir "$dumpdir"; then
        die "$EX_SOFTWARE" "vzdump misslyckades för vmid $vmid (se $jobfile)"
    fi
    local archive; archive="$(ls -1t "${dumpdir}"/vzdump-*-"${vmid}"-*.tar 2>/dev/null | head -1)"
    [[ -n "$archive" && -f "$archive" ]] || die "$EX_SOFTWARE" "ingen okomprimerad vzdump-tar i $dumpdir"
    local base; base="$(basename "$archive")"
    local ts; ts="$(_archive_ts "$base")"; [[ -n "$ts" ]] || ts="$(date +%Y_%m_%d-%H_%M_%S)"
    # config-sidecar för restore (unprivileged/bind-mounts)
    pct config "$vmid" > "${archive}.conf" 2>/dev/null || true

    # 2. restic backup av KATALOGEN (stabil path → grupperingsvänligt)
    local wrepo; wrepo="$(_restic_write_repo)"
    log_info "backup $vmid: restic backup → $wrepo (tags vmid=$vmid,ts=$ts)"
    if ! run_stream "$jobfile" "restic-backup[$vmid]" -- \
            _restic "$wrepo" backup "$dumpdir" \
                --tag "vmid=$vmid" --tag "ts=$ts" --tag "type=$gtype" --host "$(hostname -s)"; then
        die "$EX_SOFTWARE" "restic backup misslyckades för $base (se $jobfile)"
    fi

    # 3. cached-läge: copy nya snapshoten → offsite
    if [[ "${LOCAL_REPO:-true}" == "true" && "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        log_info "backup $vmid: restic copy cache → offsite"
        if ! run_stream "$jobfile" "restic-copy[$vmid]" -- \
                _restic "$RESTIC_OFFSITE_REPO" copy --from-repo "$RESTIC_CACHE_REPO" --tag "vmid=$vmid,ts=$ts"; then
            die "$EX_UNAVAILABLE" "restic copy → offsite misslyckades för vmid $vmid"
        fi
    fi

    # 4. städa lös tar (bor nu i repot)
    rm -f "${dumpdir}"/vzdump-* 2>/dev/null || true

    local rrepo; rrepo="$(_restic_read_repo)"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "uploaded" "true" "vmid" "$vmid" "ts" "$ts" "engine" "restic" \
            "archive" "$base" "repo" "$rrepo" "job" "$jobfile"
    else
        log_info "backup $vmid: KLART (restic) — ts=$ts"
    fi
    return "$EX_OK"
}

# ---------------------------------------------------------------------------
# list — emittera SAMMA envelope som tar-motorn ({archives:[...]}) så UI:t orört.
# ---------------------------------------------------------------------------
rdo_list() {
    local only="${1:-}"
    local repo; repo="$(_restic_read_repo)"
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq krävs för list"
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
              archive:("vzdump-\($typ)-\($vmid)-\($ts).tar"),
              size_bytes:((.summary.total_bytes_processed) // (.summary.data_added) // 0),
              modtime:.time, age_seconds:0, snapshot:.short_id } ]' 2>/dev/null || echo '[]')"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        printf '{"command":"list","status":"ok","ok":true,"dry_run":false,"archives":%s}\n' "$archives"
    else
        printf '%-6s  %-42s  %12s  %s\n' VMID ARKIV STORLEK SNAP
        printf '%s' "$archives" | jq -r '.[] | "\(.vmid)  \(.archive)  \(.size_bytes)  \(.snapshot)"'
    fi
}

# ---------------------------------------------------------------------------
# extraktion: hämta+verifiera en snapshot till <target>, echo:a tar-sökväg.
# ---------------------------------------------------------------------------
# Sätter GLOBALEN RX_TAR (INTE via stdout — log_info går till stdout i icke-json-
# läge och skulle förorena command-substitution → trasig pct-restore-sökväg).
RX_TAR=""
_restic_extract() {            # _restic_extract <vmid> <ts> <target> → RX_TAR
    local vmid="$1" ts="$2" target="$3"
    RX_TAR=""
    local repo; repo="$(_restic_read_repo)"
    mkdir -p "$target"
    local id
    id="$(_restic "$repo" snapshots --json --tag "vmid=$vmid,ts=$ts" 2>/dev/null | jq -r '.[-1].short_id // empty')"
    [[ -n "$id" ]] || { log_error "restic: ingen snapshot vmid=$vmid ts=$ts i $repo"; return 1; }
    log_info "restic restore snapshot $id → $target (verifierar vid utläsning)"
    _restic "$repo" restore "$id" --target "$target" >/dev/null 2>&1 \
        || { log_error "restic restore misslyckades (snap $id)"; return 1; }
    RX_TAR="$(find "$target" -type f -name 'vzdump-*.tar' | head -1)"
    [[ -n "$RX_TAR" ]] || { log_error "restic: ingen tar i återställd snapshot $id"; return 1; }
    return 0
}

# Läs unprivileged ur .conf-sidecar bredvid taren (default 1).
_conf_unpriv() {               # _conf_unpriv <tar>
    local conf="${1}.conf" u=1
    [[ -f "$conf" ]] && { u="$(awk -F': ' '/^unprivileged:/{print $2; exit}' "$conf")"; [[ "$u" =~ ^[01]$ ]] || u=1; }
    printf '%s' "$u"
}

# ---------------------------------------------------------------------------
# restore — restic → pct restore till NYTT vmid (aldrig överskrivning).
# ---------------------------------------------------------------------------
rdo_restore() {
    local src="$1" ts="$2" newid="$3" storage="$4" yes="$5"
    pct config "$newid" >/dev/null 2>&1 && die "$EX_USAGE" "mål-vmid $newid finns redan — vägrar"
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] restic restore $src ($ts) → nytt vmid $newid"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$src" "target_vmid" "$newid"
        return "$EX_OK"
    fi
    local rdir="${CACHE_DIR}/restore-${newid}"; rm -rf "$rdir"
    _restic_extract "$src" "$ts" "$rdir" || die "$EX_DATAERR" "restic-extraktion misslyckades"
    local tar="$RX_TAR"
    local unpriv; unpriv="$(_conf_unpriv "$tar")"
    [[ -n "$storage" ]] || storage="nvmepool"
    local cmd=(pct restore "$newid" "$tar" --storage "$storage" --unprivileged "$unpriv")
    if [[ "$yes" != "1" ]]; then
        log_info "restore (visning, kör med --yes): ${cmd[*]}"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "planned" "true" "vmid" "$src" \
            "target_vmid" "$newid" "storage" "$storage" "restore_command" "${cmd[*]}"
        rm -rf "$rdir" 2>/dev/null || true
        return "$EX_OK"
    fi
    local jobfile="${JOBS_DIR}/restore-${newid}-$(date +%Y%m%d-%H%M%S).log"
    audit_log "restore src=$src ts=$ts target=$newid storage=$storage unprivileged=$unpriv engine=restic"
    if ! run_stream "$jobfile" "pct-restore[$newid]" -- "${cmd[@]}"; then
        die "$EX_SOFTWARE" "pct restore misslyckades för mål $newid (se $jobfile)"
    fi
    rm -rf "$rdir" 2>/dev/null || true
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "restored" "true" "vmid" "$src" "target_vmid" "$newid" "storage" "$storage" "engine" "restic"
    else
        log_info "restore: KLART → CT $newid (restic, unprivileged=$unpriv, storage=$storage)"
    fi
    return "$EX_OK"
}

# ---------------------------------------------------------------------------
# test-restore — full kedja mot engångs-vmid (återanvänder _tr_* ur testrestore.sh).
# ---------------------------------------------------------------------------
rdo_test_restore() {
    local vmid="$1"
    local repo; repo="$(_restic_read_repo)"
    local ts
    ts="$(_restic "$repo" snapshots --json --tag "vmid=$vmid" 2>/dev/null \
        | jq -r '[ .[] | (.tags // []) | map(select(startswith("ts=")))[0] // empty | sub("ts=";"") ] | sort | last // empty')"
    [[ -n "$ts" ]] || die "$EX_DATAERR" "test-restore: inga restic-snapshots för vmid $vmid"
    local target; target="$(_tr_pick_target)" || die "$EX_UNAVAILABLE" "inget ledigt engångs-vmid 9000–9099"
    audit_log "test-restore vmid=$vmid ts=$ts throwaway=$target engine=restic"
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] test-restore $vmid ($ts) → engångs-$target"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$vmid" "throwaway" "$target"
        return "$EX_OK"
    fi
    local rdir="${CACHE_DIR}/restore-${target}"; rm -rf "$rdir"
    local jobfile="${JOBS_DIR}/testrestore-${vmid}-$(date +%Y%m%d-%H%M%S).log"
    _restic_extract "$vmid" "$ts" "$rdir" || die "$EX_DATAERR" "restic-extraktion misslyckades"
    local tar="$RX_TAR"
    local unpriv; unpriv="$(_conf_unpriv "$tar")"
    local storage="${TR_STORAGE:-nvmepool}"
    local ok=1 stage=""
    if ! run_stream "$jobfile" "pct-restore[$target]" -- \
            pct restore "$target" "$tar" --storage "$storage" --unprivileged "$unpriv"; then ok=0; stage="restore"; fi
    if (( ok )) && ! run_stream "$jobfile" "pct-start[$target]" -- pct start "$target"; then ok=0; stage="start"; fi
    if (( ok )); then log_info "test-restore: väntar på att CT $target svarar…"; _tr_wait "$target" || { ok=0; stage="respond"; }; fi
    _tr_destroy "$target"; rm -rf "$rdir" 2>/dev/null || true
    if (( ok )); then
        notify_success "test-restore OK: vmid $vmid ($ts) bootade på engångs-$target (restic)"
        if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_result "test_ok" "true" "vmid" "$vmid" "ts" "$ts" "throwaway" "$target"
        else log_info "test-restore: ✅ vmid $vmid bootade från restic (engångs-$target städad)"; fi
        return "$EX_OK"
    fi
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "test_failed" "false" "vmid" "$vmid" "stage" "$stage" "throwaway" "$target"
    die "$EX_SOFTWARE" "test-restore MISSLYCKADES i steg '$stage' för vmid $vmid"
}

# ---------------------------------------------------------------------------
# prune — restic forget/prune. Envelope {cache_deleted,offsite_deleted} som UI:t.
# offsite_deleted = borttagna snapshot-id (offsite/läs-repot). --group-by paths
# ger behåll-per-gäst (stabil dumpdir-path).
# ---------------------------------------------------------------------------
# _restic_forget_json <repo> <keep-flags...> → JSON-array av borttagna short_id.
# --group-by paths ger behåll-per-gäst (stabil dumpdir-path).
_restic_forget_json() {
    local repo="$1"; shift
    # `forget --json` ALLENA ger en ren remove-lista (ett json-värde). Kör INTE
    # --prune här (det strukturerar om outputen); reclaima utrymme separat nedan.
    local fflags=(forget --group-by paths "$@" --json)
    [[ "${DRY_RUN:-0}" == 1 ]] && fflags+=(--dry-run)
    local out; out="$(_restic "$repo" "${fflags[@]}" 2>/dev/null || echo '[]')"
    local removed; removed="$(printf '%s' "$out" | jq -cs '[ (.[0] // []) | .[]? | .remove[]?.short_id ]' 2>/dev/null || echo '[]')"
    # Skarp körning som faktiskt tog bort snapshots → reclaima packfiler separat.
    if [[ "${DRY_RUN:-0}" != 1 && "$(printf '%s' "$removed" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]]; then
        _restic "$repo" prune >/dev/null 2>&1 || log_warn "restic prune ($repo) gav fel — utrymme ej helt återvunnet"
    fi
    printf '%s' "$removed"
}

# prune — cache-repot prunas keep-last, offsite prunas REN GFS. I cached-läge
# prunas BÅDA. Envelope {cache_deleted, offsite_deleted} = borttagna id per repo.
rdo_prune() {
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq krävs för prune"
    local cache_removed='[]' offsite_removed='[]'
    # Lokalt cache-repo: keep-last (snabb restore-tier).
    if [[ "${LOCAL_REPO:-true}" == "true" ]]; then
        cache_removed="$(_restic_forget_json "$RESTIC_CACHE_REPO" --keep-last "${RESTIC_KEEP_LAST}")"
    fi
    # Offsite: ren GFS (daily/weekly/monthly) — inget keep-last (cache-koncept).
    if [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
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
        log_info "prune (restic): cache tog bort $nc, offsite tog bort $no$( [[ "${DRY_RUN:-0}" == 1 ]] && echo ' (dry-run)')"
    fi
    return "$EX_OK"
}

# usage — repo-storlek/dedup ur `restic stats` (för Metrics-fliken/dashboarden).
rdo_usage() {
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq krävs för usage"
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
        log_info "usage: fysiskt $(jq -r '.total_size//0' <<<"$raw") B, logiskt $(jq -r '.total_size//0' <<<"$rest") B, snapshots $(jq -r '.snapshots_count//0' <<<"$raw")"
    fi
    return "$EX_OK"
}

# verify — restic check (light) el. --read-data (djup) via VERIFY_READ_DATA=1.
rdo_verify() {
    local repo; repo="$(_restic_read_repo)"
    local args=(check); [[ "${VERIFY_READ_DATA:-0}" == 1 ]] && args+=(--read-data)
    if _restic "$repo" "${args[@]}" >/dev/null 2>&1; then
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "ok" "true" "engine" "restic" "repo" "$repo" || log_info "verify: OK ($repo)"
        return "$EX_OK"
    fi
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "failed" "false" "engine" "restic" "repo" "$repo"
    die "$EX_DATAERR" "restic check FAILADE för $repo"
}
