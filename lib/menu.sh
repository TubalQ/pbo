# shellcheck shell=bash
# lib/menu.sh — interactive prompt-CLI (rclone config style). Pure bash, zero
# dependencies, no alternate-screen → behaves identically over SSH/serial/tmux.
# Launched with `pbo menu`. This is the primary interactive interface.
#
# No business logic lives here; the menu shells out to `$PBO_BIN` (or reads
# --json). Config changes (BACKUP_ORDER) are written atomically, mode 0600.

PBO_BIN="${PBO_SELF_BIN:-${SELF_DIR}/pbo}"

# --- colors (off when not a tty) ---
if [[ -t 1 ]]; then
    C_B=$'\033[1m'; C_D=$'\033[2m'; C_G=$'\033[32m'; C_C=$'\033[36m'
    C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
    C_B=""; C_D=""; C_G=""; C_C=""; C_Y=""; C_R=""; C_0=""
fi

_ask()   { local p="$1" d="${2:-}" a; read -r -p "$p${d:+ [$d]}: " a; printf '%s' "${a:-$d}"; }
_askpw() { local p="$1" a; read -r -s -p "$p: " a; echo >&2; printf '%s' "$a"; }
_pause() { read -r -p "${C_D}— press Enter to continue —${C_0} " _; }
_yn()    { local a; a="$(_ask "$1 (y/n)" "${2:-n}")"; [[ "$a" == [yYjJ]* ]]; }

# Write/update KEY=VALUE in the config (atomic, 0600) + update in memory.
_cfg_set() {
    local k="$1" v="$2" cfg="${PBO_CONFIG_LOADED:-${PBO_CONFIG:-/etc/pbo/config}}" tmp
    [[ -f "$cfg" ]] || { printf 'config not found: %s\n' "$cfg" >&2; return 1; }
    tmp="$(mktemp)"
    if grep -qE "^${k}=" "$cfg"; then sed "s|^${k}=.*|${k}=${v}|" "$cfg" > "$tmp"
    else { cat "$cfg"; printf '%s=%s\n' "$k" "$v"; } > "$tmp"; fi
    chmod 600 "$tmp"; mv "$tmp" "$cfg"
    if [[ "$k" == "BACKUP_ORDER" ]]; then BACKUP_ORDER="$v"; fi
    return 0
}

# Cluster guests as TSV: vmid \t name \t type \t node \t status
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
    printf '%s│%s engine %s%s%s · offsite %s%s%s · protected %s%s%s\n' \
        "$C_C" "$C_0" "$C_B" "${ENGINE:-tar}" "$C_0" "$C_C" "$repo" "$C_0" "$C_B" "$prot" "$C_0"
    printf '%s└───────────────────────────────────────────────────────────┘%s\n' "$C_C" "$C_0"
}

# --- 2. GUESTS: scan / add / delete (manage BACKUP_ORDER) ---
menu_guests() {
    while true; do
        _menu_header
        printf '%s Guests — scan the cluster, add/remove from backup%s\n\n' "$C_B" "$C_0"
        printf '  %-6s %-22s %-5s %-9s %-9s %s\n' "VMID" "NAME" "TYPE" "NODE" "STATUS" "PROTECTED"
        printf '  %s\n' "-------------------------------------------------------------------"
        local v n t nd st mark new
        while IFS=$'\t' read -r v n t nd st; do
            [[ -n "$v" ]] || continue
            if _is_protected "$v"; then mark="${C_G}✓ yes${C_0}"; new=""
            else mark="${C_D}—${C_0}"; new=" ${C_Y}(new)${C_0}"; fi
            printf '  %-6s %-22s %-5s %-9s %-9s %b%b\n' "$v" "${n:0:22}" "$t" "$nd" "$st" "$mark" "$new"
        done < <(_menu_guests_tsv)
        printf '\n  %s[a]%s protect (add)   %s[d]%s remove from backup   %s[r]%s refresh   %s[0]%s back\n' \
            "$C_B" "$C_0" "$C_B" "$C_0" "$C_B" "$C_0" "$C_B" "$C_0"
        local c; c="$(_ask "Choice" )"
        case "$c" in
            a) local id; id="$(_ask "VMID to protect")"
               if [[ "$id" =~ ^[0-9]+$ ]] && _menu_guests_tsv | grep -q "^$id	"; then
                   _is_protected "$id" && { echo "  already protected."; } || {
                       local order; order="$(tr ',' ' ' <<<"$BACKUP_ORDER") $id"
                       _cfg_set BACKUP_ORDER "$(echo $order | tr ' ' ',' | sed 's/^,//')"
                       echo "  ${C_G}protected: $id${C_0}"; }
               else echo "  ${C_R}unknown vmid $id${C_0}"; fi; _pause ;;
            d) local id; id="$(_ask "VMID to remove from backup")"
               local order=(); local x
               for x in $(tr ',' ' ' <<<"$BACKUP_ORDER"); do [[ "$x" == "$id" ]] || order+=("$x"); done
               _cfg_set BACKUP_ORDER "$(IFS=,; echo "${order[*]}")"
               echo "  ${C_Y}removed from backup: $id${C_0}"; _pause ;;
            r) : ;;
            0|"") return ;;
            *) : ;;
        esac
    done
}

# --- 3. BACKUP ---
menu_backup() {
    _menu_header
    printf '%s Back up%s\n\n' "$C_B" "$C_0"
    printf '  %s[1]%s All protected — one by one (stream)\n' "$C_B" "$C_0"
    printf '  %s[2]%s All protected — all at once (batch)\n' "$C_B" "$C_0"
    printf '  %s[3]%s Pick a single guest\n' "$C_B" "$C_0"
    printf '  %s[0]%s back\n\n' "$C_B" "$C_0"
    local c; c="$(_ask "Choice")"
    case "$c" in
        1) _yn "Back up all protected guests (stream)?" y && { "$PBO_BIN" run-schedule --stream; _pause; } ;;
        2) _yn "Back up all protected guests (batch)?" y && { "$PBO_BIN" run-schedule --batch; _pause; } ;;
        3) local id; id="$(_ask "VMID to back up")"
           [[ "$id" =~ ^[0-9]+$ ]] && _yn "Back up $id now?" y && { "$PBO_BIN" backup "$id"; _pause; } ;;
        *) : ;;
    esac
}

# --- 5. STATUS ---
menu_status() {
    _menu_header
    printf '%s Status%s\n\n' "$C_B" "$C_0"
    printf '  Reading from the repo…\n'
    "$PBO_BIN" --json list 2>/dev/null | jq -r '
        .archives as $a | "  guests with snapshots: \($a|map(.vmid)|unique|length)\n  snapshots total:       \($a|length)\n  logical size:          \(($a|map(.size_bytes|tonumber)|add // 0)/1e9*10|floor/10) GB"' 2>/dev/null \
        || echo "  (could not read list)"
    if [[ "${ENGINE:-tar}" == "restic" ]]; then
        "$PBO_BIN" --json usage 2>/dev/null | jq -r '"  physical offsite:      \(.physical_bytes/1e9*10|floor/10) GB (dedup \(.compression_ratio)×)"' 2>/dev/null
    fi
    printf '\n  next scheduled run:\n'; systemctl list-timers pbo.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/    /'
    echo; _pause
}

# --- SETUP WIZARD (used by `pbo setup`, install.sh, and the menu) ---
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
        cdir="$(_ask "Where should the cache live? (path)" "/var/cache/pbo")"
        mkdir -p "$cdir" 2>/dev/null
        _cfg_set LOCAL_REPO true
        _cfg_set CACHE_DIR "$cdir"
        _cfg_set RESTIC_CACHE_REPO "$cdir/repo"
        echo "  Cached mode: local repo at $cdir/repo + copy to offsite."
    else
        cdir="$(_ask "Path for temporary dump staging" "/var/cache/pbo")"
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
    local pass passfile="${RESTIC_PASSWORD_FILE:-/etc/pbo/restic-pass}"
    if _yn "Generate a random repo password (recommended)?" y; then
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
        ntopic="$(_ask "ntfy topic" "pbo")"
        _cfg_set NTFY_URL "$nurl"
        _cfg_set NTFY_TOPIC "$ntopic"
        echo "  ntfy enabled (add a token to NTFY_CREDS_FILE if your server needs auth)."
    else
        _cfg_set NTFY_URL ""
        echo "  ntfy disabled."
    fi

    # --- init ---
    printf '\n  Creating/verifying the restic repo…\n'
    "$PBO_BIN" init
    printf '\n%s  Setup complete.%s Next steps:\n' "$C_G" "$C_0"
    printf '    1) Protect guests:  pbo menu → Guests (scan/add)\n'
    printf '    2) Test a backup:   pbo menu → Backup\n'
    printf '    3) %sExport your DR key%s → password manager (menu → Export DR key)\n' "$C_B" "$C_0"
    return 0
}

# Menu choice 1 → same wizard (+ pause)
menu_setup() { run_setup_wizard; _pause; }

# --- 4. EXPORT DR KEY ---
menu_export() {
    _menu_header
    printf '%s Export DR key%s\n\n' "$C_B" "$C_0"
    _yn "This shows SECRETS (repo password on screen). Continue?" n || return
    local pf="${RESTIC_PASSWORD_FILE:-/etc/pbo/restic-pass}" pw
    pw="$(cat "$pf" 2>/dev/null || echo '<no password file>')"
    echo; echo "  ${C_Y}# PBO DR key — SECRET. On a new host: install PBO, paste this, then list→restore${C_0}"
    echo "  ENGINE=restic"
    echo "  RESTIC_OFFSITE_REPO=${RESTIC_OFFSITE_REPO:-<not set>}"
    echo "  RESTIC_SFTP_COMMAND=${RESTIC_SFTP_COMMAND:-<not set>}"
    echo "  ${C_B}RESTIC_PASSWORD=${pw}${C_0}"
    echo
    if _yn "Save a copy to /root/pbo-dr-key.txt (0600)?" n; then
        ( umask 077; { echo "ENGINE=restic"; echo "RESTIC_OFFSITE_REPO=${RESTIC_OFFSITE_REPO}";
          echo "RESTIC_SFTP_COMMAND=${RESTIC_SFTP_COMMAND}"; echo "RESTIC_PASSWORD=${pw}"; } > /root/pbo-dr-key.txt )
        echo "  ${C_G}saved: /root/pbo-dr-key.txt${C_0} — move it offline and delete it from this host."
    fi
    _pause
}

# --- 6. RESTORE ---
menu_restore() {
    _menu_header
    printf '%s Restore%s\n\n' "$C_B" "$C_0"
    echo "  Fetching offsite archives…"
    local listing; listing="$("$PBO_BIN" --json list 2>/dev/null)"
    local vmids; vmids="$(jq -r '[.archives[].vmid]|unique|.[]' <<<"$listing" 2>/dev/null)"
    [[ -n "$vmids" ]] || { echo "  No offsite archives."; _pause; return; }
    echo "  Guests with backups: ${C_C}$(echo $vmids | tr '\n' ' ')${C_0}"
    local src; src="$(_ask "VMID to restore")"
    [[ "$src" =~ ^[0-9]+$ ]] || return
    local tss; tss="$(jq -r --arg v "$src" '.archives[]|select(.vmid==$v)|.archive' <<<"$listing" | grep -oE '[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}' | sort -r)"
    [[ -n "$tss" ]] || { echo "  ${C_R}No snapshots for $src.${C_0}"; _pause; return; }
    echo "  Snapshots (newest first):"; echo "$tss" | sed 's/^/    /'
    local ts; ts="$(_ask "Timestamp" "$(echo "$tss" | head -1)")"
    local used free=9100
    used="$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | jq -r '.[].vmid')"
    while grep -qx "$free" <<<"$used"; do free=$((free+1)); done
    local newid; newid="$(_ask "New VMID (never overwrites)" "$free")"
    local stores; stores="$(pvesh get /storage --output-format json 2>/dev/null | jq -r '.[]|select((.content//"")|test("rootdir"))|.storage')"
    echo "  Storage: ${C_C}$(echo $stores | tr '\n' ' ')${C_0}"
    local storage; storage="$(_ask "Storage" "$(echo "$stores" | head -1)")"
    _yn "Restore $src ($ts) → NEW vmid $newid on $storage?" y || return
    "$PBO_BIN" restore "$src" "$ts" --to "$newid" --storage "$storage" --yes
    _pause
}

# --- 7. MAINTENANCE ---
menu_maint() {
    _menu_header
    printf '%s Maintenance%s\n\n' "$C_B" "$C_0"
    printf '  %s[1]%s Prune (dry run)          %s[2]%s Prune (for real)\n' "$C_B" "$C_0" "$C_B" "$C_0"
    printf '  %s[3]%s Verify (restic check)    %s[4]%s Test-restore\n' "$C_B" "$C_0" "$C_B" "$C_0"
    printf '  %s[0]%s back\n\n' "$C_B" "$C_0"
    local c; c="$(_ask "Choice")"
    case "$c" in
        1) "$PBO_BIN" --dry-run prune; _pause ;;
        2) _yn "Run a REAL prune (deletes snapshots outside the policy)?" n && { "$PBO_BIN" prune; _pause; } ;;
        3) echo "  Verifying (this can take a while)…"; "$PBO_BIN" verify; _pause ;;
        4) local id; id="$(_ask "VMID to test-restore")"
           [[ "$id" =~ ^[0-9]+$ ]] && _yn "Test-restore $id (fetch→boot→destroy a throwaway copy)?" y && { "$PBO_BIN" test-restore "$id"; _pause; } ;;
        *) : ;;
    esac
}

# --- main menu ---
menu_main() {
    # Interactive: read/grep/[[ ]] often return !=0 — the dispatcher's set -Eeuo
    # must NOT kill the menu. (CLI actions run as their own subprocesses with their own set -e.)
    set +e +u
    command -v jq >/dev/null 2>&1 || { printf 'jq is required for the menu (apt install jq)\n' >&2; return 1; }
    while true; do
        _menu_header
        printf '\n'
        printf '  %s[1]%s Setup / onboarding        %s[4]%s Export DR key\n' "$C_B" "$C_0" "$C_B" "$C_0"
        printf '  %s[2]%s Guests (scan/add/delete)  %s[5]%s Status\n' "$C_B" "$C_0" "$C_B" "$C_0"
        printf '  %s[3]%s Back up                    %s[6]%s Restore\n' "$C_B" "$C_0" "$C_B" "$C_0"
        printf '  %s[7]%s Maintenance (prune/verify) %s[0]%s Quit\n\n' "$C_B" "$C_0" "$C_B" "$C_0"
        local c; c="$(_ask "Choice")"
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
