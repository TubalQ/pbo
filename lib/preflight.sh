# shellcheck shell=bash
# lib/preflight.sh — kontroller INNAN en backup (PLAN.md §6, IMPL steg 2).
#
# Hårda krav (FAIL → avbryt backup):
#   - containern finns          (pct config <vmid>)
#   - ZFS-pool free ≥ 1.5 × använd storlek för de volymer som ska backas
#   - cache-katalogen finns och är skrivbar
#   - rclone-remote svarar       (rclone about)
# Varningar (WARN → fortsätt, men skriv in i meta):
#   - bind-mounts (backas ALDRIG upp, hoppas tyst av vzdump)
#   - volymer med backup=0 (exkluderade)
#
# Alla externa kommandon (pct/zfs/zpool/rclone) går via PATH → mockbara i test.

# Globala resultatsamlare (nollställs per körning).
PF_CHECKS_JSON=""       # array-element för --json
PF_WARNINGS=()          # människoläsbara varningar
PF_BINDMOUNTS=()        # "mp1=/srv/host" för meta.json (steg 3)
PF_EXCLUDED=()          # "mp0" volymer med backup=0
PF_FAIL=0

_pf_add_check() { # <namn> <ok:true|false> <detalj>
    local sep=""; [[ -n "$PF_CHECKS_JSON" ]] && sep=","
    PF_CHECKS_JSON+="${sep}{\"name\":\"$(json_escape "$1")\",\"ok\":$2,\"detail\":\"$(json_escape "$3")\"}"
    if [[ "$2" == "true" ]]; then
        log_info "preflight: $1 — OK ($3)"
    else
        log_error "preflight: $1 — FEL ($3)"
        PF_FAIL=1
    fi
}

# Bygg storeid→pool-karta ur storage.cfg (endast zfspool-typ).
_pf_pool_for_storeid() {
    local want="$1"
    awk -v want="$want" '
        /^zfspool:/ { id=$2; next }
        /^[a-z]+:/  { id="" }          # ny block-typ, nolla
        id!="" && $1=="pool" { map[id]=$2 }
        END { print (want in map) ? map[want] : want }
    ' /etc/pve/storage.cfg 2>/dev/null || printf '%s' "$want"
}

# Parsa `pct config <vmid>` → hitta rootfs + mpN, klassa bind-mount/backup=0,
# och samla (pool, dataset) för de volymer som faktiskt ska backas upp.
# Fyller globalen PF_BACKUP_VOLUMES=("pool|dataset" ...).
_pf_parse_volumes() {
    local vmid="$1" conf
    if ! conf="$(pct config "$vmid" 2>/dev/null)"; then
        _pf_add_check "container_exists" "false" "vmid $vmid: pct config misslyckades"
        return 1
    fi
    _pf_add_check "container_exists" "true" "vmid $vmid finns"

    PF_BACKUP_VOLUMES=()
    local line key val volspec opts
    while IFS= read -r line; do
        key="${line%%:*}"
        [[ "$key" == "rootfs" || "$key" =~ ^mp[0-9]+$ ]] || continue
        val="${line#*: }"
        volspec="${val%%,*}"        # "storeid:volume" ELLER "/host/path"
        opts=",${val#*,},"          # omgärda med komma för säker matchning

        # Bind-mount: volspec är en absolut sökväg, inte storeid:volume.
        if [[ "$volspec" == /* ]]; then
            PF_WARNINGS+=("$key är en bind-mount ($volspec) — backas ALDRIG upp av vzdump")
            PF_BINDMOUNTS+=("$key=$volspec")
            continue
        fi
        # Exkluderad volym (backup=0).
        if [[ "$opts" == *",backup=0,"* ]]; then
            PF_WARNINGS+=("$key ($volspec) har backup=0 — exkluderas från arkivet")
            PF_EXCLUDED+=("$key")
            continue
        fi
        # Volym som ska backas: mappa till ZFS-dataset.
        local storeid="${volspec%%:*}" volume="${volspec#*:}" pool
        pool="$(_pf_pool_for_storeid "$storeid")"
        PF_BACKUP_VOLUMES+=("$pool|$pool/$volume")
    done <<<"$conf"
    return 0
}

# ZFS-utrymme: per involverad pool, kräv free ≥ 1.5 × summan av volymernas used.
_pf_check_zfs_space() {
    [[ "${#PF_BACKUP_VOLUMES[@]}" -gt 0 ]] || {
        _pf_add_check "zfs_space" "false" "inga backup-bara volymer hittades"
        return 1
    }
    # Summera used per pool.
    declare -A used_by_pool=()
    local entry pool ds u
    for entry in "${PF_BACKUP_VOLUMES[@]}"; do
        pool="${entry%%|*}"; ds="${entry#*|}"
        u="$(zfs list -Hpo used "$ds" 2>/dev/null)" || u=""
        [[ "$u" =~ ^[0-9]+$ ]] || {
            _pf_add_check "zfs_space" "false" "kan inte läsa 'used' för dataset $ds"
            return 1
        }
        used_by_pool[$pool]=$(( ${used_by_pool[$pool]:-0} + u ))
    done
    # Kontrollera varje pool.
    local free need ok_all=1 detail=""
    for pool in "${!used_by_pool[@]}"; do
        free="$(zpool list -Hpo free "$pool" 2>/dev/null)" || free=""
        [[ "$free" =~ ^[0-9]+$ ]] || {
            _pf_add_check "zfs_space" "false" "kan inte läsa free för pool $pool"
            return 1
        }
        need=$(( used_by_pool[$pool] * 3 / 2 ))   # 1.5×
        detail+="${pool}: free=$(_pf_h "$free") behov=$(_pf_h "$need"); "
        (( free >= need )) || ok_all=0
    done
    _pf_add_check "zfs_space" "$( ((ok_all)) && echo true || echo false )" "${detail%%; }"
}

# Cache-katalog: finns och är skrivbar.
_pf_check_cache() {
    if mkdir -p "$CACHE_DIR" 2>/dev/null && [[ -w "$CACHE_DIR" ]]; then
        local free; free="$(df -PB1 "$CACHE_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
        _pf_add_check "cache_writable" "true" "$CACHE_DIR skrivbar (fritt $(_pf_h "${free:-0}"))"
    else
        _pf_add_check "cache_writable" "false" "$CACHE_DIR saknas eller ej skrivbar"
    fi
}

# rclone-remote svarar.
_pf_check_rclone() {
    if ! command -v rclone >/dev/null 2>&1; then
        _pf_add_check "rclone_remote" "false" "rclone ej installerat (krävs på hosten)"
        return
    fi
    if rclone about "${RCLONE_REMOTE}:" >/dev/null 2>&1; then
        _pf_add_check "rclone_remote" "true" "remote '${RCLONE_REMOTE}:' svarar"
    else
        _pf_add_check "rclone_remote" "false" "remote '${RCLONE_REMOTE}:' svarar inte"
    fi
}

# Bytes → människoläsbart (GiB/MiB), heltalsmatte.
_pf_h() {
    local b="${1:-0}"
    if   (( b >= 1073741824 )); then printf '%d.%02dG' $(( b/1073741824 )) $(( (b%1073741824)*100/1073741824 ))
    elif (( b >= 1048576 ));    then printf '%dM' $(( b/1048576 ))
    else printf '%dB' "$b"; fi
}

# Huvudingång: run_preflight <vmid> → 0 om alla hårda krav ok, annars EX_UNAVAILABLE.
run_preflight() {
    local vmid="$1"
    PF_CHECKS_JSON=""; PF_WARNINGS=(); PF_BINDMOUNTS=(); PF_EXCLUDED=(); PF_FAIL=0
    PF_BACKUP_VOLUMES=()

    if _pf_parse_volumes "$vmid"; then
        _pf_check_zfs_space
    fi
    _pf_check_cache
    _pf_check_rclone

    # Varningar loggas (och tas med i meta i steg 3).
    local w
    for w in "${PF_WARNINGS[@]:-}"; do [[ -n "$w" ]] && log_warn "preflight: $w"; done

    (( PF_FAIL == 0 )) && return "$EX_OK" || return "$EX_UNAVAILABLE"
}

# Emittera preflight-resultat som JSON (för GUI:t och --json).
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
