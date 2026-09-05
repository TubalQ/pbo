# shellcheck shell=bash
# lib/lock.sh: two-level locking. Must be right from the start.
#
#   Global lock  (/var/lock/pbo.global)
#     Lets EXACTLY one backup/push operation through at a time, regardless of vmid.
#     Reason: two concurrent vzdump --mode snapshot against raidz2 punish running
#     containers. fetch/restore NEVER take this lock, they don't write from the pool.
#
#   Per-vmid lock (/var/lock/pbo.vmid-<vmid>.lock)
#     Prevents the same container from being queued/run twice.
#
#   Modes:
#     queue , scheduled run: waits for the global lock up to
#              GLOBAL_LOCK_TIMEOUT, then exits with an error (a queue you SEE).
#     now   , manual run: exits immediately with a message about WHAT is blocking
#              and FOR HOW LONG (a silently queued manual run = confusion).
#
# Locks are released automatically when the process dies (fd closes), the holder
# file is cleaned up in cleanup_locks via the EXIT trap.

GLOBAL_LOCK_HELD=0
VMID_LOCK_HELD=0
GLOBAL_LOCK_FD=""
VMID_LOCK_FD=""

# Write/read holder metadata so `status` and now-mode can show who is blocking.
_write_global_holder() {
    local op="$1" vmid="$2"
    printf '%s|%s|%s|%s\n' "${vmid:-none}" "$op" "$$" "$(date +%s)" \
        > "$GLOBAL_HOLDER_FILE" 2>/dev/null || true
}

# Returns a readable description of the global lock holder, or an empty string.
read_global_holder() {
    [[ -f "$GLOBAL_HOLDER_FILE" ]] || { printf ''; return; }
    local line vmid op pid since now age
    line="$(<"$GLOBAL_HOLDER_FILE")"
    IFS='|' read -r vmid op pid since <<<"$line"
    now="$(date +%s)"; age=$(( now - ${since:-now} ))
    printf 'vmid=%s op=%s pid=%s since=%ss' "$vmid" "$op" "$pid" "$age"
}

# acquire_global_lock <queue|now> <op> [vmid]
acquire_global_lock() {
    local mode="$1" op="$2" vmid="${3:-}"
    exec {GLOBAL_LOCK_FD}>"$GLOBAL_LOCK_FILE" \
        || die "$EX_CANTCREAT" "cannot open global lock file: $GLOBAL_LOCK_FILE"

    if [[ "$mode" == "queue" ]]; then
        log_info "waiting for global lock (queue, timeout ${GLOBAL_LOCK_TIMEOUT}s)…"
        if ! flock -w "$GLOBAL_LOCK_TIMEOUT" "$GLOBAL_LOCK_FD"; then
            local h; h="$(read_global_holder)"
            die "$EX_TEMPFAIL" "global lock not acquired within ${GLOBAL_LOCK_TIMEOUT}s (held by: ${h:-unknown})"
        fi
    else
        if ! flock -n "$GLOBAL_LOCK_FD"; then
            local h; h="$(read_global_holder)"
            die "$EX_TEMPFAIL" "global lock busy, an operation is already running (${h:-unknown}). Exiting (manual mode does not queue)."
        fi
    fi

    GLOBAL_LOCK_HELD=1
    _write_global_holder "$op" "$vmid"
    log_info "global lock acquired (op=$op vmid=${vmid:-none})."
}

# acquire_vmid_lock <vmid> , non-blocking; double-queuing is always an error.
acquire_vmid_lock() {
    local vmid="$1"
    local f="${LOCK_DIR}/pbo.vmid-${vmid}.lock"
    exec {VMID_LOCK_FD}>"$f" \
        || die "$EX_CANTCREAT" "cannot open vmid lock file: $f"
    if ! flock -n "$VMID_LOCK_FD"; then
        die "$EX_TEMPFAIL" "vmid $vmid is already queued or running, skipping."
    fi
    VMID_LOCK_HELD=1
    log_info "vmid lock acquired for $vmid."
}

# Clean up locks + holder file. Set as the EXIT trap by the main script.
cleanup_locks() {
    if [[ "${GLOBAL_LOCK_HELD:-0}" == 1 ]]; then
        rm -f "$GLOBAL_HOLDER_FILE" 2>/dev/null || true
        [[ -n "$GLOBAL_LOCK_FD" ]] && flock -u "$GLOBAL_LOCK_FD" 2>/dev/null || true
    fi
    [[ "${VMID_LOCK_HELD:-0}" == 1 && -n "$VMID_LOCK_FD" ]] && flock -u "$VMID_LOCK_FD" 2>/dev/null || true
}
