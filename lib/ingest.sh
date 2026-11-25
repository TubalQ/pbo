# shellcheck shell=bash
# lib/ingest.sh: archives that PVE backup jobs write to the pbo storage (ADR 0006
# Phase 2, ADR 0007).
#
#   pbo ingest --vmid V --archive P   upload one spool archive (the hook's backup-end)
#   pbo ingest --pending              spool leftovers + the offsite copies that failed
#   pbo _vzdump-hook <phase> [mode vmid]   (hidden) the vzdump hook, via lib/vzdump-hook
#
# A PVE job that targets the `pbo` storage writes a plain vzdump archive to
# <spool>/dump (PVE_SPOOL_DIR/dump, the storage's `path` + /dump). At backup-end
# the hook runs `pbo ingest`, which
#   - checks the archive strictly: in the spool itself, a regular file (no
#     symlink), named vzdump-<lxc|qemu>-<vmid>-<ts>.<tar|vma> for THAT vmid;
#   - takes only the guest's own lock (non-blocking: EX_TEMPFAIL at once), never
#     pbo.global or the schedule lock. pbo.timer holds pbo.global while it waits
#     for vzdump's node lock, and this runs inside vzdump: waiting would deadlock;
#   - moves (renames) the archive into $CACHE_DIR/<vmid>, writes the .conf
#     sidecar and runs the same upload as a pbo backup (_upload_dumpdir), so the
#     snapshot's path is $CACHE_DIR/<vmid> as for every other backup of the guest;
#   - uploads synchronously to the cache AND offsite: the PVE job is never green
#     while offsite failed;
#   - adds the entry to the catalogue.
# Stop mode is the exception. vzdump runs backup-end inside the guest's task and
# restarts a stopped guest only afterwards, in its cleanup (VZDump.pm:1261 vs
# :1287-1300, pve-manager 9.2.32); an upload there would keep the guest down
# until the offsite copy is done. So for a guest backed up in stop mode
# backup-end only checks the archive and records it (STATE_DIR/ingest-deferred),
# and job-end, after every guest is running again, ingests what was recorded. A
# failure there fails the job (job-end is inside the job's eval,
# VZDump.pm:1435-1446), so the job is still never green while offsite failed;
# the guest's own line in the task stays "ok", and job-end output goes to the
# job's notification, not the task log.
# It sends no pbo notification: PVE notifies about its job. Every line goes to
# stdout/stderr, which vzdump copies into the task log.
#
# Failures: when nothing reached a repo the archive goes back to the spool, so
# `ingest --pending` retries it (and the PVE storage lists it as "not ingested").
# When the cache has it but the copy to offsite failed, the loose archive is
# dropped, the snapshot is recorded under STATE_DIR/ingest-copy/<vmid>_<ts>, and
# `ingest --pending` copies exactly the recorded snapshots (never an unfiltered
# copy: that would bring back snapshots offsite retention removed on purpose).

INGEST_USAGE="ingest --vmid <vmid> --archive <spool archive> | ingest --pending"
readonly INGEST_PENDING_MIN=10   # --pending leaves younger spool archives alone (minutes)
IG_PATH="" IG_BASE="" IG_TYPE="" IG_TS=""
INGEST_ARCHIVE_GLOB_RE='vzdump-(lxc|qemu)-[0-9]+-[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}\.(tar|vma)'

# _ingest_spool → the directory PVE jobs write archives to.
_ingest_spool() { printf '%s/dump' "${PVE_SPOOL_DIR%/}"; }
# _ingest_defer_dir → where backup-end records stop-mode archives for job-end:
# one empty file per archive, named like it.
_ingest_defer_dir() { printf '%s/ingest-deferred' "${STATE_DIR%/}"; }
_ingest_copy_dir()  { printf '%s/ingest-copy' "${STATE_DIR%/}"; }

# _ingest_copy_mark <vmid> <ts>: record a snapshot that is in the cache repo but
# not offsite, for `ingest --pending`.
_ingest_copy_mark() {
    local d; d="$(_ingest_copy_dir)"
    ( umask 077; mkdir -p -- "$d" && : > "$d/${1}_${2}" ) 2>/dev/null \
        || log_warn "ingest $1: could not record ts=$2 for 'ingest --pending' in $d; run 'pbo ingest --pending' after fixing it, or copy it by hand"
}

# _ingest_copy_list → recorded <vmid>_<ts> names, oldest first.
_ingest_copy_list() {
    local d; d="$(_ingest_copy_dir)"
    [[ -d "$d" ]] || return 0
    find "$d" -maxdepth 1 -type f -name '*_*' -printf '%T@ %f\n' 2>/dev/null | sort -n | cut -d' ' -f2- || true
}

# _ingest_check_archive <vmid> <path>: refuse anything but an uncompressed
# vzdump archive of <vmid> lying directly in the spool. Sets IG_PATH (resolved),
# IG_BASE, IG_TYPE (lxc|qemu), IG_TS.
_ingest_check_archive() {
    local vmid="$1" p="$2" spool sreal real base
    spool="$(_ingest_spool)"
    sreal="$(realpath -e -- "$spool" 2>/dev/null)" || die "$EX_DATAERR" "ingest: the spool $spool does not exist (PVE_SPOOL_DIR=${PVE_SPOOL_DIR})"
    [[ -L "$p" ]] && die "$EX_DATAERR" "ingest: $p is a symlink, refused"
    [[ -e "$p" ]] || die "$EX_DATAERR" "ingest: $p does not exist"
    real="$(realpath -e -- "$p" 2>/dev/null)" || die "$EX_DATAERR" "ingest: cannot resolve $p"
    [[ "$(dirname -- "$real")" == "$sreal" ]] || die "$EX_DATAERR" "ingest: $p is not in the spool $spool, refused"
    [[ -f "$real" && ! -L "$real" ]] || die "$EX_DATAERR" "ingest: $p is not a regular file, refused"
    base="${real##*/}"
    local re="^vzdump-(lxc|qemu)-${vmid}-([0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2})\.(tar|vma)$"
    [[ "$base" =~ $re ]] \
        || die "$EX_DATAERR" "ingest: $base is not an uncompressed vzdump archive of vmid $vmid (vzdump-<lxc|qemu>-$vmid-<YYYY_MM_DD-HH_MM_SS>.<tar|vma>; pbo needs compression none)"
    IG_TYPE="${BASH_REMATCH[1]}" IG_TS="${BASH_REMATCH[2]}"
    if [[ "$IG_TYPE" == lxc && "${BASH_REMATCH[3]}" != tar ]] || [[ "$IG_TYPE" == qemu && "${BASH_REMATCH[3]}" != vma ]]; then
        die "$EX_DATAERR" "ingest: $base: type $IG_TYPE does not match .${BASH_REMATCH[3]}"
    fi
    IG_PATH="$real" IG_BASE="$base"
}

# _ingest_snap_id <repo> <vmid> <ts> → the id of the newest snapshot with those
# tags (empty when there is none or the repo cannot be read).
_ingest_snap_id() {
    _restic "$1" --no-lock snapshots --json --tag "vmid=$2,ts=$3" 2>/dev/null \
        | jq -r 'if type == "array" and length > 0 then (max_by(.time) | .id // empty) else empty end' 2>/dev/null || true
}

# _ingest_same_fs <a> <b>: both directories on the same mount, so mv is a rename.
_ingest_same_fs() { [[ "$(stat -c '%d %m' -- "$1" 2>/dev/null)" == "$(stat -c '%d %m' -- "$2" 2>/dev/null)" ]]; }

# _ingest_catalog <vmid> <ts> <type> <base> <size> <cache_snap> <offsite_snap> <keep>:
# the new snapshot in the catalogue. In standalone there may be no index; that is
# not worth a warning there.
_ingest_catalog() {
    if _catalog_valid "$PBO_CATALOG" || ! _integration_standalone; then
        _catalog_add_entry "$@" || true
    fi
    return 0
}

# ingest_archive <vmid> <path>
ingest_archive() {
    local vmid="$1" p="$2"
    _ingest_check_archive "$vmid" "$p"
    local src="$IG_PATH" base="$IG_BASE" gtype="$IG_TYPE" ts="$IG_TS"
    local dumpdir="${CACHE_DIR}/${vmid}"
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] ingest $vmid: $base → $dumpdir → restic $(_restic_write_repo)"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$vmid" "archive" "$base" "ts" "$ts"
        return "$EX_OK"
    fi
    acquire_vmid_lock "$vmid"
    # another ingest (the hook or --pending) may have taken it between the check and the lock
    [[ -f "$src" && ! -L "$src" ]] || die "$EX_DATAERR" "ingest: $base is no longer in the spool (ingested by another run?)"
    [[ -r "$RESTIC_PASSWORD_FILE" ]] || die "$EX_CONFIG" "ingest: missing password file $RESTIC_PASSWORD_FILE (the archive stays in the spool)"
    mkdir -p "$dumpdir" "$JOBS_DIR" || die "$EX_CANTCREAT" "ingest: cannot create $dumpdir (the archive stays in the spool)"
    # a rename, never a copy: the spool must be on the cache's filesystem (doctor checks it too)
    _ingest_same_fs "$(dirname -- "$src")" "$dumpdir" \
        || die "$EX_CONFIG" "ingest: the spool $(dirname -- "$src") and $dumpdir are not on the same filesystem; PVE_SPOOL_DIR must live on CACHE_DIR's filesystem (the archive stays in the spool)"
    # the write repo must exist; offsite is not touched before the copy (an
    # offsite outage still leaves the backup in the cache)
    local wrepo rc=0; wrepo="$(_restic_write_repo)"
    _restic_ensure "$wrepo" || rc=$?
    (( rc == 0 )) || _restic_init_die "$( [[ "$wrepo" == "$RESTIC_CACHE_REPO" ]] && echo cache || echo offsite )" "$rc"

    local jobfile; jobfile="${JOBS_DIR}/ingest-${vmid}-$(date +%Y%m%d-%H%M%S).log"
    local size; size="$(stat -c %s -- "$src" 2>/dev/null || echo 0)"
    log_info "ingest $vmid: $base ($size bytes) → $dumpdir"
    # clean dumpdir → the snapshot holds exactly this archive and its sidecar
    rm -f "${dumpdir}"/vzdump-* 2>/dev/null || true
    mv -T -- "$src" "${dumpdir}/${base}" || die "$EX_CANTCREAT" "ingest: cannot move $base into $dumpdir (the archive stays in the spool)"
    # vzdump's own log, when it is already there (stop mode: job-end runs after
    # log-end, which keeps it for us; snapshot mode: vzdump writes it only after
    # backup-end, so it stays in the Proxmox task history instead)
    local stem="${base%.*}" lsrc="${src%/*}/${base%.*}.log" haslog=0
    if [[ -f "$lsrc" && ! -L "$lsrc" ]] && mv -T -- "$lsrc" "${dumpdir}/${stem}.log" 2>/dev/null; then haslog=1; fi
    # out of the spool: a job-end record of it is done (if it comes back, --pending has it)
    rm -f -- "$(_ingest_defer_dir)/${base}" 2>/dev/null || true
    # config sidecar for restore (lxc: unprivileged/bind-mounts; qemu: disks)
    _g_config "$gtype" "$vmid" > "${dumpdir}/${base}.conf" 2>/dev/null || true

    if ! _upload_dumpdir "$vmid" "$gtype" "$dumpdir" "$base" "$ts" "$jobfile" ingest; then
        local code
        if [[ "$UD_STAGE" == backup ]]; then
            # nothing reached a repo: back to the spool, `ingest --pending` retries it
            local where="the archive is back in the spool"
            rm -f "${dumpdir}/${base}.conf"
            mv -T -- "${dumpdir}/${base}" "$src" 2>/dev/null || where="the archive stays in $dumpdir"
            (( haslog )) && { mv -T -- "${dumpdir}/${stem}.log" "$lsrc" 2>/dev/null || true; }
            code="$EX_SOFTWARE"; [[ -n "$UD_LOCK" ]] && code="$EX_TEMPFAIL"
            die "$code" "ingest $vmid: restic backup of $base failed${UD_LOCK:+: repo locked ($UD_LOCK)}; $where (see $jobfile)"
        fi
        # in the cache, not offsite: the loose archive goes, `ingest --pending` copies the snapshot
        rm -f "${dumpdir}"/vzdump-* 2>/dev/null || true
        _ingest_copy_mark "$vmid" "$ts"
        _ingest_catalog "$vmid" "$ts" "$gtype" "$base" "$size" "$(_ingest_snap_id "$RESTIC_CACHE_REPO" "$vmid" "$ts")" "" "$UD_KEEP"
        code="$EX_UNAVAILABLE"; [[ -n "$UD_LOCK" ]] && code="$EX_TEMPFAIL"
        die "$code" "ingest $vmid: $base is in the cache repo, but the copy → offsite failed${UD_LOCK:+: repo locked ($UD_LOCK)}; 'pbo ingest --pending' copies it (see $jobfile)"
    fi

    local cs="" os=""
    if [[ "${LOCAL_REPO:-true}" == "true" ]]; then
        cs="$(_ingest_snap_id "$RESTIC_CACHE_REPO" "$vmid" "$ts")"
        [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]] && os="$(_ingest_snap_id "$RESTIC_OFFSITE_REPO" "$vmid" "$ts")"
    else
        os="$(_ingest_snap_id "$RESTIC_OFFSITE_REPO" "$vmid" "$ts")"
    fi
    _ingest_catalog "$vmid" "$ts" "$gtype" "$base" "$size" "$cs" "$os" "$UD_KEEP"
    audit_log "ingest vmid=$vmid archive=$base ts=$ts cache=${cs:0:8} offsite=${os:0:8}"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "ingested" "true" "vmid" "$vmid" "ts" "$ts" "type" "$gtype" "archive" "$base" "size:n" "$size" \
            "snapshot_cache" "$cs" "snapshot_offsite" "$os" "repo" "$(_restic_read_repo)" "job" "$jobfile"
    else
        log_info "ingest $vmid: DONE, ts=$ts (cache ${cs:0:8}${os:+, offsite ${os:0:8}})"
    fi
    return "$EX_OK"
}

# _vzdump_running: vzdump holds its node lock (VZDUMP_LOCK). Tested with a
# non-blocking shared flock that is dropped at once; vzdump takes it exclusively
# (VZDump.pm get_lock_file). A lock file that cannot be opened counts as held.
_vzdump_running() {
    local f="${VZDUMP_LOCK:-/var/run/vzdump.lock}" fd
    [[ -e "$f" ]] || return 1
    exec {fd}<"$f" 2>/dev/null || return 0
    if flock -n -s "$fd"; then exec {fd}<&-; return 1; fi
    exec {fd}<&-
    return 0
}

# _ingest_pending_list → spool archives older than INGEST_PENDING_MIN minutes.
_ingest_pending_list() {
    local spool; spool="$(_ingest_spool)"
    [[ -d "$spool" ]] || return 0
    find "$spool" -maxdepth 1 -type f -mmin "+${INGEST_PENDING_MIN}" -regextype posix-extended \
        -regex ".*/${INGEST_ARCHIVE_GLOB_RE}" -printf '%p\n' 2>/dev/null | sort
}

# ingest_pending: the leftovers. Each archive is ingested by a child pbo (its own
# vmid lock; one failure does not stop the rest). Archives are left alone while
# vzdump runs: a running job ingests its own at backup-end. Then, in cached mode,
# a restic copy cache → offsite of each snapshot an ingest recorded because its
# own copy failed (--tag vmid=,ts=, like the upload itself; idempotent). Only
# those: an unfiltered copy would re-upload whatever offsite retention removed.
ingest_pending() {
    local cands=() f busy=0
    mapfile -t cands < <(_ingest_pending_list)
    if (( ${#cands[@]} )) && _vzdump_running; then
        busy=1
        log_info "ingest --pending: vzdump is running (${VZDUMP_LOCK} held), ${#cands[@]} spool archive(s) left for the next run"
        cands=()
    fi
    local copy_on=0
    [[ "${LOCAL_REPO:-true}" == "true" && "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]] && copy_on=1
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        for f in "${cands[@]+"${cands[@]}"}"; do log_info "[dry-run] ingest --pending: would ingest ${f##*/}"; done
        if (( copy_on )); then for f in $(_ingest_copy_list); do log_info "[dry-run] ingest --pending: would copy ${f%%_*} ts=${f#*_} cache → offsite"; done; fi
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "pending:n" "${#cands[@]}" "vzdump_running:b" "$( ((busy)) && echo true || echo false )"
        return "$EX_OK"
    fi
    (( ${#cands[@]} )) && log_info "ingest --pending: ${#cands[@]} spool archive(s) older than ${INGEST_PENDING_MIN} min"
    local okn=0 failn=0 failed=() base v rc re="^${INGEST_ARCHIVE_GLOB_RE}$"
    for f in "${cands[@]+"${cands[@]}"}"; do
        base="${f##*/}"
        [[ "$base" =~ $re ]] || continue
        v="${base#vzdump-*-}"; v="${v%%-*}"
        rc=0
        # stdout too goes to stderr: our own stdout carries this command's JSON
        ( _close_lock_fds; "${SELF_DIR}/pbo" ingest --vmid "$v" --archive "$f" ) >&2 || rc=$?
        if (( rc == 0 )); then okn=$((okn+1)); else failn=$((failn+1)); failed+=("$base"); log_warn "ingest --pending: $base failed (exit $rc)"; fi
    done
    local copy=off marks=() m cv ct copied=0
    if (( copy_on )); then
        copy=none
        mapfile -t marks < <(_ingest_copy_list)
        local jobfile="" tsre='^[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}$'
        for m in "${marks[@]+"${marks[@]}"}"; do
            cv="${m%%_*}"; ct="${m#*_}"
            if [[ ! "$cv" =~ ^[0-9]+$ || ! "$ct" =~ $tsre ]]; then
                log_warn "ingest --pending: ignoring a malformed record $(_ingest_copy_dir)/$m"; rm -f -- "$(_ingest_copy_dir)/$m"; continue
            fi
            if [[ -z "$jobfile" ]]; then
                mkdir -p "$JOBS_DIR" 2>/dev/null || true
                jobfile="${JOBS_DIR}/ingest-pending-$(date +%Y%m%d-%H%M%S).log"
            fi
            log_info "ingest --pending: restic copy $cv ts=$ct cache → offsite"
            if [[ -r "$RESTIC_PASSWORD_FILE" ]] && run_stream "$jobfile" "restic-copy[$cv]" -- \
                    _restic_w "$RESTIC_OFFSITE_REPO" copy --from-repo "$RESTIC_CACHE_REPO" --tag "vmid=$cv,ts=$ct"; then
                rm -f -- "$(_ingest_copy_dir)/$m"; copied=$((copied+1)); [[ "$copy" == failed ]] || copy=ok
            else
                copy=failed; log_warn "ingest --pending: restic copy of $cv ts=$ct cache → offsite failed (see $jobfile)"
            fi
        done
    fi
    if (( okn > 0 || copied > 0 )); then
        [[ "${PBO_INGEST_NO_REFRESH:-0}" == 1 ]] || _catalog_refresh_hook "ingest --pending"
    fi
    local good=true; (( failn == 0 )) && [[ "$copy" != failed ]] || good=false
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "$( [[ "$good" == true ]] && echo ok || echo partial )" "$good" "ingested:n" "$okn" "failed:n" "$failn" "copied:n" "$copied" \
            "failed_archives" "${failed[*]:-}" "vzdump_running:b" "$( ((busy)) && echo true || echo false )" "copy" "$copy"
    else
        log_info "ingest --pending: done, ${okn} ingested, ${failn} failed, ${copied} offsite copies, copy ${copy}"
    fi
    (( failn == 0 )) || return "$EX_SOFTWARE"
    [[ "$copy" != failed ]] || return "$EX_UNAVAILABLE"
    return "$EX_OK"
}

# _ingest_pending_hook <what>: at the start of run-schedule with the integration
# on, pick up spool leftovers in a child pbo. A failure is a warning and never
# fails the caller (doctor flags spool archives older than 24 h).
_ingest_pending_hook() {
    _integration_standalone && return 0
    [[ "${DRY_RUN:-0}" == 1 ]] && return 0
    _is_janitor && return 0
    local rc=0
    # the caller refreshes the catalogue itself at the end; output → stderr (our stdout may be JSON)
    ( _close_lock_fds; PBO_INGEST_NO_REFRESH=1 "${SELF_DIR}/pbo" ingest --pending ) >&2 || rc=$?
    (( rc == 0 )) || log_warn "$1: ingest --pending failed (exit $rc), spool leftovers or offsite copies wait for the next run"
    return 0
}

# rdo_ingest: the `pbo ingest` dispatcher.
rdo_ingest() {
    export PBO_NO_NOTIFY=1   # PVE notifies about its job; pbo stays silent (also in its children)
    local vmid="" archive="" pending=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vmid)    [[ $# -ge 2 ]] || die "$EX_USAGE" "$INGEST_USAGE"; vmid="$2"; shift 2 ;;
            --archive) [[ $# -ge 2 ]] || die "$EX_USAGE" "$INGEST_USAGE"; archive="$2"; shift 2 ;;
            --pending) pending=1; shift ;;
            *) die "$EX_USAGE" "unknown ingest argument: $1 ($INGEST_USAGE)" ;;
        esac
    done
    if (( pending )); then
        [[ -z "$vmid" && -z "$archive" ]] || die "$EX_USAGE" "$INGEST_USAGE"
        ingest_pending
        return
    fi
    require_vmid "$vmid"
    [[ -n "$archive" ]] || die "$EX_USAGE" "$INGEST_USAGE"
    ingest_archive "$vmid" "$archive"
}

# ---------------------------------------------------------------------------
# pbo _vzdump-hook <phase> [<mode> <vmid>]: run by lib/vzdump-hook, only for a
# storage of type pbo. Arguments and environment as PVE::VZDump::run_hook_script
# passes them (VZDump.pm:787-815): phase, and for guest phases mode and vmid;
# TARGET, DUMPDIR, VMTYPE, LOGFILE, STOREID. A non-zero exit fails the guest.
# ---------------------------------------------------------------------------
# _hook_stop_reason <vmid> → why pbo wants stop mode for the guest.
_hook_stop_reason() {
    local vmid="$1"
    if _ct_is_fuse "$vmid"; then printf 'fuse=1 deadlocks snapshot and suspend mode'
    elif _in_csv "$vmid" "${VZDUMP_STOP_VMIDS:-}"; then printf 'listed in VZDUMP_STOP_VMIDS'
    elif _guest_force_stop "$vmid"; then printf 'tagged pbo-stop'
    else printf 'VZDUMP_MODE=%s' "${VZDUMP_MODE:-}"; fi
}

# backup-start: refuse what pbo cannot use, before vzdump stops or snapshots the guest.
_hook_backup_start() {
    local mode="$1" vmid="$2" t="${TARGET:-}"
    _cache_dir_protect "$vmid"   # the spool under CACHE_DIR: closed to local users, this CT's tar let through
    case "$t" in
        *.tar|*.vma) ;;
        *) die 1 "pbo needs compression none: this job would write '${t:-no target}' for vmid $vmid. Set compression none on the job (restic compresses and deduplicates itself)" ;;
    esac
    local need; need="$(_effective_mode "$vmid")"
    if [[ "$need" == stop && "$mode" != stop ]]; then
        die 1 "pbo: vmid $vmid must be backed up in stop mode ($(_hook_stop_reason "$vmid")), this job runs it in $mode mode; move it to a stop-mode job"
    fi
    log_info "pbo: vmid $vmid accepted ($mode mode, ${t##*/})"
    return 0
}

# backup-end in stop mode: check the archive now (a bad one fails the guest),
# upload it at job-end, after vzdump has restarted the guest.
_hook_defer() {
    local vmid="$1" t="$2" dir
    _ingest_check_archive "$vmid" "$t"
    dir="$(_ingest_defer_dir)"
    mkdir -p "$dir" && : > "$dir/$IG_BASE" \
        || die 1 "pbo: cannot record $IG_BASE for job-end in $dir; it stays in the spool for 'pbo ingest --pending'"
    log_info "pbo: vmid $vmid ran in stop mode: $IG_BASE is uploaded at job-end, once vzdump has restarted the guest"
    return 0
}

# job-end: ingest the stop-mode archives backup-end recorded, one child pbo each
# (its own vmid lock; one failure does not stop the rest). Any failure fails the
# job; the archive is then back in the spool or in the cache, and `pbo ingest
# --pending` finishes it. Nothing recorded: no restic, nothing to audit.
_hook_job_end() {
    local dir; dir="$(_ingest_defer_dir)"
    local marks=() m base v f spool rc n=0 failn=0 re="^${INGEST_ARCHIVE_GLOB_RE}$"
    [[ -d "$dir" ]] && mapfile -t marks < <(find "$dir" -maxdepth 1 -type f -name 'vzdump-*' -printf '%p\n' 2>/dev/null | sort)
    if (( ${#marks[@]} == 0 )); then PBO_AUDIT_DONE=1; return 0; fi
    spool="$(_ingest_spool)"
    for m in "${marks[@]}"; do
        base="${m##*/}"
        rm -f -- "$m"
        [[ "$base" =~ $re ]] || continue
        f="$spool/$base"
        if [[ ! -f "$f" ]]; then log_info "pbo: job-end: $base is no longer in the spool"; continue; fi
        v="${base#vzdump-*-}"; v="${v%%-*}"
        n=$((n+1)); rc=0
        log_info "pbo: job-end: ingest $v ($base, backed up in stop mode)"
        ( _close_lock_fds; "${SELF_DIR}/pbo" ingest --vmid "$v" --archive "$f" ) || rc=$?
        if (( rc != 0 )); then failn=$((failn+1)); log_warn "pbo: job-end: ingest of $base failed (exit $rc)"; fi
    done
    (( failn == 0 )) || die 1 "pbo: $failn of $n stop-mode upload(s) failed at job-end; 'pbo ingest --pending' retries them"
    return 0
}

# log-end: vzdump copied its task log next to the archive after backup-end
# (VZDump.pm:1367-1372). A snapshot-mode archive is already uploaded, so its .log
# (and maybe .notes) is removed; a stop-mode archive waiting for job-end keeps
# its .log, which the job-end ingest puts into the snapshot. Only when DUMPDIR is
# the spool.
_hook_log_end() {
    local t="${TARGET:-}" d="${DUMPDIR:-}" sreal dreal base stem
    [[ -n "$t" && -n "$d" ]] || return 0
    sreal="$(realpath -e -- "$(_ingest_spool)" 2>/dev/null)" || return 0
    dreal="$(realpath -e -- "$d" 2>/dev/null)" || return 0
    [[ "$dreal" == "$sreal" ]] || return 0
    base="${t##*/}"
    [[ "$base" =~ ^(vzdump-(lxc|qemu)-[0-9]+-[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2})\. ]] || return 0
    stem="${BASH_REMATCH[1]}"
    rm -f -- "$sreal/$base.notes" 2>/dev/null || true
    # deferred to job-end (stop mode) and the archive still here: the .log goes with it
    [[ -e "$(_ingest_defer_dir)/$base" && -f "$sreal/$base" ]] && return 0
    rm -f -- "$sreal/$stem.log" 2>/dev/null || true
    return 0
}

rdo_vzdump_hook() {
    export PBO_NO_NOTIFY=1   # a refused or failed guest fails the PVE job, which PVE notifies about
    local phase="${1:-}" mode="${2:-}" vmid="${3:-}"
    case "$phase" in
        backup-start)
            require_vmid "$vmid"
            _hook_backup_start "$mode" "$vmid" ;;
        backup-end)
            require_vmid "$vmid"
            [[ -n "${TARGET:-}" ]] || die 1 "pbo: backup-end for vmid $vmid without TARGET"
            # stop mode: the guest is still down here, the upload waits for job-end
            if [[ "$mode" == stop ]]; then _hook_defer "$vmid" "$TARGET"; return 0; fi
            local j=(); [[ "${JSON_OUTPUT:-0}" == 1 ]] && j=(--json)
            json_close
            exec "${SELF_DIR}/pbo" "${j[@]+"${j[@]}"}" ingest --vmid "$vmid" --archive "$TARGET" ;;
        job-end)
            _hook_job_end ;;
        log-end)
            _hook_log_end ;;
        *)  # job-init, job-start, job-abort, pre-stop, pre-restart,
            # post-restart, backup-abort (the archive stays in the spool for
            # --pending) and any later phase: nothing to do, nothing to audit
            PBO_AUDIT_DONE=1 ;;
    esac
    return 0
}
