# shellcheck shell=bash
# lib/tui.sh — terminal-UI (whiptail). ADR 0003. Aktiveras med `lxc-offsite tui`.
#
# TUI:n har INGEN egen affärslogik: den shell:ar ut till samma CLI
# (`$LXCO_BIN [--json] <cmd>`) — lås/preflight/audit/envelope återanvänds.
# Config-vars (ENGINE, RESTIC_*) är redan laddade av main→load_config.
#
# Fokus (ADR 0003): 1) enkel restic-setup 2) exportera DR-nyckel
# 3) backup alla/enskild 4) restore 5) metrics (lägre).

LXCO_BIN="${LXCO_SELF_BIN:-${SELF_DIR}/lxc-offsite}"
WT_H=20; WT_W=78; WT_MH=10
export NEWT_COLORS='root=,black'

# ---- whiptail-hjälpare (OK→stdout, Cancel→rc1) ----
_wt_menu()      { whiptail --title "$1" --menu "$2" "$WT_H" "$WT_W" "$WT_MH" "${@:3}" 3>&1 1>&2 2>&3; }
_wt_input()     { whiptail --title "$1" --inputbox "$2" 10 "$WT_W" "$3" 3>&1 1>&2 2>&3; }
_wt_password()  { whiptail --title "$1" --passwordbox "$2" 10 "$WT_W" 3>&1 1>&2 2>&3; }
_wt_radiolist() { whiptail --title "$1" --radiolist "$2" "$WT_H" "$WT_W" "$WT_MH" "${@:3}" 3>&1 1>&2 2>&3; }
_wt_checklist() { whiptail --title "$1" --checklist "$2" "$WT_H" "$WT_W" "$WT_MH" "${@:3}" 3>&1 1>&2 2>&3; }
_wt_yesno()     { whiptail --title "$1" --yesno "$2" 12 "$WT_W"; }
_wt_msg()       { whiptail --title "$1" --msgbox "$2" 14 "$WT_W"; }
_wt_text()      { whiptail --title "$1" --scrolltext --textbox "$2" "$WT_H" "$WT_W"; }
# Kör ett kommando, fånga output, visa i textbox. _wt_run <titel> <cmd...>
_wt_run() { local t="$1"; shift; local f; f="$(mktemp)"; { echo "\$ $*"; echo; "$@"; echo; echo "[rc=$?]"; } >"$f" 2>&1; _wt_text "$t" "$f"; rm -f "$f"; }

# ---- datahjälpare (via CLI --json + pvesh) ----
_guests_json() { pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || echo '[]'; }
_rootdir_storages() { pvesh get /storage --output-format json 2>/dev/null | jq -r '.[]|select((.content//"")|test("rootdir"))|.storage' 2>/dev/null; }
_offsite_vmids() { "$LXCO_BIN" --json list 2>/dev/null | jq -r '.archives[].vmid' 2>/dev/null | sort -un; }

# ---- 1. SETUP / onboarding (restic) — högsta fokus ----
tui_setup() {
    local eng; eng="$(_wt_radiolist "Setup — motor" "Vilken backup-motor?" \
        restic "restic (dedup, incremental, kryptering)" ON \
        tar    "tar.zst via rclone (äldre)" OFF)" || return 0
    if [[ "$eng" != "restic" ]]; then _tui_set_cfg ENGINE tar; _wt_msg "Setup" "ENGINE=tar satt."; return 0; fi

    local mode; mode="$(_wt_radiolist "Setup — läge" "Var ska backuperna bo?" \
        cached "Lokal cache + offsite (snabb restore)" ON \
        offsite "Bara offsite (minimal disk)" OFF)" || return 0
    local host user port keyf repo pass
    host="$(_wt_input "Setup — SFTP" "SFTP-host (t.ex. uXXXXX-subN.your-storagebox.de)" "")" || return 0
    user="$(_wt_input "Setup — SFTP" "SFTP-användare" "$host")" || return 0
    port="$(_wt_input "Setup — SFTP" "Port" "23")" || return 0
    keyf="$(_wt_input "Setup — SFTP" "SSH-nyckelfil på hosten" "/root/.ssh/id_rsa")" || return 0
    repo="$(_wt_input "Setup — repo" "Repo-path (RELATIV — Storage Box chroot)" "lxc-restic")" || return 0
    if _wt_yesno "Setup — repo-lösen" "Generera ett nytt repo-lösen automatiskt?\n(annars anger du eget)"; then
        pass="$(openssl rand -base64 24 2>/dev/null || head -c18 /dev/urandom | base64)"
    else
        pass="$(_wt_password "Setup — repo-lösen" "Ange repo-lösen (DR-nyckel!)")" || return 0
    fi
    # skriv config + lösenfil
    local passfile="/etc/lxc-offsite/restic-pass"
    ( umask 077; printf '%s\n' "$pass" > "$passfile" )
    _tui_set_cfg ENGINE restic
    _tui_set_cfg LOCAL_REPO "$([[ "$mode" == cached ]] && echo true || echo false)"
    _tui_set_cfg OFFSITE_ENABLED true
    _tui_set_cfg RESTIC_OFFSITE_REPO "sftp:hetzner:${repo}"
    _tui_set_cfg RESTIC_PASSWORD_FILE "$passfile"
    _tui_set_cfg_q RESTIC_SFTP_COMMAND "ssh ${user}@${host} -p ${port} -i ${keyf} -o StrictHostKeyChecking=accept-new -s sftp"
    _wt_run "Setup — kör init" "$LXCO_BIN" init
    _wt_msg "Setup klar" "Motor=restic, läge=${mode}.\nRepo: sftp:…:${repo}\nLösen sparat i ${passfile} (0600).\n\nVIKTIGT: exportera DR-nyckeln (meny 4) och lägg den i Vaultwarden + offline."
}

# Skriv KEY=VALUE (oquoted) i configen, atomiskt.
_tui_set_cfg()   { _tui_cfg_write "$1" "$2" ""; }
# Skriv KEY="VALUE" (citerat — för värden med blanksteg).
_tui_set_cfg_q() { _tui_cfg_write "$1" "$2" q; }
_tui_cfg_write() {
    local k="$1" v="$2" q="$3" cfg="${LXCO_CONFIG:-/etc/lxc-offsite/config}"
    local line; [[ "$q" == q ]] && line="${k}=\"${v}\"" || line="${k}=${v}"
    local tmp; tmp="$(mktemp)"
    if [[ -f "$cfg" ]] && grep -qE "^${k}=" "$cfg"; then
        sed "s|^${k}=.*|${line}|" "$cfg" > "$tmp"
    else
        { [[ -f "$cfg" ]] && cat "$cfg"; printf '%s\n' "$line"; } > "$tmp"
    fi
    chmod 600 "$tmp"; mv "$tmp" "$cfg"
}

# ---- 2. BACKUP — alla eller enskild ----
tui_backup() {
    local c; c="$(_wt_menu "Säkerhetskopiera" "Vad vill du backa upp?" \
        all "Alla skyddade gäster (run-schedule)" \
        one "Välj enskild gäst…")" || return 0
    if [[ "$c" == all ]]; then
        _wt_yesno "Backup" "Kör backup av ALLA skyddade gäster nu?" || return 0
        _wt_run "Backup — alla" "$LXCO_BIN" run-schedule
    else
        local args=() row
        while IFS= read -r row; do args+=("$row" "" OFF); done < <(_guests_json | jq -r '.[]|select(.type=="lxc")|"\(.vmid):\(.name//"-")"')
        [[ ${#args[@]} -gt 0 ]] || { _wt_msg "Backup" "Inga LXC-gäster hittades."; return 0; }
        local sel; sel="$(_wt_checklist "Backup — välj gäster" "Bocka i gäster att backa upp:" "${args[@]}")" || return 0
        local id
        for id in $sel; do id="${id//\"/}"; id="${id%%:*}"; _wt_run "Backup $id" "$LXCO_BIN" backup "$id"; done
    fi
}

# ---- 3. RESTORE ----
tui_restore() {
    local vmids; mapfile -t vmids < <(_offsite_vmids)
    [[ ${#vmids[@]} -gt 0 ]] || { _wt_msg "Restore" "Inga offsite-arkiv hittades (kör backup först)."; return 0; }
    local menu=() v; for v in "${vmids[@]}"; do menu+=("$v" "gäst $v"); done
    local src; src="$(_wt_menu "Restore — gäst" "Vilken gäst ska återställas?" "${menu[@]}")" || return 0
    # snapshots (ts) för gästen
    local tsmenu=() ts
    while IFS= read -r ts; do tsmenu+=("$ts" "snapshot"); done < <("$LXCO_BIN" --json list "$src" 2>/dev/null | jq -r '.archives[].archive' | grep -oE '[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}' | sort -r)
    [[ ${#tsmenu[@]} -gt 0 ]] || { _wt_msg "Restore" "Inga snapshots för $src."; return 0; }
    local pick; pick="$(_wt_menu "Restore — snapshot" "Välj snapshot för $src:" "${tsmenu[@]}")" || return 0
    local nf; nf="$("$LXCO_BIN" --json list >/dev/null 2>&1; echo)"; # placeholder
    local newid; newid="$(_wt_input "Restore — nytt VMID" "Återställ ALLTID till nytt vmid (aldrig överskrivning):" "9100")" || return 0
    local smenu=() s; while IFS= read -r s; do smenu+=("$s" "pool"); done < <(_rootdir_storages)
    local storage; storage="$(_wt_menu "Restore — storage" "Vilken storage?" "${smenu[@]}")" || return 0
    _wt_yesno "Restore — bekräfta" "Återställ gäst $src ($pick) → NYTT vmid $newid på $storage?" || return 0
    _wt_run "Restore" "$LXCO_BIN" restore "$src" "$pick" --to "$newid" --storage "$storage" --yes
}

# ---- 4. EXPORTERA DR-NYCKEL ----
tui_export_key() {
    _wt_yesno "DR-nyckel" "Detta visar HEMLIGHETER (repo-lösen). Förvara offline (Vaultwarden + USB). Fortsätt?" || return 0
    local f; f="$(mktemp)"
    {
        echo "# lxc-offsite DR-nyckel — behandla som HEMLIGHET"
        echo "# Installera lxc-offsite på ny host, klistra in config, kör: list → restore"
        echo
        echo "ENGINE=restic"
        echo "RESTIC_OFFSITE_REPO=${RESTIC_OFFSITE_REPO:-<ej satt>}"
        echo "RESTIC_SFTP_COMMAND=\"${RESTIC_SFTP_COMMAND:-<ej satt>}\""
        echo -n "RESTIC_PASSWORD="; cat "${RESTIC_PASSWORD_FILE:-/etc/lxc-offsite/restic-pass}" 2>/dev/null || echo "<ingen lösenfil>"
    } > "$f"
    chmod 600 "$f"
    _wt_text "DR-nyckel (hemlig)" "$f"
    if _wt_yesno "DR-nyckel" "Spara en kopia till /root/lxc-offsite-dr-key.txt (0600)?"; then
        install -m 600 "$f" /root/lxc-offsite-dr-key.txt && _wt_msg "DR-nyckel" "Sparad: /root/lxc-offsite-dr-key.txt\nFlytta den offline och radera från hosten."
    fi
    rm -f "$f"
}

# ---- 5. STATUS & METRICS (lägre fokus) ----
tui_status() {
    local f; f="$(mktemp)"
    {
        echo "=== Motor ==="; echo "ENGINE=${ENGINE:-tar}  LÄGE=$([[ "${LOCAL_REPO:-true}" == true ]] && echo cached || echo offsite-only)"
        echo "OFFSITE=${RESTIC_OFFSITE_REPO:-${RCLONE_REMOTE:-<ej satt>}}"
        echo; echo "=== Offsite-arkiv ==="
        "$LXCO_BIN" --json list 2>/dev/null | jq -r '"gäster med snapshots: \(.archives|map(.vmid)|unique|length)\ntotalt snapshots: \(.archives|length)\nlogisk storlek: \((.archives|map(.size_bytes)|add)//0) B"' 2>/dev/null || echo "(kunde ej läsa list)"
        echo; echo "=== Globalt lås / senaste jobb ==="
        "$LXCO_BIN" --json status 2>/dev/null | jq -r '"lås: \(.lock_state // .global_lock // "-")\nsenaste jobb: \(.recent_jobs // "-")"' 2>/dev/null || echo "(status ej tillgänglig)"
    } > "$f"
    _wt_text "Status & metrics" "$f"; rm -f "$f"
}

# ---- 6. UNDERHÅLL ----
tui_maint() {
    local c; c="$(_wt_menu "Underhåll" "Åtgärd:" \
        prune "Prune (rensa enligt policy)" \
        verify "Verify (restic check)" \
        test "Test-restore (boota engångskopia)")" || return 0
    case "$c" in
        prune)
            _wt_run "Prune — dry-run" "$LXCO_BIN" --dry-run prune
            _wt_yesno "Prune" "Kör SKARP prune nu (raderar enligt policy)?" && _wt_run "Prune — skarp" "$LXCO_BIN" prune ;;
        verify) _wt_run "Verify" "$LXCO_BIN" verify ;;
        test)
            local menu=() v; for v in $(_offsite_vmids); do menu+=("$v" "gäst $v"); done
            [[ ${#menu[@]} -gt 0 ]] || { _wt_msg "Test-restore" "Inga offsite-arkiv."; return 0; }
            local id; id="$(_wt_menu "Test-restore" "Vilken gäst?" "${menu[@]}")" || return 0
            _wt_yesno "Test-restore" "Kör full test-restore av $id (hämta→boota→destroy)?" && _wt_run "Test-restore $id" "$LXCO_BIN" test-restore "$id" ;;
    esac
}

# ---- huvudmeny ----
tui_main() {
    command -v whiptail >/dev/null 2>&1 || { printf 'whiptail saknas (apt install whiptail)\n' >&2; return "$EX_UNAVAILABLE"; }
    while true; do
        local c
        c="$(_wt_menu "lxc-offsite — huvudmeny" "Motor: ${ENGINE:-tar}   (piltangenter + Enter)" \
            1 "Setup / onboarding (restic)" \
            2 "Säkerhetskopiera (backup)" \
            3 "Återställ (restore)" \
            4 "Exportera DR-nyckel" \
            5 "Status & metrics" \
            6 "Underhåll (prune/verify/test)" \
            0 "Avsluta")" || break
        case "$c" in
            1) tui_setup ;; 2) tui_backup ;; 3) tui_restore ;;
            4) tui_export_key ;; 5) tui_status ;; 6) tui_maint ;; 0) break ;;
        esac
    done
    clear 2>/dev/null || true
}

# ---- icke-interaktiv wiring-koll (ingen TTY) ----
_tui_selftest() {
    local ok=1
    printf 'whiptail:        '; command -v whiptail >/dev/null && echo OK || { echo SAKNAS; ok=0; }
    printf 'LXCO_BIN:        '; [[ -x "$LXCO_BIN" || -f "$LXCO_BIN" ]] && echo "$LXCO_BIN" || { echo SAKNAS; ok=0; }
    printf 'config laddad:   '; echo "ENGINE=${ENGINE:-tar} OFFSITE=${RESTIC_OFFSITE_REPO:-<->}"
    printf 'gäst-query:      '; local n; n="$(_guests_json | jq 'length' 2>/dev/null || echo 0)"; echo "${n} gäster i klustret"
    printf 'storage-query:   '; _rootdir_storages | paste -sd' ' -
    printf 'offsite-vmids:   '; local v; v="$(_offsite_vmids | paste -sd' ' -)"; echo "${v:-<inga / offsite ej satt>}"
    printf 'funktioner:      '; declare -F tui_setup tui_backup tui_restore tui_export_key tui_status tui_maint tui_main >/dev/null && echo "alla definierade" || { echo SAKNAS; ok=0; }
    (( ok )) && echo "SELFTEST: OK" || echo "SELFTEST: FEL"
}
