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
    if [[ "$k" == "BACKUP_ORDER" ]]; then BACKUP_ORDER="$v"; fi
    return 0
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

# --- SETUP WIZARD (English — used by `pbo setup`, install.sh, and the menu) ---
run_setup_wizard() {
    set +e +u
    printf '\n%s=== PBO · Proxmox Backup Offsite — setup ===%s\n\n' "$C_B" "$C_0"
    local eng; eng="$(_ask "Backup engine (restic/tar)" "restic")"
    if [[ "$eng" != "restic" ]]; then _cfg_set ENGINE tar; echo "  ENGINE=tar set."; return 0; fi
    _cfg_set ENGINE restic

    # --- cache tier ---
    printf '\n%sCache = a local restic repo for fast local restores (needs disk space).\n%s' "$C_D" "$C_0"
    local cdir
    if _yn "Do you have local cache space you want to use?" n; then
        cdir="$(_ask "Where should the cache live? (path)" "/var/cache/lxc-offsite")"
        mkdir -p "$cdir" 2>/dev/null
        _cfg_set LOCAL_REPO true
        _cfg_set CACHE_DIR "$cdir"
        _cfg_set RESTIC_CACHE_REPO "$cdir/repo"
        echo "  Cached mode: local repo at $cdir/repo + copy to offsite."
    else
        cdir="$(_ask "Path for temporary dump staging" "/var/cache/lxc-offsite")"
        mkdir -p "$cdir" 2>/dev/null
        _cfg_set LOCAL_REPO false
        _cfg_set CACHE_DIR "$cdir"
        echo "  Offsite-only mode: minimal local disk."
    fi

    # --- SFTP / repo ---
    printf '\n'
    local host user port key repo
    host="$(_ask "SFTP host (e.g. uXXXXX-subN.your-storagebox.de)")"
    [[ -n "$host" ]] || { echo "  ${C_R}SFTP host required — aborting setup.${C_0}"; return 1; }
    user="$(_ask "SFTP user" "$host")"
    port="$(_ask "SFTP port" "23")"
    key="$(_ask "SSH key file on this host" "/root/.ssh/id_rsa")"
    repo="$(_ask "Repo path (RELATIVE — Storage Box is chrooted)" "lxc-restic")"
    _cfg_set OFFSITE_ENABLED true
    _cfg_set RESTIC_OFFSITE_REPO "sftp:hetzner:${repo}"
    _cfg_set RESTIC_SFTP_COMMAND "\"ssh ${user}@${host} -p ${port} -i ${key} -o StrictHostKeyChecking=accept-new -s sftp\""

    # --- restic password (DR key) ---
    printf '\n'
    local pass passfile="${RESTIC_PASSWORD_FILE:-/etc/lxc-offsite/restic-pass}"
    if _yn "Generate a random repo password (recommended)?" j; then
        pass="$(openssl rand -base64 30 2>/dev/null || head -c22 /dev/urandom | base64)"
        echo "  Generated — export it afterwards (menu → Export DR key) and store it safely."
    else
        pass="$(_askpw "Enter restic repo password (this IS your DR key)")"
    fi
    ( umask 077; printf '%s\n' "$pass" > "$passfile" )
    _cfg_set RESTIC_PASSWORD_FILE "$passfile"

    # --- backup mode ---
    printf '\n'
    local mode; mode="$(_ask "Back up all: one-by-one (stream) or all-at-once (batch)?" "stream")"
    if [[ "$mode" == "batch" ]]; then _cfg_set BACKUP_MODE batch; else _cfg_set BACKUP_MODE stream; fi

    # --- ntfy ---
    printf '\n'
    if _yn "Enable ntfy notifications (alert on failure)?" n; then
        local nurl ntopic
        nurl="$(_ask "ntfy base URL (e.g. https://ntfy.example.com)")"
        ntopic="$(_ask "ntfy topic" "lxc-offsite")"
        _cfg_set NTFY_URL "$nurl"
        _cfg_set NTFY_TOPIC "$ntopic"
        echo "  ntfy enabled (add a token to NTFY_CREDS_FILE if your server needs auth)."
    else
        _cfg_set NTFY_URL ""
        echo "  ntfy disabled."
    fi

    # --- init ---
    printf '\n  Creating/verifying the restic repo…\n'
    "$LXCO_BIN" init
    printf '\n%s  Setup complete.%s Next steps:\n' "$C_G" "$C_0"
    printf '    1) Protect guests:  pbo menu → Guests (scan/add)\n'
    printf '    2) Test a backup:   pbo menu → Backup\n'
    printf '    3) %sExport your DR key%s → password manager (pbo menu → Export DR key)\n' "$C_B" "$C_0"
    return 0
}

# Menyval 1 → samma wizard (+ paus)
menu_setup() { run_setup_wizard; _pause; }

# --- 4. EXPORTERA DR-NYCKEL ---
menu_export() {
    _menu_header
    printf '%s Exportera DR-nyckel%s\n\n' "$C_B" "$C_0"
    _yn "Detta visar HEMLIGHETER (repo-lösen på skärmen). Fortsätt?" n || return
    local pf="${RESTIC_PASSWORD_FILE:-/etc/lxc-offsite/restic-pass}" pw
    pw="$(cat "$pf" 2>/dev/null || echo '<ingen lösenfil>')"
    echo; echo "  ${C_Y}# PBO DR-nyckel — HEMLIG. Ny host: installera PBO, klistra in, list→restore${C_0}"
    echo "  ENGINE=restic"
    echo "  RESTIC_OFFSITE_REPO=${RESTIC_OFFSITE_REPO:-<ej satt>}"
    echo "  RESTIC_SFTP_COMMAND=${RESTIC_SFTP_COMMAND:-<ej satt>}"
    echo "  ${C_B}RESTIC_PASSWORD=${pw}${C_0}"
    echo
    if _yn "Spara kopia till /root/pbo-dr-key.txt (0600)?" n; then
        ( umask 077; { echo "ENGINE=restic"; echo "RESTIC_OFFSITE_REPO=${RESTIC_OFFSITE_REPO}";
          echo "RESTIC_SFTP_COMMAND=${RESTIC_SFTP_COMMAND}"; echo "RESTIC_PASSWORD=${pw}"; } > /root/pbo-dr-key.txt )
        echo "  ${C_G}sparad: /root/pbo-dr-key.txt${C_0} — flytta offline och radera från hosten."
    fi
    _pause
}

# --- 6. ÅTERSTÄLL ---
menu_restore() {
    _menu_header
    printf '%s Återställ%s\n\n' "$C_B" "$C_0"
    echo "  Hämtar offsite-arkiv…"
    local listing; listing="$("$LXCO_BIN" --json list 2>/dev/null)"
    local vmids; vmids="$(jq -r '[.archives[].vmid]|unique|.[]' <<<"$listing" 2>/dev/null)"
    [[ -n "$vmids" ]] || { echo "  Inga offsite-arkiv."; _pause; return; }
    echo "  Gäster med backup: ${C_C}$(echo $vmids | tr '\n' ' ')${C_0}"
    local src; src="$(_ask "VMID att återställa")"
    [[ "$src" =~ ^[0-9]+$ ]] || return
    local tss; tss="$(jq -r --arg v "$src" '.archives[]|select(.vmid==$v)|.archive' <<<"$listing" | grep -oE '[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}' | sort -r)"
    [[ -n "$tss" ]] || { echo "  ${C_R}Inga snapshots för $src.${C_0}"; _pause; return; }
    echo "  Snapshots (nyast först):"; echo "$tss" | sed 's/^/    /'
    local ts; ts="$(_ask "Tidsstämpel" "$(echo "$tss" | head -1)")"
    local used free=9100
    used="$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | jq -r '.[].vmid')"
    while grep -qx "$free" <<<"$used"; do free=$((free+1)); done
    local newid; newid="$(_ask "Nytt VMID (aldrig överskrivning)" "$free")"
    local stores; stores="$(pvesh get /storage --output-format json 2>/dev/null | jq -r '.[]|select((.content//"")|test("rootdir"))|.storage')"
    echo "  Storage: ${C_C}$(echo $stores | tr '\n' ' ')${C_0}"
    local storage; storage="$(_ask "Storage" "$(echo "$stores" | head -1)")"
    _yn "Återställ $src ($ts) → NYTT vmid $newid på $storage?" j || return
    "$LXCO_BIN" restore "$src" "$ts" --to "$newid" --storage "$storage" --yes
    _pause
}

# --- 7. UNDERHÅLL ---
menu_maint() {
    _menu_header
    printf '%s Underhåll%s\n\n' "$C_B" "$C_0"
    printf '  %s[1]%s Prune (torrkörning)     %s[2]%s Prune (skarpt)\n' "$C_B" "$C_0" "$C_B" "$C_0"
    printf '  %s[3]%s Verifiera (restic check) %s[4]%s Test-restore\n' "$C_B" "$C_0" "$C_B" "$C_0"
    printf '  %s[0]%s tillbaka\n\n' "$C_B" "$C_0"
    local c; c="$(_ask "Val")"
    case "$c" in
        1) "$LXCO_BIN" --dry-run prune; _pause ;;
        2) _yn "Kör SKARP prune (raderar snapshots utanför policyn)?" n && { "$LXCO_BIN" prune; _pause; } ;;
        3) echo "  Verifierar (kan ta en stund)…"; "$LXCO_BIN" verify; _pause ;;
        4) local id; id="$(_ask "VMID för test-restore")"
           [[ "$id" =~ ^[0-9]+$ ]] && _yn "Test-restore $id (hämta→boota→destroy engångskopia)?" j && { "$LXCO_BIN" test-restore "$id"; _pause; } ;;
        *) : ;;
    esac
}

# --- huvudmeny ---
menu_main() {
    # Interaktivt: read/grep/[[ ]] returnerar ofta !=0 — dispatcherns set -Eeuo får
    # INTE fälla menyn. (CLI-åtgärderna körs som egna subprocesser med egen set -e.)
    set +e +u
    command -v jq >/dev/null 2>&1 || { printf 'jq krävs för menyn (apt install jq)\n' >&2; return 1; }
    while true; do
        _menu_header
        printf '\n'
        printf '  %s[1]%s Setup / onboarding        %s[4]%s Exportera DR-nyckel\n' "$C_B" "$C_0" "$C_B" "$C_0"
        printf '  %s[2]%s Gäster (scan/add/delete)  %s[5]%s Status\n' "$C_B" "$C_0" "$C_B" "$C_0"
        printf '  %s[3]%s Säkerhetskopiera          %s[6]%s Återställ\n' "$C_B" "$C_0" "$C_B" "$C_0"
        printf '  %s[7]%s Underhåll (prune/verify)  %s[0]%s Avsluta\n\n' "$C_B" "$C_0" "$C_B" "$C_0"
        local c; c="$(_ask "Val")"
        case "$c" in
            1) menu_setup ;;
            2) menu_guests ;;
            3) menu_backup ;;
            4) menu_export ;;
            5) menu_status ;;
            6) menu_restore ;;
            7) menu_maint ;;
            0|q|"") clear 2>/dev/null || true; return "$EX_OK" ;;
            *) : ;;
        esac
    done
}
