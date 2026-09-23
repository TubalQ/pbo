# shellcheck shell=bash
# lib/menu.sh: interactive prompt-CLI (rclone config style). Pure bash, zero
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
_pause() { read -r -p "${C_D}press Enter to continue${C_0} " _; }
_yn()    { local a; a="$(_ask "$1 (y/n)" "${2:-n}")"; [[ "$a" == [yYjJ]* ]]; }

# _pick_index <prompt> <default-num> <label...>: print a numbered list of labels,
# read a choice, echo ONLY the chosen 1-based index on stdout. Fails (non-zero, no
# output) on an empty/invalid/out-of-range answer so callers can abort. The list is
# printed to stderr so callers can capture the index with $(...) without swallowing it.
_pick_index() {
    local prompt="$1" def="$2"; shift 2
    local i=1 lbl
    for lbl in "$@"; do printf '    %s[%d]%s %s\n' "$C_B" "$i" "$C_0" "$lbl" >&2; ((i++)); done
    local n; n="$(_ask "$prompt" "$def")"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= $# )) && { printf '%s' "$n"; return 0; }
    return 1
}

# _ago <iso-time|epoch> <now-epoch>: coarse relative age, e.g. "5m ago", "8h ago".
_ago() {
    local t="$1" now="$2" s
    [[ "$t" =~ ^[0-9]+$ ]] && s="$t" || s="$(date -d "$t" +%s 2>/dev/null || echo 0)"
    local d=$(( now - s )); (( d < 0 )) && d=0
    (( d < 3600  )) && { printf '%dm ago' $(( d/60 ));   return; }
    (( d < 86400 )) && { printf '%dh ago' $(( d/3600 )); return; }
    printf '%dd ago' $(( d/86400 ))
}

# _hsize <bytes>: human-readable size, falls back to raw bytes without numfmt.
_hsize() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }

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
    local repo="${RESTIC_OFFSITE_REPO:-none}"
    local prot; prot="$(tr ',' ' ' <<<"${BACKUP_ORDER:-}" | wc -w)"
    printf '%s┌─ %sPBO%s%s · Proxmox Backup Offsite ────────────────────────┐%s\n' "$C_C" "$C_B" "$C_0$C_C" "" "$C_0"
    printf '%s│%s engine %srestic%s · offsite %s%s%s · protected %s%s%s\n' \
        "$C_C" "$C_0" "$C_B" "$C_0" "$C_C" "$repo" "$C_0" "$C_B" "$prot" "$C_0"
    printf '%s└───────────────────────────────────────────────────────────┘%s\n' "$C_C" "$C_0"
}

# --- 2. GUESTS: scan / add / delete (manage BACKUP_ORDER) ---
menu_guests() {
    while true; do
        _menu_header
        printf '%s Guests, scan the cluster, add/remove from backup%s\n\n' "$C_B" "$C_0"
        printf '  %-6s %-22s %-5s %-9s %-9s %s\n' "VMID" "NAME" "TYPE" "NODE" "STATUS" "PROTECTED"
        printf '  %s\n' "-------------------------------------------------------------------"
        local v n t nd st mark new
        while IFS=$'\t' read -r v n t nd st; do
            [[ -n "$v" ]] || continue
            if _is_protected "$v"; then mark="${C_G}✓ yes${C_0}"; new=""
            else mark="${C_D}-${C_0}"; new=" ${C_Y}(new)${C_0}"; fi
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
    printf '  %s[1]%s All protected, one by one (stream)\n' "$C_B" "$C_0"
    printf '  %s[2]%s All protected, all at once (batch)\n' "$C_B" "$C_0"
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
# Render one restic tier (cache|offsite): guests, snapshots, size, newest. Reads
# via the PBO_REPO override so `list`/`usage` target that exact repo. On an
# unreachable repo (e.g. Storage Box offline) it says so instead of failing.
_menu_status_tier() {           # <label> <cache|offsite>
    local label="$1" which="$2" ls
    printf '  %s%s%s\n' "$C_B" "$label" "$C_0"
    ls="$(PBO_REPO="$which" "$PBO_BIN" --json list 2>/dev/null)"
    if [[ -z "$ls" ]] || ! printf '%s' "$ls" | jq -e '.archives' >/dev/null 2>&1; then
        printf '    %s(unreachable)%s\n\n' "$C_R" "$C_0"; return
    fi
    printf '%s' "$ls" | jq -r '
        .archives as $a
        | "    guests:    \($a|map(.vmid)|unique|length)\n    snapshots: \($a|length)"' 2>/dev/null
    PBO_REPO="$which" "$PBO_BIN" --json usage 2>/dev/null | jq -r '
        "    size:      \(.physical_bytes/1e9*10|floor/10) GB physical, \(.logical_bytes/1e9*10|floor/10) GB logical (dedup \(.compression_ratio)×)"' 2>/dev/null
    printf '%s' "$ls" | jq -r '
        (.archives | map(.modtime) | max) as $m
        | if $m then "    newest:    \($m | sub("\\..*";"") | sub("T";" "))" else empty end' 2>/dev/null
    printf '\n'
}

menu_status() {
    _menu_header
    printf '%s Status%s\n\n' "$C_B" "$C_0"
    printf '  %sReading both tiers…%s\n\n' "$C_D" "$C_0"
    if [[ "${LOCAL_REPO:-true}" == "true" ]]; then
        _menu_status_tier "Local  (cache: ${CACHE_DIR:-?})" cache
    else
        printf '  %sLocal%s\n    %s(offsite-only mode, no local cache repo)%s\n\n' "$C_B" "$C_0" "$C_D" "$C_0"
    fi
    if [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        _menu_status_tier "Offsite (${RESTIC_OFFSITE_REPO})" offsite
    fi
    printf '  %snext scheduled run:%s\n' "$C_B" "$C_0"; systemctl list-timers pbo.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/    /'
    echo; _pause
}

# --- SETUP WIZARD (used by `pbo setup`, install.sh, and the menu) ---
run_setup_wizard() {
    set +e +u
    printf '\n%s=== PBO · Proxmox Backup Offsite, setup ===%s\n\n' "$C_B" "$C_0"

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
    [[ -n "$host" ]] || { echo "  ${C_R}SFTP host required, aborting setup.${C_0}"; return 1; }
    user="$(_ask "SFTP user" "$host")"
    port="$(_ask "SFTP port" "23")"
    key="$(_ask "SSH key file on this host" "/root/.ssh/id_rsa")"
    repo="$(_ask "Repo path (RELATIVE, Storage Box is chrooted)" "lxc-restic")"
    _cfg_set OFFSITE_ENABLED true
    _cfg_set RESTIC_OFFSITE_REPO "sftp:hetzner:${repo}"
    _cfg_set RESTIC_SFTP_COMMAND "\"ssh ${user}@${host} -p ${port} -i ${key} -o StrictHostKeyChecking=accept-new -s sftp\""

    # --- restic password (DR key) ---
    printf '\n'
    local pass passfile="${RESTIC_PASSWORD_FILE:-/etc/pbo/restic-pass}"
    if _yn "Generate a random repo password (recommended)?" y; then
        pass="$(openssl rand -base64 30 2>/dev/null || head -c22 /dev/urandom | base64)"
        echo "  Generated, export it afterwards (menu → Export DR key) and store it safely."
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
    echo; echo "  ${C_Y}# PBO DR key, SECRET. On a new host: install PBO, paste this, then list→restore${C_0}"
    echo "  RESTIC_OFFSITE_REPO=${RESTIC_OFFSITE_REPO:-<not set>}"
    echo "  RESTIC_SFTP_COMMAND=${RESTIC_SFTP_COMMAND:-<not set>}"
    echo "  ${C_B}RESTIC_PASSWORD=${pw}${C_0}"
    echo
    if _yn "Save a copy to /root/pbo-dr-key.txt (0600)?" n; then
        ( umask 077; { echo "RESTIC_OFFSITE_REPO=${RESTIC_OFFSITE_REPO}";
          echo "RESTIC_SFTP_COMMAND=${RESTIC_SFTP_COMMAND}"; echo "RESTIC_PASSWORD=${pw}"; } > /root/pbo-dr-key.txt )
        echo "  ${C_G}saved: /root/pbo-dr-key.txt${C_0}, move it offline and delete it from this host."
    fi
    _pause
}

# --- 6. RESTORE ---
menu_restore() {
    _menu_header
    printf '%s Restore%s\n\n' "$C_B" "$C_0"
    echo "  Fetching offsite archives…"
    local listing; listing="$("$PBO_BIN" --json list 2>/dev/null)"
    jq -e '.archives|length>0' <<<"$listing" >/dev/null 2>&1 \
        || { echo "  ${C_R}No offsite archives.${C_0}"; _pause; return; }

    local now; now="$(date +%s)"
    local names; names="$(_menu_guests_tsv | awk -F'\t' '{print $1"\t"$2}')"

    # --- STEP 1: pick a guest (vmid · name · #snapshots · newest age) ---
    local gv=() glabel=() vmid nsnap newest nm
    while IFS=$'\t' read -r vmid nsnap newest; do
        [[ -n "$vmid" ]] || continue
        nm="$(awk -F'\t' -v v="$vmid" '$1==v{print $2}' <<<"$names")"
        gv+=("$vmid")
        glabel+=("$(printf '%-6s %-18s %2d snapshots · newest %s' \
            "$vmid" "${nm:-–}" "$nsnap" "$(_ago "$newest" "$now")")")
    done < <(jq -r '.archives | group_by(.vmid)[]
        | [ .[0].vmid, length, ([.[].modtime]|max) ] | @tsv' <<<"$listing")

    printf '\n  %sGuests with backups:%s\n' "$C_B" "$C_0"
    local gi; gi="$(_pick_index "Guest" 1 "${glabel[@]}")" || { _pause; return; }
    local src="${gv[gi-1]}"

    # --- STEP 2: pick a snapshot of that guest (newest first) ---
    local sv=() slabel=() ts size modt snap
    while IFS=$'\t' read -r ts size modt snap; do
        [[ -n "$ts" ]] || continue
        sv+=("$ts")
        slabel+=("$(printf '%-9s · %7s · %s' \
            "$(_ago "$modt" "$now")" "$(_hsize "$size")" "$(sed 's/T/ /;s/\..*//' <<<"$modt")")")
    done < <(jq -r --arg v "$src" '.archives[] | select(.vmid==$v)
        | [ (.archive|capture("(?<t>[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2})").t),
            .size_bytes, .modtime, .snapshot ] | @tsv' <<<"$listing" | sort -rk3)
    [[ ${#sv[@]} -gt 0 ]] || { echo "  ${C_R}No snapshots for $src.${C_0}"; _pause; return; }

    printf '\n  %sSnapshots of %s · %s (newest first):%s\n' \
        "$C_B" "$src" "$(awk -F'\t' -v v="$src" '$1==v{print $2}' <<<"$names")" "$C_0"
    local si; si="$(_pick_index "Snapshot" 1 "${slabel[@]}")" || { _pause; return; }
    local ts="${sv[si-1]}"

    local used free=9100
    used="$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | jq -r '.[].vmid')"
    while grep -qx "$free" <<<"$used"; do free=$((free+1)); done
    local newid; newid="$(_ask "New VMID (never overwrites)" "$free")"
    # Storage must match the guest type: a VM needs images, a container needs rootdir.
    local arch content; arch="$(jq -r --arg v "$src" --arg t "$ts" '.archives[]|select(.vmid==$v and (.archive|test($t)))|.archive' <<<"$listing" | head -1)"
    case "$arch" in *qemu*) content=images ;; *) content=rootdir ;; esac
    local stores; stores="$(pvesh get /storage --output-format json 2>/dev/null | jq -r --arg c "$content" '.[]|select((.content//"")|test($c))|.storage')"
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
    printf '  %s[5]%s Health check (doctor)    %s[6]%s Rotate DR key\n' "$C_B" "$C_0" "$C_B" "$C_0"
    printf '  %s[7]%s Unlock repo (stale lock) %s[0]%s back\n\n' "$C_B" "$C_0" "$C_B" "$C_0"
    local c; c="$(_ask "Choice")"
    case "$c" in
        1) "$PBO_BIN" --dry-run prune; _pause ;;
        2) _yn "Run a REAL prune (deletes snapshots outside the policy)?" n && { "$PBO_BIN" prune; _pause; } ;;
        3) echo "  Verifying (this can take a while)…"; "$PBO_BIN" verify; _pause ;;
        4) local id; id="$(_ask "VMID to test-restore")"
           [[ "$id" =~ ^[0-9]+$ ]] && _yn "Test-restore $id (fetch→boot→destroy a throwaway copy)?" y && { "$PBO_BIN" test-restore "$id"; _pause; } ;;
        5) "$PBO_BIN" doctor; _pause ;;
        6) menu_rotate_key ;;
        7) _yn "Remove stale restic locks (only if no backup is running)?" n && { "$PBO_BIN" unlock; _pause; } ;;
        *) : ;;
    esac
}

# Rotate the repo password (DR key): generate or type a new one, rotate every
# repo, then offer to export the new key. The old key stops working afterwards.
menu_rotate_key() {
    _menu_header
    printf '%s Rotate DR key%s\n\n' "$C_B" "$C_0"
    echo "  This changes the repo password on ALL repos. restic re-encrypts nothing"
    echo "  (keys wrap the master key), but the OLD key stops working afterwards."
    echo "  ${C_Y}Export the new key and update your password manager immediately.${C_0}"
    echo
    _yn "Rotate the DR key now?" n || return
    local newpass tmp
    if _yn "Generate a random new password (recommended)?" y; then
        newpass="$(openssl rand -base64 30 2>/dev/null || head -c22 /dev/urandom | base64)"
    else
        newpass="$(_askpw "Enter the NEW repo password")"
        [[ -n "$newpass" ]] || { echo "  ${C_R}empty password, aborted.${C_0}"; _pause; return; }
    fi
    tmp="$(mktemp)"; ( umask 077; printf '%s\n' "$newpass" > "$tmp" )
    if "$PBO_BIN" rotate-key "$tmp"; then
        echo "  ${C_G}rotation complete.${C_0} The new DR key:"
        echo "    ${C_B}RESTIC_PASSWORD=${newpass}${C_0}"
        echo "  Store it now, then export via menu → Export DR key."
    else
        echo "  ${C_R}rotation failed, the OLD key is still valid.${C_0} See the log."
    fi
    shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
    _pause
}

# --- main menu ---
menu_main() {
    # Interactive: read/grep/[[ ]] often return !=0, the dispatcher's set -Eeuo
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
