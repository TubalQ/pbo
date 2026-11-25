# shellcheck shell=bash
# lib/catalog.sh: the catalogue that the PVE storage plugin reads (ADR 0006, Phase 1).
#
#   pbo catalog refresh [--out <file>]   read both repo tiers, write the index
#   pbo catalog show                     print the index
#   pbo catalog materialize [--background] <archive>
#                                        put one archive in PVE_STAGING_DIR for a restore
#   pbo catalog release [--all]          remove staged archives older than PVE_STAGING_TTL,
#                                        or no longer in the index (pbo-catalog.service runs it)
#
# The index ($PBO_CATALOG, default /var/lib/pbo/catalog/index.json) is the only
# thing the plugin's list_volumes/status/activate_storage read: they never fork,
# never touch the network or FUSE. Format (version 1):
#   {version:1, generated:<epoch>, updated:<epoch>, node, storage_id, staging_dir, spool_dir,
#    tiers:{cache:{enabled,ok,count}, offsite:{enabled,ok,count}},
#    entries:[{volname:"backup/vzdump-<lxc|qemu>-<vmid>-<YYYY_MM_DD-HH_MM_SS>.<tar|vma>",
#              vmid:<number>, type, ts, ctime:<epoch>, size:<bytes>,
#              snapshots:{cache:<id|null>, offsite:<id|null>},
#              keep:<reason>, offsite_only:<bool>}]}
# staging_dir is where materialize puts archives: the plugin's path() for a volume
# not in the spool is <staging_dir>/<archive>, so it never parses pbo's config.
# spool_dir (PVE_SPOOL_DIR) is informational: the plugin takes the spool from the
# storage's own `path` in storage.cfg; `pbo integrate` and doctor compare the two.
# keep is the retention that governs the snapshot, read from its tags: the
# per-guest keep spec (keep=d30.w8...) or "default" (the config's KEEP_*). It is
# not a prune forecast: that would cost a dry-run forget per policy group on
# every 15-minute refresh (`pbo list --reasons` has it).
#
# Rules:
#   - Every repo read uses --no-lock: a refresh never leaves a lock that blocks a
#     prune, and never waits on one.
#   - An enabled tier that cannot be read fails the refresh. The old index stays;
#     an empty or partial index is never written (the plugin would show "no
#     backups", the worst thing to see before a restore).
#   - The index is written atomically (temp file in the same directory, then mv),
#     mode 0644 in a 0755 directory, under the catalogue lock.
#   - The volname is the archive's vzdump name. A snapshot's tags carry its
#     vmid/ts/type, and pbo derives ts from the archive name at backup time
#     (rdo_backup), so the name rebuilt from the tags is the archive's own name.
#     materialize looks the file up inside the snapshot by that name and fails if
#     it is not there.

readonly CATALOG_VERSION=1
readonly CATALOG_BASENAME_RE='^vzdump-(lxc|qemu)-[0-9]+-[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}\.(tar|vma)$'
readonly PBO_MOUNT_UNIT=pbo-mount.service
CATALOG_LOCK_FD=""

_catalog_cache_on()   { [[ "${LOCAL_REPO:-true}" == "true" ]]; }
_catalog_offsite_on() { [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; }

# _catalog_lock: serialise index writers (refresh, _catalog_add_entry). A refresh
# holds it from the first repo read to the write, so an entry added meanwhile is
# never overwritten by an older listing.
_catalog_lock() {
    [[ -n "$CATALOG_LOCK_FD" ]] && return 0
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    exec {CATALOG_LOCK_FD}>>"${LOCK_DIR}/pbo.catalog" || { CATALOG_LOCK_FD=""; return 1; }
    if ! flock -w "${CATALOG_LOCK_TIMEOUT:-600}" "$CATALOG_LOCK_FD"; then
        exec {CATALOG_LOCK_FD}>&-; CATALOG_LOCK_FD=""; return 1
    fi
}
_catalog_unlock() {
    [[ -n "$CATALOG_LOCK_FD" ]] || return 0
    exec {CATALOG_LOCK_FD}>&-; CATALOG_LOCK_FD=""
}

# _catalog_valid <file>: a readable version-1 index.
_catalog_valid() {
    [[ -s "$1" && -r "$1" ]] && jq -e --argjson v "$CATALOG_VERSION" '.version == $v and (.entries|type) == "array"' "$1" >/dev/null 2>&1
}

# _catalog_write <file>: write stdin (an index) to <file> atomically. Refuses
# anything that is not a valid index. Returns non-zero and leaves <file> alone
# on any failure (the caller says so).
_catalog_write() {
    local f="$1" dir tmp
    dir="$(dirname -- "$f")"
    if [[ ! -d "$dir" ]]; then
        ( umask 022; mkdir -p -- "$dir" ) 2>/dev/null || return 1
        chmod 0755 "$dir" 2>/dev/null || true
    fi
    tmp="$(mktemp "$dir/.index.XXXXXX" 2>/dev/null)" || return 1
    if ! jq -c --argjson v "$CATALOG_VERSION" 'if .version == $v and (.entries|type) == "array" then . else error("not an index") end' > "$tmp" 2>/dev/null \
       || ! chmod 0644 "$tmp" || ! mv -f -- "$tmp" "$f"; then
        rm -f -- "$tmp"
        return 1
    fi
    return 0
}

# _catalog_read_tier <repo>: the tier's archives (with path/epoch/keep_tag) on
# stdout; non-zero when the repo cannot be read.
_catalog_read_tier() {
    local rc=0 out
    out="$(LIST_NO_LOCK=1 _list_archives_json "$1" "" 1)" || rc=$?
    (( rc == 0 )) || return 1
    printf '%s' "$out"
}

# catalog_refresh [--out <file>]
catalog_refresh() {
    local out="$PBO_CATALOG"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out) [[ -n "${2:-}" ]] || die "$EX_USAGE" "catalog refresh --out needs a file"; out="$2"; shift 2 ;;
            *) die "$EX_USAGE" "unknown catalog refresh flag: $1" ;;
        esac
    done
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for catalog"
    _catalog_cache_on || _catalog_offsite_on || die "$EX_CONFIG" "catalog: no repo tier is enabled (LOCAL_REPO=false and no offsite repo)"
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] catalog refresh → $out"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "ok" "true" "path" "$out"
        return "$EX_OK"
    fi
    _catalog_lock || die "$EX_TEMPFAIL" "catalog: another refresh holds the catalogue lock (${LOCK_DIR}/pbo.catalog)"
    local cj='[]' oj='[]' cen=false oen=false
    if _catalog_cache_on; then
        cen=true
        cj="$(_catalog_read_tier "$RESTIC_CACHE_REPO")" \
            || die "$EX_UNAVAILABLE" "catalog: cache repo $(_mask_url "$RESTIC_CACHE_REPO") not readable; $out left unchanged"
    fi
    if _catalog_offsite_on; then
        oen=true
        oj="$(_catalog_read_tier "$RESTIC_OFFSITE_REPO")" \
            || die "$EX_UNAVAILABLE" "catalog: offsite repo $(_mask_url "$RESTIC_OFFSITE_REPO") not readable; $out left unchanged"
    fi
    local idx
    idx="$(jq -cn --slurpfile c <(printf '%s' "$cj") --slurpfile o <(printf '%s' "$oj") \
        --argjson cen "$cen" --argjson oen "$oen" --argjson now "$(date +%s)" --argjson v "$CATALOG_VERSION" \
        --arg node "$(_local_node)" --arg sid "${PVE_STORAGE_ID:-pbo}" --arg stg "${PVE_STAGING_DIR:-}" --arg spool "${PVE_SPOOL_DIR:-}" \
        --arg re "$CATALOG_BASENAME_RE" '
        def guests($tier): map(select((.type == "lxc" or .type == "qemu") and (.vmid | test("^[0-9]+$"))
                                      and (.archive | test($re))) | . + {tier:$tier});
        (($c[0] // []) | guests("cache")) as $cs | (($o[0] // []) | guests("offsite")) as $os
        | [ ($cs + $os) | group_by(.archive)[]
            | (map(select(.tier == "cache"))   | sort_by(.epoch // 0) | last) as $ce
            | (map(select(.tier == "offsite")) | sort_by(.epoch // 0) | last) as $oe
            | ($ce // $oe) as $p
            | { volname:("backup/" + $p.archive), vmid:($p.vmid | tonumber), type:$p.type, ts:$p.ts,
                ctime:(($p.epoch // 0) | floor), size:($p.size_bytes // 0),
                snapshots:{cache:($ce.id // null), offsite:($oe.id // null)},
                keep:($p.keep_tag // "default"), offsite_only:($ce == null) } ]
        | sort_by(.vmid, .ts) as $e
        | {version:$v, generated:$now, updated:$now, node:$node, storage_id:$sid, staging_dir:$stg, spool_dir:$spool,
           tiers:{cache:{enabled:$cen, ok:(if $cen then true else null end), count:([$e[] | select(.snapshots.cache != null)] | length)},
                  offsite:{enabled:$oen, ok:(if $oen then true else null end), count:([$e[] | select(.snapshots.offsite != null)] | length)}},
           entries:$e}' 2>/dev/null)" || die "$EX_SOFTWARE" "catalog: could not build the index; $out left unchanged"
    printf '%s' "$idx" | _catalog_write "$out" || die "$EX_CANTCREAT" "catalog: could not write $out"
    _catalog_unlock
    local n nc no
    read -r n nc no < <(jq -r '"\(.entries|length) \(.tiers.cache.count) \(.tiers.offsite.count)"' <<<"$idx")
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "ok" "true" "path" "$out" "entries:n" "$n" "cache:n" "$nc" "offsite:n" "$no"
    else
        log_info "catalog: $n archive(s) (cache $nc, offsite $no) → $out"
    fi
}

# _catalog_add_entry <vmid> <ts> <type> <basename> <size> <cache_snap> <offsite_snap> [keep]
# Insert or update one entry without listing a repo (ingest, M4). An empty snap
# id keeps what the index already has for that tier. Needs an existing index: on
# a missing one it adds nothing and returns 1 (a one-entry index would hide every
# other backup; the next refresh writes a full one).
_catalog_add_entry() {
    local vmid="$1" ts="$2" typ="$3" base="$4" size="${5:-0}" cs="${6:-}" os="${7:-}" keep="${8:-}"
    if ! is_vmid "$vmid" || [[ "$typ" != lxc && "$typ" != qemu ]] || ! [[ "$base" =~ $CATALOG_BASENAME_RE ]] \
       || [[ "$base" != "vzdump-${typ}-${vmid}-${ts}."* ]]; then
        log_warn "catalog: refusing entry vmid=$vmid ts=$ts type=$typ archive=$base"; return 1
    fi
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    _catalog_lock || { log_warn "catalog: lock busy, $base not added (the next refresh adds it)"; return 1; }
    if ! _catalog_valid "$PBO_CATALOG"; then
        _catalog_unlock
        log_warn "catalog: no index at $PBO_CATALOG, $base not added (run 'pbo catalog refresh')"; return 1
    fi
    local idx rc=0
    idx="$(jq -c --arg vol "backup/$base" --arg vmid "$vmid" --arg ts "$ts" --arg typ "$typ" --argjson size "$size" \
        --arg cs "$cs" --arg os "$os" --arg keep "$keep" --argjson now "$(date +%s)" '
        (first(.entries[] | select(.volname == $vol)) // null) as $old
        | ((if $cs != "" then $cs else ($old.snapshots.cache // null) end)) as $c
        | ((if $os != "" then $os else ($old.snapshots.offsite // null) end)) as $o
        | .entries = ([.entries[] | select(.volname != $vol)]
            + [{volname:$vol, vmid:($vmid | tonumber), type:$typ, ts:$ts, ctime:($old.ctime // $now),
                size:$size, snapshots:{cache:$c, offsite:$o},
                keep:(if $keep != "" then $keep else ($old.keep // "default") end), offsite_only:($c == null)}]
            | sort_by(.vmid, .ts))
        | .updated = $now
        | .tiers.cache.count = ([.entries[] | select(.snapshots.cache != null)] | length)
        | .tiers.offsite.count = ([.entries[] | select(.snapshots.offsite != null)] | length)' "$PBO_CATALOG" 2>/dev/null)" || rc=1
    (( rc == 0 )) && { printf '%s' "$idx" | _catalog_write "$PBO_CATALOG" || rc=1; }
    _catalog_unlock
    (( rc == 0 )) || { log_warn "catalog: could not add $base"; return 1; }
    log_info "catalog: added $base"
}

# catalog show: the index as it is (--json: {path, catalog:<index>}).
catalog_show() {
    [[ $# -eq 0 ]] || die "$EX_USAGE" "catalog show takes no arguments"
    _catalog_valid "$PBO_CATALOG" || die "$EX_UNAVAILABLE" "catalog: no readable index at $PBO_CATALOG (run 'pbo catalog refresh')"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        jq -c --arg p "$PBO_CATALOG" --argjson now "$(date +%s)" \
            '{status:"ok", ok:true, path:$p, age_seconds:($now - (.generated // $now)), catalog:.}' "$PBO_CATALOG" | json_emit
        return "$EX_OK"
    fi
    jq -r --argjson now "$(date +%s)" '
        "catalog \(.storage_id) on \(.node): \(.entries|length) archive(s), refreshed \($now - .generated)s ago"
        + " (cache \(if .tiers.cache.enabled then .tiers.cache.count else "off" end), offsite \(if .tiers.offsite.enabled then .tiers.offsite.count else "off" end))",
        (.entries[] | "  \(.volname)  \(.size)  cache:\(.snapshots.cache // "-" | .[0:8])  offsite:\(.snapshots.offsite // "-" | .[0:8])\(if .offsite_only then "  (offsite only)" else "" end)")' "$PBO_CATALOG"
}

# ---------------------------------------------------------------------------
# materialize / release: archives for a PVE restore or Show Configuration.
# ---------------------------------------------------------------------------
# _catalog_stage_lock <basename>: one materialize/release per archive at a time.
# Sets STAGE_LOCK_FD; flock args follow (e.g. -n).
_catalog_stage_lock() {
    local base="$1"; shift
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    exec {STAGE_LOCK_FD}>>"${LOCK_DIR}/pbo.stage.${base}" || return 1
    flock "$@" "$STAGE_LOCK_FD" || { exec {STAGE_LOCK_FD}>&-; return 1; }
}
_catalog_stage_unlock() { [[ -n "${STAGE_LOCK_FD:-}" ]] && exec {STAGE_LOCK_FD}>&-; STAGE_LOCK_FD=""; }

# _catalog_snapshot_file <repo> <snapshot> <basename>: the archive's path inside
# the snapshot and its size → CS_PATH, CS_SIZE. Fails when it is not there.
_catalog_snapshot_file() {
    local repo="$1" snap="$2" base="$3" line
    CS_PATH=""; CS_SIZE=""
    line="$(_restic "$repo" --no-lock ls --json "$snap" 2>/dev/null \
        | jq -rn --arg b "$base" 'first(inputs | select(.struct_type == "node" and .type == "file" and .name == $b)) | "\(.size)\t\(.path)"' 2>/dev/null || true)"
    [[ -n "$line" ]] || return 1
    CS_SIZE="${line%%$'\t'*}"; CS_PATH="${line#*$'\t'}"
    [[ "$CS_SIZE" =~ ^[0-9]+$ && "$CS_PATH" == /* ]]
}

# _catalog_mount_file <snapshot-id> <path-in-snapshot> → where the archive shows
# up inside the pbo-mount.service FUSE mount (restic mount of the cache repo at
# PVE_CATALOG_MOUNT_DIR).
# Layout verified in spike A (ADR 0006 amendment 13, restic 0.18.0): restic mount
# lists each snapshot as ids/<8-char short id>/ followed by the snapshot's
# absolute paths. Everything that depends on the mount layout is in this one
# function. The mount must hold its restic lock (never --no-lock): a prune under
# a lock-free mount turns open reads into EIO. materialize stages a cache
# archive through the mount unless PVE_CATALOG_MOUNT=false (then restic dump).
_catalog_mount_file() {
    printf '%s/ids/%s%s' "${PVE_CATALOG_MOUNT_DIR:-/run/pbo/mnt}" "${1:0:8}" "$2"
}

_catalog_systemctl_ok() { command -v systemctl >/dev/null 2>&1; }
_catalog_mount_active() { _catalog_systemctl_ok && systemctl is-active --quiet "$PBO_MOUNT_UNIT" 2>/dev/null; }

# _catalog_mount_ensure <file-in-mount> [wait seconds]: start pbo-mount.service
# when needed and wait for <file> to appear (default CATALOG_MOUNT_WAIT, 30 s).
# Fails (the caller falls back to restic dump) when the unit is not installed or
# the file does not show up. A running mount lists a new snapshot only after
# a delay (spike A, ADR 0006 amendment 13).
_catalog_mount_ensure() {
    local f="$1" wait="${2:-${CATALOG_MOUNT_WAIT:-30}}" i
    [[ -f "$f" ]] && return 0
    _catalog_systemctl_ok || return 1
    if ! _catalog_mount_active; then
        systemctl cat "$PBO_MOUNT_UNIT" >/dev/null 2>&1 || { log_info "catalog: $PBO_MOUNT_UNIT is not installed"; return 1; }
        systemctl start "$PBO_MOUNT_UNIT" >/dev/null 2>&1 || { log_warn "catalog: could not start $PBO_MOUNT_UNIT"; return 1; }
    fi
    [[ "$wait" =~ ^[0-9]+$ ]] || wait=30
    for (( i = 0; i < wait; i++ )); do
        [[ -f "$f" ]] && return 0
        sleep 1
    done
    log_warn "catalog: $f did not appear in the mount"
    return 1
}

# _catalog_mount_busy: a process has a file open (or its cwd) inside the mount,
# e.g. a PVE restore reading a staged archive through a symlink. Read from /proc
# (readlink of fd/cwd, never a request to the FUSE mount itself); as root it
# sees every process.
_catalog_mount_busy() {
    local m="${PVE_CATALOG_MOUNT_DIR:-/run/pbo/mnt}"
    m="${m%/}"
    [[ -n "$m" ]] || return 1
    [[ -n "$(find /proc -mindepth 2 -maxdepth 3 \( -path '/proc/[0-9]*/fd/*' -o -path '/proc/[0-9]*/cwd' \) \
                \( -lname "$m" -o -lname "$m/*" \) -print -quit 2>/dev/null)" ]]
}

# _catalog_mount_stop <why>: stop pbo-mount.service if it runs (prune and verify
# take exclusive restic locks; the mount holds a lock on the cache repo). A no-op
# in standalone (the integration never started it), on a janitor and when the
# unit is not installed or not active. While a restore reads through the mount it
# waits up to CATALOG_MOUNT_BUSY_WAIT seconds (default 900), then dies with
# EX_TEMPFAIL: stopping it would fail that restore halfway.
_catalog_mount_stop() {
    _is_janitor && return 0
    _integration_standalone && return 0
    _catalog_mount_active || return 0
    local waited=0 max="${CATALOG_MOUNT_BUSY_WAIT:-900}" step
    [[ "$max" =~ ^[0-9]+$ ]] || max=900
    while _catalog_mount_busy; do
        (( waited < max )) \
            || die "$EX_TEMPFAIL" "$1: $PBO_MOUNT_UNIT is in use (a restore reads through ${PVE_CATALOG_MOUNT_DIR:-/run/pbo/mnt}); not stopping it under the restore, $1 skipped, retry later"
        (( waited == 0 )) && log_info "$1: $PBO_MOUNT_UNIT is in use (a restore reads through it), waiting up to ${max}s"
        step=$(( max - waited < 10 ? max - waited : 10 ))
        sleep "$step"; waited=$(( waited + step ))
    done
    log_info "$1: stopping $PBO_MOUNT_UNIT (it holds a lock on the cache repo)"
    systemctl stop "$PBO_MOUNT_UNIT" >/dev/null 2>&1 || log_warn "$1: could not stop $PBO_MOUNT_UNIT"
    return 0
}

# catalog materialize [--background] <basename>: put the archive at
# PVE_STAGING_DIR/<basename> and print that path. Cache tier first, offsite as the
# fallback (offsite-only entries). A cache archive becomes a symlink into the
# restic mount (pbo-mount.service; the default, PVE_CATALOG_MOUNT);
# when the mount is off or not usable, and for offsite, the archive is copied
# out with restic dump --no-lock to <basename>.part.* and renamed when complete.
# --background is for callers that must not block (the storage plugin inside a
# synchronous pvedaemon/pveproxy request: Show Configuration, the Restore
# dialog, a QEMU restore before its worker forks). An archive already staged is
# returned at once. A cache archive with the mount on is linked inline, waiting
# at most CATALOG_MOUNT_BG_WAIT (10 s) for it to show in the mount: the plugin
# gives the whole call 20 s. Otherwise a detached `pbo catalog materialize` is
# started (or one already runs) and this exits EX_TEMPFAIL with "retry in a few
# minutes".
catalog_materialize() {
    local bg=0
    [[ "${1:-}" == --background ]] && { bg=1; shift; }
    local base="${1:-}"
    [[ $# -eq 1 ]] || die "$EX_USAGE" "catalog materialize [--background] <vzdump archive name>"
    [[ "$base" =~ $CATALOG_BASENAME_RE ]] || die "$EX_USAGE" "catalog materialize: '$base' is not a vzdump archive name (vzdump-<lxc|qemu>-<vmid>-<YYYY_MM_DD-HH_MM_SS>.<tar|vma>)"
    _catalog_valid "$PBO_CATALOG" || die "$EX_UNAVAILABLE" "catalog: no readable index at $PBO_CATALOG (run 'pbo catalog refresh')"
    local entry; entry="$(jq -c --arg v "backup/$base" 'first(.entries[] | select(.volname == $v)) // empty' "$PBO_CATALOG" 2>/dev/null || true)"
    [[ -n "$entry" ]] || die "$EX_DATAERR" "catalog: $base is not in the catalogue (run 'pbo catalog refresh')"
    local csnap osnap
    csnap="$(jq -r '.snapshots.cache // empty' <<<"$entry")"; osnap="$(jq -r '.snapshots.offsite // empty' <<<"$entry")"
    local tier="" repo="" snap=""
    if [[ -n "$csnap" ]] && _catalog_cache_on; then tier=cache; repo="$RESTIC_CACHE_REPO"; snap="$csnap"
    elif [[ -n "$osnap" ]] && _catalog_offsite_on; then tier=offsite; repo="$RESTIC_OFFSITE_REPO"; snap="$osnap"
    else die "$EX_UNAVAILABLE" "catalog: $base has no snapshot in an enabled tier"; fi
    [[ "$snap" =~ ^[0-9a-f]{8,64}$ ]] || die "$EX_DATAERR" "catalog: bad snapshot id for $base in the index"

    local dir="$PVE_STAGING_DIR" dest
    if [[ ! -d "$dir" ]]; then
        ( umask 077; mkdir -p -- "$dir" ) 2>/dev/null || die "$EX_CANTCREAT" "catalog: cannot create $dir"
    fi
    [[ -L "$dir" ]] && die "$EX_CONFIG" "catalog: PVE_STAGING_DIR $dir is a symlink"
    dest="$dir/$base"
    local use_mount=0
    [[ "$tier" == cache && "${PVE_CATALOG_MOUNT:-true}" == true ]] && use_mount=1
    if (( bg )); then
        # staged already, or a cache archive the mount can serve inline: the normal
        # path below (reuse, or link), with a short lock wait; else stage detached
        [[ -f "$dest" ]] || (( use_mount )) || _catalog_stage_detached "$base" "$tier" "$snap"
        _cfg_int_r CATALOG_STAGE_WAIT
        _catalog_stage_lock "$base" -w "$_CI_R" || die "$EX_TEMPFAIL" "catalog: $base is being staged right now; retry in a few minutes"
    else
        _catalog_stage_lock "$base" -w "${GLOBAL_LOCK_TIMEOUT:-7200}" || die "$EX_TEMPFAIL" "catalog: $base is being staged by another process"
    fi

    local method="" reused=false
    if [[ -f "$dest" ]]; then
        # already staged (a regular file, or a symlink into a live mount): reuse
        # it and restart its TTL
        touch -h -- "$dest" 2>/dev/null || true
        method="$([[ -L "$dest" ]] && echo mount || echo dump)"; reused=true
    else
        _catalog_snapshot_file "$repo" "$snap" "$base" \
            || die "$EX_UNAVAILABLE" "catalog: $base not found in $tier snapshot ${snap:0:8} ($(_mask_url "$repo") unreadable, or the snapshot holds another archive)"
        if (( use_mount )); then
            local mf mwait=""; mf="$(_catalog_mount_file "$snap" "$CS_PATH")"
            (( bg )) && mwait="${CATALOG_MOUNT_BG_WAIT:-10}"
            if _catalog_mount_ensure "$mf" $mwait; then
                ln -sfn -- "$mf" "$dest.lnk.$$" && mv -fT -- "$dest.lnk.$$" "$dest" && method=mount \
                    || rm -f -- "$dest.lnk.$$"
            fi
            if [[ -z "$method" ]] && (( bg )); then
                _catalog_stage_unlock
                _catalog_stage_detached "$base" "$tier" "$snap"   # dies EX_TEMPFAIL: retry
            fi
            [[ -n "$method" ]] || log_info "catalog: mount not usable for $base, falling back to restic dump"
        fi
        if [[ -z "$method" ]]; then
            local avail; avail="$(df -B1 --output=avail -- "$dir" 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
            if [[ -n "$avail" ]] && (( avail < CS_SIZE )); then
                die "$EX_CANTCREAT" "catalog: $base needs $CS_SIZE bytes, $dir has $avail free"
            fi
            local part errf rc=0; part="$(mktemp "$dir/$base.part.XXXXXX" 2>/dev/null)" || die "$EX_CANTCREAT" "catalog: cannot write in $dir"
            errf="$(mktemp)"
            log_info "catalog: restic dump $tier snapshot ${snap:0:8} → $dest"
            _restic "$repo" --no-lock dump "$snap" "$CS_PATH" > "$part" 2>"$errf" || rc=$?
            if (( rc != 0 )) || [[ "$(stat -c %s -- "$part" 2>/dev/null)" != "$CS_SIZE" ]]; then
                rm -f -- "$part"
                local why; why="$(tail -1 "$errf" 2>/dev/null)"; rm -f -- "$errf"
                die "$EX_UNAVAILABLE" "catalog: restic dump of $base from $tier failed (rc=$rc${why:+: $why})"
            fi
            rm -f -- "$errf"
            chmod 0600 -- "$part"
            mv -fT -- "$part" "$dest" || { rm -f -- "$part"; die "$EX_CANTCREAT" "catalog: cannot move $base into $dir"; }
            method=dump
        fi
    fi
    _catalog_stage_unlock
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "ok" "true" "path" "$dest" "volname" "backup/$base" "tier" "$tier" "method" "$method" "reused:b" "$reused"
    else
        printf '%s\n' "$dest"
    fi
}

# _catalog_stage_detached <basename> <tier> <snap>: start a detached `pbo catalog
# materialize <basename>` (its own session, no inherited lock fds, output to a job
# log) unless one already holds the archive's stage lock, then die EX_TEMPFAIL:
# the caller (a synchronous PVE API request) retries once it is staged.
_catalog_stage_detached() {
    local base="$1" tier="$2" snap="$3" log
    if ! _catalog_stage_lock "$base" -n; then
        die "$EX_TEMPFAIL" "pbo is staging $base from the $tier repo right now; retry in a few minutes"
    fi
    _catalog_stage_unlock
    [[ "${DRY_RUN:-0}" == 1 ]] && die "$EX_TEMPFAIL" "[dry-run] would stage $base from the $tier repo in the background"
    command -v setsid >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "catalog: setsid (util-linux) is needed to stage $base in the background"
    mkdir -p "$JOBS_DIR" 2>/dev/null || true
    # a previous background attempt that failed: say why, and try again
    local last why=""
    last="$(find "$JOBS_DIR" -maxdepth 1 -type f -name "stage-${base}-*.log" -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)"
    [[ -n "$last" ]] && why="$(grep -E '\[ERROR\]' -- "$last" 2>/dev/null | tail -1 | sed -E 's/^.*\[ERROR\] //')"
    log="${JOBS_DIR}/stage-${base}-$(date +%Y%m%d-%H%M%S).log"
    ( _close_lock_fds; umask 077; exec setsid -f "${SELF_DIR}/pbo" catalog materialize "$base" </dev/null >>"$log" 2>&1 ) \
        || die "$EX_SOFTWARE" "catalog: could not start the background staging of $base"
    audit_log "catalog stage-background archive=$base tier=$tier snapshot=${snap:0:8}"
    die "$EX_TEMPFAIL" "pbo started staging $base from the $tier repo (snapshot ${snap:0:8}) in the background${why:+ (the last attempt failed: $why)}; retry in a few minutes (log: $log)"
}

# catalog release [--all]: remove staged archives (and stale .part files) older
# than PVE_STAGING_TTL, or all of them, and every staged archive the index no
# longer lists (its snapshot was pruned: retention must not leave a decrypted
# copy behind); skip one that is being staged right now. A symlink into the mount
# costs a second to make again, so it goes after PVE_STAGING_LINK_TTL (15 min)
# while no process reads through the mount: the mount and its lock on the cache
# repo do not stay up for the 6 h a real copy is kept. Stops pbo-mount.service
# when no staged symlink into it is left and no process reads through it.
# pbo-catalog.service runs it every 15 minutes, before the refresh.
catalog_release() {
    local all=0
    case "${1:-}" in "") ;; --all) all=1 ;; *) die "$EX_USAGE" "unknown catalog release flag: $1 (use --all)" ;; esac
    local dir="$PVE_STAGING_DIR" now cutoff lcutoff f name base removed=0 kept=0 orphaned=0 orphan v fcut
    now="$(date +%s)"; cutoff=$(( now - ${PVE_STAGING_TTL:-21600} )); lcutoff=$(( now - ${PVE_STAGING_LINK_TTL:-900} ))
    local mdir="${PVE_CATALOG_MOUNT_DIR:-/run/pbo/mnt}" mbusy=0
    mdir="${mdir%/}"
    # a restore reading through the mount: its symlinks keep the long TTL
    _catalog_mount_active && _catalog_mount_busy && mbusy=1
    # the archives the index lists; without a readable index nothing counts as orphaned
    local have_idx=0; declare -A known=()
    if _catalog_valid "$PBO_CATALOG"; then
        have_idx=1
        while IFS= read -r v; do [[ -n "$v" ]] && known["${v#backup/}"]=1; done < <(jq -r '.entries[].volname' "$PBO_CATALOG" 2>/dev/null)
    fi
    if [[ -d "$dir" && ! -L "$dir" ]]; then
        while IFS= read -r -d '' f; do
            name="${f##*/}"; base="${name%%.part.*}"
            [[ "$base" =~ $CATALOG_BASENAME_RE ]] || continue
            orphan=0
            (( have_idx )) && [[ "$name" == "$base" && -z "${known[$base]:-}" ]] && orphan=1
            fcut="$cutoff"
            [[ -L "$f" && "$(readlink -- "$f")" == "$mdir"/* ]] && (( ! mbusy )) && fcut="$lcutoff"
            if (( ! all && ! orphan )) && (( $(stat -c %Y -- "$f" 2>/dev/null || echo "$now") > fcut )); then
                kept=$((kept+1)); continue
            fi
            if [[ "${DRY_RUN:-0}" == 1 ]]; then log_info "[dry-run] would remove $f"; removed=$((removed+1)); continue; fi
            # a .part belongs to a running dump while its lock is held
            if ! _catalog_stage_lock "$base" -n; then kept=$((kept+1)); continue; fi
            if rm -f -- "$f"; then
                removed=$((removed+1))
                (( orphan )) && { orphaned=$((orphaned+1)); log_info "catalog: $name is no longer in the catalogue (pruned), removed"; }
            fi
            _catalog_stage_unlock
        done < <(find "$dir" -maxdepth 1 -mindepth 1 \( -type f -o -type l \) -name 'vzdump-*' -print0 2>/dev/null)
    fi
    local stopped=false
    if [[ "${DRY_RUN:-0}" != 1 ]] && _catalog_mount_active; then
        local inuse=0 l
        while IFS= read -r -d '' l; do
            [[ "$(readlink -- "$l")" == "$mdir"/* ]] && inuse=1
        done < <(find "$dir" -maxdepth 1 -mindepth 1 -type l -print0 2>/dev/null)
        # a restore may still read an archive whose symlink is gone (TTL, --all)
        if (( ! inuse )) && _catalog_mount_busy; then
            inuse=1; log_info "catalog: a process still reads through $mdir, $PBO_MOUNT_UNIT keeps running"
        fi
        if (( ! inuse )); then
            log_info "catalog: no staged archive uses the mount, stopping $PBO_MOUNT_UNIT"
            systemctl stop "$PBO_MOUNT_UNIT" >/dev/null 2>&1 && stopped=true || log_warn "catalog: could not stop $PBO_MOUNT_UNIT"
        fi
    fi
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "ok" "true" "removed:n" "$removed" "orphaned:n" "$orphaned" "kept:n" "$kept" "mount_stopped:b" "$stopped"
    else
        local note=""; [[ "$stopped" == true ]] && note=", $PBO_MOUNT_UNIT stopped"
        log_info "catalog: released $removed staged archive(s) ($orphaned no longer in the catalogue), $kept kept$note"
    fi
}

# catalog _mount: run `restic mount` of the cache repo in the foreground at
# PVE_CATALOG_MOUNT_DIR. Internal: the ExecStart of pbo-mount.service.
# --allow-other: Proxmox restores an unprivileged CT by passing the archive's
# open fd to `lxc-usernsexec tar`, which runs as the CT's mapped root (e.g.
# uid 100000); FUSE refuses every request (even fstat on an open fd) from a uid
# other than the mounting one unless allow_other is set, and the restore fails
# with "tar: -: Cannot open: Permission denied". restic keeps
# default_permissions, so file modes still apply, and the parent of the mount
# point must be root-only (checked here), so no local user can walk into it.
catalog_mount_run() {
    _catalog_cache_on || die "$EX_CONFIG" "catalog: only the local cache repo is mounted (LOCAL_REPO=false)"
    local m="${PVE_CATALOG_MOUNT_DIR:-/run/pbo/mnt}"
    m="${m%/}"
    [[ "$m" == /?*/?* && "/$m/" != */./* && "/$m/" != */../* && "$m" != *//* ]] \
        || die "$EX_CONFIG" "catalog: PVE_CATALOG_MOUNT_DIR must be a plain absolute path below a root-only directory, without . or .. (got '$m')"
    ( umask 077; mkdir -p -- "$m" ) || die "$EX_CANTCREAT" "catalog: cannot create $m"
    # the check below must see the directory the mount really sits under: no symlink anywhere
    local real; real="$(readlink -e -- "$m")" || die "$EX_CANTCREAT" "catalog: cannot resolve $m"
    [[ "$real" == "$m" ]] || die "$EX_CONFIG" "catalog: PVE_CATALOG_MOUNT_DIR $m resolves to $real: no symlinks in the mount path (the mount uses allow_other)"
    local parent="${m%/*}" pm
    pm="$(stat -c '%u %a' -- "$parent" 2>/dev/null)" || die "$EX_CANTCREAT" "catalog: cannot stat $parent"
    if [[ "${pm%% *}" != 0 || ! "${pm#* }" =~ ^[0-7]?[0-7]00$ ]]; then
        die "$EX_CONFIG" "catalog: $parent (parent of the mount point) must be owned by root with no group/other access (it is uid ${pm%% *}, mode ${pm#* }): the mount uses allow_other"
    fi
    log_info "catalog: restic mount $(_mask_url "$RESTIC_CACHE_REPO") at $m (allow-other)"
    _restic "$RESTIC_CACHE_REPO" mount --allow-other "$m"
}

# catalog _umount: the ExecStopPost of pbo-mount.service. restic unmounts on
# SIGTERM; this covers a restic that died hard and left a dead FUSE mount
# ("Transport endpoint is not connected"), which would make the next start
# fail. It reads the mount point from the config (PVE_CATALOG_MOUNT_DIR), so
# the unit names no path that can differ from it, and lazily unmounts only a
# FUSE mount there: nothing mounted is fine, any other filesystem (a mistyped
# key pointing at a real mount) is left alone. Never fails the unit's stop.
catalog_umount_run() {
    local m="${PVE_CATALOG_MOUNT_DIR:-/run/pbo/mnt}" fst
    m="${m%/}"
    [[ "$m" == /?* ]] || { log_warn "catalog: PVE_CATALOG_MOUNT_DIR '$m' is not an absolute path: nothing unmounted"; return 0; }
    fst="$(_catalog_mount_fstype "$m")"
    if [[ -z "$fst" ]]; then
        log_info "catalog: nothing mounted at $m"; return 0
    fi
    case "$fst" in
        fuse|fuse.*) ;;
        *) log_warn "catalog: $m is a $fst mount, not restic's FUSE mount: left alone"; return 0 ;;
    esac
    if [[ "${DRY_RUN:-0}" == 1 ]]; then log_info "[dry-run] catalog: would unmount $m (lazy, $fst)"; return 0; fi
    if umount -l -- "$m" 2>/dev/null; then log_info "catalog: unmounted $m (lazy, $fst)"
    else log_warn "catalog: could not unmount $m ($fst)"; fi
    return 0
}

# _catalog_mount_fstype <dir> → the type of the filesystem mounted exactly at
# <dir> (empty: none). findmnt (util-linux); without it the kernel's mount
# table, whose paths escape a blank as \040.
_catalog_mount_fstype() {
    local d="$1" mp ty
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -n -o FSTYPE --mountpoint "$d" 2>/dev/null | tail -1
        return 0
    fi
    while read -r _ mp ty _; do
        mp="${mp//\\040/ }"
        [[ "$mp" == "$d" ]] && printf '%s\n' "$ty"
    done < /proc/self/mounts 2>/dev/null | tail -1
    return 0
}

# _catalog_refresh_hook <what>: after run-schedule and prune, with the
# integration on, refresh the index in a child pbo. A failure is a warning and
# never fails the caller (the pbo-catalog.timer tries again within 15 minutes).
_catalog_refresh_hook() {
    _integration_standalone && return 0
    [[ "${DRY_RUN:-0}" == 1 ]] && return 0
    _is_janitor && return 0
    local out rc=0
    out="$( _close_lock_fds; PBO_NO_NOTIFY=1 "${SELF_DIR}/pbo" catalog refresh 2>&1 )" || rc=$?
    if (( rc == 0 )); then
        log_info "$1: catalogue refreshed"
    else
        log_warn "$1: catalogue refresh failed (exit $rc), the PVE storage view may be stale: $(grep -E '\[ERROR\]' <<<"$out" | tail -1 | sed -E 's/^.*\[ERROR\] //')"
    fi
    return 0
}

# rdo_catalog <subcommand> ...: the `pbo catalog` dispatcher.
rdo_catalog() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        refresh)     catalog_refresh "$@" ;;
        show)        catalog_show "$@" ;;
        materialize) catalog_materialize "$@" ;;
        release)     catalog_release "$@" ;;
        _mount)      catalog_mount_run "$@" ;;
        _umount)     catalog_umount_run "$@" ;;
        *) die "$EX_USAGE" "catalog refresh [--out <file>] | show | materialize [--background] <archive> | release [--all]" ;;
    esac
}
