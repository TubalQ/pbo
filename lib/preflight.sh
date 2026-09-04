# shellcheck shell=bash
# lib/preflight.sh — checks BEFORE a backup (PLAN.md §6, IMPL step 2).
#
# Hard requirements (FAIL → abort backup):
#   - the container exists      (pct config <vmid>)
#   - ZFS pool free ≥ 1.5 × used size of the volumes to be backed up
#   - the cache directory exists and is writable
#   - the rclone remote responds (rclone about)
# Warnings (WARN → continue, but record in meta):
#   - bind mounts (NEVER backed up, silently skipped by vzdump)
#   - volumes with backup=0 (excluded)
#
# All external commands (pct/zfs/zpool/rclone) go via PATH → mockable in tests.

# Global result collectors (reset per run).
PF_CHECKS_JSON=""       # array elements for --json
PF_WARNINGS=()          # human-readable warnings
PF_BINDMOUNTS=()        # "mp1=/srv/host" for meta.json (step 3)
PF_EXCLUDED=()          # "mp0" volumes with backup=0
PF_FAIL=0

_pf_add_check() { # <name> <ok:true|false> <detail>
    local sep=""; [[ -n "$PF_CHECKS_JSON" ]] && sep=","
    PF_CHECKS_JSON+="${sep}{\"name\":\"$(json_escape "$1")\",\"ok\":$2,\"detail\":\"$(json_escape "$3")\"}"
    if [[ "$2" == "true" ]]; then
        log_info "preflight: $1 — OK ($3)"
    else
        log_error "preflight: $1 — ERROR ($3)"
        PF_FAIL=1
    fi
}

# Storage type for a storeid (zfspool/lvmthin/dir/…) from storage.cfg.
_pf_storage_type() {
    awk -v id="$1" '/^[a-z]+:[[:space:]]*[^ ]/{ ty=$1; sub(/:$/,"",ty); if($2==id){print ty; exit} }' \
        /etc/pve/storage.cfg 2>/dev/null
}

# Build a storeid→pool map from storage.cfg (zfspool type only).
_pf_pool_for_storeid() {
    local want="$1"
    awk -v want="$want" '
        /^zfspool:/ { id=$2; next }
        /^[a-z]+:/  { id="" }          # new block type, reset
        id!="" && $1=="pool" { map[id]=$2 }
        END { print (want in map) ? map[want] : want }
    ' /etc/pve/storage.cfg 2>/dev/null || printf '%s' "$want"
}

# Parse `pct config <vmid>` → find rootfs + mpN, classify bind-mount/backup=0,
# and collect (pool, dataset) for the volumes that will actually be backed up.
# Fills the global PF_BACKUP_VOLUMES=("pool|dataset" ...).
_pf_parse_volumes() {
    local vmid="$1" conf
    if ! conf="$(pct config "$vmid" 2>/dev/null)"; then
        _pf_add_check "container_exists" "false" "vmid $vmid: pct config failed"
        return 1
    fi
    _pf_add_check "container_exists" "true" "vmid $vmid exists"

    PF_BACKUP_VOLUMES=()
    local line key val volspec opts
    while IFS= read -r line; do
        key="${line%%:*}"
        [[ "$key" == "rootfs" || "$key" =~ ^mp[0-9]+$ ]] || continue
        val="${line#*: }"
        volspec="${val%%,*}"        # "storeid:volume" OR "/host/path"
        opts=",${val#*,},"          # wrap with commas for safe matching

        # Bind mount: volspec is an absolute path, not storeid:volume.
        if [[ "$volspec" == /* ]]; then
            PF_WARNINGS+=("$key is a bind mount ($volspec) — NEVER backed up by vzdump")
            PF_BINDMOUNTS+=("$key=$volspec")
            continue
        fi
        # Excluded volume (backup=0).
        if [[ "$opts" == *",backup=0,"* ]]; then
            PF_WARNINGS+=("$key ($volspec) has backup=0 — excluded from the archive")
            PF_EXCLUDED+=("$key")
            continue
        fi
        # Volume to be backed up: ZFS volumes get a ZFS space check, others (LVM/dir)
        # are skipped (vzdump handles their snapshot space itself).
        local storeid="${volspec%%:*}" volume="${volspec#*:}" pool st
        st="$(_pf_storage_type "$storeid")"
        if [[ "$st" == "zfspool" ]]; then
            pool="$(_pf_pool_for_storeid "$storeid")"
            PF_BACKUP_VOLUMES+=("$pool|$pool/$volume")
        else
            PF_NONZFS_VOLUMES+=("$key=$storeid:$volume(${st:-unknown})")
        fi
    done <<<"$conf"
    return 0
}

# ZFS space: per involved pool, require free ≥ 1.5 × sum of the volumes' used.
_pf_check_zfs_space() {
    if [[ "${#PF_BACKUP_VOLUMES[@]}" -eq 0 ]]; then
        if [[ "${#PF_NONZFS_VOLUMES[@]}" -gt 0 ]]; then
            _pf_add_check "zfs_space" "true" "no ZFS volumes (${PF_NONZFS_VOLUMES[*]}) — ZFS space check skipped"
        else
            _pf_add_check "zfs_space" "false" "no backable volumes found"
        fi
        return 0
    fi
    # Sum used per pool.
    declare -A used_by_pool=()
    local entry pool ds u
    for entry in "${PF_BACKUP_VOLUMES[@]}"; do
        pool="${entry%%|*}"; ds="${entry#*|}"
        u="$(zfs list -Hpo used "$ds" 2>/dev/null)" || u=""
        [[ "$u" =~ ^[0-9]+$ ]] || {
            _pf_add_check "zfs_space" "false" "cannot read 'used' for dataset $ds"
            return 1
        }
        used_by_pool[$pool]=$(( ${used_by_pool[$pool]:-0} + u ))
    done
    # Check each pool.
    local free need ok_all=1 detail=""
    for pool in "${!used_by_pool[@]}"; do
        free="$(zpool list -Hpo free "$pool" 2>/dev/null)" || free=""
        [[ "$free" =~ ^[0-9]+$ ]] || {
            _pf_add_check "zfs_space" "false" "cannot read free for pool $pool"
            return 1
        }
        need=$(( used_by_pool[$pool] * 3 / 2 ))   # 1.5×
        detail+="${pool}: free=$(_pf_h "$free") need=$(_pf_h "$need"); "
        (( free >= need )) || ok_all=0
    done
    _pf_add_check "zfs_space" "$( ((ok_all)) && echo true || echo false )" "${detail%%; }"
}

# Cache directory: exists and is writable.
_pf_check_cache() {
    if mkdir -p "$CACHE_DIR" 2>/dev/null && [[ -w "$CACHE_DIR" ]]; then
        local free; free="$(df -PB1 "$CACHE_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
        _pf_add_check "cache_writable" "true" "$CACHE_DIR writable (free $(_pf_h "${free:-0}"))"
    else
        _pf_add_check "cache_writable" "false" "$CACHE_DIR missing or not writable"
    fi
}

# restic repo responds (ENGINE=restic) OR rclone remote responds (ENGINE=tar).
_pf_check_rclone() {
    if [[ "${ENGINE:-tar}" == "restic" ]]; then
        if [[ "${OFFSITE_ENABLED:-true}" != "true" || -z "${RESTIC_OFFSITE_REPO:-}" ]]; then
            _pf_add_check "restic_repo" "true" "offsite disabled — skipping repo check"
            return
        fi
        if _restic "$(_restic_read_repo)" cat config >/dev/null 2>&1; then
            _pf_add_check "restic_repo" "true" "repo '$(_restic_read_repo)' reachable"
        else
            _pf_add_check "restic_repo" "false" "repo '$(_restic_read_repo)' not responding / not initialized"
        fi
        return
    fi
    if ! command -v rclone >/dev/null 2>&1; then
        _pf_add_check "rclone_remote" "false" "rclone not installed (required on the host)"
        return
    fi
    # `rclone mkdir` on the target directory instead of `about`/`lsd`:
    #   - about: the Storage Box's limited shell often lacks df → false failure.
    #   - lsd: fails on the FIRST backup (crypt base dir doesn't exist yet → "not found").
    # mkdir is idempotent, proves reachability + write access, and prepares the target.
    if rclone mkdir "${RCLONE_REMOTE}:${REMOTE_PATH}" >/dev/null 2>&1; then
        _pf_add_check "rclone_remote" "true" "remote '${RCLONE_REMOTE}:${REMOTE_PATH}' reachable + writable"
    else
        _pf_add_check "rclone_remote" "false" "remote '${RCLONE_REMOTE}:${REMOTE_PATH}' not responding / not writable"
    fi
}

# Bytes → human-readable (GiB/MiB), integer math.
_pf_h() {
    local b="${1:-0}"
    if   (( b >= 1073741824 )); then printf '%d.%02dG' $(( b/1073741824 )) $(( (b%1073741824)*100/1073741824 ))
    elif (( b >= 1048576 ));    then printf '%dM' $(( b/1048576 ))
    else printf '%dB' "$b"; fi
}

# Main entry: run_preflight <vmid> → 0 if all hard requirements ok, else EX_UNAVAILABLE.
run_preflight() {
    local vmid="$1"
    PF_CHECKS_JSON=""; PF_WARNINGS=(); PF_BINDMOUNTS=(); PF_EXCLUDED=(); PF_FAIL=0
    PF_BACKUP_VOLUMES=(); PF_NONZFS_VOLUMES=()

    if _pf_parse_volumes "$vmid"; then
        _pf_check_zfs_space
    fi
    _pf_check_cache
    _pf_check_rclone

    # Warnings are logged (and included in meta in step 3).
    local w
    for w in "${PF_WARNINGS[@]:-}"; do [[ -n "$w" ]] && log_warn "preflight: $w"; done

    (( PF_FAIL == 0 )) && return "$EX_OK" || return "$EX_UNAVAILABLE"
}

# Emit the preflight result as JSON (for the GUI and --json).
emit_preflight_json() {
    local vmid="$1" rc="$2"
    local warns="" b sep=""
    for b in "${PF_WARNINGS[@]:-}"; do
        [[ -n "$b" ]] || continue
        warns+="${sep}\"$(json_escape "$b")\""; sep=","
    done
    printf '{"command":"preflight","status":"%s","ok":%s,"dry_run":%s,"vmid":"%s","checks":[%s],"warnings":[%s]}\n' \
        "$( ((rc==0)) && echo ready || echo not_ready )" \
        "$( ((rc==0)) && echo true || echo false )" \
        "$( [[ "${DRY_RUN:-0}" == 1 ]] && echo true || echo false )" \
        "$(json_escape "$vmid")" "$PF_CHECKS_JSON" "$warns"
}
