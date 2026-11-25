# shellcheck shell=bash
# lib/cachemove.sh: moving CACHE_DIR with its data, `pbo config set CACHE_DIR
# <new>` (0.6 M7, ADR 0009 "Cache move").
#
# The config writer (lib/config.sh _cfg_write) runs the move-cache hook
# (_cfg_hook_move_cache) under the config lock, after it has checked the new
# file and before it replaces the old one. An empty cache stays M4's: the new
# directory is created and the config written. A cache with data, a cache whose
# spool the PVE storage names, and every change of CACHE_DIR while a move is
# unfinished come here:
#
#   preflight   every check at once, read-only but for a probe file next to the
#               target (ACL support): 78 when the input is wrong, 69 when the
#               system refuses (filesystem, parents, space, CTs, storage, busy)
#   pre-write   journalled steps (STATE_DIR/cache-move.json, written atomically):
#               lock, mount-stop, storage-disable, staging-clear, target-create,
#               data
#   config      the writer's own rename: CACHE_DIR plus the keys that follow it,
#               one transaction
#   post-write  storage-update, catalog-refresh, perms, old-remove; then the
#               cache lock is released and pbo-mount.service starts again if it
#               ran before
#
# A failure before the config write rolls back at once (the old tree is left as
# it was, but for the staged archives, which are made again on demand; the
# storage and the mount as they were). After the write the move only
# goes forward: `--resume` runs the steps that are left. `--abort` rolls back a
# move that was interrupted before the write. While the journal is not final,
# backups, ingest, restores, the mount and `restic init` stop with exit 75
# (_cm_block), and doctor fails.
#
# The cache lock LOCK_DIR/pbo.cache (lib/lock.sh acquire_cache_lock) is what
# keeps every other user of the cache out: they take it shared, the move takes
# it exclusive.
#
# Test hooks (environment, the test suite only): PBO_TEST_CM_FAIL=<step> fails
# the move right after that step, PBO_TEST_CM_KILL=<step> kills pbo there,
# PBO_TEST_CM_COPY=1 copies even on the same filesystem, PBO_TEST_CM_FREE=<bytes>
# is the free space on the target, PBO_TEST_CM_FSTYPE=<type> its filesystem,
# PBO_TEST_CM_NEW_MOUNT=<dir> the mount point the target is on,
# PBO_TEST_CM_MOUNTINFO=<file> is read instead of /proc/self/mountinfo, and
# PBO_TEST_CM_VZDUMP_PIDS=<pids> are the running vzdump processes (empty: none).

readonly CM_JOURNAL_VERSION=1
# what pbo itself keeps below CACHE_DIR: the only entries a copied old
# directory may hold for pbo to remove it (dump directories per guest and per
# host, restore and fetch scratch, the cache repo, spool and staging; the
# snapshot directories of a dataset or an export, and lost+found)
readonly CM_KNOWN_RE='^([0-9]+|host-.+|restore-[0-9]+|testrestore-.+|fetch-[0-9]+|repo|spool|staging|lost\+found|\.zfs|\.snapshot)$'
# entries at the root of a directory that belong to its filesystem, never to
# the cache: not copied, not compared, not counted as data
readonly CM_FS_ENTRIES=' lost+found .zfs .snapshot '
# The two lists hold the names `stat -f -c %T` prints (coreutils), not mount(8)
# types: devtmpfs shows as tmpfs, NFS v3 and v4 both as nfs, 9p as v9fs, a
# FUSE filesystem (glusterfs, sshfs) as fuseblk or fuse.* (refused on its own).
# filesystems the cache may not live on: lost on reboot, or not a disk
readonly CM_FS_REFUSED=' tmpfs ramfs proc sysfs devpts cgroupfs cgroup2fs squashfs isofs '
# network filesystems: refused unless --force (locks and ACLs are not what
# vzdump and restic expect; a dropped mount stops every backup)
readonly CM_FS_NETWORK=' nfs cifs smb smb2 smbfs v9fs ceph afs '

# flags from `pbo config set` (lib/config.sh _config_change_cmd)
CM_YES=0 CM_RESUME=0 CM_ABORT=0 CM_KEEP_OLD=0 CM_FIX_PARENTS=0 CM_VERIFY_DATA=0 CM_FORCE=0
# a move is prepared under the config lock (pre-write done): the config write follows
CM_PENDING=0
# an empty-cache change of CACHE_DIR (OLD<TAB>NEW) for _cm_journal_empty_change
CM_EMPTY_CHANGE=''
CMJ=''

# --- small helpers --------------------------------------------------------------------
_cm_norm() { local p="$1"; while [[ "$p" == */ && "$p" != / ]]; do p="${p%/}"; done; printf '%s' "$p"; }
# _cm_under PATH DIR: PATH is DIR or below it
_cm_under() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }
_cm_final() { case "$1" in done|rolled-back|aborted) return 0 ;; esac; return 1; }
# _cm_existing PATH → PATH or its nearest existing ancestor
_cm_existing() { local p="$1"; while [[ -n "$p" && "$p" != / && ! -e "$p" ]]; do p="${p%/*}"; [[ -n "$p" ]] || p=/; done; printf '%s' "${p:-/}"; }
_cm_human() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"; }
# _cm_follow_keys → the schema keys that live below CACHE_DIR by default
_cm_follow_keys() {
    local k
    _cs_load
    for k in "${CS_ORDER[@]}"; do [[ ",${CS_FLAGS[$k]}," == *,follows=CACHE_DIR,* ]] && printf '%s\n' "$k"; done
    return 0
}
# _cm_entries DIR → the entries directly in DIR that are not its filesystem's own
_cm_entries() {
    local e n
    while IFS= read -r -d '' e; do
        n="${e##*/}"; [[ "$CM_FS_ENTRIES" == *" $n "* ]] && continue
        printf '%s\n' "$n"
    done < <(find "$1" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}
# _cm_vzdump_pids → pids of running vzdump processes (PBO_TEST_CM_VZDUMP_PIDS
# for the tests: a PVE host that runs the suite may run a vzdump job meanwhile)
_cm_vzdump_pids() {
    if [[ -n "${PBO_TEST_CM_VZDUMP_PIDS+x}" ]]; then printf '%s' "${PBO_TEST_CM_VZDUMP_PIDS:-}"; return 0; fi
    pgrep -x vzdump 2>/dev/null | paste -sd' ' - || true
}
# _cm_open_below DIR → "pid:path" of the first file another process has open
# below DIR. /proc/<pid>/fd links name the resolved path: DIR below a symlinked
# ancestor (/var/cache a link to a data disk) matches in either spelling.
_cm_open_below() {
    local d="$1" r l pid
    r="$(readlink -f -- "$d" 2>/dev/null)" || r=''
    [[ -n "$r" ]] || r="$d"
    while IFS= read -r l; do
        pid="${l#/proc/}"; pid="${pid%%/*}"
        [[ "$pid" == "$$" || "$pid" == "${BASHPID:-}" ]] && continue
        printf '%s:%s' "$pid" "$(readlink -- "$l" 2>/dev/null)"; return 0
    done < <(find /proc -mindepth 3 -maxdepth 3 -path '/proc/[0-9]*/fd/*' \
                 \( -lname "$r" -o -lname "$r/*" -o -lname "$d" -o -lname "$d/*" \) -print 2>/dev/null)
    return 1
}
# _cm_mount_of PATH → the mount point PATH is on, from mountinfo (it tells bind
# mounts of one filesystem apart, which share st_dev and stat's %m)
_cm_mount_of() {
    findmnt -n -o TARGET -T "$1" 2>/dev/null | head -n 1
}
# _cm_mounts_below DIR → each mount point strictly below DIR (or below its
# resolved path), one per line, mountinfo's octal escapes decoded; not a
# dataset's own snapshots, which ZFS mounts below DIR/.zfs on access
_cm_mounts_below() {
    local d="$1" r mi="${PBO_TEST_CM_MOUNTINFO:-/proc/self/mountinfo}" mp
    r="$(readlink -f -- "$d" 2>/dev/null)" || r=''
    [[ -n "$r" ]] || r="$d"
    [[ -r "$mi" ]] || return 0
    while IFS= read -r mp; do
        # \040 (space), \011, \012, \134: what the kernel escapes in a path
        [[ "$mp" != *\\* ]] || printf -v mp '%b' "${mp//\\/\\0}"
        [[ "$mp" == "$d"/* || "$mp" == "$r"/* ]] || continue
        [[ "$mp" == "$d"/.zfs/* || "$mp" == "$r"/.zfs/* ]] || printf '%s\n' "$mp"
    done < <(awk '{ print $5 }' "$mi" 2>/dev/null)
    return 0
}
# _cm_rename OLD NEW: rename(2) and nothing else. GNU mv falls back to a copy
# and delete when the rename gives EXDEV (another mount of the same
# filesystem): unchecked, without the space check; here that fails instead.
_cm_rename() {
    if mv --help 2>/dev/null | grep -q -- '--no-copy'; then
        mv --no-copy -T -- "$1" "$2"
    else
        perl -e 'rename($ARGV[0], $ARGV[1]) or die "rename $ARGV[0] -> $ARGV[1]: $!\n"' -- "$1" "$2"
    fi
}
# _cm_lock_busy FILE: another process holds this lock file (exclusive or shared)
_cm_lock_busy() {
    local fd
    [[ -e "$1" && ! -L "$1" ]] || return 1
    { exec {fd}<"$1"; } 2>/dev/null || return 0
    if flock -n -x "$fd"; then exec {fd}<&-; return 1; fi
    exec {fd}<&-
    return 0
}
# _cm_test_point STEP: the suite's failure injection (see the header)
_cm_test_point() {
    [[ "${PBO_TEST_CM_KILL:-}" == "$1" ]] && kill -KILL "$$"
    if [[ "${PBO_TEST_CM_FAIL:-}" == "$1" ]]; then CM_ERR="test hook: the move fails after the step $1"; return 1; fi
    return 0
}
_cm_say() { log_info "cache move: $*"; }

# --- the journal (STATE_DIR/cache-move.json) -----------------------------------------
_cm_jfile() { printf '%s/cache-move.json' "${STATE_DIR%/}"; }
# _cm_jload → CMJ; 1 when there is no journal, 2 when it cannot be read
_cm_jload() {
    local f; f="$(_cm_jfile)"; CMJ=''
    [[ -e "$f" ]] || return 1
    CMJ="$(jq -ce 'select(type == "object" and (.version | type) == "number" and (.state | type) == "string")' -- "$f" 2>/dev/null)" || { CMJ=''; return 2; }
    return 0
}
_cm_jv() { jq -r "$1 // empty" <<<"$CMJ" 2>/dev/null; }
# _cm_jsave: CMJ to the journal, atomically and durably (a dry run writes nothing)
_cm_jsave() {
    [[ "${DRY_RUN:-0}" == 1 ]] && return 0
    local f d tmp; f="$(_cm_jfile)"; d="${f%/*}"
    [[ -d "$d" ]] || mkdir -p -- "$d" 2>/dev/null || return 1
    tmp="$(mktemp "$d/.cache-move.json.XXXXXX" 2>/dev/null)" || return 1
    if ! printf '%s\n' "$CMJ" > "$tmp"; then rm -f -- "$tmp"; return 1; fi
    sync -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$f" || { rm -f -- "$tmp"; return 1; }
    sync -- "$d" 2>/dev/null || true
}
# _cm_jupd FILTER [jq args...]: change the journal (updated = now) and save it
_cm_jupd() {
    local filter="$1" n; shift
    n="$(jq -c --argjson now "$(date +%s)" "$@" "$filter | .updated = \$now" <<<"$CMJ" 2>/dev/null)" || return 1
    [[ -n "$n" ]] || return 1
    CMJ="$n"; _cm_jsave
}
_cm_jdone() { jq -e --arg s "$1" 'any(.done[]?; . == $s)' >/dev/null 2>&1 <<<"$CMJ"; }
_cm_mark() { _cm_jupd 'if any(.done[]; . == $s) then . else .done += [$s] end | .step = $s' --arg s "$1"; }
# _cm_written: the config already names the new directory (the journal says so,
# or pbo was stopped between the rename and the journal entry)
_cm_written() {
    [[ "$(_cm_jv .state)" == config-written ]] && return 0
    _cm_jdone config && return 0
    [[ "$(_cm_norm "${CACHE_DIR:-}")" == "$(_cm_jv .new)" ]]
}
# _cm_active: an unfinished move (or a journal pbo cannot read: assume the worst)
_cm_active() {
    local rc=0
    _cm_jload || rc=$?
    (( rc == 1 )) && return 1
    (( rc == 2 )) && return 0
    ! _cm_final "$(_cm_jv .state)"
}
# _cm_hint: how to finish the unfinished move in CMJ
_cm_hint() {
    local new; new="$(_cm_jv .new)"
    if [[ -z "$CMJ" ]]; then printf 'the journal %s cannot be read: check it, or move it away once the cache is where the config says' "$(_cm_jfile)"; return 0; fi
    if _cm_written; then printf "finish it with 'pbo config set CACHE_DIR %s --resume'" "$new"
    else printf "finish it with 'pbo config set CACHE_DIR %s --resume' or undo it with 'pbo config set CACHE_DIR %s --abort'" "$new" "$new"; fi
}
_cm_desc() {
    [[ -n "$CMJ" ]] || { printf 'a move of CACHE_DIR'; return 0; }
    printf 'the move of CACHE_DIR %s -> %s (%s, step %s)' "$(_cm_jv .old)" "$(_cm_jv .new)" "$(_cm_jv .state)" "$(_cm_jv .step)"
}
# _cm_block WHAT: stop (75) while a move is unfinished: WHAT would use a cache
# that is half moved, or create one at a place the move is leaving
_cm_block() {
    [[ -e "$(_cm_jfile)" ]] || return 0
    _cm_active || return 0
    die "$EX_TEMPFAIL" "$1: $(_cm_desc) is unfinished; $(_cm_hint)"
}
# _cm_old_location DIR: DIR is where a finished move took the cache away from
# (and no later move brought it back): ensure_dirs must not create it again
_cm_old_location() {
    [[ -e "$(_cm_jfile)" ]] || return 1
    _cm_jload || return 1
    [[ "$(_cm_jv .state)" == "done" ]] || return 1
    local d; d="$(_cm_norm "$1")"
    _cm_under "$d" "$(_cm_jv .new)" && return 1
    jq -e --arg d "$d" '[.old, (.history[]?.old)] | any(. as $o | $d == $o or ($d | startswith($o + "/")))' >/dev/null 2>&1 <<<"$CMJ"
}

# _cm_init_guard REPO: may pbo create an empty restic repo at REPO? Not while a
# move is unfinished; not at a place a finished move left (a process that read
# the config before the move would otherwise make a new, empty cache repo there
# and back up into it); not at a path the config no longer names (read again
# from the files now). Remote repos are not judged. A cache repo pinned
# outside the cache stayed where it was (how=stays): it is no place the move
# left, so it may be created again. Returns 4 with the reason in CM_INIT_MSG.
_cm_init_guard() {
    local repo="$1" p
    CM_INIT_MSG=''
    p="${repo#local:}"
    [[ "$p" == /* ]] || return 0
    p="$(_cm_norm "$p")"
    if [[ -e "$(_cm_jfile)" ]]; then
        if _cm_active; then CM_INIT_MSG="$(_cm_desc) is unfinished, pbo creates no repo now; $(_cm_hint)"; return 4; fi
        if [[ "$(_cm_jv .state)" == "done" ]] && ! _cm_under "$p" "$(_cm_jv .new)" \
           && jq -e --arg d "$p" '[.old, (.history[]?.old), (.keys.RESTIC_CACHE_REPO | select(.how? == "follow") | .old // empty)] | any(. as $o | $d == $o or ($d | startswith($o + "/")))' >/dev/null 2>&1 <<<"$CMJ"; then
            CM_INIT_MSG="$p is where the cache was before it moved to $(_cm_jv .new) ($(_cm_jfile)): pbo creates no new repo there (a process started before the move?); run the command again"
            return 4
        fi
    fi
    # the config as it is on disk now, not as this process read it at its start
    local fresh
    if declare -F _cfg_parse_all >/dev/null && declare -F _cfgv_effective >/dev/null; then
        fresh="$( _cfg_parse_all >/dev/null 2>&1 || true; _cs_load; _cfgv_effective; printf '%s\n%s\n' "${_CFGV_E[RESTIC_CACHE_REPO]-}" "${_CFGV_E[RESTIC_OFFSITE_REPO]-}" )" || fresh=''
        if [[ -n "$fresh" ]]; then
            local l hit=0
            while IFS= read -r l; do l="${l#local:}"; [[ -n "$l" && "$(_cm_norm "$l")" == "$p" ]] && hit=1; done <<<"$fresh"
            if (( ! hit )); then
                CM_INIT_MSG="the config no longer names $p as a repo (it changed since this pbo started): pbo creates no repo there; run the command again"
                return 4
            fi
        fi
    fi
    return 0
}

# --- the plan ----------------------------------------------------------------------------
# _cm_plan OLD NEW: what the move does → CM_OLD, CM_NEW, CM_METHOD (rename|copy)
# and CM_METHOD_WHY (why a copy), CM_KO/CM_KN/CM_KHOW[key] (the keys that follow CACHE_DIR: old and new
# effective value, follow|stays|changes|stuck|mismatch), CM_INTEG, CM_SID,
# CM_ST_* (the PVE storage), CM_MOUNT, CM_USAGE. CFGW_EB/CFGW_EA (the writer's
# results) give the new effective values.
_cm_plan() {
    CM_OLD="$(_cm_norm "$1")" CM_NEW="$(_cm_norm "$2")"
    declare -gA CM_KO=() CM_KN=() CM_KHOW=()
    CM_FK=()
    local k ov nv
    while IFS= read -r k; do
        [[ -n "$k" ]] || continue
        CM_FK+=("$k")
        ov="$(_cm_norm "${!k-}")"
        if [[ -n "${CFGW_EA[$k]+x}" ]]; then nv="$(_cm_norm "${CFGW_EA[$k]}")"; else nv="$ov"; fi
        CM_KO[$k]="$ov" CM_KN[$k]="$nv"
        if _cm_under "$ov" "$CM_OLD"; then
            if [[ "$nv" == "$ov" ]]; then CM_KHOW[$k]=stuck
            elif [[ "$nv" == "$CM_NEW${ov#"$CM_OLD"}" ]]; then CM_KHOW[$k]=follow
            else CM_KHOW[$k]=mismatch; fi
        elif [[ "$nv" == "$ov" ]]; then CM_KHOW[$k]=stays
        else CM_KHOW[$k]=changes; fi
    done < <(_cm_follow_keys)
    # a rename needs one filesystem AND one mount: two bind mounts of a
    # filesystem (or a btrfs subvolume mounted twice) share st_dev, yet
    # rename(2) between them gives EXDEV. Anything else is a checked copy.
    CM_METHOD=copy CM_METHOD_WHY='another filesystem'
    local od nd om nm
    od="$(stat -c %d -- "$CM_OLD" 2>/dev/null)"; nd="$(stat -c %d -- "$(_cm_existing "$CM_NEW")" 2>/dev/null)"
    if [[ -n "$od" && "$od" == "$nd" && "${PBO_TEST_CM_COPY:-0}" != 1 ]]; then
        om="$(_cm_mount_of "$CM_OLD")"
        nm="${PBO_TEST_CM_NEW_MOUNT:-$(_cm_mount_of "$(_cm_existing "$CM_NEW")")}"
        if [[ -n "$om" && "$om" == "$nm" ]]; then CM_METHOD=rename CM_METHOD_WHY=''
        else CM_METHOD_WHY="the same filesystem through another mount (${om:-?}, ${nm:-?}: a bind mount?), where a rename fails"; fi
    fi
    CM_INTEG=0; _integration_standalone || CM_INTEG=1
    CM_SID="${PVE_STORAGE_ID:-pbo}" CM_ST_PRESENT=0 CM_ST_DISABLED=0 CM_ST_PATH='' CM_ST_NODES='' CM_ST_TYPE='' CM_ST_NEWPATH=''
    if (( CM_INTEG )); then
        local sj; sj="$(_integ_storage_json "$CM_SID" 2>/dev/null)" || sj=''
        if [[ "$(jq -r '.present' <<<"$sj" 2>/dev/null)" == true ]]; then
            CM_ST_PRESENT=1
            CM_ST_TYPE="$(jq -r '.type // ""' <<<"$sj")"
            CM_ST_NODES="$(jq -r '.nodes // ""' <<<"$sj")"
            CM_ST_PATH="$(_cm_norm "$(jq -r '.path // ""' <<<"$sj")")"
            [[ "$(jq -r '.disabled' <<<"$sj")" == true ]] && CM_ST_DISABLED=1
            # the storage's path is the spool: it moves when the spool moves
            if [[ -n "$CM_ST_PATH" && "$CM_ST_PATH" == "${CM_KO[PVE_SPOOL_DIR]-}" && "${CM_KN[PVE_SPOOL_DIR]-}" != "$CM_ST_PATH" ]]; then
                CM_ST_NEWPATH="${CM_KN[PVE_SPOOL_DIR]}"
            fi
        fi
    fi
    CM_MOUNT=0; _catalog_mount_active && CM_MOUNT=1
    CM_USAGE=0
    if [[ "$CM_METHOD" == copy ]]; then
        CM_USAGE="$(du -s -x -B1 -- "$CM_OLD" 2>/dev/null | awk '{print $1; exit}')"
        [[ "$CM_USAGE" =~ ^[0-9]+$ ]] || CM_USAGE=0
    fi
    return 0
}

# _cm_space_need USAGE → bytes the copy needs: USAGE x CACHEMOVE_SPACE_FACTOR
_cm_space_need() {
    local f="${CACHEMOVE_SPACE_FACTOR:-1.1}" a b
    [[ "$f" =~ ^[0-9]+(\.[0-9]+)?$ ]] || f=1.1
    a="${f%%.*}" b=''; [[ "$f" == *.* ]] && b="${f#*.}"
    b="${b}000"; b="${b:0:3}"
    printf '%s' $(( $1 * (10#$a * 1000 + 10#$b) / 1000 ))
}

# --- preflight -----------------------------------------------------------------------------
# _cm_check LEVEL MESSAGE: one line of the preflight (ok, warn, fail78, fail69)
_cm_check() {
    CM_CHECKS+=("$1"$'\t'"$2")
    case "$1" in fail78) CM_F78+=("$2") ;; fail69) CM_F69+=("$2") ;; warn) CM_W+=("$2") ;; esac
}

# _cm_preflight [--resume]: every check, every failure at once (CM_F78, CM_F69,
# CM_W, CM_CHECKS, CM_FIXLINES: the setfacl lines that would let the CTs
# through). --resume: only what a resumed move needs (nothing running).
_cm_preflight() {
    local resume=0; [[ "${1:-}" == --resume ]] && resume=1
    CM_F78=() CM_F69=() CM_W=() CM_CHECKS=() CM_FIXLINES=() CM_PARENTFIX=()
    local old="$CM_OLD" new="$CM_NEW" anc fst k src
    if (( ! resume )); then
        # the path
        local pathok=1
        if [[ "$new" != /* ]]; then _cm_check fail78 "CACHE_DIR $new is not an absolute path"; pathok=0
        elif [[ "$new/" == *//* || "$new/" == */./* || "$new/" == */../* ]]; then _cm_check fail78 "CACHE_DIR $new is not a canonical path (//, . or ..): write it without them"; pathok=0
        elif [[ -L "$new" ]]; then _cm_check fail78 "CACHE_DIR $new is a symlink (to $(readlink -- "$new")): give the real path"; pathok=0
        else
            local real; real="$(readlink -m -- "$new" 2>/dev/null)" || real=''
            if [[ "$real" != "$new" ]]; then _cm_check fail78 "CACHE_DIR $new goes through a symlink (it is really ${real:-?}): give the real path"; pathok=0; fi
        fi
        _perm_ensure
        if [[ "$new" == / || "$PERM_SYSTEM_DIRS" == *" $new "* ]]; then
            _cm_check fail78 "CACHE_DIR $new is a system directory: give pbo a directory of its own (e.g. $new/pbo)"; pathok=0
        fi
        if [[ -e "$new" && ! -d "$new" ]]; then _cm_check fail78 "CACHE_DIR $new exists and is not a directory"; pathok=0
        elif [[ -d "$new" ]]; then
            local hit; hit="$(_cm_entries "$new" | head -n 1)"
            [[ -r "$new" && -x "$new" ]] || hit="(cannot be read)"
            if [[ -n "$hit" ]]; then _cm_check fail78 "CACHE_DIR $new is not empty ($hit): choose an empty or a new directory"; pathok=0; fi
        fi
        if [[ -L "$old" ]]; then _cm_check fail78 "the current CACHE_DIR $old is a symlink: point CACHE_DIR at its real path ($(readlink -f -- "$old")) first"; pathok=0; fi
        local oreal; oreal="$(readlink -f -- "$old" 2>/dev/null)" || oreal="$old"
        if _cm_under "$new" "$old" || _cm_under "$new" "$oreal"; then _cm_check fail78 "CACHE_DIR $new lies inside the current one ($old)"; pathok=0
        elif _cm_under "$old" "$new" || _cm_under "$oreal" "$new"; then _cm_check fail78 "the current CACHE_DIR $old lies inside $new"; pathok=0; fi
        (( pathok )) && _cm_check ok "$new: an absolute, canonical path, not a system directory, empty or new, not nested with $old"
        # a filesystem mounted below the old cache (a child dataset for the
        # repo, an fstab mount for the spool): a rename would move only its
        # mount stub (it mounts at the old path again on the next boot, and an
        # empty repo would be made in the stub), and a copy would neither count
        # it (du -x) nor remove it (rm --one-file-system)
        local mp mps=()
        while IFS= read -r mp; do [[ -n "$mp" ]] && mps+=("$mp"); done < <(_cm_mounts_below "$old")
        for mp in "${mps[@]+"${mps[@]}"}"; do
            _cm_check fail69 "$mp is a separate filesystem mounted below the current CACHE_DIR $old: a rename would move only its mount stub (it mounts at the old path again on reboot) and a copy would not count or remove it; unmount it, or move or merge it, first"
        done
        # the keys that follow CACHE_DIR
        for k in "${CM_FK[@]}"; do
            case "${CM_KHOW[$k]}" in
                follow)   _cm_check ok "$k follows: ${CM_KO[$k]} -> ${CM_KN[$k]}" ;;
                stays)    _cm_check ok "$k stays at ${CM_KO[$k]} (set outside the cache; its data is not moved)" ;;
                changes)  _cm_check ok "$k changes ${CM_KO[$k]} -> ${CM_KN[$k]} (set outside the cache; no data is moved for it)" ;;
                stuck)    # CFG_SRC names only keys a config file assigned
                          src="${CFG_SRC[$k]-env}"; src="${src%%:*}"; [[ "$src" != env ]] || src="the environment"
                          _cm_check fail78 "$k=${CM_KO[$k]} lies below the current CACHE_DIR but comes from $src (not this config file): its data moves, the value would not; set it in the local config or the environment to the new path first" ;;
                mismatch) _cm_check fail78 "$k would become ${CM_KN[$k]}, but its data at ${CM_KO[$k]} moves with the cache to $new${CM_KO[$k]#"$old"}: change $k in a separate step" ;;
            esac
        done
        # the filesystem of the target
        anc="$(_cm_existing "$new")"
        fst="${PBO_TEST_CM_FSTYPE:-$(stat -f -c %T -- "$anc" 2>/dev/null)}"
        if [[ "$CM_FS_REFUSED" == *" $fst "* ]]; then
            _cm_check fail69 "$anc is on $fst: the cache would be lost on a reboot or is not a disk; choose a directory on a local disk"
        elif [[ "$fst" == fuse* ]]; then
            _cm_check fail69 "$anc is on a FUSE filesystem ($fst): vzdump and restic need a local filesystem"
        elif [[ "$CM_FS_NETWORK" == *" $fst "* ]]; then
            if (( CM_FORCE )); then _cm_check warn "$anc is on a network filesystem ($fst), accepted with --force: a dropped mount stops every backup, and ACLs may not work there"
            else _cm_check fail69 "$anc is on a network filesystem ($fst): refused (a dropped mount stops every backup, ACLs and locks may not work); --force uses it anyway"; fi
        else
            _cm_check ok "filesystem of $anc: ${fst:-unknown}"
        fi
        # the directories above the target: whoever can write one can swap the cache
        local d top="${PBO_PERMS_PARENTS_TOP:-}" st u m pbad=0
        top="$(_cm_norm "$top")"
        d="$(_cm_existing "${new%/*}")"; [[ -n "$d" ]] || d=/
        while :; do
            [[ -n "$top" && "$d" != "$top" && "$d" != "$top"/* ]] && break
            st="$(stat -L -c '%u %a' -- "$d" 2>/dev/null)" || st=''
            read -r u m <<<"$st"
            if [[ -z "$st" ]]; then _cm_check fail69 "cannot stat $d (a parent of $new)"; pbad=1
            elif [[ "$u" != 0 && "$u" != "$EUID" ]]; then _cm_check fail69 "$d (a parent of $new) belongs to uid $u, not root: that user could replace the cache directory"; pbad=1
            elif (( 8#$m & 8#022 )); then _cm_check fail69 "$d (a parent of $new) is group- or world-writable (mode $m): other users could replace the cache directory"; pbad=1; fi
            [[ "$d" == / ]] && break
            d="${d%/*}"; [[ -n "$d" ]] || d=/
        done
        # an existing (empty) target is not one of the parents above
        if [[ "$anc" == "$new" ]]; then
            st="$(stat -L -c '%u %a' -- "$new" 2>/dev/null)" || st=''
            read -r u m <<<"$st"
            if [[ -z "$st" ]]; then _cm_check fail69 "cannot stat $new"; pbad=1
            elif [[ "$u" != 0 && "$u" != "$EUID" ]]; then _cm_check fail69 "CACHE_DIR $new exists and belongs to uid $u, not root: that user could put anything into the cache; remove it or chown it to root first"; pbad=1
            elif (( 8#$m & 8#022 )); then _cm_check fail69 "CACHE_DIR $new exists and is group- or world-writable (mode $m): remove it or chmod go-w it first"; pbad=1; fi
        fi
        (( pbad )) || _cm_check ok "the directories above $new belong to root and only root can write them"
        # space: a rename needs none, a copy the cache's size and a margin
        if [[ "$CM_METHOD" == rename ]]; then
            _cm_check ok "$old and $new are on the same filesystem and mount: the data is renamed, not copied"
        else
            local free need
            free="${PBO_TEST_CM_FREE:-$(df -B1 --output=avail -- "$anc" 2>/dev/null | tail -n 1 | tr -dc '0-9')}"
            need="$(_cm_space_need "$CM_USAGE")"
            if [[ ! "$free" =~ ^[0-9]+$ ]]; then _cm_check fail69 "cannot tell the free space on $anc"
            elif (( free < need )); then _cm_check fail69 "not enough space on $anc: the cache uses $(_cm_human "$CM_USAGE"), the copy needs $(_cm_human "$need") (x${CACHEMOVE_SPACE_FACTOR:-1.1}, CACHEMOVE_SPACE_FACTOR), $(_cm_human "$free") is free"
            else _cm_check ok "${CM_METHOD_WHY:-another filesystem}: the data is copied ($(_cm_human "$CM_USAGE"), $(_cm_human "$free") free, $(_cm_human "$need") needed) and checked before the old copy goes"; fi
        fi
        # the probes write next to the target: only for a target that is
        # acceptable as a path (never into a system directory), and only in a
        # directory no other user can write (they could swap a probe for a
        # symlink between its creation and the setfacl on it)
        if (( ! pathok )); then _cm_check warn "the unprivileged CTs' access to $new is checked once the path is acceptable"
        elif (( pbad )); then _cm_check warn "the unprivileged CTs' access to $new is checked once the directories above the target belong to root"
        else _cm_preflight_cts "$anc"; fi
        # the PVE storage: storage.cfg is the same file on every node
        if (( CM_INTEG )); then
            if (( ! CM_ST_PRESENT )); then
                _cm_check warn "the integration is on ($(_integration_mode)) but storage.cfg has no storage '$CM_SID': nothing in PVE to repoint ('pbo integrate enable' adds it)"
            elif [[ "$CM_ST_TYPE" != pbo ]]; then
                _cm_check fail69 "storage '$CM_SID' is of type $CM_ST_TYPE, not pbo: PVE_STORAGE_ID names another storage"
            elif [[ "$CM_ST_NODES" != "$(_local_node)" ]]; then
                _cm_check fail69 "storage '$CM_SID' is not restricted to this node (nodes: ${CM_ST_NODES:-all}): storage.cfg is cluster-wide, so disabling it and changing its path would change it for every node; restrict it with 'pvesm set $CM_SID --nodes $(_local_node)' only if no other node uses it (that takes it from every other node); in a cluster move this node to its own storage first (RUNBOOK, \"In a cluster\")"
            else
                _cm_check ok "storage '$CM_SID' belongs to this node alone$([[ -n "$CM_ST_NEWPATH" ]] && printf '; its path follows the spool (%s -> %s)' "$CM_ST_PATH" "$CM_ST_NEWPATH")"
            fi
            # the spool and staging stay on the cache's filesystem (ingest and
            # materialize rename into it)
            for k in PVE_SPOOL_DIR PVE_STAGING_DIR; do
                [[ "${CM_KHOW[$k]-}" == stays || "${CM_KHOW[$k]-}" == changes ]] || continue
                local tdev kdev
                tdev="$(stat -c %d -- "$anc" 2>/dev/null)"; kdev="$(stat -c %d -- "$(_cm_existing "${CM_KN[$k]}")" 2>/dev/null)"
                [[ -n "$tdev" && "$tdev" == "$kdev" ]] || _cm_check fail69 "$k ${CM_KN[$k]} would not be on the filesystem of the new CACHE_DIR $new (ingest and staging rename into the cache): move $k along, or choose a CACHE_DIR on its filesystem"
            done
        fi
    fi
    _cm_preflight_idle
    return 0
}

# _cm_preflight_cts ANC: the mapped root of every unprivileged CT must be able
# to reach the new directory (vzdump runs tar as that uid inside it). Tested
# for real: setpriv as the uid on each existing directory above the target, and
# a probe directory on the target filesystem closed to others with an ACL
# entry for the uid (does the filesystem take POSIX ACLs, and do they work).
_cm_preflight_cts() {
    local anc="$1" u d top="${PBO_PERMS_PARENTS_TOP:-}" probe acl_ok=1 err
    _perm_ensure
    local PERM_EXTRA_VMIDS=()
    _PERM_CT_DONE=0; declare -gA _PERM_CT=()
    _perm_ct_uids
    if (( ${#_PERM_CT[@]} == 0 )); then _cm_check ok "no unprivileged CT on this node: no ACL entries needed"; return 0; fi
    local cts; cts="$(_perm_ct_list)"
    # the ACL probe: a file next to the target, removed at once
    if ! command -v setfacl >/dev/null 2>&1; then
        _cm_check fail69 "setfacl (package acl) is missing: the new CACHE_DIR could not let unprivileged CT(s) $cts through"; acl_ok=0
    elif probe="$(mktemp -p "$anc" .pbo-acl-probe.XXXXXX 2>/dev/null)"; then
        u="$(printf '%s\n' "${!_PERM_CT[@]}" | sort -n | head -n 1)"
        if ! err="$(setfacl -P -m "u:$u:x" -- "$probe" 2>&1)"; then
            acl_ok=0
            if [[ "$err" == *"not supported"* ]]; then
                _cm_check fail69 "the filesystem of $anc does not support POSIX ACLs: the new CACHE_DIR could not be closed to local users and still let unprivileged CT(s) $cts through; enable them (ZFS: zfs set acltype=posixacl <dataset>) or choose another filesystem"
            else
                _cm_check fail69 "setfacl on a probe file in $anc failed ($err)"
            fi
        fi
        rm -f -- "$probe"
    else
        _cm_check fail69 "cannot create a probe file in $anc (needed to test ACL support)"; acl_ok=0
    fi
    if (( EUID != 0 )) || ! command -v setpriv >/dev/null 2>&1; then
        _cm_check warn "not checked that the mapped root of unprivileged CT(s) $cts can reach $CM_NEW (needs root and setpriv)"
        (( acl_ok )) && _cm_check ok "the filesystem of $anc takes POSIX ACLs"
        return 0
    fi
    # a probe directory, closed to others (mktemp -d makes it 0700), with the
    # CT root's entry: can it pass?
    if (( acl_ok )) && probe="$(mktemp -d -p "$anc" .pbo-acl-probe.XXXXXX 2>/dev/null)"; then
        for u in $(printf '%s\n' "${!_PERM_CT[@]}" | sort -n); do
            if ! setfacl -P -m "u:$u:x" -- "$probe" 2>/dev/null || ! _perm_traverses "$u" "$probe"; then
                _cm_check fail69 "uid $u (unprivileged CT(s) ${_PERM_CT[$u]}) cannot pass a directory on $anc's filesystem even with an ACL entry"; acl_ok=0
            fi
        done
        rm -rf -- "$probe"
        (( acl_ok )) && _cm_check ok "the filesystem of $anc takes POSIX ACLs (an entry lets the CT root(s) through)"
    fi
    # every directory above the target that exists (those mkdir makes are 0755)
    local anclist=() bad=0
    d="$(_cm_existing "${CM_NEW%/*}")"; [[ -n "$d" ]] || d=/
    top="$(_cm_norm "$top")"
    while :; do
        [[ -n "$top" && "$d" != "$top" && "$d" != "$top"/* ]] && break
        anclist=("$d" "${anclist[@]+"${anclist[@]}"}")
        [[ "$d" == / ]] && break
        d="${d%/*}"; [[ -n "$d" ]] || d=/
    done
    for u in $(printf '%s\n' "${!_PERM_CT[@]}" | sort -n); do
        for d in "${anclist[@]+"${anclist[@]}"}"; do
            _perm_traverses "$u" "$d" && continue
            bad=1
            CM_FIXLINES+=("setfacl -m u:$u:x $d")
            CM_PARENTFIX+=("$d u:$u:--x")
            if (( CM_FIX_PARENTS )); then
                _cm_check ok "$d does not let uid $u (unprivileged CT(s) ${_PERM_CT[$u]}) through: --fix-parents adds u:$u:--x"
            else
                _cm_check fail69 "$d does not let uid $u (the mapped root of unprivileged CT(s) ${_PERM_CT[$u]}) through: their vzdump would fail in $CM_NEW; run: setfacl -m u:$u:x $d (or add --fix-parents)"
            fi
        done
    done
    (( bad )) || _cm_check ok "the mapped root of unprivileged CT(s) $cts can pass every directory above $CM_NEW (tested with setpriv)"
    return 0
}

# _cm_preflight_idle: nothing may use the cache: no backup, prune, verify,
# ingest, restore, integrate run; no vzdump; nothing in the spool waiting for
# ingest; no stop-mode archive waiting for job-end; no process with a file open
# in the cache; no restore reading through the mount.
_cm_preflight_idle() {
    local busy=() f v p
    _cm_lock_busy "$GLOBAL_LOCK_FILE" && busy+=("a backup or prune holds the global lock ($(read_global_holder))")
    _cm_lock_busy "$SCHED_LOCK_FILE" && busy+=("a scheduled run, prune or verify holds the schedule lock ($(read_schedule_holder))")
    _cm_lock_busy "${LOCK_DIR%/}/pbo.integrate" && busy+=("'pbo integrate' runs")
    for f in "${LOCK_DIR%/}"/pbo.vmid-*.lock; do
        [[ -e "$f" ]] || continue
        v="${f##*/pbo.vmid-}"; v="${v%.lock}"
        _cm_lock_busy "$f" && busy+=("guest $v is being backed up, ingested or restored (its lock is held)")
    done
    # the mount holds the cache lock shared; anything else that holds it is a user
    if (( ! CM_MOUNT )) && _cm_lock_busy "${LOCK_DIR%/}/pbo.cache"; then busy+=("a restore, fetch or staging reads the cache (lock pbo.cache)"); fi
    if (( CM_MOUNT )) && _catalog_mount_busy; then busy+=("a restore reads through $PBO_MOUNT_UNIT (${PVE_CATALOG_MOUNT_DIR:-})"); fi
    if _vzdump_running; then busy+=("vzdump runs (${VZDUMP_LOCK:-/var/run/vzdump.lock} is held)")
    else p="$(_cm_vzdump_pids)"; [[ -z "$p" ]] || busy+=("vzdump runs (pid $p)"); fi
    local sp="${CM_KO[PVE_SPOOL_DIR]:-${PVE_SPOOL_DIR%/}}" n
    if [[ -d "$sp/dump" ]]; then
        n="$(find "$sp/dump" -maxdepth 1 -type f -name 'vzdump-*' ! -name '*.log' ! -name '*.notes' 2>/dev/null | wc -l)"
        (( n == 0 )) || busy+=("$n archive(s) wait in the spool $sp/dump for ingest ('pbo ingest --pending' takes them)")
    fi
    local dd; dd="$(_ingest_defer_dir)"
    if [[ -d "$dd" ]] && [[ -n "$(find "$dd" -maxdepth 1 -type f -print -quit 2>/dev/null)" ]]; then
        busy+=("stop-mode archive(s) wait for their job's end ($dd): a PVE backup job runs")
    fi
    if [[ -d "$CM_OLD" ]] && p="$(_cm_open_below "$CM_OLD")"; then busy+=("process ${p%%:*} has ${p#*:} open"); fi
    if (( ${#busy[@]} )); then
        for f in "${busy[@]}"; do _cm_check fail69 "busy: $f"; done
    else
        _cm_check ok "nothing uses the cache: no backup, ingest, restore, vzdump; the spool is empty"
    fi
    return 0
}

# --- locks ---------------------------------------------------------------------------------------
# _cm_flock VAR FILE [WAIT]: take FILE exclusive (WAIT seconds, else not at all)
# on a new fd → VAR. 1 when it is busy.
_cm_flock() {
    local var="$1" f="$2" w="${3:-}" fd
    [[ -L "$f" ]] && { CM_ERR="the lock $f is a symlink: remove it"; return 1; }
    { exec {fd}>>"$f"; } 2>/dev/null || { CM_ERR="cannot open the lock $f"; return 1; }
    if [[ -n "$w" ]]; then flock -w "$w" -x "$fd" || { exec {fd}>&-; return 1; }
    else flock -n -x "$fd" || { exec {fd}>&-; return 1; }; fi
    printf -v "$var" '%s' "$fd"
}
# _cm_lock_all: every lock a pbo command that uses the cache takes, so none
# can start while the move runs (the cache lock comes after the mount stopped)
_cm_lock_all() {
    [[ -d "$LOCK_DIR" ]] || { mkdir -p -- "$LOCK_DIR" && chmod 0700 -- "$LOCK_DIR"; } 2>/dev/null || true
    if [[ "${GLOBAL_LOCK_HELD:-0}" != 1 ]]; then
        _cm_flock GLOBAL_LOCK_FD "$GLOBAL_LOCK_FILE" || { CM_ERR="${CM_ERR:-a backup or prune runs (global lock: $(read_global_holder))}"; return 1; }
        GLOBAL_LOCK_HELD=1; _write_global_holder cache-move ''
    fi
    if [[ "${SCHED_LOCK_HELD:-0}" != 1 ]]; then
        _cm_flock SCHED_LOCK_FD "$SCHED_LOCK_FILE" || { CM_ERR="${CM_ERR:-a scheduled run, prune or verify runs (schedule lock)}"; return 1; }
        SCHED_LOCK_HELD=1
        printf '%s|%s|%s\n' cache-move "$$" "$(date +%s)" > "$SCHED_HOLDER_FILE" 2>/dev/null || true
    fi
    if [[ -z "${INTEG_LOCK_FD:-}" ]]; then
        _cm_flock INTEG_LOCK_FD "${LOCK_DIR%/}/pbo.integrate" || { CM_ERR="${CM_ERR:-'pbo integrate' runs}"; return 1; }
    fi
    # a catalogue refresh reads the cache repo: let a running one finish
    if [[ -z "${CATALOG_LOCK_FD:-}" ]]; then
        _cm_flock CATALOG_LOCK_FD "${LOCK_DIR%/}/pbo.catalog" "${CATALOG_LOCK_TIMEOUT:-600}" || { CM_ERR="${CM_ERR:-a catalogue refresh did not finish (lock pbo.catalog)}"; return 1; }
    fi
    return 0
}
# _cm_cache_lock WAIT: the cache lock, exclusive
_cm_cache_lock() {
    [[ "${CACHE_LOCK_MODE:-}" == x ]] && return 0
    [[ -z "${CACHE_LOCK_FD:-}" ]] || { exec {CACHE_LOCK_FD}>&-; CACHE_LOCK_FD=''; }
    _cm_flock CACHE_LOCK_FD "${LOCK_DIR%/}/pbo.cache" "$1" \
        || { CM_ERR="${CM_ERR:-a restore, fetch or staging still uses the cache (lock pbo.cache)}"; return 1; }
    CACHE_LOCK_MODE=x
}
_cm_cache_unlock() {
    [[ -n "${CACHE_LOCK_FD:-}" ]] && exec {CACHE_LOCK_FD}>&-
    CACHE_LOCK_FD='' CACHE_LOCK_MODE=''
    return 0
}
_cm_catalog_unlock() { [[ -n "${CATALOG_LOCK_FD:-}" ]] && exec {CATALOG_LOCK_FD}>&-; CATALOG_LOCK_FD=''; return 0; }

# --- the steps before the config write --------------------------------------------------------------
_cm_step_lock() {
    _cm_lock_all || return 1
    (( CM_MOUNT )) && return 0
    _cm_cache_lock '' || return 1
}
_cm_step_mount_stop() {
    if ! _cm_jdone mount-stop && (( CM_MOUNT )); then
        _cm_say "stopping $PBO_MOUNT_UNIT (it holds the cache repo open)"
        systemctl stop "$PBO_MOUNT_UNIT" >/dev/null 2>&1 || { CM_ERR="could not stop $PBO_MOUNT_UNIT (systemctl stop $PBO_MOUNT_UNIT)"; return 1; }
    fi
    # the mount's restic exits and drops its shared lock: wait for that
    _cm_cache_lock "${PBO_CM_LOCK_WAIT:-30}" || return 1
}
_cm_step_storage_disable() {
    _cm_jdone storage-disable && return 0
    (( CM_INTEG && CM_ST_PRESENT && ! CM_ST_DISABLED )) || return 0
    # recorded before the change: an interruption right after it still re-enables
    _cm_jupd '.storage.disabled_by_move = true' || { CM_ERR="cannot write the journal"; return 1; }
    _cm_say "pvesm set $CM_SID --disable 1 (no PVE job writes to it while the cache moves)"
    pvesm set "$CM_SID" --disable 1 >/dev/null 2>&1 || { CM_ERR="pvesm set $CM_SID --disable 1 failed"; return 1; }
}
_cm_step_staging_clear() {
    local s="${CM_KO[PVE_STAGING_DIR]:-}" f n=0
    [[ -n "$s" && -d "$s" && ! -L "$s" ]] || return 0
    # staged archives are copies or links into the mount, made again on demand
    while IFS= read -r -d '' f; do rm -f -- "$f" && n=$((n+1)); done \
        < <(find "$s" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -name 'vzdump-*' -print0 2>/dev/null)
    (( n == 0 )) || _cm_say "removed $n staged archive(s) from $s"
    return 0
}
_cm_step_target_create() {
    local new="$CM_NEW" d miss=()
    d="${new%/*}"
    while [[ -n "$d" && ! -e "$d" ]]; do miss=("$d" "${miss[@]+"${miss[@]}"}"); d="${d%/*}"; done
    if (( ${#miss[@]} )); then
        _cm_jupd '.created_parents = (.created_parents + $p | unique)' --argjson p "$(printf '%s\n' "${miss[@]}" | jq -R . | jq -cs .)" \
            || { CM_ERR="cannot write the journal"; return 1; }
        ( umask 022; mkdir -p -- "${miss[-1]}" ) || { CM_ERR="cannot create ${miss[-1]}"; return 1; }
    fi
    if [[ ! -d "$new" ]]; then
        _cm_jupd '.created_new = true' || { CM_ERR="cannot write the journal"; return 1; }
        ( umask 022; mkdir -- "$new" ) || { CM_ERR="cannot create $new"; return 1; }
    fi
    # the CACHE_DIR rule on the new directory: the CT roots' entries, then
    # closed (a rename replaces it with the old directory, which has its own)
    local CACHE_DIR="$new" PERM_EXTRA_VMIDS=() e
    _perm_apply --fix --only CACHE_DIR:dir || true
    for e in "${PERM_FIX_ERRORS[@]+"${PERM_FIX_ERRORS[@]}"}"; do _cm_say "$e"; done
    if (( CM_FIX_PARENTS )); then
        _perm_apply --fix --fix-parents --only CACHE_DIR:parents || true
        local c; for c in "${PERM_CHANGES[@]+"${PERM_CHANGES[@]}"}"; do _cm_say "--fix-parents: $(_perm_change_text "$c")"; done
        for e in "${PERM_FIX_ERRORS[@]+"${PERM_FIX_ERRORS[@]}"}"; do CM_ERR="--fix-parents: $e"; return 1; done
        for e in "${PERM_FINDINGS[@]+"${PERM_FINDINGS[@]}"}"; do
            [[ "${e%%$'\t'*}" == ok ]] || { CM_ERR="--fix-parents: ${e##*$'\t'}"; return 1; }
        done
    fi
    return 0
}
# _cm_tree DIR → one line per entry below DIR (type, mode, owner, group, size,
# link target, path), sorted; a directory's size is the filesystem's, not data
_cm_tree() {
    local t
    # a side that cannot be read must fail the comparison, not compare empty
    t="$(cd -- "$1" 2>/dev/null && find . -mindepth 1 \( -path ./lost+found -o -path ./.zfs -o -path ./.snapshot \) -prune \
        -o -printf '%y\t%m\t%U\t%G\t%s\t%l\t%P\n')" || return 1
    awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "d" { $5 = 0 } { print }' <<<"$t" | LC_ALL=C sort
}
_cm_step_data() {
    local old="$CM_OLD" new="$CM_NEW" e
    if [[ "$CM_METHOD" == rename ]]; then
        # renamed before an interruption (another pbo may have made the old
        # directory again, empty, when it started: ensure_dirs)
        if [[ "$(_cm_jv .data_started)" == true && -d "$new" && -n "$(_cm_entries "$new")" ]] \
           && { [[ ! -e "$old" ]] || [[ -d "$old" && -z "$(_cm_entries "$old")" ]]; }; then
            return 0
        fi
        # the preflight refused a mount below the old cache; one may have come since
        local mp; mp="$(_cm_mounts_below "$old" | head -n 1)"
        [[ -z "$mp" ]] || { CM_ERR="$mp is mounted below $old: a rename would move only its mount stub"; return 1; }
        _cm_jupd '.data_started = true' || { CM_ERR="cannot write the journal"; return 1; }
        _cm_say "mv -T $old $new"
        _cm_rename "$old" "$new" || { CM_ERR="the rename $old -> $new failed (another mount of the filesystem? pbo does not fall back to an unchecked copy)"; return 1; }
        return 0
    fi
    _cm_jupd '.data_started = true' || { CM_ERR="cannot write the journal"; return 1; }
    # a resumed copy starts over: the target was empty before the move
    if [[ -n "$(_cm_entries "$new")" ]]; then _cm_rm_entries "$new" || { CM_ERR="cannot empty $new for the copy"; return 1; }; fi
    local -a ents=()
    mapfile -t ents < <(_cm_entries "$old")
    _cm_say "cp -a $old/* $new/ (${#ents[@]} entries, $(_cm_human "$CM_USAGE"))"
    for e in "${ents[@]+"${ents[@]}"}"; do
        cp -a -- "$old/$e" "$new/" || { CM_ERR="cp -a $old/$e $new/ failed (out of space?)"; return 1; }
    done
    sync -f -- "$new" 2>/dev/null || sync
    local dfo ta tb
    ta="$(_cm_tree "$old")" || { CM_ERR="cannot list $old to compare the copy"; return 1; }
    tb="$(_cm_tree "$new")" || { CM_ERR="cannot list $new to compare the copy"; return 1; }
    if ! dfo="$(diff <(printf '%s\n' "$ta") <(printf '%s\n' "$tb") 2>&1)"; then
        CM_ERR="the copy in $new differs from $old: $(head -n 4 <<<"$dfo" | tr '\n' ' ')"; return 1
    fi
    _cm_say "the copy matches $old (sizes, counts, modes, owners)"
    local nr="${CM_KN[RESTIC_CACHE_REPO]:-}" out
    if [[ "${CM_KHOW[RESTIC_CACHE_REPO]:-}" == follow && -f "$nr/config" ]]; then
        local args=(check); (( CM_VERIFY_DATA )) && args+=(--read-data)
        _cm_say "restic ${args[*]} on the copied cache repo $nr"
        if ! out="$(_restic "$nr" "${args[@]}" 2>&1)"; then
            CM_ERR="restic ${args[*]} of the copied repo $nr failed: $(tail -n 2 <<<"$out" | tr '\n' ' ')"; return 1
        fi
    fi
    return 0
}
# _cm_rm_entries DIR: everything in DIR but its filesystem's own entries
_cm_rm_entries() {
    local d="$1" e rc=0
    [[ -n "$d" && "$d" == /?* && "$PERM_SYSTEM_DIRS" != *" $d "* ]] || return 1
    while IFS= read -r e; do [[ -n "$e" ]] && { rm -rf --one-file-system -- "${d:?}/$e" || rc=1; }; done < <(_cm_entries "$d")
    return "$rc"
}

# --- the steps after the config write ------------------------------------------------------------------
_cm_step_storage_update() {
    (( CM_INTEG && CM_ST_PRESENT )) || return 0
    local sj path dis
    sj="$(_integ_storage_json "$CM_SID" 2>/dev/null)" || sj=''
    [[ "$(jq -r .present <<<"$sj" 2>/dev/null)" == true ]] || { CM_ERR="storage '$CM_SID' is no longer in storage.cfg"; return 1; }
    path="$(_cm_norm "$(jq -r '.path // ""' <<<"$sj")")"; dis="$(jq -r .disabled <<<"$sj")"
    if [[ -n "$CM_ST_NEWPATH" && "$path" != "$CM_ST_NEWPATH" ]]; then
        _cm_say "pvesm set $CM_SID --path $CM_ST_NEWPATH"
        pvesm set "$CM_SID" --path "$CM_ST_NEWPATH" >/dev/null 2>&1 || { CM_ERR="pvesm set $CM_SID --path $CM_ST_NEWPATH failed"; return 1; }
    fi
    if [[ "$(_cm_jv .storage.disabled_by_move)" == true && "$dis" == true ]]; then
        _cm_say "pvesm set $CM_SID --delete disable"
        pvesm set "$CM_SID" --delete disable >/dev/null 2>&1 || { CM_ERR="pvesm set $CM_SID --delete disable failed"; return 1; }
    fi
    return 0
}
_cm_step_catalog_refresh() {
    (( CM_INTEG )) || [[ -f "${PBO_CATALOG:-}" ]] || return 0
    # its own lock; the refresh writes the new staging_dir the plugin reads
    _cm_catalog_unlock
    local rc=0 out
    out="$( _close_lock_fds; PBO_NO_NOTIFY=1 "${SELF_DIR}/pbo" catalog refresh 2>&1 )" || rc=$?
    if (( rc != 0 )); then
        CM_POSTWARN+=("the catalogue refresh failed (exit $rc; pbo-catalog.timer tries again): $(grep -E '\[ERROR\]' <<<"$out" | tail -n 1 | sed -E 's/^.*\[ERROR\] //')")
    fi
    return 0
}
_cm_step_perms() {
    local e lv k
    local -a only=(--only CACHE_DIR:dir)
    for k in "${CM_FK[@]}"; do only+=(--only "$k"); done
    only+=(--only PVE_SPOOL_DIR/dump)
    _perm_apply --fix "${only[@]}" || true
    for e in "${PERM_CHANGES[@]+"${PERM_CHANGES[@]}"}"; do _cm_say "permissions: $(_perm_change_text "$e")"; done
    for e in "${PERM_FIX_ERRORS[@]+"${PERM_FIX_ERRORS[@]}"}"; do CM_POSTWARN+=("$e"); done
    _perm_apply --check "${only[@]}" --only CACHE_DIR:parents || true
    for e in "${PERM_FINDINGS[@]+"${PERM_FINDINGS[@]}"}"; do
        lv="${e%%$'\t'*}"
        [[ "$lv" == ok ]] || CM_POSTWARN+=("doctor: ${e##*$'\t'}")
    done
    return 0
}
_cm_step_old_remove() {
    local old="$CM_OLD" e unknown=()
    if [[ "$CM_METHOD" != copy ]]; then
        # renamed: only an empty directory another pbo made again on its start
        [[ -d "$old" && ! -L "$old" && -z "$(_cm_entries "$old")" ]] && rmdir -- "$old" 2>/dev/null
        return 0
    fi
    if (( CM_KEEP_OLD )); then CM_POSTNOTE+=("the old directory $old is kept (--keep-old): remove it when you no longer need it"); return 0; fi
    [[ -d "$old" ]] || return 0
    while IFS= read -r e; do [[ -n "$e" && ! "$e" =~ $CM_KNOWN_RE ]] && unknown+=("$e"); done < <(_cm_entries "$old")
    # a key pinned below the old directory under a name of its own moved too
    for e in "${CM_FK[@]}"; do
        [[ "${CM_KHOW[$e]}" == follow ]] || continue
        local b="${CM_KO[$e]#"$old"/}"; b="${b%%/*}"
        local -a keep=(); local u
        for u in "${unknown[@]+"${unknown[@]}"}"; do [[ "$u" == "$b" ]] || keep+=("$u"); done
        unknown=("${keep[@]+"${keep[@]}"}")
    done
    if (( ${#unknown[@]} )); then
        CM_POSTNOTE+=("the old directory $old is kept: it holds entries pbo does not know (${unknown[*]:0:5}); the copy in $CM_NEW is complete, remove $old yourself")
        return 0
    fi
    _cm_say "removing the old copy $old"
    _cm_rm_entries "$old" || { CM_POSTWARN+=("could not remove everything in the old directory $old"); return 0; }
    if ! rmdir -- "$old" 2>/dev/null; then
        CM_POSTNOTE+=("the old directory $old is empty now but stays (a mount point, or it holds its filesystem's own entries)")
    fi
    return 0
}

# --- rollback ------------------------------------------------------------------------------------
# _cm_rollback REASON [aborted]: undo the pre-write steps the journal records,
# newest first. The config was not written. Returns 1 when something could not
# be undone (the journal says rollback-failed; --abort tries again).
_cm_rollback() {
    local reason="$1" final="${2:-rolled-back}" errs=() old="$CM_OLD" new="$CM_NEW" p
    _cm_say "rolling back: $reason"
    if [[ "$(_cm_jv .data_started)" == true || "$(_cm_jv .created_new)" == true ]]; then
        if [[ "$CM_METHOD" == rename ]]; then
            if [[ -d "$new" && -n "$(_cm_entries "$new")" ]]; then
                if [[ ! -e "$old" ]] || [[ -d "$old" && -z "$(_cm_entries "$old")" ]]; then
                    _cm_say "mv -T $new $old"
                    _cm_rename "$new" "$old" || errs+=("could not rename $new back to $old")
                else
                    # a rename leaves one side empty: both full is no state the
                    # move made, and pbo cannot tell which one is the cache
                    errs+=("both $old and $new hold entries: nothing was removed; keep the one that holds the cache, empty the other")
                fi
            fi
            if [[ "$(_cm_jv .created_new)" == true && -d "$new" && -z "$(_cm_entries "$new")" ]]; then rmdir -- "$new" 2>/dev/null || errs+=("could not remove $new"); fi
        elif [[ -d "$new" ]]; then
            if [[ "$(_cm_jv .created_new)" == true ]]; then
                _cm_rm_entries "$new" && rmdir -- "$new" 2>/dev/null || errs+=("could not remove the partial copy $new")
            else
                _cm_rm_entries "$new" || errs+=("could not empty the partial copy in $new")
            fi
        fi
    fi
    while IFS= read -r p; do [[ -n "$p" && -d "$p" ]] && rmdir -- "$p" 2>/dev/null; done < <(jq -r '.created_parents[]?' <<<"$CMJ" | sort -r)
    if [[ "$(_cm_jv .storage.disabled_by_move)" == true ]]; then
        _cm_say "pvesm set $CM_SID --delete disable"
        pvesm set "$CM_SID" --delete disable >/dev/null 2>&1 || errs+=("pvesm set $CM_SID --delete disable failed: storage '$CM_SID' is still disabled")
    fi
    if (( ${#errs[@]} )); then
        # the mount is not started: it would stop at the unfinished journal
        _cm_jupd '.state = "rollback-failed" | .error = $e' --arg e "$reason; rollback: $(IFS=';'; printf '%s' "${errs[*]}")" || true
        CM_ERR="$reason; the rollback failed too: $(IFS=';'; printf '%s' "${errs[*]}" | sed 's/;/; /g'); fix that and run 'pbo config set CACHE_DIR $new --abort'"
        audit_log "cache-move rollback-failed old=$old new=$new"
        _cm_cache_unlock
        return 1
    fi
    # final before the cache lock and the mount let another pbo in: the
    # mount's `catalog _mount` (systemctl returns at once) stops at a journal
    # that is not final
    _cm_jupd '.state = $f | .error = $e | .finished = (now | floor)' --arg f "$final" --arg e "$reason" || true
    audit_log "cache-move $final old=$old new=$new reason=$(printf '%q' "$reason")"
    _cm_cache_unlock
    if [[ "$(_cm_jv .mount_was_active)" == true ]] && ! _catalog_mount_active; then
        _cm_say "starting $PBO_MOUNT_UNIT again"
        systemctl start "$PBO_MOUNT_UNIT" >/dev/null 2>&1 \
            || log_warn "cache move: could not start $PBO_MOUNT_UNIT again (it starts on the next restore)"
    fi
    return 0
}

# --- the state from the journal (resume, abort) ------------------------------------------------------
_cm_from_journal() {
    CM_OLD="$(_cm_jv .old)" CM_NEW="$(_cm_jv .new)" CM_METHOD="$(_cm_jv .method)"
    declare -gA CM_KO=() CM_KN=() CM_KHOW=()
    CM_FK=()
    local k
    while IFS=$'\t' read -r k a b c; do
        [[ -n "$k" ]] || continue
        CM_FK+=("$k"); CM_KO[$k]="$a" CM_KN[$k]="$b" CM_KHOW[$k]="$c"
    done < <(jq -r '.keys | to_entries[] | [.key, .value.old, .value.new, .value.how] | @tsv' <<<"$CMJ")
    CM_INTEG="$(_cm_jv '.storage.integ')"; [[ "$CM_INTEG" == 1 ]] || CM_INTEG=0
    CM_SID="$(_cm_jv .storage.id)"; [[ -n "$CM_SID" ]] || CM_SID="${PVE_STORAGE_ID:-pbo}"
    CM_ST_PRESENT=0; [[ "$(_cm_jv .storage.present)" == true ]] && CM_ST_PRESENT=1
    CM_ST_DISABLED=0; [[ "$(_cm_jv .storage.disabled_before)" == true ]] && CM_ST_DISABLED=1
    CM_ST_PATH="$(_cm_jv .storage.path)" CM_ST_NEWPATH="$(_cm_jv .storage.new_path)"
    CM_MOUNT=0; [[ "$(_cm_jv .mount_was_active)" == true ]] && CM_MOUNT=1
    CM_KEEP_OLD=$(( CM_KEEP_OLD || $([[ "$(_cm_jv .keep_old)" == true ]] && echo 1 || echo 0) ))
    CM_VERIFY_DATA=$(( CM_VERIFY_DATA || $([[ "$(_cm_jv .verify_data)" == true ]] && echo 1 || echo 0) ))
    CM_FIX_PARENTS=$(( CM_FIX_PARENTS || $([[ "$(_cm_jv .fix_parents)" == true ]] && echo 1 || echo 0) ))
    CM_USAGE="$(_cm_jv .usage)"; [[ "$CM_USAGE" =~ ^[0-9]+$ ]] || CM_USAGE=0
}

# _cm_journal_new: the journal of the move planned in CM_* (state running)
_cm_journal_new() {
    local keys='{}' k hist='[]' prev=''
    for k in "${CM_FK[@]}"; do
        keys="$(jq -c --arg k "$k" --arg o "${CM_KO[$k]}" --arg n "${CM_KN[$k]}" --arg h "${CM_KHOW[$k]}" '.[$k] = {old:$o, new:$n, how:$h}' <<<"$keys")"
    done
    # the places earlier moves left, for _cm_init_guard and ensure_dirs
    if _cm_jload; then
        prev="$CMJ"
        hist="$(jq -c 'if .state == "done" then [{old, new, finished, old_repo:(.keys.RESTIC_CACHE_REPO.old // null)}] else [] end + (.history // []) | .[0:20]' <<<"$prev" 2>/dev/null)" || hist='[]'
    fi
    CMJ="$(jq -cn --argjson v "$CM_JOURNAL_VERSION" --arg old "$CM_OLD" --arg new "$CM_NEW" --arg m "$CM_METHOD" \
        --arg node "$(_local_node)" --argjson pid "$$" --argjson now "$(date +%s)" --argjson keys "$keys" --argjson hist "$hist" \
        --arg sid "$CM_SID" --argjson integ "$CM_INTEG" --argjson present "$CM_ST_PRESENT" --argjson dis "$CM_ST_DISABLED" \
        --arg sp "$CM_ST_PATH" --arg snp "$CM_ST_NEWPATH" --argjson mount "$CM_MOUNT" --argjson usage "${CM_USAGE:-0}" \
        --argjson keep "$CM_KEEP_OLD" --argjson vd "$CM_VERIFY_DATA" --argjson fp "$CM_FIX_PARENTS" '
        {version:$v, old:$old, new:$new, method:$m, node:$node, pid:$pid, state:"running", step:"", done:[],
         keys:$keys, usage:$usage,
         storage:{id:$sid, integ:$integ, present:($present == 1), disabled_before:($dis == 1), path:$sp, new_path:$snp, disabled_by_move:false},
         mount_was_active:($mount == 1), keep_old:($keep == 1), verify_data:($vd == 1), fix_parents:($fp == 1),
         created_new:false, created_parents:[], data_started:false,
         started:$now, updated:$now, finished:null, error:null, history:$hist}')" || return 1
    _cm_jsave
}

# _cm_journal_empty_change OLD NEW: the config now names NEW, changed from OLD
# without a move (M4's empty cache), after an earlier move finished. Recorded
# as the latest move, so that the places the journal bans (_cm_init_guard,
# _cm_old_location) never include where the config points now; OLD becomes a
# place the cache left. Called after the config was written: a journal that
# said NEW while the write failed would ban OLD, where the config still points.
_cm_journal_empty_change() {
    local old new n
    old="$(_cm_norm "$1")" new="$(_cm_norm "$2")"
    [[ -e "$(_cm_jfile)" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    _cm_jload || return 0
    _cm_final "$(_cm_jv .state)" || return 0
    n="$(jq -c --arg old "$old" --arg new "$new" --argjson now "$(date +%s)" '
        .history = ((if .state == "done" then [{old, new, finished, old_repo:(.keys.RESTIC_CACHE_REPO.old // null)}] else [] end
                     + (.history // [])) | .[0:20])
        | .old = $old | .new = $new | .method = "empty" | .state = "done" | .step = "done" | .done = []
        | .keys = {} | .error = null | .warnings = [] | .notes = [] | .pid = null
        | .started = $now | .updated = $now | .finished = $now' <<<"$CMJ" 2>/dev/null)" || n=''
    [[ -n "$n" ]] || { log_warn "cache move: cannot record the change $old -> $new in $(_cm_jfile)"; return 0; }
    CMJ="$n"
    _cm_jsave || log_warn "cache move: cannot write $(_cm_jfile) (the change $old -> $new is not recorded)"
    return 0
}

# --- the plan as text (dry run) --------------------------------------------------------------------
_cm_plan_text() {
    local l k i=0
    printf 'cache move plan: %s -> %s (%s)\n' "$CM_OLD" "$CM_NEW" \
        "$([[ "$CM_METHOD" == rename ]] && echo 'a rename on the same filesystem' || echo "a copy: ${CM_METHOD_WHY:-another filesystem}, $(_cm_human "$CM_USAGE")")"
    printf '  checks:\n'
    for l in "${CM_CHECKS[@]}"; do printf '    %-5s %s\n' "$(case "${l%%$'\t'*}" in ok) echo ok ;; warn) echo warn ;; *) echo FAIL ;; esac)" "${l#*$'\t'}"; done
    printf '  steps:\n'
    _s() { i=$((i+1)); printf '    %2d %s\n' "$i" "$*"; }
    _s "lock: pbo.global, pbo.schedule, pbo.integrate, pbo.catalog, then pbo.cache (exclusive: backups, ingest, restores and the mount get exit 75)"
    if (( CM_MOUNT )); then _s "mount-stop: systemctl stop $PBO_MOUNT_UNIT (started again at the end)"; else _s "mount-stop: $PBO_MOUNT_UNIT is not running"; fi
    if (( CM_INTEG && CM_ST_PRESENT && ! CM_ST_DISABLED )); then _s "storage-disable: pvesm set $CM_SID --disable 1"
    else _s "storage-disable: nothing to do$( (( CM_INTEG )) || printf ' (standalone)')"; fi
    _s "staging-clear: remove the staged archives in ${CM_KO[PVE_STAGING_DIR]:-${PVE_STAGING_DIR:-}}"
    _s "target-create: $CM_NEW, closed to others (at most 0750), an ACL entry per unprivileged CT root$( (( CM_FIX_PARENTS && ${#CM_PARENTFIX[@]} )) && printf '; --fix-parents: %s' "$(IFS=,; printf '%s' "${CM_PARENTFIX[*]}" | sed 's/,/, /g')")"
    if [[ "$CM_METHOD" == rename ]]; then _s "data: mv -T $CM_OLD $CM_NEW"
    else _s "data: cp -a $CM_OLD/* $CM_NEW/, compare the trees (sizes, counts, modes, owners), restic check$( (( CM_VERIFY_DATA )) && printf ' --read-data') of the copied cache repo"; fi
    local w="CACHE_DIR=$CM_NEW"
    for k in "${CM_FK[@]}"; do
        case "${CM_KHOW[$k]}" in
            follow) w+="; $k ${CM_KO[$k]} -> ${CM_KN[$k]}" ;;
            stays)  w+="; $k stays ${CM_KO[$k]}" ;;
        esac
    done
    _s "config: one transaction ($w); the diff is below"
    local su="storage-update: "
    if (( CM_INTEG && CM_ST_PRESENT )); then
        [[ -n "$CM_ST_NEWPATH" ]] && su+="pvesm set $CM_SID --path $CM_ST_NEWPATH; "
        (( CM_ST_DISABLED )) && su+="the storage stays disabled as it was" || su+="pvesm set $CM_SID --delete disable"
    else su+="nothing to do"; fi
    _s "$su"
    _s "catalog-refresh: $( (( CM_INTEG )) || [[ -f "${PBO_CATALOG:-}" ]] && echo "pbo catalog refresh (the plugin reads the new staging directory)" || echo "no catalogue")"
    _s "perms: the CACHE_DIR, cache repo, spool and staging rules on the new paths, then their check"
    if [[ "$CM_METHOD" == rename ]]; then _s "old-remove: nothing (renamed)"
    elif (( CM_KEEP_OLD )); then _s "old-remove: $CM_OLD is kept (--keep-old)"
    else _s "old-remove: remove $CM_OLD if it holds nothing but pbo's own directories"; fi
    (( CM_MOUNT )) && _s "then: systemctl start $PBO_MOUNT_UNIT"
    unset -f _s
    return 0
}

# --- entry points --------------------------------------------------------------------------------------
# _cm_needed OLD: a change of CACHE_DIR away from OLD is a move (not M4's empty
# case): OLD holds data (any file, a directory pbo cannot read), the spool
# follows while the integration is on (storage.cfg names it), or a move is
# unfinished. → CM_WHY
_cm_needed() {
    local old="$1" hit
    CM_WHY=''
    if [[ -e "$(_cm_jfile)" ]] && _cm_active; then CM_WHY=journal; return 0; fi
    if [[ -e "$old" ]]; then
        # the snapshot directories of a ZFS dataset (snapdir=visible) or an NFS
        # export at the cache root hold old copies, not this cache's data
        if ! hit="$(find "$old" -mindepth 1 \( -path "$old/.zfs" -o -path "$old/.snapshot" \) -prune -o ! -type d -print -quit 2>/dev/null)" \
           || [[ ! -r "$old" ]]; then hit="$old (cannot be read)"; fi
        if [[ -n "$hit" ]]; then CM_WHY="data: ${hit#"$old"/}"; return 0; fi
    fi
    if [[ -n "${CFGW_EA[PVE_SPOOL_DIR]+x}" && "${CFGW_EB[PVE_SPOOL_DIR]}" != "${CFGW_EA[PVE_SPOOL_DIR]}" ]] && ! _integration_standalone; then
        CM_WHY="integration"; return 0
    fi
    return 1
}

# _cm_hook OLD NEW: the move, from the move-cache hook (config lock held, the
# new file checked, not yet in place). Dry run: the plan. Otherwise preflight,
# the journal, the pre-write steps; CM_PENDING=1 when the writer may now
# replace the file (_config_change_cmd then calls _cm_after_write, or
# _cm_rollback when the write fails). Returns an exit code with CFGW_ERR.
_cm_hook() {
    local old new resume=0 f
    old="$(_cm_norm "$1")" new="$(_cm_norm "$2")"
    CM_ERR='' CM_PENDING=0
    command -v jq >/dev/null 2>&1 || { CFGW_ERR="jq is required to move CACHE_DIR"; return "$EX_UNAVAILABLE"; }
    if _is_janitor; then
        CFGW_ERR="CACHE_DIR $old holds data: pbo moves a janitor's cache only when it is empty; stop pbo-janitor.timer, move the directory yourself (mv), then run config set again"
        return "$EX_CONFIG"
    fi
    if [[ -e "$(_cm_jfile)" ]] && _cm_active; then
        if (( ! CM_RESUME )) || [[ -z "$CMJ" ]]; then CFGW_ERR="$(_cm_desc) is unfinished; $(_cm_hint)"; return "$EX_TEMPFAIL"; fi
        if [[ "$(_cm_jv .old)" != "$old" || "$(_cm_jv .new)" != "$new" ]]; then
            CFGW_ERR="the unfinished move is $(_cm_jv .old) -> $(_cm_jv .new), not $old -> $new; $(_cm_hint)"; return "$EX_USAGE"
        fi
        resume=1
    fi
    if (( resume )); then
        _cm_from_journal
        # the keys must follow as planned: the config is the one the move started from
        local k nv
        for k in "${CM_FK[@]}"; do
            if [[ -n "${CFGW_EA[$k]+x}" ]]; then nv="$(_cm_norm "${CFGW_EA[$k]}")"; else nv="$(_cm_norm "${!k-}")"; fi
            [[ "$nv" == "${CM_KN[$k]}" ]] || { CFGW_ERR="the config changed since the move started ($k would be $nv, the move planned ${CM_KN[$k]}): undo it with 'pbo config set CACHE_DIR $new --abort'"; return "$EX_CONFIG"; }
        done
        _cm_preflight --resume
    else
        _cm_plan "$old" "$new"
        _cm_preflight
    fi
    if (( ${#CM_F78[@]} + ${#CM_F69[@]} )); then
        for f in "${CM_F78[@]+"${CM_F78[@]}"}" "${CM_F69[@]+"${CM_F69[@]}"}"; do log_warn "cache move: $f"; done
        for f in "${CM_FIXLINES[@]+"${CM_FIXLINES[@]}"}"; do log_warn "cache move: to let the CT roots through, run:  $f"; done
        # a dry run shows the whole plan with its failures (the refusal ends
        # the command before the report)
        if [[ "${DRY_RUN:-0}" == 1 && "${JSON_OUTPUT:-0}" != 1 ]]; then _cm_plan_text >&2; fi
        local all=("${CM_F78[@]+"${CM_F78[@]}"}" "${CM_F69[@]+"${CM_F69[@]}"}") j=''
        for f in "${all[@]}"; do j+="${j:+; }$f"; done
        CFGW_ERR="CACHE_DIR $old -> $new refused, nothing was changed: $j"
        (( ${#CM_F78[@]} )) && return "$EX_CONFIG"
        return "$EX_UNAVAILABLE"
    fi
    for f in "${CM_W[@]+"${CM_W[@]}"}"; do log_warn "cache move: $f"; done
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        (( resume )) && { _cfgh move-cache would "would resume $(_cm_desc) at the steps not done yet: $(jq -r '.done | join(", ")' <<<"$CMJ") done"; return 0; }
        _cfgh move-cache would "$(_cm_plan_text)"
        return 0
    fi
    if (( ! resume && ! CM_YES )); then
        local q
        q="move CACHE_DIR $old -> $new ($([[ "$CM_METHOD" == rename ]] && echo rename || echo "copy $(_cm_human "$CM_USAGE")"))? Backups, ingest, restores$( (( CM_INTEG )) && printf ", the PVE storage '%s'" "$CM_SID"; true) are blocked while it runs"
        if [[ ! -t 0 ]]; then CFGW_ERR="the cache holds data: $q. Not a terminal: add --yes to move it (--dry-run shows the plan)"; return "$EX_USAGE"; fi
        local a; read -r -p "config: $q [y/N] " a
        [[ "$a" == [yYjJ]* ]] || { CFGW_ERR="cancelled, nothing was changed"; return "$EX_USAGE"; }
    fi
    if (( ! resume )); then
        _cm_journal_new || { CFGW_ERR="cannot write the journal $(_cm_jfile)"; return "$EX_CANTCREAT"; }
        audit_log "cache-move start old=$old new=$new method=$CM_METHOD"
    else
        _cm_jupd '.state = "running" | .pid = $p | .error = null' --argjson p "$$" || { CFGW_ERR="cannot write the journal $(_cm_jfile)"; return "$EX_CANTCREAT"; }
        audit_log "cache-move resume old=$old new=$new step=$(_cm_jv .step)"
    fi
    _cm_say "$old -> $new ($CM_METHOD)"
    local s fn
    for s in lock mount-stop storage-disable staging-clear target-create data; do
        fn="_cm_step_${s//-/_}"
        _cm_jupd '.step = $s' --arg s "$s" || { CM_ERR="cannot write the journal"; break; }
        "$fn" || { CM_ERR="${CM_ERR:-the step $s failed}"; break; }
        _cm_mark "$s" || { CM_ERR="cannot write the journal"; break; }
        _cm_test_point "$s" || break
        CM_ERR=''
    done
    if [[ -n "$CM_ERR" ]]; then
        local why="step $s: $CM_ERR"
        if _cm_rollback "$why"; then
            CFGW_ERR="the cache move failed at $why; rolled back, nothing was changed ($CM_OLD is as it was)"
        else
            CFGW_ERR="the cache move failed at $why. $CM_ERR"
        fi
        return "$EX_UNAVAILABLE"
    fi
    _cm_test_point config-write || {
        _cm_rollback "step config: $CM_ERR" || true
        CFGW_ERR="the cache move failed before the config write ($CM_ERR); rolled back, nothing was changed"; return "$EX_UNAVAILABLE"
    }
    CM_PENDING=1
    _cfgh move-cache ok "the data is in $new ($CM_METHOD); the config follows"
    return 0
}

# _cm_after_write: the writer replaced the config: the journal says so, then
# the steps after it. Returns 1 when one failed (the config is written; the
# journal stays config-written for --resume).
_cm_after_write() {
    _cm_test_point config || true
    _cm_jupd 'if any(.done[]; . == "config") then . else .done += ["config"] end | .state = "config-written" | .step = "config"' \
        || CM_POSTWARN+=("cannot write the journal after the config write")
    audit_log "cache-move config-written old=$CM_OLD new=$CM_NEW"
    _cm_run_post
}

# _cm_run_post: storage-update, catalog-refresh, perms, old-remove, then done;
# the mount starts again once the cache lock is free.
_cm_run_post() {
    CM_POSTWARN=() CM_POSTNOTE=()
    local k s fn
    # what pbo uses from here on: the new paths
    CACHE_DIR="$CM_NEW"
    for k in "${CM_FK[@]}"; do printf -v "$k" '%s' "${CM_KN[$k]}"; done
    for s in storage-update catalog-refresh perms old-remove; do
        _cm_jdone "$s" && continue
        fn="_cm_step_${s//-/_}"; CM_ERR=''
        _cm_jupd '.step = $s' --arg s "$s" || true
        if ! "$fn"; then
            _cm_jupd '.error = $e' --arg e "step $s: ${CM_ERR:-failed}" || true
            CM_ERR="the config names $CM_NEW and the data is there, but the step $s failed: ${CM_ERR:-?}; fix it and run 'pbo config set CACHE_DIR $CM_NEW --resume' (backups stay blocked until then)"
            _cfgh move-cache failed "$CM_ERR"
            audit_log "cache-move failed old=$CM_OLD new=$CM_NEW step=$s"
            return 1
        fi
        _cm_mark "$s" || true
        _cm_test_point "$s" || { _cm_jupd '.error = $e' --arg e "step $s: $CM_ERR" || true; _cfgh move-cache failed "$CM_ERR; run 'pbo config set CACHE_DIR $CM_NEW --resume'"; return 1; }
    done
    _cm_jupd '.state = "done" | .step = "done" | .error = null | .finished = (now | floor)
              | .warnings = $w | .notes = $n' \
        --argjson w "$(printf '%s\n' "${CM_POSTWARN[@]+"${CM_POSTWARN[@]}"}" | jq -R . | jq -cs 'map(select(length > 0))')" \
        --argjson n "$(printf '%s\n' "${CM_POSTNOTE[@]+"${CM_POSTNOTE[@]}"}" | jq -R . | jq -cs 'map(select(length > 0))')" || true
    audit_log "cache-move done old=$CM_OLD new=$CM_NEW method=$CM_METHOD"
    _cm_cache_unlock
    if (( CM_MOUNT )) && ! _catalog_mount_active; then
        _cm_say "starting $PBO_MOUNT_UNIT again"
        systemctl start "$PBO_MOUNT_UNIT" >/dev/null 2>&1 || CM_POSTWARN+=("could not start $PBO_MOUNT_UNIT again (it starts on the next restore)")
    fi
    local msg="CACHE_DIR moved: $CM_OLD -> $CM_NEW ($CM_METHOD)"
    for k in "${CM_POSTNOTE[@]+"${CM_POSTNOTE[@]}"}"; do msg+="; $k"; done
    _cfgh move-cache ok "$msg"
    for k in "${CM_POSTWARN[@]+"${CM_POSTWARN[@]}"}"; do log_warn "cache move: $k"; _cfgh move-cache warn "$k"; done
    return 0
}

# _cm_before_write SUB NEW: `config set|unset CACHE_DIR` while a journal says a
# move is unfinished, or with --resume/--abort: run what needs no config write
# here (abort; resume after the write) and return 1 when the command is done
# (CFGH holds what happened, CM_RC the exit code); return 0 to go on to the
# writer (a new move, or a resume before the write).
_cm_before_write() {
    local new; new="$(_cm_norm "$2")"
    CM_RC=0
    local active=1 rc=0
    _cm_jload || rc=$?
    if (( rc == 1 )); then active=0
    elif (( rc == 0 )) && _cm_final "$(_cm_jv .state)"; then active=0; fi
    if (( ! active )); then
        if (( CM_RESUME || CM_ABORT )); then
            die "$EX_USAGE" "config $1 CACHE_DIR: no unfinished cache move to $( (( CM_RESUME )) && echo resume || echo abort )$([[ -n "$CMJ" ]] && printf ' (the last one, %s -> %s, is %s)' "$(_cm_jv .old)" "$(_cm_jv .new)" "$(_cm_jv .state)")"
        fi
        return 0
    fi
    (( rc == 2 )) && die "$EX_TEMPFAIL" "config $1 CACHE_DIR: $(_cm_hint)"
    if [[ "$(_cm_jv .new)" != "$new" ]]; then
        die "$EX_USAGE" "config $1 CACHE_DIR: $(_cm_desc) is unfinished; $(_cm_hint)"
    fi
    (( CM_RESUME || CM_ABORT )) || die "$EX_TEMPFAIL" "config $1 CACHE_DIR: $(_cm_desc) is unfinished; $(_cm_hint)"
    _cm_from_journal
    if (( CM_ABORT )); then
        _cm_written && die "$EX_USAGE" "config $1 CACHE_DIR --abort: the config already names $CM_NEW (the data is there); a move is only undone before its config write: finish it with --resume, then move back if you want"
        if [[ "${DRY_RUN:-0}" == 1 ]]; then _cfgh move-cache would "would roll back $(_cm_desc): $(jq -r '.done | join(", ")' <<<"$CMJ") done"; return 1; fi
        _cm_abort_locks || die "$EX_TEMPFAIL" "config $1 CACHE_DIR --abort: $CM_ERR"
        if _cm_rollback "aborted by 'config $1 CACHE_DIR --abort'" aborted; then
            _cfgh move-cache ok "the move $CM_OLD -> $CM_NEW is undone: $CM_OLD is as it was, nothing in the config changed"
        else
            _cfgh move-cache failed "$CM_ERR"; CM_RC="$EX_UNAVAILABLE"
        fi
        return 1
    fi
    # --resume: before the write the writer runs it (the hook resumes it)
    _cm_written || return 0
    if [[ "${DRY_RUN:-0}" == 1 ]]; then _cfgh move-cache would "would finish $(_cm_desc): the steps after the config write that are not done"; return 1; fi
    _cm_abort_locks || die "$EX_TEMPFAIL" "config $1 CACHE_DIR --resume: $CM_ERR"
    _cm_jupd '.state = "config-written" | .pid = $p | (if any(.done[]; . == "config") then . else .done += ["config"] end)' --argjson p "$$" || true
    audit_log "cache-move resume old=$CM_OLD new=$CM_NEW step=$(_cm_jv .step)"
    _cm_run_post || CM_RC="$EX_UNAVAILABLE"
    return 1
}
# _cm_abort_locks: the locks a resume or an abort needs (the mount cannot run:
# the unfinished journal stops it from taking the cache lock)
_cm_abort_locks() {
    CM_ERR=''
    _cm_lock_all || return 1
    if _catalog_mount_active; then systemctl stop "$PBO_MOUNT_UNIT" >/dev/null 2>&1 || true; fi
    _cm_cache_lock "${PBO_CM_LOCK_WAIT:-30}"
}

# _cm_follow_ops TARGET: a key that follows CACHE_DIR and is set in TARGET at a
# path below the current CACHE_DIR that is not its derived default
# (RESTIC_CACHE_REPO=<cache>/myrepo) moves with the data: the same path below
# the new CACHE_DIR is set in the same transaction (_cfg_follows handles the
# derived default). Uses _config_change_cmd's _CC_* arrays.
_cm_follow_ops() {
    local target="$1" i k newb='' cur ov have
    cur="$(_cm_norm "${CACHE_DIR:-}")"
    for i in "${!_CC_KEYS[@]}"; do
        [[ "${_CC_KEYS[i]}" == CACHE_DIR ]] || continue
        newb="${_CC_VALS[i]}"
        if [[ "${_CC_OPS[i]}" == unset || -z "$newb" ]]; then _cs_default_r CACHE_DIR; newb="$_CS_R"; fi
    done
    newb="$(_cm_norm "$newb")"
    [[ -n "$newb" && "$newb" != "$cur" ]] || return 0
    while IFS= read -r k; do
        [[ -n "$k" ]] || continue
        have=0; for i in "${!_CC_KEYS[@]}"; do [[ "${_CC_KEYS[i]}" == "$k" ]] && have=1; done
        (( have )) && continue
        _cfg_target_value "$k" "$target" || continue
        ov="$(_cm_norm "$_CFG_TV")"
        _cm_under "$ov" "$cur" || continue
        _CC_KEYS+=("$k"); _CC_OPS+=(set); _CC_VALS+=("$newb${ov#"$cur"}")
        _CC_IMPLICIT[$k]=1
        _CC_NOTES[$k]="moved along: it lies below CACHE_DIR"
    done < <(_cm_follow_keys)
    return 0
}

# _cm_doctor → CMD_LINE/CMD_LEVEL (fail, ok or empty): the journal for doctor
_cm_doctor() {
    CMD_LINE='' CMD_LEVEL=''
    [[ -e "$(_cm_jfile)" ]] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    if _cm_active; then
        local e; e="$(_cm_jv .error)"
        CMD_LEVEL=fail CMD_LINE="$(_cm_desc) is unfinished: backups, ingest, restores and restic init are blocked; $(_cm_hint)${e:+ (last error: $e)}"
        return 0
    fi
    if [[ "$(_cm_jv .state)" == "done" ]]; then
        CMD_LEVEL=ok CMD_LINE="last cache move: $(_cm_jv .old) -> $(_cm_jv .new) ($(_cm_jv .method), $(date -d "@$(_cm_jv .finished)" '+%Y-%m-%d %H:%M' 2>/dev/null || true))"
        [[ "$(_cm_jv .method)" == copy && -d "$(_cm_jv .old)" ]] && CMD_LINE+="; the old directory $(_cm_jv .old) still exists"
    fi
    return 0
}
