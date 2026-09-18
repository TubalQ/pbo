# shellcheck shell=bash
# lib/backup.sh: shared backup plumbing.
#   - run_stream: real-time, timestamped streaming of a subprocess to the log
#     and job file. Without it a long vzdump/restic looks hung and someone kills
#     it mid-run.
#   - vzdump mode helpers: fuse containers deadlock --mode snapshot, so they are
#     forced to --mode stop (short downtime instead of a frozen service).
#
# The actual backup flow lives in the restic engine (lib/restic.sh). do_backup
# is a thin dispatcher so the command layer does not need to know the engine.

# ---------------------------------------------------------------------------
# run_stream <jobfile> <label> -- <command...>
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
# vzdump mode helpers.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# do_backup <vmid>, dispatch to the restic engine (assumes preflight already ran).
# ---------------------------------------------------------------------------
do_backup() { rdo_backup "$1"; }
