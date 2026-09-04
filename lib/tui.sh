# shellcheck shell=bash
# lib/tui.sh — terminal UI (whiptail). ADR 0003. Enabled with `lxc-offsite tui`.
#
# FROZEN: superseded by the interactive prompt-CLI (`lxc-offsite menu`). Kept for
# compatibility. The TUI has NO business logic of its own: it shells out to the
# same CLI (`$LXCO_BIN [--json] <cmd>`) — locks/preflight/audit/envelope reused.
# Config vars (ENGINE, RESTIC_*) are already loaded by main→load_config.
#
# Focus (ADR 0003): 1) easy restic setup 2) export DR key
# 3) backup all/single 4) restore 5) metrics (lower priority).

LXCO_BIN="${LXCO_SELF_BIN:-${SELF_DIR}/lxc-offsite}"
WT_H=20; WT_W=78; WT_MH=10
export NEWT_COLORS='root=,black'

# ---- whiptail helpers (OK→stdout, Cancel→rc1) ----
_wt_menu()      { whiptail --title "$1" --menu "$2" "$WT_H" "$WT_W" "$WT_MH" "${@:3}" 3>&1 1>&2 2>&3; }
_wt_input()     { whiptail --title "$1" --inputbox "$2" 10 "$WT_W" "$3" 3>&1 1>&2 2>&3; }
_wt_password()  { whiptail --title "$1" --passwordbox "$2" 10 "$WT_W" 3>&1 1>&2 2>&3; }
_wt_radiolist() { whiptail --title "$1" --radiolist "$2" "$WT_H" "$WT_W" "$WT_MH" "${@:3}" 3>&1 1>&2 2>&3; }
_wt_checklist() { whiptail --title "$1" --checklist "$2" "$WT_H" "$WT_W" "$WT_MH" "${@:3}" 3>&1 1>&2 2>&3; }
_wt_yesno()     { whiptail --title "$1" --yesno "$2" 12 "$WT_W"; }
_wt_msg()       { whiptail --title "$1" --msgbox "$2" 14 "$WT_W"; }
_wt_text()      { whiptail --title "$1" --scrolltext --textbox "$2" "$WT_H" "$WT_W"; }
# Run a command, capture output, show in a textbox. _wt_run <title> <cmd...>
_wt_run() { local t="$1"; shift; local f; f="$(mktemp)"; { echo "\$ $*"; echo; "$@"; echo; echo "[rc=$?]"; } >"$f" 2>&1; _wt_text "$t" "$f"; rm -f "$f"; }

# ---- data helpers (via CLI --json + pvesh) ----
_guests_json() { pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || echo '[]'; }
_rootdir_storages() { pvesh get /storage --output-format json 2>/dev/null | jq -r '.[]|select((.content//"")|test("rootdir"))|.storage' 2>/dev/null; }
_offsite_vmids() { "$LXCO_BIN" --json list 2>/dev/null | jq -r '.archives[].vmid' 2>/dev/null | sort -un; }

# ---- 1. SETUP / onboarding (restic) — highest focus ----
tui_setup() {
    local eng; eng="$(_wt_radiolist "Setup — engine" "Which backup engine?" \
        restic "restic (dedup, incremental, encryption)" ON \
        tar    "tar.zst via rclone (legacy)" OFF)" || return 0
    if [[ "$eng" != "restic" ]]; then _tui_set_cfg ENGINE tar; _wt_msg "Setup" "ENGINE=tar set."; return 0; fi

    local mode; mode="$(_wt_radiolist "Setup — mode" "Where should the backups live?" \
        cached "Local cache + offsite (fast restore)" ON \
        offsite "Offsite only (minimal disk)" OFF)" || return 0
    local host user port keyf repo pass
    host="$(_wt_input "Setup — SFTP" "SFTP host (e.g. uXXXXX-subN.your-storagebox.de)" "")" || return 0
    user="$(_wt_input "Setup — SFTP" "SFTP user" "$host")" || return 0
    port="$(_wt_input "Setup — SFTP" "Port" "23")" || return 0
    keyf="$(_wt_input "Setup — SFTP" "SSH key file on this host" "/root/.ssh/id_rsa")" || return 0
    repo="$(_wt_input "Setup — repo" "Repo path (RELATIVE — Storage Box is chrooted)" "lxc-restic")" || return 0
    if _wt_yesno "Setup — repo password" "Generate a new repo password automatically?\n(otherwise you enter your own)"; then
        pass="$(openssl rand -base64 24 2>/dev/null || head -c18 /dev/urandom | base64)"
    else
        pass="$(_wt_password "Setup — repo password" "Enter repo password (this IS your DR key!)")" || return 0
    fi
    # write config + password file
    local passfile="/etc/lxc-offsite/restic-pass"
    ( umask 077; printf '%s\n' "$pass" > "$passfile" )
    _tui_set_cfg ENGINE restic
    _tui_set_cfg LOCAL_REPO "$([[ "$mode" == cached ]] && echo true || echo false)"
    _tui_set_cfg OFFSITE_ENABLED true
    _tui_set_cfg RESTIC_OFFSITE_REPO "sftp:hetzner:${repo}"
    _tui_set_cfg RESTIC_PASSWORD_FILE "$passfile"
    _tui_set_cfg_q RESTIC_SFTP_COMMAND "ssh ${user}@${host} -p ${port} -i ${keyf} -o StrictHostKeyChecking=accept-new -s sftp"
    _wt_run "Setup — running init" "$LXCO_BIN" init
    _wt_msg "Setup complete" "Engine=restic, mode=${mode}.\nRepo: sftp:…:${repo}\nPassword saved in ${passfile} (0600).\n\nIMPORTANT: export the DR key (menu 4) and store it in a password manager + offline."
}

# Write KEY=VALUE (unquoted) into the config, atomically.
_tui_set_cfg()   { _tui_cfg_write "$1" "$2" ""; }
# Write KEY="VALUE" (quoted — for values with spaces).
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

# ---- 2. BACKUP — all or single ----
tui_backup() {
    local c; c="$(_wt_menu "Back up" "What do you want to back up?" \
        all "All protected guests (run-schedule)" \
        one "Pick a single guest…")" || return 0
    if [[ "$c" == all ]]; then
        _wt_yesno "Backup" "Back up ALL protected guests now?" || return 0
        _wt_run "Backup — all" "$LXCO_BIN" run-schedule
    else
        local args=() row
        while IFS= read -r row; do args+=("$row" "" OFF); done < <(_guests_json | jq -r '.[]|select(.type=="lxc")|"\(.vmid):\(.name//"-")"')
        [[ ${#args[@]} -gt 0 ]] || { _wt_msg "Backup" "No LXC guests found."; return 0; }
        local sel; sel="$(_wt_checklist "Backup — pick guests" "Check the guests to back up:" "${args[@]}")" || return 0
        local id
        for id in $sel; do id="${id//\"/}"; id="${id%%:*}"; _wt_run "Backup $id" "$LXCO_BIN" backup "$id"; done
    fi
}

# ---- 3. RESTORE ----
tui_restore() {
    local vmids; mapfile -t vmids < <(_offsite_vmids)
    [[ ${#vmids[@]} -gt 0 ]] || { _wt_msg "Restore" "No offsite archives found (run a backup first)."; return 0; }
    local menu=() v; for v in "${vmids[@]}"; do menu+=("$v" "guest $v"); done
    local src; src="$(_wt_menu "Restore — guest" "Which guest should be restored?" "${menu[@]}")" || return 0
    # snapshots (ts) for the guest
    local tsmenu=() ts
    while IFS= read -r ts; do tsmenu+=("$ts" "snapshot"); done < <("$LXCO_BIN" --json list "$src" 2>/dev/null | jq -r '.archives[].archive' | grep -oE '[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}' | sort -r)
    [[ ${#tsmenu[@]} -gt 0 ]] || { _wt_msg "Restore" "No snapshots for $src."; return 0; }
    local pick; pick="$(_wt_menu "Restore — snapshot" "Pick a snapshot for $src:" "${tsmenu[@]}")" || return 0
    local nf; nf="$("$LXCO_BIN" --json list >/dev/null 2>&1; echo)"; # placeholder
    local newid; newid="$(_wt_input "Restore — new VMID" "Always restore to a NEW vmid (never overwrite):" "9100")" || return 0
    local smenu=() s; while IFS= read -r s; do smenu+=("$s" "pool"); done < <(_rootdir_storages)
    local storage; storage="$(_wt_menu "Restore — storage" "Which storage?" "${smenu[@]}")" || return 0
    _wt_yesno "Restore — confirm" "Restore guest $src ($pick) → NEW vmid $newid on $storage?" || return 0
    _wt_run "Restore" "$LXCO_BIN" restore "$src" "$pick" --to "$newid" --storage "$storage" --yes
}

# ---- 4. EXPORT DR KEY ----
tui_export_key() {
    _wt_yesno "DR key" "This shows SECRETS (repo password). Store it offline (password manager + USB). Continue?" || return 0
    local f; f="$(mktemp)"
    {
        echo "# lxc-offsite DR key — treat as a SECRET"
        echo "# Install lxc-offsite on a new host, paste this config, run: list → restore"
        echo
        echo "ENGINE=restic"
        echo "RESTIC_OFFSITE_REPO=${RESTIC_OFFSITE_REPO:-<not set>}"
        echo "RESTIC_SFTP_COMMAND=\"${RESTIC_SFTP_COMMAND:-<not set>}\""
        echo -n "RESTIC_PASSWORD="; cat "${RESTIC_PASSWORD_FILE:-/etc/lxc-offsite/restic-pass}" 2>/dev/null || echo "<no password file>"
    } > "$f"
    chmod 600 "$f"
    _wt_text "DR key (secret)" "$f"
    if _wt_yesno "DR key" "Save a copy to /root/lxc-offsite-dr-key.txt (0600)?"; then
        install -m 600 "$f" /root/lxc-offsite-dr-key.txt && _wt_msg "DR key" "Saved: /root/lxc-offsite-dr-key.txt\nMove it offline and delete it from this host."
    fi
    rm -f "$f"
}

# ---- 5. STATUS & METRICS (lower priority) ----
tui_status() {
    local f; f="$(mktemp)"
    {
        echo "=== Engine ==="; echo "ENGINE=${ENGINE:-tar}  MODE=$([[ "${LOCAL_REPO:-true}" == true ]] && echo cached || echo offsite-only)"
        echo "OFFSITE=${RESTIC_OFFSITE_REPO:-${RCLONE_REMOTE:-<not set>}}"
        echo; echo "=== Offsite archives ==="
        "$LXCO_BIN" --json list 2>/dev/null | jq -r '"guests with snapshots: \(.archives|map(.vmid)|unique|length)\ntotal snapshots: \(.archives|length)\nlogical size: \((.archives|map(.size_bytes)|add)//0) B"' 2>/dev/null || echo "(could not read list)"
        echo; echo "=== Global lock / recent jobs ==="
        "$LXCO_BIN" --json status 2>/dev/null | jq -r '"lock: \(.lock_state // .global_lock // "-")\nrecent jobs: \(.recent_jobs // "-")"' 2>/dev/null || echo "(status unavailable)"
    } > "$f"
    _wt_text "Status & metrics" "$f"; rm -f "$f"
}

# ---- 6. MAINTENANCE ----
tui_maint() {
    local c; c="$(_wt_menu "Maintenance" "Action:" \
        prune "Prune (clean per policy)" \
        verify "Verify (restic check)" \
        test "Test-restore (boot a throwaway copy)")" || return 0
    case "$c" in
        prune)
            _wt_run "Prune — dry run" "$LXCO_BIN" --dry-run prune
            _wt_yesno "Prune" "Run a REAL prune now (deletes per policy)?" && _wt_run "Prune — real" "$LXCO_BIN" prune ;;
        verify) _wt_run "Verify" "$LXCO_BIN" verify ;;
        test)
            local menu=() v; for v in $(_offsite_vmids); do menu+=("$v" "guest $v"); done
            [[ ${#menu[@]} -gt 0 ]] || { _wt_msg "Test-restore" "No offsite archives."; return 0; }
            local id; id="$(_wt_menu "Test-restore" "Which guest?" "${menu[@]}")" || return 0
            _wt_yesno "Test-restore" "Run a full test-restore of $id (fetch→boot→destroy)?" && _wt_run "Test-restore $id" "$LXCO_BIN" test-restore "$id" ;;
    esac
}

# ---- main menu ----
tui_main() {
    command -v whiptail >/dev/null 2>&1 || { printf 'whiptail missing (apt install whiptail)\n' >&2; return "$EX_UNAVAILABLE"; }
    while true; do
        local c
        c="$(_wt_menu "lxc-offsite — main menu" "Engine: ${ENGINE:-tar}   (arrow keys + Enter)" \
            1 "Setup / onboarding (restic)" \
            2 "Back up (backup)" \
            3 "Restore" \
            4 "Export DR key" \
            5 "Status & metrics" \
            6 "Maintenance (prune/verify/test)" \
            0 "Quit")" || break
        case "$c" in
            1) tui_setup ;; 2) tui_backup ;; 3) tui_restore ;;
            4) tui_export_key ;; 5) tui_status ;; 6) tui_maint ;; 0) break ;;
        esac
    done
    clear 2>/dev/null || true
}

# ---- non-interactive wiring check (no TTY) ----
_tui_selftest() {
    local ok=1
    printf 'whiptail:        '; command -v whiptail >/dev/null && echo OK || { echo MISSING; ok=0; }
    printf 'LXCO_BIN:        '; [[ -x "$LXCO_BIN" || -f "$LXCO_BIN" ]] && echo "$LXCO_BIN" || { echo MISSING; ok=0; }
    printf 'config loaded:   '; echo "ENGINE=${ENGINE:-tar} OFFSITE=${RESTIC_OFFSITE_REPO:-<->}"
    printf 'guest query:     '; local n; n="$(_guests_json | jq 'length' 2>/dev/null || echo 0)"; echo "${n} guests in the cluster"
    printf 'storage query:   '; _rootdir_storages | paste -sd' ' -
    printf 'offsite vmids:   '; local v; v="$(_offsite_vmids | paste -sd' ' -)"; echo "${v:-<none / offsite not set>}"
    printf 'functions:       '; declare -F tui_setup tui_backup tui_restore tui_export_key tui_status tui_maint tui_main >/dev/null && echo "all defined" || { echo MISSING; ok=0; }
    (( ok )) && echo "SELFTEST: OK" || echo "SELFTEST: FAIL"
}
