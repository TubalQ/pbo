# shellcheck shell=bash
# lib/restic.sh: the backup engine (ADR 0001, Path A). restic is the only engine.
#
# The vzdump archive (UNCOMPRESSED) is stored IN restic instead of being pushed as
# tar.zst via rclone. restore goes via `restic restore` → `pct restore`.
#
# Repo model:
#   LOCAL_REPO=true  (cached)      : backup → RESTIC_CACHE_REPO → copy → RESTIC_OFFSITE_REPO
#   LOCAL_REPO=false (offsite-only): backup → RESTIC_OFFSITE_REPO directly (dumpdir transient)
#
# Grouping trick: we back up the DIRECTORY $CACHE_DIR/<vmid> (stable path per
# guest) → the snapshot's .paths stays stable → `forget --group-by paths` gives
# keep-per-guest. A guest whose path changed (CACHE_DIR moved) is retained as one
# guest by an extra pass (lib/policy.sh _forget_policy_runs). ts is added as a TAG
# (ts=YYYY_MM_DD-HH_MM_SS) for selection, vmid as a tag for migration safety. The sidecar (.conf) is included in the snapshot.

# --- restic wrapper: repo + password + own metadata cache + optional native-sftp command ---
# Used by ALL restic calls (also via run_stream) so sftp.command is set in ONE
# place. Runs as a function in run_stream's subshell (functions are inherited).
# _restic_opts: backend options shared by every restic call (also rotate-key,
# which runs restic with its own password files). Fills the RESTIC_OPTS array.
_restic_opts() {               # _restic_opts <repo>: options for THAT repo's backend
    RESTIC_OPTS=()
    case "$1" in
        sftp:*)
            [[ -n "${RESTIC_SFTP_COMMAND:-}" ]] && RESTIC_OPTS+=(-o "sftp.command=${RESTIC_SFTP_COMMAND}")
            [[ -n "${RESTIC_SFTP_CONNECTIONS:-}" ]] && RESTIC_OPTS+=(-o "sftp.connections=${RESTIC_SFTP_CONNECTIONS}") ;;
        rest:*)
            [[ -n "${RESTIC_CACERT:-}" ]] && RESTIC_OPTS+=(--cacert "${RESTIC_CACERT}") ;;
    esac
    return 0
}
# _restic_rest_env: export rest-server basic auth for the restic child. Via env,
# never argv (argv shows up in ps for every user on the host).
_restic_rest_env() {
    if [[ -n "${RESTIC_REST_USERNAME:-}" ]]; then
        export RESTIC_REST_USERNAME
        RESTIC_REST_PASSWORD="$(_rest_password)"; export RESTIC_REST_PASSWORD
    fi
    return 0
}
_restic() {                    # _restic <repo> <args...>
    _restic_opts "$1"
    # The env prefixes below re-export config vars for the restic child; the RHS
    # references the outer (config) values, not the sibling prefixes. Intended.
    # shellcheck disable=SC2097,SC2098
    ( _restic_rest_env
      RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
      RESTIC_FROM_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
      RESTIC_CACHE_DIR="$RESTIC_CACHE_DIR" \
          "$RESTIC_BIN" -r "$1" "${RESTIC_OPTS[@]+"${RESTIC_OPTS[@]}"}" "${@:2}" )
}

# _restic_w: _restic for WRITE ops (backup/copy/forget/prune/init). Adds
# --retry-lock so a short overlap with another restic process (another node's
# backup, a manual check) waits instead of failing outright. Read paths keep
# plain _restic so status/list never hang behind a long prune.
# --retry-lock needs restic >= 0.16; older binaries just fail fast as before.
_restic_has_retry_lock() {
    if [[ -z "${_RESTIC_RETRY_LOCK_OK:-}" ]]; then
        if "$RESTIC_BIN" --help 2>/dev/null | grep -q -- '--retry-lock'; then _RESTIC_RETRY_LOCK_OK=1
        else _RESTIC_RETRY_LOCK_OK=0; fi
    fi
    [[ "$_RESTIC_RETRY_LOCK_OK" == 1 ]]
}
_restic_w() {                  # _restic_w <repo> <args...>
    if [[ -n "${RESTIC_RETRY_LOCK:-}" ]] && _restic_has_retry_lock; then
        _restic "$1" --retry-lock "$RESTIC_RETRY_LOCK" "${@:2}"
    else
        _restic "$@"
    fi
}

# _restic_lock_msg <file>: if restic's output says the repo was locked, print the
# holder line ("repository is already locked exclusively by PID ... on <host>").
# Lets a failure say "repo locked" instead of a misleading "init failed".
_restic_lock_msg() {
    grep -m1 -oE 'repository is already locked.*' "$1" 2>/dev/null
}

# Newest vzdump archive for a vmid in a dumpdir, .tar (lxc) or .vma (qemu).
# Uses find (returns 0 on no match) instead of a two-glob `ls` (which returns
# non-zero when one glob misses → trips set -e/pipefail on the assignment).
_newest_dump() {               # <dir> <vmid> → path (empty if none)
    find "$1" -maxdepth 1 -type f \
        \( -name "vzdump-*-$2-*.tar" -o -name "vzdump-*-$2-*.vma" \) \
        -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-
}

# _restic_lock_die <jobfile> <what>: die with a "repo locked" reason if that is
# why the step failed; otherwise return and let the caller's generic die run.
# (`|| true`: no lock line is the normal case, and under errexit a failing
# assignment would end pbo here, before the caller's die says what failed.)
_restic_lock_die() {
    local lm; lm="$(_restic_lock_msg "$1")" || true
    [[ -n "$lm" ]] || return 0
    die "$EX_TEMPFAIL" "$2 failed: repo locked ($lm), see $1"
}

# Primary READ repo (list/restore/prune): offsite if enabled, otherwise cache.
# PBO_REPO=cache|offsite overrides the pick (used by `status` to query each tier
# separately); it is an env var, not a config key, so it survives load_config.
_restic_read_repo() {
    case "${PBO_REPO:-}" in
        cache)   printf '%s' "$RESTIC_CACHE_REPO";   return ;;
        offsite) printf '%s' "$RESTIC_OFFSITE_REPO"; return ;;
    esac
    if [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        printf '%s' "$RESTIC_OFFSITE_REPO"
    else
        printf '%s' "$RESTIC_CACHE_REPO"
    fi
}

# Primary WRITE repo (backup): cache in cached mode, otherwise offsite directly.
_restic_write_repo() {
    if [[ "${LOCAL_REPO:-true}" == "true" ]]; then printf '%s' "$RESTIC_CACHE_REPO"
    else printf '%s' "$RESTIC_OFFSITE_REPO"; fi
}

# Ensure repo (init if not present). Extra args → init.
# The existence check runs with --no-lock: `cat config` otherwise takes a repo
# lock, fails while a prune holds it, and the repo looked missing → a bogus init
# → "init failed". Returns 3 if the repo is locked, not missing.
_restic_ensure() {             # _restic_ensure <repo> [init-args...]
    local repo="$1"; shift
    _restic "$repo" --no-lock cat config >/dev/null 2>&1 && return 0
    log_info "restic: init repo $repo"
    local errf rc=0; errf="$(mktemp)"
    _restic_w "$repo" init "$@" 2>"$errf" >&2 || rc=$?
    if (( rc != 0 )); then
        local lm; lm="$(_restic_lock_msg "$errf")"
        sed 's/^/    restic: /' "$errf" >&2
        rm -f "$errf"
        [[ -n "$lm" ]] && { RESTIC_LOCK_MSG="$lm"; return 3; }
        return "$rc"
    fi
    rm -f "$errf"
}

# _restic_init_die <tier> <rc>: tell "locked" apart from a real init failure.
_restic_init_die() {
    if [[ "$2" == 3 ]]; then
        die "$EX_TEMPFAIL" "restic: $1 repo is locked by another process (${RESTIC_LOCK_MSG:-unknown}), not an init error. Is a prune or check running?"
    fi
    die "$EX_SOFTWARE" "restic: $1 repo init failed"
}

# restic_init, init cache and/or offsite repo (onboarding, idempotent).
restic_init() {
    [[ -r "$RESTIC_PASSWORD_FILE" ]] || die "$EX_CONFIG" "restic: missing password file $RESTIC_PASSWORD_FILE (0600)"
    if [[ "${LOCAL_REPO:-true}" == "true" ]]; then
        _restic_ensure "$RESTIC_CACHE_REPO" || _restic_init_die cache $?
    fi
    if [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        if [[ "${LOCAL_REPO:-true}" == "true" ]]; then
            _restic_ensure "$RESTIC_OFFSITE_REPO" --copy-chunker-params --from-repo "$RESTIC_CACHE_REPO" \
                || _restic_init_die offsite $?
        else
            _restic_ensure "$RESTIC_OFFSITE_REPO" || _restic_init_die offsite $?
        fi
    fi
}

# ---------------------------------------------------------------------------
# upload
# ---------------------------------------------------------------------------
# _upload_dumpdir <vmid> <gtype> <dumpdir> <base> <ts> <jobfile> [label]
# The upload half of a backup, shared by rdo_backup, rdo_run_batch and ingest
# (lib/ingest.sh): restic backup of the DIRECTORY <dumpdir> (= $CACHE_DIR/<vmid>,
# a stable path, so `forget --group-by paths` keeps per guest) into the write
# repo with the tags vmid/ts/type (+ keep= from the guest's Proxmox tags) and
# --host <node>; in cached mode a restic copy of that one snapshot to offsite;
# then the loose archive is removed (it lives in the repo now). <label> prefixes
# the progress lines ("backup", "ingest"); empty = quiet (batch).
# Returns 0 on success. On failure returns 1 and leaves the archive in
# <dumpdir>, with UD_STAGE=backup|copy (the step that failed) and UD_LOCK (the
# restic lock holder when the repo was locked, else empty). UD_KEEP = keep tag.
UD_STAGE="" UD_LOCK="" UD_KEEP=""
_upload_dumpdir() {
    local vmid="$1" gtype="$2" dumpdir="$3" base="$4" ts="$5" jobfile="$6" label="${7:-}"
    UD_STAGE="" UD_LOCK="" UD_KEEP=""
    local wrepo; wrepo="$(_restic_write_repo)"
    local keep; keep="$(_guest_keep_tag "$vmid")"
    local ktag=(); [[ -n "$keep" ]] && ktag=(--tag "keep=$keep")
    UD_KEEP="$keep"
    if [[ -n "$base" && ! -f "${dumpdir}/${base}" ]]; then
        UD_STAGE=backup; log_warn "upload $vmid: $base is not in $dumpdir"; return 1
    fi
    [[ -n "$label" ]] && log_info "$label $vmid: restic backup → $wrepo (tags vmid=$vmid,ts=$ts${keep:+,keep=$keep})"
    if ! run_stream "$jobfile" "restic-backup[$vmid]" -- \
            _restic_w "$wrepo" backup "$dumpdir" \
                --tag "vmid=$vmid" --tag "ts=$ts" --tag "type=$gtype" "${ktag[@]+"${ktag[@]}"}" --host "$(_local_node)"; then
        UD_STAGE=backup; UD_LOCK="$(_restic_lock_msg "$jobfile")" || true
        return 1
    fi
    # cached mode: copy the new snapshot → offsite
    if [[ "${LOCAL_REPO:-true}" == "true" && "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        [[ -n "$label" ]] && log_info "$label $vmid: restic copy cache → offsite"
        if ! run_stream "$jobfile" "restic-copy[$vmid]" -- \
                _restic_w "$RESTIC_OFFSITE_REPO" copy --from-repo "$RESTIC_CACHE_REPO" --tag "vmid=$vmid,ts=$ts"; then
            UD_STAGE=copy; UD_LOCK="$(_restic_lock_msg "$jobfile")" || true
            return 1
        fi
    fi
    # clean up the loose archive (now lives in the repo)
    rm -f "${dumpdir}"/vzdump-* 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# backup
# ---------------------------------------------------------------------------
rdo_backup() {
    local vmid="$1"
    local mode; mode="$(_effective_mode "$vmid")"
    local gtype; gtype="$(_guest_type "$vmid")" || gtype="lxc"   # lxc | qemu
    local dumpdir="${CACHE_DIR}/${vmid}"
    local job_id; job_id="backup-${vmid}-$(date +%Y%m%d-%H%M%S)"
    local jobfile="${JOBS_DIR}/${job_id}.log"

    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] restic backup vmid $vmid (mode $mode)"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$vmid" "engine" "restic"
        return "$EX_OK"
    fi

    restic_init
    # A killed previous run can leave a stale restic lock; clear it if no live
    # pbo run holds it, so one crash doesn't wedge every future backup.
    _restic_stale_unlock "$(_restic_write_repo)"
    [[ "${LOCAL_REPO:-true}" == "true" && "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]] && _restic_stale_unlock "$RESTIC_OFFSITE_REPO"
    # Clean dumpdir → snapshot content = exactly this run's archive+sidecar.
    rm -f "${dumpdir}"/vzdump-* 2>/dev/null || true
    mkdir -p "$dumpdir" "$JOBS_DIR"
    _cache_dir_protect "$vmid"   # the dump is plaintext; an unprivileged CT's tar still gets through

    # 1. vzdump UNCOMPRESSED (restic compresses itself → dedup works)
    log_info "backup $vmid: vzdump ($mode, uncompressed) → $dumpdir"
    if ! run_stream "$jobfile" "vzdump[$vmid]" -- \
            vzdump "$vmid" --mode "$mode" --compress 0 --dumpdir "$dumpdir"; then
        die "$EX_SOFTWARE" "vzdump failed for vmid $vmid (see $jobfile)"
    fi
    # lxc → .tar, qemu → .vma (both uncompressed via --compress 0)
    local archive; archive="$(_newest_dump "$dumpdir" "$vmid")"
    [[ -n "$archive" && -f "$archive" ]] || die "$EX_SOFTWARE" "no uncompressed vzdump archive (.tar/.vma) in $dumpdir"
    local base; base="$(basename "$archive")"
    local ts; ts="$(_archive_ts "$base")"; [[ -n "$ts" ]] || ts="$(date +%Y_%m_%d-%H_%M_%S)"
    # config sidecar for restore (lxc: unprivileged/bind-mounts; qemu: disks)
    _g_config "$gtype" "$vmid" > "${archive}.conf" 2>/dev/null || true

    # 2.-4. restic backup of the DIRECTORY, copy offsite, drop the loose archive
    # Per-guest retention from Proxmox tags travels with the snapshot (lib/policy.sh).
    _guest_skipped "$vmid" && log_warn "backup $vmid: guest is tagged pbo-skip; backing it up anyway (manual run)"
    _pve_jobs_load   # standalone: no-op
    local owner_job; owner_job="$(_pve_owner_job "$vmid")"
    [[ -n "$owner_job" ]] && log_warn "backup $vmid: guest $vmid is owned by PVE job $owner_job; this is an extra backup"
    if ! _upload_dumpdir "$vmid" "$gtype" "$dumpdir" "$base" "$ts" "$jobfile" backup; then
        if [[ "$UD_STAGE" == backup ]]; then
            [[ -n "$UD_LOCK" ]] && die "$EX_TEMPFAIL" "restic backup of $base failed: repo locked ($UD_LOCK), see $jobfile"
            die "$EX_SOFTWARE" "restic backup failed for $base (see $jobfile)"
        fi
        [[ -n "$UD_LOCK" ]] && die "$EX_TEMPFAIL" "restic copy → offsite for vmid $vmid failed: repo locked ($UD_LOCK), see $jobfile"
        die "$EX_UNAVAILABLE" "restic copy → offsite failed for vmid $vmid"
    fi

    local rrepo; rrepo="$(_restic_read_repo)"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "uploaded" "true" "vmid" "$vmid" "ts" "$ts" "engine" "restic" \
            "archive" "$base" "repo" "$rrepo" "job" "$jobfile"
    else
        log_info "backup $vmid: DONE (restic), ts=$ts"
    fi
    return "$EX_OK"
}

# ---------------------------------------------------------------------------
# list, emit the SAME envelope as the tar engine ({archives:[...]}) so the UI is untouched.
# ---------------------------------------------------------------------------
# _list_archives_json <repo> [vmid] [extra:0|1]: the repo's guest snapshots as a
# JSON array of archives (the `list` fields). extra=1 appends the fields the
# catalogue (lib/catalog.sh) needs: path (the snapshot's backed-up directory),
# epoch (snapshot time, seconds) and keep_tag (the per-guest keep= tag or null).
# LIST_NO_LOCK=1 reads with --no-lock (the catalogue never leaves a lock behind).
# Returns 1 when the repo is unreadable, 2 when it returned no snapshot list
# (both print nothing: an unreadable repo is never "no archives"), 3 when the
# snapshots could not be parsed (prints []).
_list_archives_json() {
    local repo="$1" only="${2:-}" extra="${3:-0}" nl=()
    [[ "${LIST_NO_LOCK:-0}" == 1 ]] && nl=(--no-lock)
    local snaps; snaps="$(_restic "$repo" "${nl[@]+"${nl[@]}"}" snapshots --json 2>/dev/null)" || return 1
    jq -e 'type=="array"' >/dev/null 2>&1 <<<"$snaps" || return 2
    local now; now="$(date +%s)"
    local xb=false; [[ "$extra" == 1 ]] && xb=true
    printf '%s' "$snaps" | jq -c --arg only "$only" --argjson now "$now" --argjson x "$xb" '
        def ts: (capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2}))$")
                 | ((.d + "Z") | fromdateiso8601)
                   - (if .z == "Z" then 0 else ((if .s == "+" then 1 else -1 end) * ((.h|tonumber)*3600 + (.m|tonumber)*60)) end))? // null;
        [ .[]
          | ((.tags // []) | map(select(startswith("vmid="))) | .[0] // "" | sub("vmid=";"")) as $vmid
          | ((.tags // []) | map(select(startswith("ts=")))   | .[0] // "" | sub("ts=";""))   as $ts
          | ((.tags // []) | map(select(startswith("type="))) | .[0] // "type=lxc" | sub("type=";"")) as $typ
          | select($vmid != "" and ($only == "" or $vmid == $only))
          | { vmid:$vmid,
              archive:("vzdump-\($typ)-\($vmid)-\($ts)." + (if $typ=="qemu" then "vma" else "tar" end)),
              size_bytes:((.summary.total_bytes_processed) // (.summary.data_added) // 0),
              modtime:.time, age_seconds:((.time | ts) as $e | if $e then $now - $e else null end),
              snapshot:.short_id, id:.id, ts:$ts, type:$typ }
            + (if $x then { path:((.paths // [])[0] // null), epoch:(.time | ts),
                            keep_tag:((.tags // []) | map(select(startswith("keep="))) | .[0] // null | if . then sub("keep=";"") else null end) }
               else {} end) ]' 2>/dev/null || { printf '[]'; return 3; }
}

rdo_list() {
    local only="${1:-}"
    local repo; repo="$(_restic_read_repo)"
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for list"
    # an unreadable repo is an error, never "no archives" (that's the worst
    # moment to be told there is nothing to restore)
    local archives rc=0
    archives="$(_list_archives_json "$repo" "$only")" || rc=$?
    case "$rc" in
        1) die "$EX_UNAVAILABLE" "list: repo $(_mask_url "$repo") not readable" ;;
        2) die "$EX_UNAVAILABLE" "list: repo $(_mask_url "$repo") returned no snapshot list" ;;
    esac
    # Optional: annotate each snapshot with the retention bucket(s) keeping it
    # (daily/weekly/monthly/…) and whether the next prune would drop it. Runs a
    # dry-run forget with THIS repo's policy (cache=keep-last, offsite=GFS) and
    # merges the reasons in by short_id. Off by default (extra round-trip).
    if [[ "${LIST_WITH_REASONS:-0}" == 1 ]]; then
        # The same runner prune uses (lib/policy.sh _forget_policy_runs), so the
        # plan shown is the plan pruned. Each group is marked with its pass.
        local fj fjf; fjf="$(mktemp)"
        _list_reasons_cb() {
            local out; out="$(_restic "$1" forget "${@:2}" --dry-run --json 2>/dev/null)"
            # the runner asked for the raw JSON (the cache tier's split-guest detection)
            if [[ -n "${_FORGET_RAW_FILE:-}" ]]; then printf '%s' "$out" > "$_FORGET_RAW_FILE"; fi
            printf '%s' "$out" \
                | jq -c --arg p "$_RET_PASS" 'if type == "array" then map(. + {pbo_pass: $p}) else . end' >> "$fjf" 2>/dev/null
            printf '\n' >> "$fjf"
        }
        if [[ "$repo" == "$RESTIC_CACHE_REPO" ]]; then
            _forget_policy_runs "$repo" _list_reasons_cb "${RESTIC_KEEP_LAST:-2}" || true
        else
            _FORGET_READONLY=1 _forget_policy_runs "$repo" _list_reasons_cb || true
        fi
        fj="$(jq -cs 'map(select(type=="array")) | add // []' "$fjf" 2>/dev/null || echo '[]')"; rm -f "$fjf"
        [[ -n "$fj" ]] || fj='[]'
        # Merge via --slurpfile over a process substitution: the forget JSON can be
        # hundreds of KB (every snapshot), which overflows argv with --argjson.
        # A split guest's snapshots are in its paths groups too: its reasons come
        # from its guest pass alone (a paths group may keep what the guest pass
        # drops), and keep=false for whatever any pass removes (what prune does).
        archives="$(printf '%s' "$archives" | jq -c --slurpfile fj <(printf '%s' "$fj") '
            ($fj[0] // []) as $g
            | ( [ $g[]? | select(.pbo_pass == "guest") | ((.keep // []) + (.remove // []))[]? | {key:.short_id, value:true} ] | from_entries ) as $gs
            | ( [ $g[]? | (.pbo_pass == "guest") as $gp | (.reasons // [])[]
                  | select($gp or (($gs[.snapshot.short_id] // false) | not))
                  | {key:(.snapshot.short_id), value:(.matches // [])} ] | from_entries ) as $why
            | ( [ $g[]? | (.remove // [])[]? | .short_id ] ) as $rem
            | map( .snapshot as $sid | . + { reasons:($why[$sid] // []), keep:(($rem | index($sid)) == null) } )
        ' 2>/dev/null || printf '%s' "$archives")"
    fi
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        # on stdin, not --argjson: a list of hundreds of snapshots overflows argv
        printf '%s' "$archives" | jq -c '{status:"ok", ok:true, archives:.}' | json_emit
    else
        printf '%-6s  %-42s  %12s  %s\n' VMID ARCHIVE SIZE SNAP
        printf '%s' "$archives" | jq -r '.[] | "\(.vmid)  \(.archive)  \(.size_bytes)  \(.snapshot)"'
    fi
}

# ---------------------------------------------------------------------------
# extraction: fetch+verify a snapshot to <target>, echo the tar path.
# ---------------------------------------------------------------------------
# Sets the GLOBAL RX_TAR (NOT via stdout, log_info goes to stdout in non-json
# mode and would pollute command substitution → broken pct-restore path).
RX_TAR=""
_restic_extract() {            # _restic_extract <vmid> <ts> <target> → RX_TAR
    local vmid="$1" ts="$2" target="$3"
    RX_TAR=""
    local repo; repo="$(_restic_read_repo)"
    mkdir -p "$target"
    local id
    id="$(_restic "$repo" snapshots --json --tag "vmid=$vmid,ts=$ts" 2>/dev/null | jq -r '.[-1].short_id // empty')"
    [[ -n "$id" ]] || { log_error "restic: no snapshot vmid=$vmid ts=$ts in $repo"; return 1; }
    log_info "restic restore snapshot $id → $target (verifies on read-out)"
    _restic "$repo" restore "$id" --target "$target" >/dev/null 2>&1 \
        || { log_error "restic restore failed (snap $id)"; return 1; }
    RX_TAR="$(find "$target" -type f \( -name 'vzdump-*.tar' -o -name 'vzdump-*.vma' \) | head -1)"
    [[ -n "$RX_TAR" ]] || { log_error "restic: no vzdump archive (.tar/.vma) in restored snapshot $id"; return 1; }
    return 0
}

# _conf_unpriv <tar> → 1 (unprivileged) or 0 (privileged) for an LXC archive.
# Proxmox writes "unprivileged: 1" for an unprivileged CT and leaves the key out
# for a privileged one (schema default 0), so a config without the line is a
# privileged CT. The config comes from the .conf sidecar next to the tar; when
# that is missing or empty, from the copy vzdump puts first in the archive
# (./etc/vzdump/pct.conf). Only the main section counts (a [snapshot] section
# ends it). With no readable config at all: 1, the safe guess.
_conf_unpriv() {
    local conf="${1}.conf" cfg="" u
    if [[ -s "$conf" ]]; then cfg="$(cat -- "$conf" 2>/dev/null)" || cfg=""
    else cfg="$(tar -xOf "$1" --occurrence=1 ./etc/vzdump/pct.conf 2>/dev/null)" || cfg=""; fi
    if [[ -z "$cfg" ]]; then printf 1; return 0; fi
    u="$(awk -F': *' '/^\[/{exit} /^unprivileged:/{print $2; exit}' <<<"$cfg")"
    [[ -n "$u" ]] || u=0
    [[ "$u" =~ ^[01]$ ]] || u=1
    printf '%s' "$u"
}

# ---------------------------------------------------------------------------
# restore, restic → pct restore to a NEW vmid (never overwrite).
# ---------------------------------------------------------------------------
# _restore_link_down <type> <vmid>: set link_down=1 on every netN. RLD_STATE is
# "disconnected", or "none" when the guest has no network. Fails if any
# interface could not be changed (the caller then does not start the guest).
_restore_link_down() {
    local t="$1" id="$2" k v line tool=pct n=0
    [[ "$t" == qemu ]] && tool=qm
    while IFS= read -r line; do
        k="${line%%:*}"; v="${line#*: }"
        v="$(sed -E 's/(^|,)link_down=[01]//; s/^,//' <<<"$v"),link_down=1"
        "$tool" set "$id" "--$k" "$v" >/dev/null 2>&1 || return 1
        n=$((n+1))
    done < <("$tool" config "$id" 2>/dev/null | grep -E '^net[0-9]+: ')
    # verify: no interface may be left up
    "$tool" config "$id" 2>/dev/null | grep -E '^net[0-9]+: ' | grep -vq 'link_down=1' && return 1
    RLD_STATE=disconnected; (( n )) || RLD_STATE=none
    return 0
}

# _restore_isolate <type> <vmid>: an isolated copy next to the running original,
# under the test-restore allowlist (lib/testrestore.sh) except that its NICs
# stay, disconnected. Done under a config lock so the copy cannot be started
# halfway (pct/qm set refuse a locked guest, so the edit is made in the config
# file itself, main section only), then unlocked and checked. If any step fails
# the copy is destroyed: it is a guest this run just created.
_restore_isolate() {
    local t="$1" id="$2" tool=pct f
    [[ "$t" == qemu ]] && tool=qm
    f="$(_tr_conf_file "$t" "$id")"
    _restore_isolate_fail() { "$tool" unlock "$id" >/dev/null 2>&1 || true; _tr_destroy "$id" "$t"; die "$EX_SOFTWARE" "restore: $1; the copy $id was destroyed"; }
    "$tool" set "$id" --lock create >/dev/null 2>&1 || _restore_isolate_fail "could not lock $id for isolation"
    # unsafe keys (NICs excluded: they are kept and taken down below)
    local -a strip=(); local k
    while read -r k; do [[ -n "$k" && ! "$k" =~ ^net[0-9]+$ ]] && strip+=("$k"); done < <(_tr_unsafe_keys "$t" "$id")
    for k in "${strip[@]+"${strip[@]}"}"; do
        [[ "$k" == "<unreadable>" || "$k" == "<section "* || "$k" == rootfs ]] && _restore_isolate_fail "cannot isolate $k"
    done
    local body
    body="$(STRIP=" ${strip[*]:-} " awk '
        BEGIN { main = 1 }
        /^\[/ { main = 0 }
        {
            if (!main || $0 ~ /^[[:space:]]*(#|$)/) { print; next }
            k = $0; sub(/[[:space:]]*[:=].*/, "", k)
            if (index(ENVIRON["STRIP"], " " k " ") > 0) next
            if (k == "onboot") next
            if (k ~ /^net[0-9]+$/) { v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/(^|,)link_down=[01]/, "", v); sub(/^,/, "", v)
                                     print k ": " v ",link_down=1"; next }
            print
        }
        END { print "onboot: 0" }' "$f")" || _restore_isolate_fail "could not read the config of $id"
    printf '%s\n' "$body" > "$f" || _restore_isolate_fail "could not write the config of $id"
    TR_STRIPPED=("${strip[@]+"${strip[@]}"}")
    RLD_STATE=disconnected; grep -qE '^net[0-9]+:' "$f" || RLD_STATE=none
    "$tool" unlock "$id" >/dev/null 2>&1 || _restore_isolate_fail "could not unlock $id"
    [[ -n "${TR_STRIPPED[*]:-}" ]] && log_info "restore: removed host-bound config from $id: ${TR_STRIPPED[*]}"
    TR_ALLOW_LINKDOWN_NET=1 _tr_isolated "$t" "$id" || _restore_isolate_fail "$id still had host-bound config after isolation"
    audit_log "restore isolate target=$id stripped=${TR_STRIPPED[*]:-none}"
}

# _vmid_in_cluster <vmid>: the guest exists on any node (cluster resources),
# or locally when there is no cluster view.
_vmid_in_cluster() {
    local j; j="$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null)" || j=""
    if jq -e 'type=="array" and length > 0' >/dev/null 2>&1 <<<"$j"; then
        jq -e --argjson v "$1" 'any(.[]; .vmid == $v)' >/dev/null 2>&1 <<<"$j"
    else
        _g_exists "$1"
    fi
}

rdo_restore() {
    local src="$1" ts="$2" newid="$3" storage="$4" yes="$5"
    _g_exists "$newid" && die "$EX_USAGE" "target vmid $newid already exists, refusing"
    _vmid_in_cluster "$newid" && die "$EX_USAGE" "vmid $newid exists in the cluster, refusing"
    # --keep-network gives the copy the original's MAC/IP, mounts and devices:
    # only for disaster recovery, never next to the original
    if [[ "${RESTORE_KEEP_NET:-0}" == 1 ]] && _vmid_in_cluster "$src"; then
        die "$EX_USAGE" "--keep-network: guest $src still exists in the cluster; restore isolated (the default), or remove $src first"
    fi
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] restic restore $src ($ts) → new vmid $newid"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$src" "target_vmid" "$newid"
        return "$EX_OK"
    fi
    local rdir="${CACHE_DIR}/restore-${newid}"; rm -rf "$rdir"
    _restic_extract "$src" "$ts" "$rdir" || die "$EX_DATAERR" "restic extraction failed"
    local tar="$RX_TAR"
    local gtype; gtype="$(_guest_type_from_archive "$tar")"
    [[ -n "$storage" ]] || storage="$(_default_storage "$gtype")"
    [[ -n "$storage" ]] || die "$EX_USAGE" "no --storage given and no $([[ "$gtype" == qemu ]] && echo images || echo rootdir)-capable storage found"
    local cmd=() unpriv=""
    if [[ "$gtype" == qemu ]]; then
        cmd=(qmrestore "$tar" "$newid" --storage "$storage")            # <archive> <vmid>; no --unprivileged
    else
        unpriv="$(_conf_unpriv "$tar")"
        cmd=(pct restore "$newid" "$tar" --storage "$storage" --unprivileged "$unpriv")
        # a privileged container is root on the host: Proxmox reserves creating one
        # for root; a wrapper acting for a Proxmox user passes --restricted unless
        # that user has Sys.Modify
        if [[ "$unpriv" != 1 && "${RESTORE_RESTRICTED:-0}" == 1 ]]; then
            rm -rf "$rdir" 2>/dev/null || true
            die "$EX_USAGE" "restore: $src is a privileged container; restoring it requires Sys.Modify on / (or the CLI)"
        fi
    fi
    if [[ "$yes" != "1" ]]; then
        log_info "restore (preview, run with --yes): ${cmd[*]}"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "planned" "true" "vmid" "$src" \
            "target_vmid" "$newid" "storage" "$storage" "restore_command" "${cmd[*]}"
        rm -rf "$rdir" 2>/dev/null || true
        return "$EX_OK"
    fi
    local jobfile; jobfile="${JOBS_DIR}/restore-${newid}-$(date +%Y%m%d-%H%M%S).log"
    audit_log "restore src=$src ts=$ts target=$newid storage=$storage unprivileged=$unpriv engine=restic"
    if ! run_stream "$jobfile" "${gtype}-restore[$newid]" -- "${cmd[@]}"; then
        die "$EX_SOFTWARE" "${gtype} restore failed for target $newid (see $jobfile)"
    fi
    rm -rf "$rdir" 2>/dev/null || true
    # --start: boot the copy. Its network config is the original's (same
    # MAC/IP), so unless --keep-network every interface is set link_down=1 first:
    # the copy runs, but cannot clash with the guest it was taken from.
    local started=false network=unchanged stripped=""
    # --isolate (for a wrapper acting for a Proxmox user, unless --keep-network): the same
    # isolation for a copy that is NOT started, so nobody can start it later with
    # host bindings a Proxmox user could not have created (pct restore ran as root).
    if [[ "${RESTORE_ISOLATE:-0}" == 1 || ( "${RESTORE_START:-0}" == 1 && "${RESTORE_KEEP_NET:-0}" != 1 ) ]]; then
        _restore_isolate "$gtype" "$newid"; network="$RLD_STATE"; stripped="${TR_STRIPPED[*]:-}"
    fi
    if [[ "${RESTORE_START:-0}" == 1 ]]; then
        if [[ "${RESTORE_KEEP_NET:-0}" == 1 ]]; then network=connected
        fi
        run_stream "$jobfile" "${gtype}-start[$newid]" -- _g_start "$gtype" "$newid" \
            || die "$EX_SOFTWARE" "restore: $newid restored but did not start (see $jobfile)"
        started=true
        audit_log "restore start target=$newid network=$network"
    fi
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "restored" "true" "vmid" "$src" "target_vmid" "$newid" "storage" "$storage" "type" "$gtype" "engine" "restic" \
            "started:b" "$started" "network" "$network" "stripped" "$stripped"
    else
        log_info "restore: DONE → $( [[ "$gtype" == qemu ]] && echo VM || echo CT ) $newid (restic, $gtype, storage=$storage)$( [[ "$started" == true ]] && echo ", started, network $network")"
    fi
    return "$EX_OK"
}

# ---------------------------------------------------------------------------
# test-restore, full chain against a throwaway vmid (reuses _tr_* from testrestore.sh).
# ---------------------------------------------------------------------------
rdo_test_restore() {
    local vmid="$1"
    local repo; repo="$(_restic_read_repo)"
    # newest snapshot of the guest (by its ts= tag), kept whole for the evidence record
    local snap ts
    snap="$(_restic "$repo" snapshots --json --tag "vmid=$vmid" 2>/dev/null \
        | jq -c '[ .[] | . + {pbo_ts: ((.tags // []) | map(select(startswith("ts=")))[0] // "" | sub("ts=";""))}
                   | select(.pbo_ts != "") ] | sort_by(.pbo_ts) | last // empty' 2>/dev/null)" \
        || die "$EX_UNAVAILABLE" "test-restore: repo $(_mask_url "$repo") not readable"
    ts="$(jq -r '.pbo_ts // empty' <<<"$snap" 2>/dev/null)" || ts=""
    [[ -n "$ts" ]] || die "$EX_DATAERR" "test-restore: no restic snapshots for vmid $vmid"
    # not in a $(...): the target's lock must stay held by this shell
    _tr_pick_target || die "$EX_UNAVAILABLE" "no free throwaway vmid 9000-9099"
    local target="$TR_TARGET"
    audit_log "test-restore vmid=$vmid ts=$ts throwaway=$target engine=restic trigger=${TR_TRIGGER:-manual}"
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] test-restore $vmid ($ts) → throwaway-$target"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$vmid" "throwaway" "$target"
        return "$EX_OK"
    fi
    mkdir -p "$CACHE_DIR"
    local rdir; rdir="$(mktemp -d "${CACHE_DIR}/testrestore-XXXXXX")" || die "$EX_CANTCREAT" "test-restore: no temp dir in $CACHE_DIR"
    local jobfile; jobfile="${JOBS_DIR}/testrestore-${vmid}-$(date +%Y%m%d-%H%M%S).log"
    local t_start t ok=1 stage="" rcmd=() storage="" bytes=0 created=0
    local gtype; gtype="$(jq -r '(.tags // []) | map(select(startswith("type=")))[0] // "type=lxc" | sub("type=";"")' <<<"$snap")" || gtype=lxc
    [[ "$gtype" =~ ^(lxc|qemu)$ ]] || gtype=lxc
    TR_STAGES=(); t_start="$(date +%s)"

    t="$(date +%s)"
    if _restic_extract "$vmid" "$ts" "$rdir"; then _tr_stage fetch true $(( $(date +%s) - t ))
    else _tr_stage fetch false $(( $(date +%s) - t )); ok=0; stage="fetch"; fi
    local tar="${RX_TAR:-}"
    if (( ok )); then
        gtype="$(_guest_type_from_archive "$tar")"
        bytes="$(stat -c %s "$tar" 2>/dev/null || echo 0)"
        storage="${TR_STORAGE:-$(_default_storage "$gtype")}"
        if [[ "$gtype" == lxc && "$(_conf_unpriv "$tar")" != 1 && "${TR_RESTRICTED:-0}" == 1 ]]; then
            log_error "test-restore: $vmid is a privileged container; testing it requires Sys.Modify on / (or the CLI)"
            ok=0; stage="restricted"
        elif [[ -z "$storage" ]]; then
            log_error "test-restore: no $([[ "$gtype" == qemu ]] && echo images || echo rootdir)-capable storage (set TR_STORAGE)"
            ok=0; stage="storage"
        fi
    fi
    if (( ok )); then
        if [[ "$gtype" == qemu ]]; then rcmd=(qmrestore "$tar" "$target" --storage "$storage")
        else rcmd=(pct restore "$target" "$tar" --storage "$storage" --unprivileged "$(_conf_unpriv "$tar")"); fi
        t="$(date +%s)"
        # created=1 only once our restore succeeded: never destroy a guest we did not make
        if run_stream "$jobfile" "${gtype}-restore[$target]" -- "${rcmd[@]}"; then _tr_stage restore true $(( $(date +%s) - t )); created=1
        else _tr_stage restore false $(( $(date +%s) - t )); ok=0; stage="restore"; fi
    fi
    # Isolate the throwaway before boot: tag it (a copy left behind by a crash shows
    # up in doctor), no autostart, no network (cloned MAC/IP would clash with the
    # running source), nothing bound to the host (_tr_strip_host). Then check the
    # result; anything left means no boot.
    TR_STRIPPED=()
    if (( ok )); then
        t="$(date +%s)"
        # each step may fail; _tr_isolated below is what decides
        _tr_mark_throwaway "$gtype" "$target" || true; _tr_isolate_net "$gtype" "$target" || true
        _tr_strip_host "$gtype" "$target" || true
        (( ${#TR_STRIPPED[@]} )) && log_info "test-restore: removed host-bound config from throwaway $target: ${TR_STRIPPED[*]}"
        if _tr_isolated "$gtype" "$target"; then _tr_stage isolate true $(( $(date +%s) - t ))
        else _tr_stage isolate false $(( $(date +%s) - t )); ok=0; stage="isolate"
             log_error "test-restore: throwaway $target could not be isolated from the host/network, not booting it"; fi
    fi
    if (( ok )); then
        t="$(date +%s)"
        if run_stream "$jobfile" "${gtype}-start[$target]" -- _g_start "$gtype" "$target"; then _tr_stage start true $(( $(date +%s) - t ))
        else _tr_stage start false $(( $(date +%s) - t )); ok=0; stage="start"; fi
    fi
    if (( ok )); then
        log_info "test-restore: waiting for $gtype $target to respond…"
        t="$(date +%s)"
        if _tr_wait "$target" "$gtype"; then _tr_stage respond true $(( $(date +%s) - t ))
            [[ "$TR_RESPOND_HOW" == running ]] && log_warn "test-restore: VM $vmid has no guest agent; only proven that it runs, not that the OS answered"
        else _tr_stage respond false $(( $(date +%s) - t )); ok=0; stage="respond"; fi
    fi
    rm -rf "$rdir" 2>/dev/null || true
    if (( created )); then
        t="$(date +%s)"
        _tr_destroy "$target" "$gtype"
        local clean=true; _g_exists "$target" && clean=false
        _tr_stage cleanup "$clean" $(( $(date +%s) - t ))
        [[ "$clean" == true ]] || { log_warn "test-restore: throwaway $target could not be destroyed, remove it by hand"
            notify_warning "test-restore of $vmid: throwaway guest $target could not be destroyed, remove it by hand"; }
    fi

    local tier=offsite; [[ "$repo" == "${RESTIC_CACHE_REPO:-}" ]] && tier=cache
    local name; name="$(_g_config "$gtype" "$vmid" 2>/dev/null | sed -nE 's/^(hostname|name):[[:space:]]*//p' | head -1)" || name=""
    _tr_record "$(printf '%s\n' "${TR_STAGES[@]}" | jq -cs --arg time "$(date --iso-8601=seconds)" --argjson epoch "$(date +%s)" \
        --arg node "$(_local_node 2>/dev/null)" --arg ver "${VERSION:-}" --arg user "$(_audit_who)" \
        --arg trigger "${TR_TRIGGER:-manual}" --arg vmid "$vmid" --arg name "$name" --arg type "$gtype" \
        --argjson snap "$snap" --arg tier "$tier" --arg url "$(sed -E 's#(://)[^/@]*@#\1#' <<<"$repo")" \
        --arg throwaway "$target" --arg storage "$storage" --argjson bytes "${bytes:-0}" \
        --argjson ok "$( ((ok)) && echo true || echo false )" --arg stage "$stage" \
        --arg how "${TR_RESPOND_HOW:-}" \
        --argjson stripped "$(printf '%s\n' "${TR_STRIPPED[@]+"${TR_STRIPPED[@]}"}" | jq -cR 'select(length>0)' | jq -cs .)" \
        --argjson dur $(( $(date +%s) - t_start )) '
        def ep: (capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2}))$")
                 | ((.d + "Z") | fromdateiso8601)
                   - (if .z == "Z" then 0 else ((if .s == "+" then 1 else -1 end) * ((.h|tonumber)*3600 + (.m|tonumber)*60)) end))? // null;
        { time:$time, epoch:$epoch, kind:"restore-test", node:$node, version:$ver, user:$user, trigger:$trigger,
          vmid:$vmid, name:$name, type:$type,
          snapshot: { id:$snap.id, short_id:$snap.short_id, time:$snap.time, ts:$snap.pbo_ts,
                      age_s: (($snap.time | ep) as $e | if $e then ($epoch - $e) else null end) },
          repo: { tier:$tier, url:$url }, throwaway:$throwaway, storage:$storage, archive_bytes:$bytes,
          stripped: $stripped, respond_check: (if $how == "" then null else $how end), stages: ., ok:$ok, failed_stage: (if $ok then null else $stage end), duration_s:$dur,
          cleanup_ok: (map(select(.name=="cleanup"))[0] | if . == null then true else .ok end) }' 2>/dev/null)"

    if (( ok )); then
        notify_success "test-restore OK: vmid $vmid ($ts) booted on throwaway-$target (restic)"
        if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_result "test_ok" "true" "vmid" "$vmid" "ts" "$ts" "throwaway" "$target"
        else log_info "test-restore: ✅ vmid $vmid booted from restic (throwaway-$target cleaned up)"; fi
        return "$EX_OK"
    fi
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "test_failed" "false" "vmid" "$vmid" "stage" "$stage" "throwaway" "$target"
    die "$EX_SOFTWARE" "test-restore FAILED at step '$stage' for vmid $vmid"
}

# ---------------------------------------------------------------------------
# prune, restic forget/prune. Envelope {cache_deleted,offsite_deleted} like the UI.
# offsite_deleted = removed snapshot ids (offsite/read repo). The grouping (per
# path, plus one pass per split guest) comes from lib/policy.sh _forget_policy_runs.
# ---------------------------------------------------------------------------
# _restic_forget_json <repo> <forget args...> → JSON array of removed short_id.
# The args carry the --group-by (the runner decides it).
_restic_forget_json() {
    local repo="$1"; shift
    # `forget --json` ALONE gives a clean remove list (one json value). Do NOT run
    # --prune here (it restructures the output); reclaim space separately below.
    local fflags=(forget "$@" --json)
    [[ "${DRY_RUN:-0}" == 1 ]] && fflags+=(--dry-run)
    # Distinguish a FAILED forget (repo unreachable, lock, auth) from "nothing to
    # remove". Swallowing the error made a failed offsite prune look like a clean
    # "removed 0", so retention could silently stop applying. Return 1 on failure.
    local out rc errf; errf="$(mktemp)"
    out="$(_restic_w "$repo" "${fflags[@]}" 2>"$errf")"; rc=$?
    if (( rc != 0 )); then
        local lm; lm="$(_restic_lock_msg "$errf")"
        if [[ -n "$lm" ]]; then
            log_warn "restic forget ($repo) FAILED: repo locked ($lm) — retention NOT applied this run"
        else
            log_warn "restic forget ($repo) FAILED (rc=$rc) — retention NOT applied this run"
        fi
        rm -f "$errf"
        printf '[]'
        return 1
    fi
    rm -f "$errf"
    # the runner asked for the raw JSON (the cache tier's split-guest detection)
    if [[ -n "${_FORGET_RAW_FILE:-}" ]]; then printf '%s' "$out" > "$_FORGET_RAW_FILE"; fi
    local removed; removed="$(printf '%s' "$out" | jq -cs '[ (.[0] // []) | .[]? | .remove[]?.short_id ]' 2>/dev/null || echo '[]')"
    # Real run that actually removed snapshots → reclaim pack files separately.
    # (_FORGET_NO_PRUNE=1: the caller runs several forgets and prunes once.)
    if [[ "${DRY_RUN:-0}" != 1 && "${_FORGET_NO_PRUNE:-0}" != 1 && "$(printf '%s' "$removed" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]]; then
        _restic_w "$repo" prune >/dev/null 2>&1 || log_error "restic prune ($(_mask_url "$repo")) failed: the forgotten snapshots are gone but their space was not reclaimed; run 'pbo prune' again"
    fi
    printf '%s' "$removed"
    return 0
}

# _tier_forget <repo> [<keep-last N>] → removed short_ids (JSON array). Every
# forget run of the retention runner (lib/policy.sh _forget_policy_runs), one
# prune at the end. Without N: offsite GFS per policy group (config default +
# per-guest keep= overrides); with N: the cache tier, keep-last N per guest.
_FORGET_REMOVED_FILE=""
_tier_forget_cb() {                # <repo> <forget args...>
    local r
    if _is_janitor && [[ -n "${_CHECKED_IDS_FILE:-}" ]]; then r="$(_janitor_bound_forget "$@")" || return 1
    else r="$(_FORGET_NO_PRUNE=1 _restic_forget_json "$@")" || return 1; fi
    printf '%s\n' "$r" >> "$_FORGET_REMOVED_FILE"
}
_tier_forget() {
    local repo="$1" rc=0 all
    _FORGET_REMOVED_FILE="$(mktemp)"
    # "${@:2}": the cache passes its N even when empty, so a bad value fails the
    # forget as in 0.5 instead of turning the cache into a GFS run
    _forget_policy_runs "$repo" _tier_forget_cb "${@:2}" || rc=1
    # a dry run plans a split guest's paths and guest passes on the same list,
    # so an id can come twice; keep the first, in order (no-op otherwise)
    all="$(jq -cs 'add // [] | reduce .[] as $x ({s: {}, o: []}; if .s[$x] then . else .s[$x] = true | .o += [$x] end) | .o' \
        "$_FORGET_REMOVED_FILE" 2>/dev/null || echo '[]')"; rm -f "$_FORGET_REMOVED_FILE"
    if (( rc == 0 )) && [[ "${DRY_RUN:-0}" != 1 ]] && [[ "$(jq 'length' <<<"$all")" -gt 0 ]]; then
        _restic_w "$repo" prune >/dev/null 2>&1 || log_error "restic prune ($(_mask_url "$repo")) failed: the forgotten snapshots are gone but their space was not reclaimed; run 'pbo prune' again"
    fi
    printf '%s' "$all"
    return "$rc"
}

# prune, the cache repo is pruned keep-last, offsite is pruned PURE GFS. In cached mode
# BOTH are pruned. Envelope {cache_deleted, offsite_deleted} = removed ids per repo.
rdo_prune() {
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for prune"
    local cache_removed='[]' offsite_removed='[]'
    local failed=()
    # Local cache repo: keep-last (fast restore tier).
    if [[ "${LOCAL_REPO:-true}" == "true" ]]; then
        _restic_stale_unlock "$RESTIC_CACHE_REPO"
        cache_removed="$(_tier_forget "$RESTIC_CACHE_REPO" "${RESTIC_KEEP_LAST}")" || failed+=("cache")
    fi
    # Offsite: pure GFS (daily/weekly/monthly), no keep-last (a cache concept).
    # Append-only offsite: the janitor owns retention. Running forget here would
    # get 403 per snapshot and still exit 0, a prune that looks fine and isn't.
    local offsite_skipped=""
    if [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]] && _offsite_append_only; then
        offsite_skipped="append_only"
        log_info "prune: offsite is append-only, retention there runs on the janitor"
    elif [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        _restic_stale_unlock "$RESTIC_OFFSITE_REPO"
        offsite_removed="$(_tier_forget "$RESTIC_OFFSITE_REPO")" || failed+=("offsite")
    fi
    local dry; dry="$( [[ "${DRY_RUN:-0}" == 1 ]] && echo true || echo false )"
    local nc no; nc="$(printf '%s' "$cache_removed" | jq 'length' 2>/dev/null || echo 0)"
    no="$(printf '%s' "$offsite_removed" | jq 'length' 2>/dev/null || echo 0)"
    local ok=true status=ok
    (( ${#failed[@]} == 0 )) || { ok=false; status=partial; }
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        jq -e 'type=="array"' >/dev/null 2>&1 <<<"$cache_removed" || cache_removed='[]'
        jq -e 'type=="array"' >/dev/null 2>&1 <<<"$offsite_removed" || offsite_removed='[]'
        json_emit "$(jq -cn --arg st "$status" --argjson ok "$ok" --argjson c "${cache_removed:-[]}" --argjson o "${offsite_removed:-[]}" \
            --arg f "${failed[*]:-}" --arg sk "$offsite_skipped" \
            '{status:$st, ok:$ok, cache_deleted:$c, offsite_deleted:$o,
              failed_tiers:($f | split(" ") | map(select(length > 0))), offsite_skipped:$sk}')"
    elif (( ${#failed[@]} > 0 )); then
        log_warn "prune (restic): retention FAILED on ${failed[*]} (repo unreachable/locked?) — cache removed $nc, offsite removed $no"
    else
        log_info "prune (restic): cache removed $nc, offsite removed $no$( [[ "${DRY_RUN:-0}" == 1 ]] && echo ' (dry-run)')"
    fi
    # with the Proxmox integration on, the PVE storage view drops what was pruned
    # (also after a partial failure: one tier may have changed)
    _catalog_refresh_hook prune
    # A failed tier surfaces as a non-zero exit + ntfy, so a silent no-op (the
    # offsite forget that quietly did nothing) cannot recur.
    if (( ${#failed[@]} > 0 )); then
        notify_failure "pbo prune: retention FAILED on ${failed[*]} — offsite may grow unbounded until fixed"
        return "$EX_UNAVAILABLE"
    fi
    return "$EX_OK"
}

# rotate-key: rotate the repo password (the DR key) on ALL configured repos to a
# new value. restic keys are wrapped copies of the master key, so this is instant
# and re-encrypts nothing. Adds the new key, verifies it opens the repo, then
# removes the old key, per repo, and finally repoints RESTIC_PASSWORD_FILE.
rdo_rotate_key() {
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for rotate-key"
    local newfile="$1" oldfile="$RESTIC_PASSWORD_FILE"
    [[ -r "$oldfile" ]] || die "$EX_CONFIG" "rotate-key: current password file $oldfile unreadable"
    [[ -r "$newfile" ]] || die "$EX_CONFIG" "rotate-key: new password file $newfile unreadable"
    [[ -s "$newfile" ]] || die "$EX_CONFIG" "rotate-key: new password file is empty"
    cmp -s "$newfile" "$oldfile" && die "$EX_USAGE" "rotate-key: the new password is the current one"
    local repos=()
    [[ "${LOCAL_REPO:-true}" == "true" ]] && repos+=("$RESTIC_CACHE_REPO")
    [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]] && repos+=("$RESTIC_OFFSITE_REPO")
    (( ${#repos[@]} )) || die "$EX_CONFIG" "rotate-key: no repos configured"
    _restic_rest_env
    # R <passfile> <repo> <args...>: restic against one repo with a given password
    R() { local pf="$1" r="$2"; shift 2; _restic_opts "$r"
          RESTIC_PASSWORD_FILE="$pf" RESTIC_CACHE_DIR="$RESTIC_CACHE_DIR" "$RESTIC_BIN" -r "$r" "${RESTIC_OPTS[@]+"${RESTIC_OPTS[@]}"}" "$@"; }
    _curkey() { R "$1" "$2" key list --json 2>/dev/null | jq -r '.[]|select(.current==true)|.id' 2>/dev/null; }
    # Three phases, so no failure can leave a repo that only the new (not yet
    # saved) key opens: 1. add + verify the new key everywhere (undo on failure),
    # 2. install the new password file, 3. remove the old keys.
    local repo i oldid newid
    local -a olds=() news=() done_repos=()
    rollback() {
        local j; for (( j=0; j < ${#done_repos[@]}; j++ )); do
            R "$oldfile" "${done_repos[$j]}" key remove "${news[$j]}" >/dev/null 2>&1 \
                || log_error "rotate-key: ROLLBACK FAILED on $(_mask_url "${done_repos[$j]}"): it also accepts the new key ${news[$j]}; keep $newfile"
        done
    }
    for repo in "${repos[@]}"; do
        oldid="$(_curkey "$oldfile" "$repo")" || oldid=""
        [[ -n "$oldid" ]] || { rollback; die "$EX_SOFTWARE" "rotate-key: cannot read the current key of $(_mask_url "$repo") (unreachable or wrong password); nothing changed"; }
        R "$oldfile" "$repo" key add --new-password-file "$newfile" >/dev/null 2>&1 \
            || { rollback; die "$EX_SOFTWARE" "rotate-key: 'key add' failed on $(_mask_url "$repo"); nothing changed"; }
        newid="$(_curkey "$newfile" "$repo")" || newid=""
        if [[ -z "$newid" || "$newid" == "$oldid" ]]; then
            rollback; die "$EX_SOFTWARE" "rotate-key: the new key does not open $(_mask_url "$repo"); nothing changed (an extra key may remain there: check 'restic key list')"
        fi
        olds+=("$oldid"); news+=("$newid"); done_repos+=("$repo")
    done
    # phase 2: from here every repo opens with the new key
    local keep_old; keep_old="${oldfile}.old-$(date +%Y%m%d-%H%M%S)"
    install -m 0600 "$oldfile" "$keep_old" || { rollback; die "$EX_CANTCREAT" "rotate-key: could not back up $oldfile; nothing changed"; }
    install -m 0600 "$newfile" "$oldfile" || { rollback; die "$EX_CANTCREAT" "rotate-key: could not write $oldfile; the old key is still active (backup in $keep_old)"; }
    audit_log "rotate-key new key installed repos=${#repos[@]}"
    # phase 3: retire the old keys
    local pending=() left=0
    for (( i=0; i < ${#done_repos[@]}; i++ )); do
        repo="${done_repos[$i]}"
        if [[ "$repo" == "${RESTIC_OFFSITE_REPO:-}" ]] && _offsite_append_only; then
            pending+=("${olds[$i]}")
            log_warn "rotate-key: $(_mask_url "$repo") is append-only, old key ${olds[$i]} is STILL VALID there. On the janitor: install the new password file, then: restic -r <repo> key remove ${olds[$i]}"
            notify_warning "rotate-key: the old key ${olds[$i]} still opens the append-only offsite repo; remove it on the janitor"
            continue
        fi
        if R "$oldfile" "$repo" key remove "${olds[$i]}" >/dev/null 2>&1; then
            log_info "rotate-key: $(_mask_url "$repo") rotated (removed old key ${olds[$i]})"
        else
            left=1; log_warn "rotate-key: could not remove old key ${olds[$i]} on $(_mask_url "$repo") (the new key works; remove it by hand)"
        fi
    done
    # the old password file is no longer needed once no repo accepts it
    if (( left == 0 && ${#pending[@]} == 0 )); then shred -u "$keep_old" 2>/dev/null || rm -f "$keep_old"
    else log_warn "rotate-key: the old password stays in $keep_old until its keys are removed everywhere"; fi
    log_info "rotate-key: DONE. Export the new DR key and update your password manager."
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "ok" "true" "repos:n" "${#repos[@]}" "offsite_old_key_pending" "${pending[*]:-}"
    return "$EX_OK"
}

# usage, repo size/dedup from `restic stats` (for the Metrics tab/dashboard).
rdo_usage() {
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for usage"
    local repo raw rest
    repo="$(_restic_read_repo)"
    raw="$(_restic "$repo" stats --mode raw-data --json 2>/dev/null || echo '{}')"
    rest="$(_restic "$repo" stats --mode restore-size --json 2>/dev/null || echo '{}')"
    [[ "$raw" == \{* ]] || raw='{}'; [[ "$rest" == \{* ]] || rest='{}'
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        jq -cn --argjson raw "$raw" --argjson rest "$rest" --arg repo "$(_mask_url "$repo")" '
          {status:"ok",ok:true,repo:$repo,
           physical_bytes:($raw.total_size//0),
           logical_bytes:($rest.total_size//0),
           uncompressed_bytes:($raw.total_uncompressed_size//0),
           compression_ratio:(($raw.compression_ratio//1)*1000|floor/1000),
           snapshots:($raw.snapshots_count//0),
           files:($rest.total_file_count//0)}' | json_emit
    else
        log_info "usage: physical $(jq -r '.total_size//0' <<<"$raw") B, logical $(jq -r '.total_size//0' <<<"$rest") B, snapshots $(jq -r '.snapshots_count//0' <<<"$raw")"
    fi
    return "$EX_OK"
}

# verify: restic check on BOTH tiers (cache + offsite), so a silent cache
# corruption is caught too. Structure-only by default; VERIFY_READ_DATA=1 reads
# every pack (expensive over SFTP), VERIFY_SUBSET=<n%|size> reads a cheap sample
# (e.g. VERIFY_SUBSET=5% for an affordable periodic deep check).
_rdo_verify_one() {                # <repo> → 0 ok, 1 fail (empty repo = skip, ok)
    local repo="$1"
    # unreachable or the wrong password is a failed verify, never a skipped one
    # (a skip made the rotating deep read silently pass over offsite)
    _restic "$repo" --no-lock cat config >/dev/null 2>&1 || { log_error "verify: $(_mask_url "$repo") could not be opened (unreachable or wrong password)"; return 1; }
    local args=(check)
    if [[ "${VERIFY_READ_DATA:-0}" == 1 ]]; then args+=(--read-data)
    elif [[ -n "${VERIFY_SUBSET:-}" ]]; then args+=(--read-data-subset "${VERIFY_SUBSET}"); fi
    if _restic_w "$repo" "${args[@]}" >/dev/null 2>&1; then
        log_info "verify: OK ($repo${VERIFY_SUBSET:+, read $VERIFY_SUBSET})"; return 0
    fi
    log_error "verify: restic check FAILED for $repo"; return 1
}

# Scheduled deep verify: each scheduled run reads the next slice
# n/VERIFY_ROTATE of the data (restic --read-data-subset n/t), so every pack is
# read once per VERIFY_ROTATE runs without any single run reading it all. The
# slice counter lives in STATE_DIR so it advances run to run, whatever the timer.
_verify_next_slice() {
    local f="${STATE_DIR}/verify.slice" last=0 r="${VERIFY_ROTATE:-12}"
    [[ -r "$f" ]] && last="$(tr -cd '0-9' < "$f")"
    printf '%s' $(( (${last:-0} % r) + 1 ))
}
_verify_record() {                 # <ok:true|false> <subset> <tiers>
    local f="${STATE_DIR}/verify.last"
    printf '{"time":"%s","epoch":%s,"ok":%s,"subset":"%s","tiers":"%s"}\n' \
        "$(date --iso-8601=seconds)" "$(date +%s)" "$1" "$2" "$3" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
}

rdo_verify() {
    local scheduled=0 slice=""
    [[ "${1:-}" == "--scheduled" ]] && scheduled=1
    if (( scheduled )) && [[ "${VERIFY_READ_DATA:-0}" != 1 ]] && (( ${VERIFY_ROTATE:-12} > 0 )); then
        slice="$(_verify_next_slice)"
        VERIFY_SUBSET="${slice}/${VERIFY_ROTATE:-12}"
    fi
    local fail=0 checked=()
    if [[ "${LOCAL_REPO:-true}" == "true" ]]; then
        _rdo_verify_one "$RESTIC_CACHE_REPO" || fail=1; checked+=("cache")
    fi
    if [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        _rdo_verify_one "$RESTIC_OFFSITE_REPO" || fail=1; checked+=("offsite")
    fi
    local subset="${VERIFY_SUBSET:-}"; [[ "${VERIFY_READ_DATA:-0}" == 1 ]] && subset="all"
    if [[ "${DRY_RUN:-0}" != 1 ]]; then
        _verify_record "$( ((fail==0)) && echo true || echo false )" "${subset:-structure}" "${checked[*]:-none}"
        # Advance the slice only when this one passed, so a failed slice is re-read.
        [[ -n "$slice" ]] && (( fail == 0 )) && printf '%s\n' "$slice" > "${STATE_DIR}/verify.slice"
    fi
    if (( fail == 0 )); then
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "ok" "true" "engine" "restic" "tiers" "${checked[*]:-none}" "subset" "${subset:-structure}" || log_info "verify: OK (${checked[*]:-nothing to check}${subset:+, data read: $subset})"
        return "$EX_OK"
    fi
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "failed" "false" "engine" "restic" "tiers" "${checked[*]:-none}" "subset" "${subset:-structure}"
    die "$EX_DATAERR" "restic check FAILED (${checked[*]:-}, data read: ${subset:-structure})"
}

# _doctor_verify: last verify age/result from STATE_DIR/verify.last.
_doctor_verify() {
    local ok="$1" bad="$2" warn="$3" f="${STATE_DIR}/verify.last"
    DV_LINE=""; DV_PROBLEM=0; DV_WARN=0
    local max="${VERIFY_MAX_AGE:-3456000}"   # 40 days
    if [[ ! -r "$f" ]]; then DV_LINE="$warn  no verify recorded yet (pbo verify, or enable pbo-verify.timer)"; DV_WARN=1; return; fi
    local ep vok sub days; ep="$(jq -r '.epoch//0' "$f" 2>/dev/null)"; vok="$(jq -r '.ok' "$f" 2>/dev/null)"; sub="$(jq -r '.subset//""' "$f" 2>/dev/null)"
    days=$(( ( $(date +%s) - ${ep:-0} ) / 86400 ))
    if [[ "$vok" != true ]]; then DV_LINE="$bad  last verify FAILED ${days}d ago (data read: $sub)"; DV_PROBLEM=1
    elif (( $(date +%s) - ${ep:-0} > max )); then DV_LINE="$warn  last verify ${days}d ago (> $(( max/86400 ))d)"; DV_WARN=1
    else DV_LINE="$ok  last verify ${days}d ago, OK (data read: $sub)"; fi
}

# _doctor_json <problems> <warnings> <line...>: the findings as objects.
# Each line is "  <OK|WARN|FAIL>  <message>" (colour codes stripped); vmid is
# taken from "guest N" / "vmid N" in the message, null otherwise. After
# --fix, `changes` lists what the fix pass changed (or, in a dry run, would
# change): {name, path, change, from, to, applied} (DP_CHANGES_JSON).
_doctor_json() {
    local p="$1" w="$2"; shift 2
    printf '%s\n' "$@" | sed -E 's/\x1b\[[0-9;]*m//g' | jq -R -c '
        capture("^\\s*(?<lv>OK|WARN|FAIL)\\s+(?<msg>.*)$")?
        | { level: ({OK:"ok", WARN:"warn", FAIL:"fail"}[.lv]), message: .msg,
            vmid: ((.msg | capture("(guest|vmid) (?<v>[0-9]{1,9})\\b")? | .v) // null) }' \
      | jq -cs --argjson p "$p" --argjson w "$w" --argjson ch "$DP_CHANGES_JSON" '{status: (if $p == 0 then "ok" else "problems" end), ok: ($p == 0),
            problems: $p, warnings: $w, findings: .} + (if $ch == null then {} else {changes: $ch} end)' | json_emit
}

# fetch: extract+verify one snapshot into the cache WITHOUT restoring. Proves the
# snapshot restores to bytes on disk (restic verifies on read-out). No global lock.
rdo_fetch() {
    local vmid="$1" ts="$2"
    local target="${CACHE_DIR}/fetch-${vmid}"; rm -rf "$target"
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] would extract snapshot vmid=$vmid ts=$ts → $target"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$vmid"
        return "$EX_OK"
    fi
    _restic_extract "$vmid" "$ts" "$target" || die "$EX_DATAERR" "fetch failed for vmid $vmid ts $ts"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "fetched" "true" "vmid" "$vmid" "ts" "$ts" "archive" "$RX_TAR" "verified" "restic"
    else
        log_info "fetch $vmid: DONE, $RX_TAR (restic-verified on read-out)"
    fi
    return "$EX_OK"
}

# unlock: clear a stale restic lock left by a killed backup/prune. restic locks
# are held for the life of a process; a SIGKILL/OOM/reboot leaves one behind and
# the next run fails "repository is already locked". `unlock` removes stale (non-
# live) locks only; a genuinely concurrent run keeps its lock.
rdo_unlock() {
    local rc=0 repo repos=()
    [[ "${LOCAL_REPO:-true}" == "true" ]] && repos+=("$RESTIC_CACHE_REPO")
    [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]] && repos+=("$RESTIC_OFFSITE_REPO")
    for repo in "${repos[@]}"; do
        if [[ "${DRY_RUN:-0}" == 1 ]]; then log_info "[dry-run] restic unlock $repo"; continue; fi
        if _restic "$repo" unlock >/dev/null 2>&1; then log_info "unlock: cleared stale locks on $repo"
        else log_warn "unlock: could not unlock $repo (unreachable?)"; rc=1; fi
    done
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "$( ((rc==0)) && echo ok || echo partial )" "$( ((rc==0)) && echo true || echo false )" "repos" "${repos[*]:-none}"
    (( rc == 0 )) || return "$EX_UNAVAILABLE"
    return "$EX_OK"
}

# _restic_stale_unlock <repo>: auto-clear a lock ONLY if no pbo backup/prune is
# actually running (our own global lock is free). Called before backup/prune so a
# crashed previous run doesn't wedge every future run.
_restic_stale_unlock() {
    local repo="$1"
    [[ "${DRY_RUN:-0}" == 1 ]] && return 0      # a dry run changes nothing, not even locks
    _restic "$repo" list locks 2>/dev/null | grep -q . || return 0   # no locks, nothing to do
    # If pbo itself is mid-operation the lock is legitimate; leave it.
    if [[ -f "$GLOBAL_HOLDER_FILE" ]]; then
        local pid; pid="$(cut -d'|' -f3 "$GLOBAL_HOLDER_FILE" 2>/dev/null)"
        [[ -n "$pid" && "$pid" != "$$" ]] && kill -0 "$pid" 2>/dev/null && return 0
    fi
    log_warn "restic: stale lock on $repo (no live pbo run) → unlocking"
    _restic "$repo" unlock >/dev/null 2>&1 || true
}

# doctor: a fast health check that surfaces the things that silently rot, repo
# reachability, permissions (the DR key, CACHE_DIR and the rest of the rule
# table in lib/perms.sh; `doctor --fix` applies it first), the timer, provider
# snapshots, and, per guest, how old the newest snapshot is (catches a guest
# that quietly stopped being backed up, e.g. one whose data lives on a backup=0
# mountpoint).
rdo_doctor() {
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for doctor"
    _guest_meta_load    # once, in this shell: the $(...) calls below inherit it
    _is_janitor || _pve_jobs_load   # the same for guest ownership (no-op in standalone)
    local problems=0 warns=0 lines=()
    local ok="  ${C_G:-}OK${C_0:-}" bad="  ${C_R:-}FAIL${C_0:-}" warn="  ${C_Y:-}WARN${C_0:-}"

    # Permissions: the rule table (lib/perms.sh), after `doctor --fix` applied
    # it. The DR key line comes first, as it always did.
    _doctor_perms "$ok" "$bad" "$warn"
    lines+=("${DP_DR[@]+"${DP_DR[@]}"}"); problems=$((problems+DP_PROBLEMS)); warns=$((warns+DP_WARNS))

    # Repo reachable.
    local repo; repo="$(_restic_read_repo)"
    if _restic "$repo" --no-lock cat config >/dev/null 2>&1; then lines+=("$ok  repo $(_mask_url "$repo") reachable")
    else lines+=("$bad  repo $(_mask_url "$repo") not reachable"); problems=$((problems+1)); fi

    # Timer enabled (the janitor's own timer on a janitor).
    local timer=pbo.timer what="nightly backup"
    _is_janitor && { timer=pbo-janitor.timer; what="offsite retention + verify"; }
    if systemctl is-enabled "$timer" >/dev/null 2>&1; then lines+=("$ok  $timer enabled")
    else lines+=("$warn  $timer not enabled (no $what)"); warns=$((warns+1)); fi
    # Proxmox integration: the catalogue the storage plugin reads
    if ! _is_janitor && ! _integration_standalone; then
        if systemctl is-enabled pbo-catalog.timer >/dev/null 2>&1; then lines+=("$ok  pbo-catalog.timer enabled")
        else lines+=("$warn  pbo-catalog.timer not enabled (the PVE storage view goes stale; 'pbo integrate enable' turns it on)"); warns=$((warns+1)); fi
    fi

    # Append-only offsite (host side): prove the server refuses deletes.
    _doctor_append_only "$ok" "$bad" "$warn"
    lines+=("${AO_LINES[@]+"${AO_LINES[@]}"}"); problems=$((problems+AO_PROBLEMS)); warns=$((warns+AO_WARNS))

    # Ransomware backstop: a verified append-only server, or provider snapshots.
    if _is_janitor; then :
    elif (( AO_VERIFIED )); then :
    elif [[ "${STORAGE_BOX_SNAPSHOTS_CONFIRMED:-false}" == "true" ]]; then lines+=("$ok  provider snapshots confirmed")
    else lines+=("$warn  no ransomware backstop: offsite is not append-only and STORAGE_BOX_SNAPSHOTS_CONFIRMED=false"); warns=$((warns+1)); fi

    # Janitor: repo files must stay owned by the rest-server user.
    if _is_janitor && [[ "$repo" != *:* ]]; then
        local own
        if own="$(_doctor_janitor_ownership "$repo")"; then lines+=("$ok  repo file ownership consistent")
        else lines+=("$bad  $own"); problems=$((problems+1)); fi
    fi

    # The other permission findings: CACHE_DIR closed with an ACL entry per
    # unprivileged CT, the directories above it, LOCK_DIR, logs, state, config.
    lines+=("${DP_LINES[@]+"${DP_LINES[@]}"}")

    # Alerting: someone has to hear about a failed backup.
    if [[ "${PBO_NO_NOTIFY:-0}" != 1 ]]; then
        local nb=(); _ntfy_configured && nb+=(ntfy); _notify_use_pve && nb+=(proxmox)
        if (( ${#nb[@]} == 0 )); then lines+=("$warn  no alerting: no ntfy configured and Proxmox notifications unavailable (NOTIFY_PVE=${NOTIFY_PVE:-auto})"); warns=$((warns+1))
        elif [[ " ${nb[*]} " == *" proxmox "* ]] && ! _pve_templates_installed; then lines+=("$warn  Proxmox notifications on but pbo templates missing in $PVE_TEMPLATE_DIR (run install.sh)"); warns=$((warns+1))
        else lines+=("$ok  alerts via ${nb[*]}"); fi
    fi

    # Config: unknown keys (typos) and a config newer than this pbo.
    _config_check "${PBO_CONFIG_LOADED:-}" "${PBO_CONFIG_SHARED_LOADED:-}"
    local cl; for cl in "${CC_LINES[@]+"${CC_LINES[@]}"}"; do lines+=("$warn  $cl"); done
    warns=$((warns+CC_WARNS))
    # What the strict reader found (load_config already stopped on its errors):
    # a key pbo ignores in the cluster-shared file is a FAIL, the rest warnings.
    _config_doctor_lines
    for cl in "${CDL_FAIL[@]+"${CDL_FAIL[@]}"}"; do lines+=("$bad  $cl"); problems=$((problems+1)); done
    for cl in "${CDL_WARN[@]+"${CDL_WARN[@]}"}"; do lines+=("$warn  $cl"); warns=$((warns+1)); done

    # Integrity: when did verify last run, and did it pass.
    _doctor_verify "$ok" "$bad" "$warn"
    lines+=("$DV_LINE"); problems=$((problems+DV_PROBLEM)); warns=$((warns+DV_WARN))

    # Proxmox integration: the mode, and who owns each guest (lib/ownership.sh).
    if ! _is_janitor; then
        _doctor_integration "$ok" "$bad" "$warn"
        lines+=("${DI_LINES[@]+"${DI_LINES[@]}"}"); problems=$((problems+DI_PROBLEMS)); warns=$((warns+DI_WARNS))
    fi

    # Restore tests: the proof that a backup boots, not just that its bytes are intact.
    if ! _is_janitor; then
        _doctor_testrestore "$ok" "$bad" "$warn"
        lines+=("${TRD_LINES[@]}"); problems=$((problems+TRD_PROBLEMS)); warns=$((warns+TRD_WARNS))
    fi

    # Per-guest freshness: newest snapshot age vs DOCTOR_MAX_AGE, for every guest
    # on this node. A live guest with NO snapshot at all is a hard finding.
    # On a janitor there are no local guests: check every vmid seen in the repo,
    # which catches a host that quietly stopped sending backups.
    local now; now="$(date +%s)"
    local snaps; snaps="$(_restic "$repo" snapshots --json 2>/dev/null || echo '[]')"
    # Snapshots claiming a time in the future: clock trouble, or a writer trying
    # to take over the retention buckets. The janitor refuses to prune while any exist.
    local fut; fut="$(_future_snapshots "$snaps")"
    if [[ -n "$fut" ]]; then lines+=("$bad  snapshots dated in the future: $fut$(_is_janitor && echo ' (janitor prune is blocked until they are gone)')"); problems=$((problems+1)); fi
    # Guests with snapshots under several path sets (CACHE_DIR moved, host paths
    # changed): retention keeps each as one guest (lib/policy.sh _split_guests).
    # From the list just loaded, no extra round-trip. Informational, unless
    # RETENTION_GROUP_BY is anything but guest: then the old path groups are
    # never pruned. The local setting only says how retention runs where this
    # machine owns the repo's retention: on an append-only offsite the janitor
    # prunes with its own RETENTION_GROUP_BY, which only its doctor can see.
    local sg_id sg_n sg_kind sg_split="" sg_shared="" sg_ns=0 sg_nh=0
    while IFS=$'\t' read -r sg_id sg_n sg_kind; do
        [[ -n "$sg_id" ]] || continue
        if [[ "$sg_kind" == split ]]; then sg_split+="${sg_split:+, }$sg_id ($sg_n paths)"; sg_ns=$((sg_ns+1))
        else sg_shared+="${sg_shared:+, }$sg_id ($sg_n paths)"; sg_nh=$((sg_nh+1)); fi
    done < <(_split_guests "$snaps")
    local sg_ao=0; [[ "$repo" == "${RESTIC_OFFSITE_REPO:-}" ]] && _offsite_append_only && sg_ao=1
    if (( sg_ns && sg_ao )); then
        lines+=("$ok  $sg_ns guest(s) have snapshots under more than one path (CACHE_DIR moved / host paths changed); offsite is append-only, so the janitor's RETENTION_GROUP_BY decides how they are retained (run doctor on the janitor): $sg_split")
    elif (( sg_ns )) && [[ "${RETENTION_GROUP_BY:-guest}" != guest ]]; then
        lines+=("$warn  $sg_ns guest(s) have snapshots under more than one path (CACHE_DIR moved / host paths changed), and RETENTION_GROUP_BY=${RETENTION_GROUP_BY} retains each path on its own, so the old ones are never pruned: $sg_split"); warns=$((warns+1))
    elif (( sg_ns )); then
        lines+=("$ok  $sg_ns guest(s) have snapshots under more than one path (CACHE_DIR moved / host paths changed); retained as one guest each: $sg_split")
    fi
    if (( sg_nh )); then
        lines+=("$warn  $sg_nh guest(s) have snapshots under more than one path, one of them shared with another vmid or with snapshots without a vmid tag: retained per path as in 0.5: $sg_shared"); warns=$((warns+1))
    fi
    if _is_janitor; then
        local back brc=0; back="$(_backdated_snapshots "$snaps" "$repo")" || brc=$?
        (( brc == 0 )) || { lines+=("$bad  janitor baseline $(_janitor_seen_file "$repo") unreadable or malformed (prune blocked)"); problems=$((problems+1)); }
        if [[ -n "$back" ]]; then lines+=("$bad  backdated snapshots (arrived after the last janitor run, claim an earlier time): $back (prune blocked)"); problems=$((problems+1)); fi
        [[ -r "$(_janitor_seen_file "$repo")" ]] || { lines+=("$warn  janitor has no baseline of seen snapshots yet (set on the first prune)"); warns=$((warns+1)); }
    fi
    local id newest age hrs guests
    if _is_janitor; then
        guests="$(printf '%s' "$snaps" | jq -r '[.[].tags[]? | select(startswith("vmid=") and (startswith("vmid=host-")|not)) | sub("^vmid=";"") | select(test("^[0-9]{1,9}$"))] | unique | .[]' 2>/dev/null || true)"
    else
        guests="$(_backup_set || true)"
        local sk; for sk in $(_backup_set_skipped); do lines+=("$warn  guest $sk is not backed up (Proxmox tag pbo-skip)"); warns=$((warns+1)); done
        # own retention below the default: visible, since anyone who can edit the
        # guest's tags can set it (the floor is KEEP_OVERRIDE_MIN_LAST snapshots)
        local g kt p n def low
        while read -r g; do
            [[ -n "$g" ]] || continue
            kt="$(_guest_keep_tag "$g")"; [[ -n "$kt" ]] || continue
            low=""
            for p in ${kt//./ }; do
                n=$((10#${p:1})); case "${p:0:1}" in d) def="${KEEP_OFFSITE_DAILY:-7}";; w) def="${KEEP_OFFSITE_WEEKLY:-4}";; m) def="${KEEP_OFFSITE_MONTHLY:-6}";; y) def="${KEEP_OFFSITE_YEARLY:-0}";; esac
                [[ "$def" =~ ^[0-9]+$ ]] && (( n < def )) && low+="${low:+, }${p:0:1} $n < $def"
            done
            [[ -n "$low" ]] && { lines+=("$warn  guest $g keeps less than the default ($low; tag pbo-keep-*)"); warns=$((warns+1)); }
        done <<<"$guests"
    fi
    while read -r id; do
        [[ -n "$id" ]] || continue
        newest="$(printf '%s' "$snaps" | jq -r --arg v "$id" '[ .[] | select((.tags//[])|any(.=="vmid=\($v)")) | .time ] | sort | last // empty' 2>/dev/null)"
        if [[ -z "$newest" ]]; then lines+=("$bad  guest $id has NO snapshot in the repo"); problems=$((problems+1)); continue; fi
        age=$(( now - $(date -d "$newest" +%s 2>/dev/null || echo "$now") )); hrs=$(( age/3600 ))
        if (( age > ${DOCTOR_MAX_AGE:-172800} )) && _is_janitor; then
            # on the janitor this is the only sign that a host stopped sending: a problem, and an alert
            lines+=("$bad  guest $id newest snapshot ${hrs}h old (> $(( ${DOCTOR_MAX_AGE:-172800}/3600 ))h): its host stopped sending backups?"); problems=$((problems+1))
            notify_failure "janitor: guest $id has no new snapshot for ${hrs}h, its host may have stopped sending backups"
        elif (( age > ${DOCTOR_MAX_AGE:-172800} )); then lines+=("$warn  guest $id newest snapshot ${hrs}h old (> $(( ${DOCTOR_MAX_AGE:-172800}/3600 ))h)"); warns=$((warns+1))
        else lines+=("$ok  guest $id newest snapshot ${hrs}h old"); fi
    done <<<"$guests"

    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        _doctor_json "$problems" "$warns" "${lines[@]}"
    else
        printf '%s\n' "${lines[@]}"
        log_info "doctor: ${problems} problem(s), ${warns} warning(s)"
    fi
    (( problems == 0 )) || return "$EX_UNAVAILABLE"
    return "$EX_OK"
}

# ---------------------------------------------------------------------------
# BATCH mode: dump ALL guests to cache first, then upload all → the SAME repo.
# (BACKUP_MODE=batch). Fuse downtime is clumped in phase 1; a single upload phase in phase 2.
# Falls back to stream if the dumps don't fit in CACHE_DIR.
# ---------------------------------------------------------------------------

# Estimated tar size for a guest (ZFS used if possible, otherwise config size).
_guest_bytes() {
    local vmid="$1" spec volid ds used szg gt total=0 line
    gt="$(_guest_type "$vmid")" || gt="lxc"
    if [[ "$gt" == qemu ]]; then                 # sum VM disk sizes (skip cdrom/cloudinit)
        while IFS= read -r line; do
            [[ "$line" =~ ^(scsi|virtio|sata|ide|efidisk|tpmstate)[0-9]*: ]] || continue
            [[ "$line" == *media=cdrom* || "$line" == *cloudinit* ]] && continue
            szg="$(sed -n 's/.*size=\([0-9]\+\)G.*/\1/p' <<<"$line")"
            [[ "$szg" =~ ^[0-9]+$ ]] && total=$(( total + szg * 1073741824 ))
        done < <(qm config "$vmid" 2>/dev/null)
        (( total > 0 )) || total=$(( 8 * 1073741824 ))
        printf '%s' "$total"; return
    fi
    # LXC: sum rootfs + every mpN that is actually backed up (skip bind mounts and
    # backup=0). A big data mountpoint on mp0 counts, so batch-fit doesn't undershoot.
    while IFS= read -r line; do
        [[ "$line" =~ ^(rootfs|mp[0-9]+): ]] || continue
        spec="${line#*: }"; volid="${spec%%,*}"
        [[ "$volid" == /* ]] && continue                       # bind mount, never in the archive
        [[ ",${spec#*,}," == *",backup=0,"* ]] && continue     # excluded volume
        ds="${volid/:/\/}"                                     # storeid:volume → storeid/volume
        used="$(zfs list -Hpo used "$ds" 2>/dev/null)"
        if [[ "$used" =~ ^[0-9]+$ ]]; then
            total=$(( total + used ))
        else
            szg="$(sed -n 's/.*size=\([0-9]\+\)G.*/\1/p' <<<"$spec")"
            total=$(( total + ${szg:-4} * 1073741824 ))
        fi
    done < <(pct config "$vmid" 2>/dev/null)
    (( total > 0 )) || total=$(( 4 * 1073741824 ))
    printf '%s' "$total"
}

# Do all dumps fit in the cache? (requires 85% margin.)
_batch_fits() {
    local free need=0 v
    free="$(df -PB1 "$CACHE_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
    [[ "$free" =~ ^[0-9]+$ ]] || return 1
    for v in "$@"; do need=$(( need + $(_guest_bytes "$v") )); done
    (( need > 0 && free > need * 100 / 85 ))
}

# _batch_vmid_lock <vmid>: the guest's own lock (the file acquire_vmid_lock
# uses), non-blocking, on a new fd → BL_FD. Batch holds it from the dump to the
# end of that guest's upload, so `pbo ingest` (a PVE job backing up the same
# guest) or a manual `pbo backup` fails fast instead of emptying $CACHE_DIR/<vmid>
# between the two phases. 1 = busy or not openable.
BL_FD=""
_batch_vmid_lock() {
    local fd
    BL_FD=""
    exec {fd}>"${LOCK_DIR}/pbo.vmid-${1}.lock" || return 1
    if ! flock -n "$fd"; then exec {fd}>&-; return 1; fi
    BL_FD="$fd"
}
_batch_vmid_unlock() { local fd="${1:-}"; [[ "$fd" =~ ^[0-9]+$ ]] && exec {fd}>&-; return 0; }

# rdo_run_batch <vmid...> → 0 ok/partial, 2 = doesn't fit (ask caller to run stream).
rdo_run_batch() {
    local vmids=("$@")
    restic_init
    if ! _batch_fits "${vmids[@]}"; then
        log_warn "batch: dumps don't fit in CACHE_DIR ($CACHE_DIR) → falling back to stream (one-by-one)"
        return 2
    fi
    acquire_global_lock "queue" "batch" "all"
    local start; start="$(date +%s)"

    # --- PHASE 1: dump all → cache ---
    log_info "batch: PHASE 1, dumping ${#vmids[@]} guests to cache…"
    local dumped=() v mode dumpdir base ts jobfile gt p1fail=()
    declare -A TS_OF=() GT_OF=() BASE_OF=() LK_OF=()
    for v in "${vmids[@]}"; do
        [[ -n "$v" ]] || continue
        if ! run_preflight "$v"; then log_warn "batch: preflight failed for $v, skipping"; p1fail+=("$v"); continue; fi
        if ! _batch_vmid_lock "$v"; then
            log_warn "batch: vmid $v is busy (a backup or ingest of it runs), skipping"; p1fail+=("$v"); continue
        fi
        LK_OF[$v]="$BL_FD"
        mode="$(_effective_mode "$v")"; dumpdir="${CACHE_DIR}/${v}"
        gt="$(_guest_type "$v")" || gt="lxc"
        rm -f "$dumpdir"/vzdump-* 2>/dev/null; mkdir -p "$dumpdir" "$JOBS_DIR"
        jobfile="${JOBS_DIR}/batch-dump-${v}-$(date +%Y%m%d-%H%M%S).log"
        log_info "batch: vzdump $v ($mode, $gt)…"
        if run_stream "$jobfile" "vzdump[$v]" -- vzdump "$v" --mode "$mode" --compress 0 --dumpdir "$dumpdir"; then
            base="$(_newest_dump "$dumpdir" "$v")"
            if [[ -n "$base" && -f "$base" ]]; then
                ts="$(_archive_ts "$(basename "$base")")"; [[ -n "$ts" ]] || ts="$(date +%Y_%m_%d-%H_%M_%S)"
                _g_config "$gt" "$v" > "${base}.conf" 2>/dev/null || true
                dumped+=("$v"); TS_OF[$v]="$ts"; GT_OF[$v]="$gt"; BASE_OF[$v]="$(basename -- "$base")"
            else
                log_warn "batch: no tar found for $v after vzdump, skipping"; p1fail+=("$v")
            fi
        else
            log_warn "batch: vzdump $v FAILED, skipping"; p1fail+=("$v")
        fi
        [[ -n "${BASE_OF[$v]:-}" ]] || { _batch_vmid_unlock "${LK_OF[$v]}"; unset 'LK_OF[$v]'; }
    done

    # --- PHASE 2: upload all dumps → ONE repo ---
    log_info "batch: PHASE 2, uploading ${#dumped[@]} dumps → $(_restic_read_repo)…"
    # phase-1 failures count: a guest that was not dumped is a failed backup
    local okc=0 failc=${#p1fail[@]} failed=("${p1fail[@]+"${p1fail[@]}"}")
    for v in "${dumped[@]}"; do
        ts="${TS_OF[$v]}"; dumpdir="${CACHE_DIR}/${v}"
        jobfile="${JOBS_DIR}/backup-${v}-$(date +%Y%m%d-%H%M%S).log"
        # the per-guest retention travels with the snapshot, as in stream mode
        # (_upload_dumpdir); the archive name makes a missing dump a failure, never
        # an empty snapshot
        if ! _upload_dumpdir "$v" "${GT_OF[$v]:-lxc}" "$dumpdir" "${BASE_OF[$v]}" "$ts" "$jobfile"; then
            failc=$((failc+1)); failed+=("$v")
            if [[ "$UD_STAGE" == backup ]]; then log_warn "batch: restic backup $v FAILED${UD_LOCK:+: repo locked ($UD_LOCK)}"
            else log_warn "batch: copy→offsite $v FAILED${UD_LOCK:+: repo locked ($UD_LOCK)}"; fi
            _batch_vmid_unlock "${LK_OF[$v]:-}"
            continue
        fi
        _batch_vmid_unlock "${LK_OF[$v]:-}"
        okc=$((okc+1))
    done
    local dur=$(( $(date +%s) - start ))

    if (( failc > 0 )); then notify_failure "batch: ${failc} failed (${failed[*]}) in ${dur}s"
    else notify_success "batch: ${okc} backups OK in ${dur}s"; fi
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "$( ((failc==0)) && echo ok || echo partial )" "$( ((failc==0)) && echo true || echo false )" \
            "mode" "batch" "backups_ok:n" "$okc" "backups_failed:n" "$failc" "duration_s:n" "$dur" "failed_vmids" "${failed[*]:-}"
    else
        log_info "batch: done, ${okc} ok, ${failc} failed, ${dur}s (all in one repo)"
    fi
    (( failc == 0 )) || return "$EX_SOFTWARE"
    return "$EX_OK"
}
