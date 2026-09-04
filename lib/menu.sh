# shellcheck shell=bash
# lib/menu.sh — interaktivt prompt-CLI (rclone config-stil). Ren bash, noll
# beroenden, inget alternate-screen → funkar identiskt över SSH/serial/tmux.
# Aktiveras med `lxc-offsite menu`. Ersätter Textual-TUI:n som interaktivt gränssnitt.
#
# All affärslogik ligger kvar i CLI:t; menyn shell:ar ut till `$LXCO_BIN` (eller
# läser --json). Config-ändringar (BACKUP_ORDER) skrivs atomiskt 0600.

LXCO_BIN="${LXCO_SELF_BIN:-${SELF_DIR}/lxc-offsite}"

# --- färger (av om ej tty) ---
if [[ -t 1 ]]; then
    C_B=$'\033[1m'; C_D=$'\033[2m'; C_G=$'\033[32m'; C_C=$'\033[36m'
    C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
    C_B=""; C_D=""; C_G=""; C_C=""; C_Y=""; C_R=""; C_0=""
fi

_ask()   { local p="$1" d="${2:-}" a; read -r -p "$p${d:+ [$d]}: " a; printf '%s' "${a:-$d}"; }
_askpw() { local p="$1" a; read -r -s -p "$p: " a; echo >&2; printf '%s' "$a"; }
_pause() { read -r -p "${C_D}— Enter för att fortsätta —${C_0} " _; }
_yn()    { local a; a="$(_ask "$1 (j/n)" "${2:-n}")"; [[ "$a" == [jJyY]* ]]; }

# Skriv/uppdatera KEY=VALUE i configen (atomiskt, 0600) + uppdatera i minnet.
_cfg_set() {
    local k="$1" v="$2" cfg="${LXCO_CONFIG_LOADED:-${LXCO_CONFIG:-/etc/lxc-offsite/config}}" tmp
    [[ -f "$cfg" ]] || { printf 'config saknas: %s\n' "$cfg" >&2; return 1; }
    tmp="$(mktemp)"
    if grep -qE "^${k}=" "$cfg"; then sed "s|^${k}=.*|${k}=${v}|" "$cfg" > "$tmp"
    else { cat "$cfg"; printf '%s=%s\n' "$k" "$v"; } > "$tmp"; fi
    chmod 600 "$tmp"; mv "$tmp" "$cfg"
    [[ "$k" == "BACKUP_ORDER" ]] && BACKUP_ORDER="$v"
}

# Klustergäster som TSV: vmid \t name \t type \t node \t status
_menu_guests_tsv() {
    pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
        | jq -r 'sort_by(.vmid)[] | "\(.vmid)\t\(.name // "-")\t\(.type)\t\(.node)\t\(.status)"' 2>/dev/null
}
_is_protected() { local v="$1"; [[ ",${BACKUP_ORDER//[[:space:]]/}," == *",$v,"* ]]; }

# --- header ---
_menu_header() {
    clear 2>/dev/null || printf '\n'
    local repo="${RESTIC_OFFSITE_REPO:-${RCLONE_REMOTE:-—}}"
    local prot; prot="$(tr ',' ' ' <<<"${BACKUP_ORDER:-}" | wc -w)"
    printf '%s┌─ %sPBO%s%s · Proxmox Backup Offsite ────────────────────────┐%s\n' "$C_C" "$C_B" "$C_0$C_C" "" "$C_0"
    printf '%s│%s motor %s%s%s · offsite %s%s%s · skyddade %s%s%s\n' \
        "$C_C" "$C_0" "$C_B" "${ENGINE:-tar}" "$C_0" "$C_C" "$repo" "$C_0" "$C_B" "$prot" "$C_0"
    printf '%s└───────────────────────────────────────────────────────────┘%s\n' "$C_C" "$C_0"
}

# --- 2. GÄSTER: scan / add / delete (hantera BACKUP_ORDER) ---
menu_guests() {
    while true; do
        _menu_header
        printf '%s Gäster — scanna klustret, lägg till/ta bort ur backup%s\n\n' "$C_B" "$C_0"
        printf '  %-6s %-22s %-5s %-9s %-9s %s\n' "VMID" "NAMN" "TYP" "NOD" "STATUS" "SKYDDAD"
        printf '  %s\n' "-------------------------------------------------------------------"
        local v n t nd st mark new
        while IFS=$'\t' read -r v n t nd st; do
            [[ -n "$v" ]] || continue
            if _is_protected "$v"; then mark="${C_G}✓ ja${C_0}"; new=""
            else mark="${C_D}—${C_0}"; new=" ${C_Y}(ny)${C_0}"; fi
            printf '  %-6s %-22s %-5s %-9s %-9s %b%b\n' "$v" "${n:0:22}" "$t" "$nd" "$st" "$mark" "$new"
        done < <(_menu_guests_tsv)
        printf '\n  %s[a]%s skydda (lägg till)   %s[d]%s ta bort skydd   %s[r]%s uppdatera   %s[0]%s tillbaka\n' \
            "$C_B" "$C_0" "$C_B" "$C_0" "$C_B" "$C_0" "$C_B" "$C_0"
        local c; c="$(_ask "Val" )"
        case "$c" in
            a) local id; id="$(_ask "VMID att skydda")"
               if [[ "$id" =~ ^[0-9]+$ ]] && _menu_guests_tsv | grep -q "^$id	"; then
                   _is_protected "$id" && { echo "  redan skyddad."; } || {
                       local order; order="$(tr ',' ' ' <<<"$BACKUP_ORDER") $id"
                       _cfg_set BACKUP_ORDER "$(echo $order | tr ' ' ',' | sed 's/^,//')"
                       echo "  ${C_G}skyddad: $id${C_0}"; }
               else echo "  ${C_R}okänt vmid $id${C_0}"; fi; _pause ;;
            d) local id; id="$(_ask "VMID att ta bort ur backup")"
               local order=(); local x
               for x in $(tr ',' ' ' <<<"$BACKUP_ORDER"); do [[ "$x" == "$id" ]] || order+=("$x"); done
               _cfg_set BACKUP_ORDER "$(IFS=,; echo "${order[*]}")"
               echo "  ${C_Y}borttagen ur backup: $id${C_0}"; _pause ;;
            r) : ;;
            0|"") return ;;
            *) : ;;
        esac
    done
}

# --- 3. BACKUP ---
menu_backup() {
    _menu_header
    printf '%s Säkerhetskopiera%s\n\n' "$C_B" "$C_0"
    printf '  %s[1]%s Alla skyddade — en i taget (stream)\n' "$C_B" "$C_0"
    printf '  %s[2]%s Alla skyddade — allt direkt (batch)\n' "$C_B" "$C_0"
    printf '  %s[3]%s Välj en gäst\n' "$C_B" "$C_0"
    printf '  %s[0]%s tillbaka\n\n' "$C_B" "$C_0"
    local c; c="$(_ask "Val")"
    case "$c" in
        1) _yn "Backa upp alla skyddade (stream)?" j && { "$LXCO_BIN" run-schedule --stream; _pause; } ;;
        2) _yn "Backa upp alla skyddade (batch)?" j && { "$LXCO_BIN" run-schedule --batch; _pause; } ;;
        3) local id; id="$(_ask "VMID att backa upp")"
           [[ "$id" =~ ^[0-9]+$ ]] && _yn "Backa upp $id nu?" j && { "$LXCO_BIN" backup "$id"; _pause; } ;;
        *) : ;;
    esac
}

# --- 5. STATUS ---
menu_status() {
    _menu_header
    printf '%s Status%s\n\n' "$C_B" "$C_0"
    printf '  Hämtar från repot…\n'
    "$LXCO_BIN" --json list 2>/dev/null | jq -r '
        .archives as $a | "  gäster med snapshots: \($a|map(.vmid)|unique|length)\n  snapshots totalt:     \($a|length)\n  logisk storlek:       \(($a|map(.size_bytes|tonumber)|add // 0)/1e9*10|floor/10) GB"' 2>/dev/null \
        || echo "  (kunde ej läsa list)"
    if [[ "${ENGINE:-tar}" == "restic" ]]; then
        "$LXCO_BIN" --json usage 2>/dev/null | jq -r '"  fysiskt offsite:      \(.physical_bytes/1e9*10|floor/10) GB (dedup \(.compression_ratio)×)"' 2>/dev/null
    fi
    printf '\n  senaste timer-körning:\n'; systemctl list-timers lxc-offsite.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/    /'
    echo; _pause
}

# --- huvudmeny ---
menu_main() {
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq krävs för menyn (apt install jq)"
    while true; do
        _menu_header
        printf '\n'
        printf '  %s[1]%s Setup / onboarding        %s[4]%s Exportera DR-nyckel\n' "$C_B" "$C_0" "$C_B" "$C_0"
        printf '  %s[2]%s Gäster (scan/add/delete)  %s[5]%s Status\n' "$C_B" "$C_0" "$C_B" "$C_0"
        printf '  %s[3]%s Säkerhetskopiera          %s[6]%s Återställ\n' "$C_B" "$C_0" "$C_B" "$C_0"
        printf '  %s[7]%s Underhåll (prune/verify)  %s[0]%s Avsluta\n\n' "$C_B" "$C_0" "$C_B" "$C_0"
        local c; c="$(_ask "Val")"
        case "$c" in
            1) printf '  (Setup-wizard kommer i nästa bit.)\n'; _pause ;;
            2) menu_guests ;;
            3) menu_backup ;;
            4) printf '  (Export-nyckel kommer i nästa bit — tills dess: cat %s)\n' "${RESTIC_PASSWORD_FILE:-/etc/lxc-offsite/restic-pass}"; _pause ;;
            5) menu_status ;;
            6) printf '  (Återställ kommer i nästa bit.)\n'; _pause ;;
            7) printf '  (Underhåll kommer i nästa bit.)\n'; _pause ;;
            0|q|"") clear 2>/dev/null || true; return "$EX_OK" ;;
            *) : ;;
        esac
    done
}
