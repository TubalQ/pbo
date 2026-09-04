# shellcheck shell=bash
# lib/list.sh — steg 5: list (offsite-inventarium) + fetch (hämta ett arkiv
# till lokal cache och verifiera). Fetch tar aldrig globalt lås (steg 1).
#
# list använder `rclone lsjson` + jq. fetch verifierar sha256 mot sidecaren —
# ett hämtat arkiv som inte matchar sin hash är korrupt och ska inte återställas.

_have_jq() { command -v jq >/dev/null 2>&1; }

# Lista arkiv för en vmid → rader "vmid|archive|size|modtime" på stdout.
_list_one_vmid() {
    local vmid="$1"
    local remote="${RCLONE_REMOTE}:${REMOTE_PATH}/${vmid}"
    rclone lsjson "$remote" 2>/dev/null | jq -r --arg v "$vmid" \
        '.[] | select(.Name|endswith(".tar.zst")) | "\($v)|\(.Name)|\(.Size)|\(.ModTime)"'
}

# Alla vmid-kataloger offsite.
_list_vmids() {
    rclone lsf "${RCLONE_REMOTE}:${REMOTE_PATH}" --dirs-only 2>/dev/null | sed 's#/$##'
}

# do_list [vmid]
do_list() {
    local only_vmid="${1:-}"
    if [[ "${ENGINE:-tar}" == "restic" ]]; then rdo_list "$only_vmid"; return $?; fi
    _have_jq || die "$EX_UNAVAILABLE" "jq krävs för 'list' men saknas (apt install jq)"

    local rows=() vmids
    if [[ -n "$only_vmid" ]]; then
        require_vmid "$only_vmid"; vmids="$only_vmid"
    else
        vmids="$(_list_vmids)"
    fi
    local v line
    for v in $vmids; do
        while IFS= read -r line; do [[ -n "$line" ]] && rows+=("$line"); done < <(_list_one_vmid "$v")
    done

    local now; now="$(date +%s)"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        local arr="" sep="" r vmid arch size mt mepoch age
        for r in "${rows[@]:-}"; do
            [[ -n "$r" ]] || continue
            IFS='|' read -r vmid arch size mt <<<"$r"
            mepoch="$(date -d "$mt" +%s 2>/dev/null || echo 0)"
            age=$(( now - mepoch ))
            arr+="${sep}{\"vmid\":\"$(json_escape "$vmid")\",\"archive\":\"$(json_escape "$arch")\",\"size_bytes\":${size:-0},\"modtime\":\"$(json_escape "$mt")\",\"age_seconds\":${age}}"
            sep=","
        done
        printf '{"command":"list","status":"ok","ok":true,"dry_run":false,"archives":[%s]}\n' "$arr"
    else
        if [[ "${#rows[@]}" -eq 0 ]]; then log_info "inga offsite-arkiv hittades."; return 0; fi
        printf '%-6s  %-46s  %10s  %s\n' "VMID" "ARKIV" "STORLEK" "ÅLDER"
        local r vmid arch size mt mepoch age
        for r in "${rows[@]}"; do
            IFS='|' read -r vmid arch size mt <<<"$r"
            mepoch="$(date -d "$mt" +%s 2>/dev/null || echo 0)"; age=$(( now - mepoch ))
            printf '%-6s  %-46s  %10s  %dd%dh\n' "$vmid" "$arch" \
                "$(numfmt --to=iec "${size:-0}" 2>/dev/null || echo "$size")" \
                $(( age/86400 )) $(( (age%86400)/3600 ))
        done
    fi
}

# _fetch_core <vmid> <ts> — hämtar arkiv+sidecars till cache/restore och
# verifierar sha256. Sätter FETCHED_ARCHIVE. Ingen JSON-utmatning (återanvänds
# av restore). die vid fel. rclone copy hoppar över redan hämtade filer.
FETCHED_ARCHIVE=""
_fetch_core() {
    local vmid="$1" ts="$2"
    local remote="${RCLONE_REMOTE}:${REMOTE_PATH}/${vmid}"
    local restoredir="${CACHE_DIR}/restore"
    local job_id="fetch-${vmid}-$(date +%Y%m%d-%H%M%S)"
    local jobfile="${JOBS_DIR}/${job_id}.log"
    mkdir -p "$restoredir" "$JOBS_DIR"

    local base
    base="$(rclone lsf "$remote" 2>/dev/null | grep -E "^vzdump-lxc-${vmid}-.*${ts}.*\.tar\.zst$" | head -1 || true)"
    [[ -n "$base" ]] || die "$EX_DATAERR" "hittar inget offsite-arkiv för vmid $vmid ts '$ts'"

    log_info "fetch $vmid: $base → $restoredir"
    if ! run_stream "$jobfile" "rclone-fetch[$vmid]" -- \
            rclone copy "$remote" "$restoredir" --include "${base}*" \
                --transfers "$RCLONE_TRANSFERS" --checkers "$RCLONE_CHECKERS" --stats 5s --stats-one-line; then
        die "$EX_UNAVAILABLE" "rclone copy (fetch) misslyckades för $base"
    fi

    local archive="${restoredir}/${base}"
    [[ -f "$archive" && -f "${archive}.sha256" ]] || die "$EX_DATAERR" "arkiv eller sha256-sidecar saknas efter fetch"
    if ( cd "$restoredir" && sha256sum -c "${base}.sha256" >/dev/null 2>&1 ); then
        log_info "fetch $vmid: sha256 verifierad ✓"
    else
        rm -f "$archive"
        die "$EX_DATAERR" "sha256 STÄMMER EJ för hämtat $base — raderat, återställ ej"
    fi
    FETCHED_ARCHIVE="$archive"
}

# do_fetch <vmid> <ts> — CLI-kommandot: _fetch_core + resultat.
do_fetch() {
    local vmid="$1" ts="$2"
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] skulle hämta arkiv för vmid $vmid ts '$ts' → ${CACHE_DIR}/restore"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$vmid"
        return "$EX_OK"
    fi
    _fetch_core "$vmid" "$ts"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "fetched" "true" "vmid" "$vmid" "archive" "$FETCHED_ARCHIVE" "verified" "sha256"
    else
        log_info "fetch $vmid: KLART — $FETCHED_ARCHIVE (sha256-verifierat)"
    fi
    return "$EX_OK"
}
