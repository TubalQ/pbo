# shellcheck shell=bash
# lib/prune.sh — steg 7: prune av cache (KEEP_LOCAL) och offsite (GFS).
#
# Hårda regler (PLAN.md §5, IMPL steg 7):
#   - Radera ALDRIG det senaste arkivet per vmid, oavsett policy.
#   - Måste stödja --dry-run.
#   - Radera aldrig något offsite om inget behållet arkiv för den vmid:en har en
#     verifierbar sha256-sidecar (annars kan vi inte intyga att en god kopia finns).
#
# GFS offsite: behåll senaste per dag (KEEP_OFFSITE_DAILY dagar), per ISO-vecka
# (KEEP_OFFSITE_WEEKLY), per månad (KEEP_OFFSITE_MONTHLY). Union behålls.

# Extrahera tidsstämpeln (YYYY_MM_DD-HH_MM_SS) ur ett arkivnamn.
_archive_ts() { [[ "$1" =~ ([0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}) ]] && printf '%s' "${BASH_REMATCH[1]}"; }
# → "YYYY-MM-DD HH:MM:SS" för `date -d`.
_ts_to_date() { local t="$1"; printf '%s-%s-%s %s:%s:%s' "${t:0:4}" "${t:5:2}" "${t:8:2}" "${t:11:2}" "${t:14:2}" "${t:17:2}"; }

# _gfs_keep — läser arkivnamn (en per rad, valfri ordning) på stdin, skriver de
# som ska BEHÅLLAS på stdout. Använder KEEP_OFFSITE_{DAILY,WEEKLY,MONTHLY}.
_gfs_keep() {
    local -a names=(); local n
    while IFS= read -r n; do [[ -n "$n" ]] && names+=("$n"); done
    [[ "${#names[@]}" -gt 0 ]] || return 0
    # Sortera fallande — arkivnamn har zero-paddad ts (YYYY_MM_DD-HH_MM_SS) så
    # lexikalt fallande = kronologiskt nyast först.
    local -a sorted
    mapfile -t sorted < <(printf '%s\n' "${names[@]}" | sort -r)
    declare -A seen_d=() seen_w=() seen_m=()
    local kept_d=0 kept_w=0 kept_m=0 first=1
    local name ts ds dk wk mk keep
    for name in "${sorted[@]}"; do
        ts="$(_archive_ts "$name")"; [[ -n "$ts" ]] || continue
        ds="$(_ts_to_date "$ts")"
        dk="$(date -d "$ds" +%Y-%m-%d 2>/dev/null)"
        wk="$(date -d "$ds" +%G-W%V 2>/dev/null)"
        mk="$(date -d "$ds" +%Y-%m 2>/dev/null)"
        keep=0
        (( first )) && keep=1                                   # senaste alltid
        if [[ -z "${seen_d[$dk]:-}" && $kept_d -lt ${KEEP_OFFSITE_DAILY:-7} ]]; then keep=1; fi
        if [[ -z "${seen_w[$wk]:-}" && $kept_w -lt ${KEEP_OFFSITE_WEEKLY:-4} ]]; then keep=1; fi
        if [[ -z "${seen_m[$mk]:-}" && $kept_m -lt ${KEEP_OFFSITE_MONTHLY:-6} ]]; then keep=1; fi
        if (( keep )); then
            [[ -z "${seen_d[$dk]:-}" ]] && { seen_d[$dk]=1; kept_d=$((kept_d+1)); }
            [[ -z "${seen_w[$wk]:-}" ]] && { seen_w[$wk]=1; kept_w=$((kept_w+1)); }
            [[ -z "${seen_m[$mk]:-}" ]] && { seen_m[$mk]=1; kept_m=$((kept_m+1)); }
            printf '%s\n' "$name"
        fi
        first=0
    done
}

PRUNE_CACHE_DELETED=(); PRUNE_OFFSITE_DELETED=()

# Cache: behåll KEEP_LOCAL nyaste per vmid, radera äldre (arkiv + sidecars).
prune_cache() {
    local vdir vmid archives keep_n="${KEEP_LOCAL:-2}"
    for vdir in "$CACHE_DIR"/*/; do
        [[ -d "$vdir" ]] || continue
        vmid="$(basename "$vdir")"
        [[ "$vmid" == "restore" ]] && continue
        mapfile -t archives < <(ls -1 "$vdir"/vzdump-lxc-"$vmid"-*.tar.zst 2>/dev/null | sort -r)
        local i=0 a
        for a in "${archives[@]}"; do
            if (( i < keep_n )); then i=$((i+1)); continue; fi
            PRUNE_CACHE_DELETED+=("$vmid:$(basename "$a")")
            if [[ "${DRY_RUN:-0}" != 1 ]]; then
                rm -f "$a" "$a".sha256 "$a".meta.json "$a".conf
                log_info "prune cache: raderade $(basename "$a")"
            else
                log_info "[dry-run] prune cache: skulle radera $(basename "$a")"
            fi
        done
    done
}

# Offsite: GFS per vmid. Skydd: skippa vmid om inget behållet arkiv har sha256.
prune_offsite() {
    local base="${RCLONE_REMOTE}:${REMOTE_PATH}"
    local vmids v files keep del a
    vmids="$(_list_vmids)"
    for v in $vmids; do
        mapfile -t files < <(rclone lsf "$base/$v" 2>/dev/null | grep -E '\.tar\.zst$' || true)
        [[ "${#files[@]}" -gt 0 ]] || continue
        mapfile -t keep < <(printf '%s\n' "${files[@]}" | _gfs_keep)
        # Skydd: minst ett behållet arkiv måste ha en sha256-sidecar offsite.
        local has_verified=0 sidecars
        sidecars="$(rclone lsf "$base/$v" 2>/dev/null | grep -E '\.sha256$' || true)"
        for a in "${keep[@]}"; do grep -qF "${a}.sha256" <<<"$sidecars" && { has_verified=1; break; }; done
        if (( ! has_verified )); then
            log_warn "prune offsite: vmid $v — inget behållet arkiv har sha256, HOPPAR (kan ej intyga god kopia)"
            continue
        fi
        # Radera de som inte är i keep-listan.
        local f in_keep
        for f in "${files[@]}"; do
            in_keep=0; for a in "${keep[@]}"; do [[ "$f" == "$a" ]] && { in_keep=1; break; }; done
            (( in_keep )) && continue
            PRUNE_OFFSITE_DELETED+=("$v:$f")
            if [[ "${DRY_RUN:-0}" != 1 ]]; then
                rclone delete "$base/$v" --include "${f}*" >/dev/null 2>&1 \
                    && log_info "prune offsite: raderade $v/$f (+sidecars)" \
                    || log_warn "prune offsite: kunde ej radera $v/$f"
            else
                log_info "[dry-run] prune offsite: skulle radera $v/$f (+sidecars)"
            fi
        done
    done
}

do_prune() {
    if [[ "${ENGINE:-tar}" == "restic" ]]; then rdo_prune; return $?; fi
    PRUNE_CACHE_DELETED=(); PRUNE_OFFSITE_DELETED=()
    prune_cache
    [[ "${OFFSITE_ENABLED:-true}" == "true" ]] && prune_offsite || log_info "prune: OFFSITE_ENABLED=false → hoppar offsite."

    if [[ "${DRY_RUN:-0}" != 1 && $(( ${#PRUNE_CACHE_DELETED[@]} + ${#PRUNE_OFFSITE_DELETED[@]} )) -gt 0 ]]; then
        audit_log "prune cache=${#PRUNE_CACHE_DELETED[@]} offsite=${#PRUNE_OFFSITE_DELETED[@]} offsite_list=[${PRUNE_OFFSITE_DELETED[*]:-}]"
    fi

    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        local c o
        c="$(mk_json_array PRUNE_CACHE_DELETED)"; o="$(mk_json_array PRUNE_OFFSITE_DELETED)"
        printf '{"command":"prune","status":"ok","ok":true,"dry_run":%s,"cache_deleted":%s,"offsite_deleted":%s}\n' \
            "$( [[ "${DRY_RUN:-0}" == 1 ]] && echo true || echo false )" "$c" "$o"
    else
        log_info "prune: cache raderade ${#PRUNE_CACHE_DELETED[@]}, offsite raderade ${#PRUNE_OFFSITE_DELETED[@]}$( [[ "${DRY_RUN:-0}" == 1 ]] && echo ' (dry-run)')"
    fi
    return "$EX_OK"
}
