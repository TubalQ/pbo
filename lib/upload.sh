# shellcheck shell=bash
# lib/upload.sh — steg 4: rclone copy → verifiera på offsite.
#
# Ordning (PLAN.md §2): verifiera lokalt (steg 3) INNAN upload; verifiera på
# offsite INNAN någon lokal prune (steg 7). Ett arkiv som aldrig verifierats
# är inte en backup.
#
# Gotchas som hanteras här:
#   - ALDRIG --inplace: rclone laddar upp till temp-namn och byter namn vid
#     slutförande → en avbruten upload lämnar inget synligt halvt arkiv offsite.
#   - crypt-remote → `rclone cryptcheck` (inte `check --checksum`; crypt
#     exponerar inga jämförbara hashar). check --checksum används för icke-crypt.
#   - transfers+checkers hålls under Hetzners anslutningsgräns (10) via config.

# Typ på RCLONE_REMOTE (sftp/crypt/…) — styr valet av verifieringskommando.
remote_type() {
    rclone config show "$RCLONE_REMOTE" 2>/dev/null | awk '/^type[[:space:]]*=/{print $NF; exit}'
}

# Byggd fjärrdestination för en vmid.
_remote_dest() { printf '%s:%s/%s' "$RCLONE_REMOTE" "$REMOTE_PATH" "$1"; }

# do_upload <vmid> <archive> <jobfile>
# Laddar upp arkivet + dess sidecars (.sha256/.meta.json/.conf).
do_upload() {
    local vmid="$1" archive="$2" jobfile="$3"
    local dest; dest="$(_remote_dest "$vmid")"
    local base; base="$(basename "$archive")"
    local bwlimit=()
    [[ -n "${RCLONE_BWLIMIT:-}" ]] && bwlimit=(--bwlimit "$RCLONE_BWLIMIT")

    log_info "upload $vmid: $base → $dest"
    # Kopiera arkiv + sidecars i en operation via include-filter (base*).
    if ! run_stream "$jobfile" "rclone-copy[$vmid]" -- \
            rclone copy "$(dirname "$archive")" "$dest" \
                --include "${base}*" \
                --transfers "$RCLONE_TRANSFERS" --checkers "$RCLONE_CHECKERS" \
                --stats 5s --stats-one-line "${bwlimit[@]}"; then
        die "$EX_UNAVAILABLE" "rclone copy misslyckades för $base (se $jobfile)"
    fi
    log_info "upload $vmid: klar"
}

# verify_offsite <vmid> <archive> <jobfile>
# crypt → cryptcheck; annars check --checksum. --one-way: kräv att våra lokala
# filer finns+matchar offsite (ignorera ev. andra filer där). Fel → radera det
# uppladdade och avbryt.
verify_offsite() {
    local vmid="$1" archive="$2" jobfile="$3"
    local dest; dest="$(_remote_dest "$vmid")"
    local base srcdir type
    base="$(basename "$archive")"; srcdir="$(dirname "$archive")"
    type="$(remote_type)"

    local verifier=(rclone check --checksum)
    [[ "$type" == "crypt" ]] && verifier=(rclone cryptcheck)
    log_info "verify $vmid: ${verifier[*]} (remote-typ: ${type:-okänd})"

    if run_stream "$jobfile" "verify[$vmid]" -- \
            "${verifier[@]}" "$srcdir" "$dest" --one-way --include "${base}*"; then
        log_info "verify $vmid: offsite matchar lokalt ✓"
        return "$EX_OK"
    fi

    log_error "verify $vmid: offsite MATCHAR EJ lokalt — raderar uppladdat och avbryter"
    rclone delete "$dest" --include "${base}*" >/dev/null 2>&1 || \
        log_warn "verify $vmid: kunde inte städa halvt uppladdat — kontrollera $dest manuellt"
    die "$EX_DATAERR" "offsite-verifiering FAILADE för $base"
}
