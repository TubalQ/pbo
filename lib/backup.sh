# shellcheck shell=bash
# lib/backup.sh — steg 3: dump → verifiera lokalt → meta.json (ingen uppladdning).
#   + steg 3b: run_stream — realtidslogg av subprocess-output med progressiva
#     tidsstämplar till både loggfil och jobbfil. Utan detta ser en långkörande
#     vzdump/rclone ut som en hängd process, och någon dödar den mitt i.
#
# Ordning (PLAN.md §2): dump → sha256 → strukturkontroll → meta. Uppladdning
# och offsite-verifiering kommer i steg 4. Verifiera ALLTID lokalt före upload.

# ---------------------------------------------------------------------------
# Steg 3b: run_stream <jobfile> <label> -- <kommando...>
# Strömmar rad för rad, prefixat med ISO-tid och sekunder sedan start, till
# stderr (så en människa ser progress), jobbfilen och loggfilen. Returnerar
# barnets exit-kod (inte pipelinens).
# ---------------------------------------------------------------------------
run_stream() {
    local jobfile="$1" label="$2"; shift 2
    [[ "${1:-}" == "--" ]] && shift
    local start now elapsed line rc rcfile
    start="$(date +%s)"
    rcfile="$(mktemp)"
    log_info "→ $label: $*"
    # Kör kommandot i subshell, slå ihop stderr→stdout, spara rc i rcfile.
    ( "$@" 2>&1; echo $? > "$rcfile" ) | while IFS= read -r line; do
        now="$(date +%s)"; elapsed=$(( now - start ))
        printf '%s [+%5ds] %s\n' "$(date --iso-8601=seconds)" "$elapsed" "$line" \
            | { tee -a "$jobfile" >&2; } 2>/dev/null
        [[ -n "${LOG_FILE:-}" ]] && printf '%s [%s] %s\n' "$(date --iso-8601=seconds)" "$label" "$line" >> "$LOG_FILE"
    done
    rc="$(<"$rcfile")"; rm -f "$rcfile"
    log_info "← $label: klart (rc=$rc, ${SECONDS}s totalt i processen)"
    return "${rc:-1}"
}

# ---------------------------------------------------------------------------
# Hjälpare.
# ---------------------------------------------------------------------------
get_ct_hostname() { pct config "$1" 2>/dev/null | awk -F': ' '/^hostname:/{print $2; exit}'; }

# mk_json_array <array-namn> → JSON-strängarray (tom = []).
mk_json_array() {
    local -n _arr="$1"
    local out="[" sep="" e
    for e in "${_arr[@]:-}"; do
        [[ -n "$e" ]] || continue
        out+="${sep}\"$(json_escape "$e")\""; sep=","
    done
    printf '%s]' "$out"
}

# Väljer tar-anrop för zstd (GNU tar --zstd om det stöds, annars pipe).
_tar_list_zstd() {
    local archive="$1"
    if tar --zstd --help >/dev/null 2>&1; then
        tar --zstd -tf "$archive" >/dev/null
    else
        zstd -dc "$archive" | tar -tf - >/dev/null
    fi
}

# ---------------------------------------------------------------------------
# meta.json — pekare-metadata bredvid arkivet (aldrig secrets).
# ---------------------------------------------------------------------------
write_meta() {
    local metafile="$1" vmid="$2" host="$3" base="$4" size="$5" sha="$6"
    local pve; pve="$(pveversion 2>/dev/null | head -1)"
    local bm ex sv
    bm="$(mk_json_array PF_BINDMOUNTS)"
    ex="$(mk_json_array PF_EXCLUDED)"
    sv="$(mk_json_array PF_BACKUP_VOLUMES)"
    cat > "$metafile" <<META
{
  "vmid": "$(json_escape "$vmid")",
  "hostname": "$(json_escape "$host")",
  "archive": "$(json_escape "$base")",
  "size_bytes": $size,
  "sha256": "$(json_escape "$sha")",
  "pve_version": "$(json_escape "$pve")",
  "mode": "$(json_escape "$VZDUMP_MODE")",
  "compress": "$(json_escape "$VZDUMP_COMPRESS")",
  "created": "$(date --iso-8601=seconds)",
  "source_volumes": $sv,
  "bind_mounts_skipped": $bm,
  "excluded_backup0": $ex
}
META
}

# ---------------------------------------------------------------------------
# do_backup <vmid> — huvudflödet för steg 3. Förutsätter att preflight redan
# körts av cmd_backup (PF_*-globalerna är satta).
# ---------------------------------------------------------------------------
do_backup() {
    local vmid="$1"
    local dumpdir="${CACHE_DIR}/${vmid}"
    local host; host="$(get_ct_hostname "$vmid")"
    local job_id="backup-${vmid}-$(date +%Y%m%d-%H%M%S)"
    local jobfile="${JOBS_DIR}/${job_id}.log"
    mkdir -p "$dumpdir" "$JOBS_DIR"

    # --- dry-run: visa planen, rör ingenting ---
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] vzdump $vmid --mode $VZDUMP_MODE --compress $VZDUMP_COMPRESS --dumpdir $dumpdir"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$vmid" "dumpdir" "$dumpdir"
        return "$EX_OK"
    fi

    # --- 1. dump (steg 3, via run_stream = steg 3b) ---
    log_info "backup $vmid: startar vzdump ($VZDUMP_MODE/$VZDUMP_COMPRESS) → $dumpdir"
    if ! run_stream "$jobfile" "vzdump[$vmid]" -- \
            vzdump "$vmid" --mode "$VZDUMP_MODE" --compress "$VZDUMP_COMPRESS" --dumpdir "$dumpdir"; then
        die "$EX_SOFTWARE" "vzdump misslyckades för vmid $vmid (se $jobfile)"
    fi

    # Hitta arkivet: parsa vzdump-utdata, annars nyaste matchande fil.
    local archive
    archive="$(grep -oE "creating vzdump archive '[^']+'" "$jobfile" | tail -1 | sed -E "s/.*'([^']+)'.*/\1/")"
    if [[ -z "$archive" || ! -f "$archive" ]]; then
        archive="$(ls -1t "${dumpdir}"/vzdump-lxc-"${vmid}"-*.tar.* 2>/dev/null | grep -vE '\.(sha256|conf)$|\.meta\.json$' | head -1)"
    fi
    [[ -n "$archive" && -f "$archive" ]] || die "$EX_SOFTWARE" "hittar inte producerat arkiv i $dumpdir"
    local base; base="$(basename "$archive")"
    local size; size="$(stat -c '%s' "$archive")"
    log_info "backup $vmid: arkiv $base ($(numfmt --to=iec "$size" 2>/dev/null || echo "$size B"))"

    # --- 2. sha256 (sidecar) ---
    local sha
    sha="$(sha256sum "$archive" | awk '{print $1}')"
    printf '%s  %s\n' "$sha" "$base" > "${archive}.sha256"
    log_info "backup $vmid: sha256 $sha"

    # --- 3. strukturkontroll: zstd -t + tar -tf ---
    log_info "backup $vmid: strukturkontroll (zstd -t + tar -tf)…"
    if ! zstd -t "$archive" >/dev/null 2>&1; then
        die "$EX_DATAERR" "zstd-integritetskontroll FAILADE för $base — arkivet dugligt EJ"
    fi
    if ! _tar_list_zstd "$archive"; then
        die "$EX_DATAERR" "tar-strukturkontroll FAILADE för $base — arkivet dugligt EJ"
    fi
    log_info "backup $vmid: strukturkontroll OK"

    # --- 4. meta.json + config-sidecar (bind-mount-återskapning vid restore) ---
    write_meta "${archive}.meta.json" "$vmid" "$host" "$base" "$size" "$sha"
    pct config "$vmid" > "${archive}.conf" 2>/dev/null || true
    log_info "backup $vmid: meta.json + config-sidecar skrivna"

    # --- 5. uppladdning + offsite-verifiering (steg 4) ---
    if [[ "${OFFSITE_ENABLED:-true}" != "true" ]]; then
        log_info "backup $vmid: OFFSITE_ENABLED=false → hoppar uppladdning (endast lokalt)."
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dumped" "true" \
            "vmid" "$vmid" "archive" "$archive" "size_bytes" "$size" \
            "sha256" "$sha" "verified" "local" "job" "$jobfile"
        return "$EX_OK"
    fi

    do_upload "$vmid" "$archive" "$jobfile"
    verify_offsite "$vmid" "$archive" "$jobfile"

    # --- resultat (prune sker i steg 7) ---
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "uploaded" "true" \
            "vmid" "$vmid" "archive" "$archive" "size_bytes" "$size" \
            "sha256" "$sha" "verified" "offsite" \
            "offsite" "$(_remote_dest "$vmid")/$base" "job" "$jobfile"
    else
        log_info "backup $vmid: KLART — uppladdat och verifierat offsite."
    fi
    return "$EX_OK"
}
