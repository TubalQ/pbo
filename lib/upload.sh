# shellcheck shell=bash
# lib/upload.sh — step 4: rclone copy → verify offsite.
#
# Order (PLAN.md §2): verify locally (step 3) BEFORE upload; verify on
# offsite BEFORE any local prune (step 7). An archive that was never verified
# is not a backup.
#
# Gotchas handled here:
#   - NEVER --inplace: rclone uploads to a temp name and renames on
#     completion → an aborted upload leaves no visible half archive offsite.
#   - crypt remote → `rclone cryptcheck` (not `check --checksum`; crypt
#     exposes no comparable hashes). check --checksum is used for non-crypt.
#   - transfers+checkers are kept under Hetzner's connection limit (10) via config.

# Type of RCLONE_REMOTE (sftp/crypt/…) — controls the choice of verification command.
remote_type() {
    rclone config show "$RCLONE_REMOTE" 2>/dev/null | awk '/^type[[:space:]]*=/{print $NF; exit}'
}

# Built remote destination for a vmid.
_remote_dest() { printf '%s:%s/%s' "$RCLONE_REMOTE" "$REMOTE_PATH" "$1"; }

# do_upload <vmid> <archive> <jobfile>
# Uploads the archive + its sidecars (.sha256/.meta.json/.conf).
do_upload() {
    local vmid="$1" archive="$2" jobfile="$3"
    local dest; dest="$(_remote_dest "$vmid")"
    local base; base="$(basename "$archive")"
    local bwlimit=()
    [[ -n "${RCLONE_BWLIMIT:-}" ]] && bwlimit=(--bwlimit "$RCLONE_BWLIMIT")

    log_info "upload $vmid: $base → $dest"
    # Copy archive + sidecars in one operation via include filter (base*).
    if ! run_stream "$jobfile" "rclone-copy[$vmid]" -- \
            rclone copy "$(dirname "$archive")" "$dest" \
                --include "${base}*" \
                --transfers "$RCLONE_TRANSFERS" --checkers "$RCLONE_CHECKERS" \
                --stats 5s --stats-one-line "${bwlimit[@]}"; then
        die "$EX_UNAVAILABLE" "rclone copy failed for $base (see $jobfile)"
    fi
    log_info "upload $vmid: done"
}

# verify_offsite <vmid> <archive> <jobfile>
# crypt → cryptcheck; otherwise check --checksum. --one-way: require that our local
# files exist+match offsite (ignore any other files there). Failure → delete the
# uploaded files and abort.
verify_offsite() {
    local vmid="$1" archive="$2" jobfile="$3"
    local dest; dest="$(_remote_dest "$vmid")"
    local base srcdir type
    base="$(basename "$archive")"; srcdir="$(dirname "$archive")"
    type="$(remote_type)"

    local verifier=(rclone check --checksum)
    [[ "$type" == "crypt" ]] && verifier=(rclone cryptcheck)
    log_info "verify $vmid: ${verifier[*]} (remote type: ${type:-unknown})"

    if run_stream "$jobfile" "verify[$vmid]" -- \
            "${verifier[@]}" "$srcdir" "$dest" --one-way --include "${base}*"; then
        log_info "verify $vmid: offsite matches local ✓"
        return "$EX_OK"
    fi

    log_error "verify $vmid: offsite DOES NOT MATCH local — deleting uploaded files and aborting"
    audit_log "offsite-delete verify-error dest=$dest base=$base"
    rclone delete "$dest" --include "${base}*" >/dev/null 2>&1 || \
        log_warn "verify $vmid: could not clean up half-uploaded files — check $dest manually"
    die "$EX_DATAERR" "offsite verification FAILED for $base"
}
