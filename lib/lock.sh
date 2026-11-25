# shellcheck shell=bash
# lib/lock.sh: two-level locking. Must be right from the start.
#
#   Global lock  (/var/lock/pbo.global)
#     Lets EXACTLY one backup/push operation through at a time, regardless of vmid.
#     Reason: two concurrent vzdump --mode snapshot runs on the same pool punish running
#     containers. fetch/restore NEVER take this lock, they don't write from the pool.
#
#   Per-vmid lock (/var/lock/pbo.vmid-<vmid>.lock)
#     Prevents the same container from being queued/run twice.
#
#   Schedule lock (/var/lock/pbo.schedule)
#     Held by run-schedule for the WHOLE run and by prune. run-schedule only takes
#     the global lock per guest, so it is free for a moment between guests; a
#     prune slipping in there takes an exclusive restic lock and every following
#     backup fails (for example catch-up timers after a long power-off). Prune takes
#     this lock first, then the global lock (so a manual backup can't collide either).
#
#   Cache lock (LOCK_DIR/pbo.cache, 0.6 M7)
#     Taken SHARED by everything that reads or writes below CACHE_DIR: backup,
#     ingest, fetch, restore, test-restore, backup-host, catalog materialize and
#     the mount service (pbo-mount.service holds it while restic mount runs).
#     A cache move (lib/cachemove.sh) takes it EXCLUSIVE; while it does, the
#     others exit 75 at once. Never waited for.
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
# _close_lock_fds: close pbo's lock fds in this (sub)shell, for children that
# may outlive pbo. The parent keeps its own copies, so its locks stay held.
_close_lock_fds() {
    local v fd
    # PBO_JSON_FD too: a child holding a copy of pbo's stdout keeps a caller's
    # $(...) waiting until the child exits
    for v in GLOBAL_LOCK_FD VMID_LOCK_FD SCHED_LOCK_FD TR_TARGET_LOCK_FD JOB_ADMIT_FD CFG_LOCK_FD CACHE_LOCK_FD INTEG_LOCK_FD CATALOG_LOCK_FD PBO_JSON_FD; do
        fd="${!v:-}"; [[ "$fd" =~ ^[0-9]+$ ]] && eval "exec $fd>&-"
    done
    return 0
}

GLOBAL_LOCK_FD=""
VMID_LOCK_FD=""
SCHED_LOCK_HELD=0
SCHED_LOCK_FD=""

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
    # a queued run may have waited out a cache move or another config change
    [[ "$mode" != queue ]] || _lock_reexec_if_changed "$op"
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

read_schedule_holder() {
    [[ -f "$SCHED_HOLDER_FILE" ]] || { printf ''; return; }
    local op pid since
    IFS='|' read -r op pid since <"$SCHED_HOLDER_FILE"
    printf 'op=%s pid=%s since=%ss' "$op" "$pid" "$(( $(date +%s) - ${since:-$(date +%s)} ))"
}

# acquire_schedule_lock <queue|now> <op>: serialize run-schedule and prune.
acquire_schedule_lock() {
    local mode="$1" op="$2" h
    exec {SCHED_LOCK_FD}>"$SCHED_LOCK_FILE" \
        || die "$EX_CANTCREAT" "cannot open schedule lock file: $SCHED_LOCK_FILE"
    if ! flock -n "$SCHED_LOCK_FD"; then
        h="$(read_schedule_holder)"
        [[ "$mode" == "queue" ]] \
            || die "$EX_TEMPFAIL" "$op: a scheduled run or prune is in progress (${h:-unknown}). Exiting (manual mode does not queue)."
        log_info "$op: waiting for ${h:-another run} to finish (schedule lock, timeout ${SCHEDULE_LOCK_TIMEOUT}s)…"
        flock -w "$SCHEDULE_LOCK_TIMEOUT" "$SCHED_LOCK_FD" \
            || die "$EX_TEMPFAIL" "$op: schedule lock not acquired within ${SCHEDULE_LOCK_TIMEOUT}s (held by: ${h:-unknown})"
    fi
    SCHED_LOCK_HELD=1
    printf '%s|%s|%s\n' "$op" "$$" "$(date +%s)" > "$SCHED_HOLDER_FILE" 2>/dev/null || true
    [[ "$mode" != queue ]] || _lock_reexec_if_changed "$op"
}

CACHE_LOCK_FD=""
CACHE_LOCK_MODE=""
# acquire_cache_lock <op>: the cache lock, shared and without waiting (75 while
# a cache move holds it). Then: no unfinished move (its journal), and, when
# this call took the lock, the config this process read is still the one on
# disk (else it starts again). A process that already holds the lock does not
# check again: it has kept every move out since it took it.
acquire_cache_lock() {
    local op="$1" f="${LOCK_DIR%/}/pbo.cache"
    if [[ -z "$CACHE_LOCK_FD" && "${DRY_RUN:-0}" != 1 ]]; then
        [[ -d "$LOCK_DIR" ]] || { mkdir -p -- "$LOCK_DIR" && chmod 0700 -- "$LOCK_DIR"; } 2>/dev/null || true
        [[ ! -L "$f" ]] || die "$EX_CANTCREAT" "the cache lock $f is a symlink: remove it"
        { exec {CACHE_LOCK_FD}>>"$f"; } 2>/dev/null || { CACHE_LOCK_FD=""; die "$EX_CANTCREAT" "cannot open the cache lock $f"; }
        if ! flock -n -s "$CACHE_LOCK_FD"; then
            exec {CACHE_LOCK_FD}>&-; CACHE_LOCK_FD=""
            die "$EX_TEMPFAIL" "$op: CACHE_DIR is being moved right now (the cache lock $f is held by 'pbo config set CACHE_DIR'); try again when the move is done"
        fi
        CACHE_LOCK_MODE=s
        declare -F _cm_block >/dev/null && _cm_block "$op"
        _lock_reexec_if_changed "$op"
        return 0
    fi
    declare -F _cm_block >/dev/null && _cm_block "$op"
    return 0
}

# _lock_config_changed: the local config this process read was replaced or
# edited after it started, appeared or went, a cache move wrote its journal
# since, or a finished move took the cache away from the CACHE_DIR this process
# loaded. PBO_START_US and PBO_START_ID (the local file's device and inode) are
# set by load_config. The inode is what catches the writer: it renames a new
# file over the config, and that file was written before the move hook ran,
# so its mtime is older than a process that read the old file during the move
# (and a filesystem with one-second timestamps hides the rest). The mtime
# catches an edit in place; only one between the start and now counts: a
# future one (a restored file, a clock that went back) must not make every run
# start again. Only local files: the cluster-shared file carries another
# node's clock and holds no key a cache move changes.
_lock_config_changed() {
    local t0="${PBO_START_US:-}" now m id f="${PBO_CONFIG_LOCAL:-}" j seen=0 files=() first=0
    [[ "$t0" =~ ^[0-9]+$ ]] || return 1
    now="${EPOCHREALTIME//[!0-9]/}"
    j="${STATE_DIR%/}/cache-move.json"
    # where a finished move left (no fork while there is no journal); a move
    # that still runs is _cm_block's. Not once this process started again: it
    # read the config as it is now, and a CACHE_DIR set back there by hand
    # would make it start again until it gives up
    [[ -e "$j" && "${PBO_REEXEC_N:-0}" == 0 ]] && declare -F _cm_old_location >/dev/null && _cm_old_location "${CACHE_DIR:-}" && return 0
    if [[ -n "$f" ]]; then
        [[ " ${PBO_CONFIG_FILES[*]-} " == *" $f "* ]] && seen=1
        if [[ -e "$f" ]]; then (( seen )) || return 0; files+=("$f"); first=1
        else (( ! seen )) || return 0; fi
    fi
    [[ -e "$j" ]] && files+=("$j")
    (( ${#files[@]} )) || return 1
    while IFS=' ' read -r m id; do
        if (( first )); then
            first=0
            [[ -n "${PBO_START_ID:-}" && -n "$id" && "$id" != "$PBO_START_ID" ]] && return 0
        fi
        m="${m//[!0-9]/}"
        [[ -n "$m" ]] && (( 10#$m > 10#$t0 && 10#$m <= 10#$now )) && return 0
    done < <(stat -c '%.6Y %d:%i' -- "${files[@]}" 2>/dev/null)
    return 1
}

# _lock_reexec_if_changed <op>: a process that waited for a lock with the old
# config (a backup queued behind a cache move: its CACHE_DIR is gone) starts
# itself again with the new one, same arguments, same pid. Its locks are
# released first (the new image takes them again). At most 3 times in a row.
# Only the top-level process: a subshell (test-restore --scheduled runs each
# guest in one) that exec'd would start a whole second run inside the first
# and release the parent's locks.
_lock_reexec_if_changed() {
    _lock_config_changed || return 0
    # fail just this unit; the next run reads the new config
    [[ "$BASHPID" == "$$" ]] || die "$EX_TEMPFAIL" "$1: the config changed during this run; skipped, the next run uses the new config"
    local n="${PBO_REEXEC_N:-0}"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    (( n < 3 )) || die "$EX_TEMPFAIL" "$1: the config keeps changing while pbo waits for its locks; try again later"
    log_info "$1: the config changed while pbo waited (a cache move or config set): starting again with the new config"
    cleanup_locks
    _close_lock_fds
    declare -F json_close >/dev/null && json_close
    trap - EXIT
    export PBO_REEXEC_N=$(( n + 1 ))
    exec "${SELF_DIR}/pbo" "${PBO_ORIG_ARGS[@]+"${PBO_ORIG_ARGS[@]}"}"
}

# Clean up locks + holder file. Set as the EXIT trap by the main script.
cleanup_locks() {
    if [[ "${GLOBAL_LOCK_HELD:-0}" == 1 ]]; then
        rm -f "$GLOBAL_HOLDER_FILE" 2>/dev/null || true
        [[ -n "$GLOBAL_LOCK_FD" ]] && flock -u "$GLOBAL_LOCK_FD" 2>/dev/null || true
    fi
    [[ "${VMID_LOCK_HELD:-0}" == 1 && -n "$VMID_LOCK_FD" ]] && flock -u "$VMID_LOCK_FD" 2>/dev/null || true
    if [[ "${SCHED_LOCK_HELD:-0}" == 1 ]]; then
        rm -f "$SCHED_HOLDER_FILE" 2>/dev/null || true
        [[ -n "$SCHED_LOCK_FD" ]] && flock -u "$SCHED_LOCK_FD" 2>/dev/null || true
    fi
}
