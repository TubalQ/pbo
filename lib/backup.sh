# shellcheck shell=bash
# lib/backup.sh — step 3: dump → verify locally → meta.json (no upload).
#   + step 3b: run_stream — real-time logging of subprocess output with
#     progressive timestamps to both the log file and the job file. Without this
#     a long-running vzdump/rclone looks like a hung process, and someone kills
#     it mid-run.
#
# Order (PLAN.md §2): dump → sha256 → structure check → meta. Upload and
# offsite verification come in step 4. ALWAYS verify locally before upload.

# ---------------------------------------------------------------------------
# Step 3b: run_stream <jobfile> <label> -- <command...>
# Streams line by line, prefixed with ISO time and seconds since start, to
# stderr (so a human sees progress), the job file and the log file. Returns
# the child's exit code (not the pipeline's).
# ---------------------------------------------------------------------------
run_stream() {
    local jobfile="$1" label="$2"; shift 2
    [[ "${1:-}" == "--" ]] && shift
    local start now elapsed line rc rcfile
    start="$(date +%s)"
    rcfile="$(mktemp)"
    log_info "→ $label: $*"
    # Run the command in a subshell, merge stderr→stdout, save rc in rcfile.
    ( "$@" 2>&1; echo $? > "$rcfile" ) | while IFS= read -r line; do
        now="$(date +%s)"; elapsed=$(( now - start ))
        printf '%s [+%5ds] %s\n' "$(date --iso-8601=seconds)" "$elapsed" "$line" \
            | { tee -a "$jobfile" >&2; } 2>/dev/null
        [[ -n "${LOG_FILE:-}" ]] && printf '%s [%s] %s\n' "$(date --iso-8601=seconds)" "$label" "$line" >> "$LOG_FILE"
    done
    rc="$(<"$rcfile")"; rm -f "$rcfile"
    local dur=$(( $(date +%s) - start ))   # the command's OWN time (not $SECONDS = the whole process)
    log_info "← $label: done (rc=$rc, ${dur}s)"
    return "${rc:-1}"
}

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------
get_ct_hostname() { pct config "$1" 2>/dev/null | awk -F': ' '/^hostname:/{print $2; exit}'; }

# A CT with fuse=1 (podman/fuse-overlayfs) DEADLOCKS vzdump --mode snapshot AND
# suspend (the fuse mount hangs in fsfreeze/rsync-final). Must run --mode stop.
_ct_is_fuse() { pct config "$1" 2>/dev/null | grep -qE '^features:.*fuse=1'; }
_in_csv() { local n="$1" l=",${2// /},"; [[ "$l" == *",$n,"* ]]; }

# Effective vzdump mode for a vmid: stop if fuse OR in VZDUMP_STOP_VMIDS.
_effective_mode() {
    local vmid="$1"
    if _ct_is_fuse "$vmid"; then
        printf 'stop'; return
    fi
    if _in_csv "$vmid" "${VZDUMP_STOP_VMIDS:-}"; then
        printf 'stop'; return
    fi
    printf '%s' "$VZDUMP_MODE"
}

# mk_json_array <array-name> → JSON string array (empty = []).
mk_json_array() {
    local -n _arr="$1"
    local out="[" sep="" e
    for e in "${_arr[@]:-}"; do
        [[ -n "$e" ]] || continue
        out+="${sep}\"$(json_escape "$e")\""; sep=","
    done
    printf '%s]' "$out"
}

# Picks the tar invocation for zstd (GNU tar --zstd if supported, otherwise pipe).
_tar_list_zstd() {
    local archive="$1"
    if tar --zstd --help >/dev/null 2>&1; then
        tar --zstd -tf "$archive" >/dev/null
    else
        zstd -dc "$archive" | tar -tf - >/dev/null
    fi
}

# ---------------------------------------------------------------------------
# meta.json — pointer metadata next to the archive (never secrets).
# ---------------------------------------------------------------------------
write_meta() {
    local metafile="$1" vmid="$2" host="$3" base="$4" size="$5" sha="$6" mode="${7:-$VZDUMP_MODE}"
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
  "mode": "$(json_escape "$mode")",
  "compress": "$(json_escape "$VZDUMP_COMPRESS")",
  "created": "$(date --iso-8601=seconds)",
  "source_volumes": $sv,
  "bind_mounts_skipped": $bm,
  "excluded_backup0": $ex
}
META
}

# ---------------------------------------------------------------------------
# do_backup <vmid> — the main flow for step 3. Assumes preflight has already
# been run by cmd_backup (the PF_* globals are set).
# ---------------------------------------------------------------------------
do_backup() {
    local vmid="$1"
    if [[ "${ENGINE:-tar}" == "restic" ]]; then rdo_backup "$vmid"; return $?; fi
    local dumpdir="${CACHE_DIR}/${vmid}"
    local host; host="$(get_ct_hostname "$vmid")"
    local mode; mode="$(_effective_mode "$vmid")"
    if [[ "$mode" != "$VZDUMP_MODE" ]]; then
        log_warn "backup $vmid: running --mode $mode (fuse/overlay FS → snapshot deadlocks; short downtime instead of a frozen service)"
    fi
    local job_id="backup-${vmid}-$(date +%Y%m%d-%H%M%S)"
    local jobfile="${JOBS_DIR}/${job_id}.log"
    mkdir -p "$dumpdir" "$JOBS_DIR"

    # --- dry-run: show the plan, touch nothing ---
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] vzdump $vmid --mode $mode --compress $VZDUMP_COMPRESS --dumpdir $dumpdir"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$vmid" "mode" "$mode" "dumpdir" "$dumpdir"
        return "$EX_OK"
    fi

    # --- 1. dump (step 3, via run_stream = step 3b) ---
    log_info "backup $vmid: starting vzdump ($mode/$VZDUMP_COMPRESS) → $dumpdir"
    if ! run_stream "$jobfile" "vzdump[$vmid]" -- \
            vzdump "$vmid" --mode "$mode" --compress "$VZDUMP_COMPRESS" --dumpdir "$dumpdir"; then
        die "$EX_SOFTWARE" "vzdump failed for vmid $vmid (see $jobfile)"
    fi

    # Find the archive: parse vzdump output, otherwise the newest matching file.
    local archive
    archive="$(grep -oE "creating vzdump archive '[^']+'" "$jobfile" | tail -1 | sed -E "s/.*'([^']+)'.*/\1/")"
    if [[ -z "$archive" || ! -f "$archive" ]]; then
        archive="$(ls -1t "${dumpdir}"/vzdump-lxc-"${vmid}"-*.tar.* 2>/dev/null | grep -vE '\.(sha256|conf)$|\.meta\.json$' | head -1)"
    fi
    [[ -n "$archive" && -f "$archive" ]] || die "$EX_SOFTWARE" "cannot find produced archive in $dumpdir"
    local base; base="$(basename "$archive")"
    local size; size="$(stat -c '%s' "$archive")"
    log_info "backup $vmid: archive $base ($(numfmt --to=iec "$size" 2>/dev/null || echo "$size B"))"

    # --- 2. sha256 (sidecar) ---
    local sha
    sha="$(sha256sum "$archive" | awk '{print $1}')"
    printf '%s  %s\n' "$sha" "$base" > "${archive}.sha256"
    log_info "backup $vmid: sha256 $sha"

    # --- 3. structure check: zstd -t + tar -tf ---
    log_info "backup $vmid: structure check (zstd -t + tar -tf)…"
    if ! zstd -t "$archive" >/dev/null 2>&1; then
        die "$EX_DATAERR" "zstd integrity check FAILED for $base — archive NOT usable"
    fi
    if ! _tar_list_zstd "$archive"; then
        die "$EX_DATAERR" "tar structure check FAILED for $base — archive NOT usable"
    fi
    log_info "backup $vmid: structure check OK"

    # --- 4. meta.json + config sidecar (bind-mount recreation on restore) ---
    write_meta "${archive}.meta.json" "$vmid" "$host" "$base" "$size" "$sha" "$mode"
    pct config "$vmid" > "${archive}.conf" 2>/dev/null || true
    log_info "backup $vmid: meta.json + config sidecar written"

    # --- 5. upload + offsite verification (step 4) ---
    if [[ "${OFFSITE_ENABLED:-true}" != "true" ]]; then
        log_info "backup $vmid: OFFSITE_ENABLED=false → skipping upload (local only)."
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dumped" "true" \
            "vmid" "$vmid" "archive" "$archive" "size_bytes" "$size" \
            "sha256" "$sha" "verified" "local" "job" "$jobfile"
        return "$EX_OK"
    fi

    do_upload "$vmid" "$archive" "$jobfile"
    verify_offsite "$vmid" "$archive" "$jobfile"

    # --- result (prune happens in step 7) ---
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "uploaded" "true" \
            "vmid" "$vmid" "archive" "$archive" "size_bytes" "$size" \
            "sha256" "$sha" "verified" "offsite" \
            "offsite" "$(_remote_dest "$vmid")/$base" "job" "$jobfile"
    else
        log_info "backup $vmid: DONE — uploaded and verified offsite."
    fi
    return "$EX_OK"
}
