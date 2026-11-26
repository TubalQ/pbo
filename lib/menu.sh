# shellcheck shell=bash
# lib/menu.sh: interactive prompt-CLI (rclone config style). Pure bash, zero
# dependencies, no alternate-screen → behaves identically over SSH/serial/tmux.
# Launched with `pbo menu`. This is the primary interactive interface.
#
# No business logic lives here; the menu shells out to `$PBO_BIN` (or reads
# --json). Config changes go through the config writer (_cfg_set below).

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

# _cfg_set KEY VALUE [KEY VALUE...]: the pairs in the config, as one
# transaction of the writer of `pbo config set` (_cfg_write, lib/config.sh:
# atomic, quoted, comments, owner and mode kept, a missing file created as the
# permission table says), and the effective values that change updated in this
# shell. Always the local file (PBO_CONFIG_LOCAL): never the cluster-shared
# /etc/pve/pbo/config. Each value is checked against the schema first; a key
# that follows another one (RESTIC_CACHE_REPO under CACHE_DIR) is not pinned at
# its derived default. The writer's after-write hooks run as they do for `pbo
# config set` (apply-schedule writes the timer drop-ins, restart-mount), and
# the change is audit-logged. A CACHE_DIR that changes is not written here: the
# cache move needs a pbo of its own (its journal, its locks), so the wizard runs
# `pbo config set CACHE_DIR` (_setup_cache_dir). confirm-repo is the caller's
# question: the wizard asks before it replaces a repo. Returns 1 (and says why
# on stderr) when nothing was written.
_cfg_set() {
    local -a ops=()
    if (( $# < 2 || $# % 2 )); then printf 'pbo: internal: _cfg_set KEY VALUE [KEY VALUE...]\n' >&2; return 1; fi
    while (( $# )); do ops+=(set "$1" "$2"); shift 2; done
    _cfg_change_local "${ops[@]}"
}

# _cfg_unset KEY...: the keys removed from the local config (as _cfg_set).
_cfg_unset() {
    local -a ops=(); local k
    for k in "$@"; do ops+=(unset "$k"); done
    (( ${#ops[@]} )) || return 0
    _cfg_change_local "${ops[@]}"
}

# _cfg_change_local OP...: _cfg_set's and _cfg_unset's transaction; OP is
# `set KEY VALUE` or `unset KEY`.
_cfg_change_local() {
    local op k v msg rc=0 hk st m cur new
    local -a ops=()
    _cfg_write_ensure
    while (( $# )); do
        op="$1"
        case "$op" in
            set)   if (( $# < 3 )); then printf 'pbo: internal: set KEY VALUE\n' >&2; return 1; fi
                   k="$2" v="$3"; shift 3 ;;
            unset) if (( $# < 2 )); then printf 'pbo: internal: unset KEY\n' >&2; return 1; fi
                   k="$2" v=''; shift 2 ;;
            *)     printf "pbo: internal: _cfg_change_local op '%s'\n" "$op" >&2; return 1 ;;
        esac
        if ! _cs_has "$k"; then printf 'pbo: %s is not a known config key, not written\n' "$k" >&2; return 1; fi
        if [[ "$(_cs_flag "$k" on_change 2>/dev/null)" == move-cache ]]; then
            cur="${!k-}" new="$v"
            if [[ -z "$new" ]]; then _cs_default_r "$k"; new="$_CS_R"; fi
            while [[ "$cur" == */ && "$cur" != / ]]; do cur="${cur%/}"; done
            while [[ "$new" == */ && "$new" != / ]]; do new="${new%/}"; done
            if [[ "$cur" != "$new" ]]; then
                printf "pbo: %s changes through 'pbo config set %s' (the cache move), not written\n" "$k" "$k" >&2; return 1
            fi
        fi
        if [[ "$op" == unset ]]; then ops+=(unset "$k"); continue; fi
        if ! msg="$(_cs_validate "$k" "$v")"; then printf 'pbo: %s, not written\n' "$msg" >&2; return 1; fi
        if [[ -n "$v" ]] && _cs_flag "$k" follows >/dev/null; then
            _cs_default_r "$k"
            # not when the shared file or the environment sets it: removing the
            # line would hand the key to that value (_cfg_key_elsewhere)
            if [[ "${v%/}" == "${_CS_R%/}" ]] && ! _cfg_key_elsewhere "$k" "$PBO_CONFIG_LOCAL"; then ops+=(unset "$k"); continue; fi
        fi
        ops+=(set "$k" "$v")
    done
    declare -ga CFGH=()
    _cfg_write "${ops[@]}" || rc=$?
    if (( rc )); then printf 'pbo: config: %s\n' "$CFGW_ERR" >&2; return 1; fi
    for k in "${!CFGW_EA[@]}"; do printf -v "$k" '%s' "${CFGW_EA[$k]}"; done
    (( CFGW_WRITTEN )) || return 0
    _cfg_set_audit
    _cfg_hooks_post || rc=1
    for hk in "${CFGH[@]+"${CFGH[@]}"}"; do
        IFS=$'\x1f' read -r hk st m <<<"$hk"
        [[ "$st" == skipped ]] || printf '  %s: %s\n' "$hk" "$m"
    done
    (( rc == 0 )) || printf 'pbo: config: %s was written, but a follow-up step failed (see above)\n' "$CFGW_FILE" >&2
    return 0
}

# _cfg_set_audit: the audit record of the change _cfg_write just made, as `pbo
# config set` writes it (a secret's value masked). Into the audit files only:
# the wizard says what it changed in its own words.
_cfg_set_audit() {
    local i k what=''
    for i in "${!CFGW_KEYS[@]}"; do
        k="${CFGW_KEYS[i]}"
        if [[ "${CFGW_OPS[i]}" == unset ]]; then what+=" unset=$k"
        elif _config_is_secret "$k"; then what+=" $k=<secret>"
        else what+=" $k=$(printf '%q' "$(_mask_url "${CFGW_VALS[i]}")")"; fi
    done
    audit_log "config set file=$CFGW_FILE$what (${PBO_COMMAND:-menu})" >/dev/null 2>&1 || true
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
    printf '  %s[4]%s This host (config + rebuild metadata)\n' "$C_B" "$C_0"
    printf '  %s[0]%s back\n\n' "$C_B" "$C_0"
    local c; c="$(_ask "Choice")"
    case "$c" in
        1) _yn "Back up all protected guests (stream)?" y && { "$PBO_BIN" run-schedule --stream; _pause; } ;;
        2) _yn "Back up all protected guests (batch)?" y && { "$PBO_BIN" run-schedule --batch; _pause; } ;;
        3) local id; id="$(_ask "VMID to back up")"
           [[ "$id" =~ ^[0-9]+$ ]] && _yn "Back up $id now?" y && { "$PBO_BIN" backup "$id"; _pause; } ;;
        4) printf '  %sSSH keys and the DR key are excluded for security — keep your own\n' "$C_Y"
           printf '  offline copy; they will NOT be in this backup.%s\n' "$C_0"
           _yn "Back up this host now?" y && { "$PBO_BIN" backup-host; _pause; } ;;
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
        (.physical_bytes // 0) as $p | (.logical_bytes // 0) as $l | (.uncompressed_bytes // 0) as $u
        | ($p/1e9*10|floor/10) as $pg | ($l/1e9*10|floor/10) as $lg
        | (if $p>0 then ($l/$p*10|floor/10) else 0 end) as $tot
        | (if $u>0 then ($l/$u*10|floor/10) else 0 end) as $dd
        | ((.compression_ratio // 0)*10|floor/10) as $cc
        | "    size:      \($pg) GB physical, \($lg) GB logical (\($tot)× total: dedup \($dd)× · compress \($cc)×)"' 2>/dev/null
    printf '%s' "$ls" | jq -r '
        (.archives | map(.modtime) | max) as $m
        | if $m then "    newest:    \($m | sub("\\..*";"") | sub("T";" "))" else empty end' 2>/dev/null
    printf '\n'
}

# One tier, DETAILED: every snapshot listed individually, grouped by guest
# (newest first within each guest). Reads the tier via the PBO_REPO override.
_menu_status_detail_tier() {    # <label> <cache|offsite>
    local label="$1" which="$2" ls
    printf '  %s%s%s\n' "$C_B" "$label" "$C_0"
    ls="$(PBO_REPO="$which" "$PBO_BIN" --json list --reasons 2>/dev/null)"
    if [[ -z "$ls" ]] || ! printf '%s' "$ls" | jq -e '.archives' >/dev/null 2>&1; then
        printf '    %s(unreachable)%s\n\n' "$C_R" "$C_0"; return
    fi
    if ! printf '%s' "$ls" | jq -e '.archives|length>0' >/dev/null 2>&1; then
        printf '    %s(no snapshots)%s\n\n' "$C_D" "$C_0"; return
    fi
    local now; now="$(date +%s)"
    local names; names="$(_menu_guests_tsv | awk -F'\t' '{print $1"\t"$2}')"
    local vmid nsnap nm modt size snap code keep
    while IFS=$'\t' read -r vmid nsnap; do
        [[ -n "$vmid" ]] || continue
        nm="$(awk -F'\t' -v v="$vmid" '$1==v{print $2}' <<<"$names")"
        [[ "$vmid" == host-* ]] && nm="host config"
        printf '    %s%-14s%s %-18s %s(%s)%s\n' "$C_C" "$vmid" "$C_0" "${nm:-–}" "$C_D" "$nsnap" "$C_0"
        while IFS=$'\t' read -r modt size snap code keep; do
            [[ -n "$modt" ]] || continue
            local tag; tag="[${code:-?}]"
            local row; row="$(printf '        %-19s  %-8s  %8s  %-6s %s' \
                "$(sed 's/T/ /;s/\..*//' <<<"$modt")" "$(_ago "$modt" "$now")" "$(_hsize "$size")" "$tag" "${snap:0:8}")"
            if [[ "$keep" == "false" ]]; then
                printf '%s%s%s %s(prunes next)%s\n' "$C_D" "$row" "$C_0" "$C_Y" "$C_0"
            else
                printf '%s\n' "$row"
            fi
        done < <(printf '%s' "$ls" | jq -r --arg v "$vmid" '
            .archives[]|select(.vmid==$v)
            | (.reasons // []) as $r
            | ( [ (if any($r[];test("daily"))   then "d" else empty end),
                  (if any($r[];test("weekly"))  then "w" else empty end),
                  (if any($r[];test("monthly")) then "m" else empty end),
                  (if any($r[];test("yearly"))  then "y" else empty end),
                  (if any($r[];test("last"))    then "L" else empty end) ] | join("") ) as $code
            | [.modtime,.size_bytes,.snapshot,$code,(.keep//true)]|@tsv' | sort -r)
    done < <(printf '%s' "$ls" | jq -r '.archives|group_by(.vmid)[]|[.[0].vmid,length]|@tsv' | sort)
    printf '\n'
}

# Run over the enabled tiers with a per-tier renderer (summary or detail).
_menu_status_tiers() {          # <renderer-fn>
    local render="$1"
    if [[ "${LOCAL_REPO:-true}" == "true" ]]; then
        "$render" "Local  (cache: ${CACHE_DIR:-?})" cache
    else
        printf '  %sLocal%s\n    %s(offsite-only mode, no local cache repo)%s\n\n' "$C_B" "$C_0" "$C_D" "$C_0"
    fi
    if [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        "$render" "Offsite (${RESTIC_OFFSITE_REPO})" offsite
    fi
    printf '  %snext scheduled run:%s\n' "$C_B" "$C_0"
    systemctl list-timers pbo.timer --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/    /'
    echo
}

_menu_status_summary() {
    _menu_header
    printf '%s Status — summary%s\n\n' "$C_B" "$C_0"
    printf '  %sReading both tiers…%s\n\n' "$C_D" "$C_0"
    _menu_status_tiers _menu_status_tier
    _pause
}

_menu_status_detailed() {
    _menu_header
    printf '%s Status — every snapshot%s\n\n' "$C_B" "$C_0"
    printf '  %sretention: d=daily w=weekly m=monthly y=yearly L=last · %sdimmed = prunes next run%s\n' "$C_D" "$C_Y" "$C_0"
    printf '  %sReading both tiers…%s\n\n' "$C_D" "$C_0"
    _menu_status_tiers _menu_status_detail_tier
    _pause
}

menu_status() {
    _menu_header
    printf '%s Status%s\n\n' "$C_B" "$C_0"
    printf '  %s[1]%s Summary (sizes, dedup, newest)\n' "$C_B" "$C_0"
    printf '  %s[2]%s Detailed (every snapshot, both tiers)\n' "$C_B" "$C_0"
    printf '  %s[0]%s back\n\n' "$C_B" "$C_0"
    local c; c="$(_ask "View" "1")"
    case "$c" in
        2)     _menu_status_detailed ;;
        1|"")  _menu_status_summary ;;
        *)     : ;;
    esac
}

# --- SETUP WIZARD: prompts and checks (unit-tested in tests/menu.sh) ---
# `pbo setup` is safe to run again (ADR 0009, "Wizard"): every default is the
# effective config, Enter keeps it, an offsite repo is shown and kept unless
# the operator chooses to change it, and a value the operator keeps is not
# written again. Config changes go through the writer (_cfg_set, and `pbo
# config set CACHE_DIR` for the cache move); the files of its own the wizard
# writes (the DR key, a rest-server password, RESTIC_ENV_FILE, the pinned host
# keys) go through _setup_write_file. Every question reads through
# _setup_read (yes/no, a value, a choice, a secret), in this shell: the end of
# the input stops the wizard there (_setup_eof, exit 64). An answer nobody
# gave is never taken as the default, and nothing after that question is
# written.

SETUP_EOF=0 SETUP_FIX_PARENTS=0 SETUP_PARENTS_HINT=0 SETUP_RERUN=0 SETUP_STEP='' SETUP_RC=0
SETUP_FAILS=()
_SP_EXTRA=()
# filesystems the cache step suggests: disk filesystems (mount types as findmnt
# and df print them); everything else (tmpfs, network, FUSE, vfat, ...) is
# left out of the list (the cache move refuses or warns about most of them)
SETUP_FS_DISK=' ext2 ext3 ext4 xfs btrfs zfs f2fs jfs reiserfs bcachefs '

# _ask_r PROMPT [DEFAULT] → _A: the answer, or DEFAULT for an empty one;
# _A_RAW: the line as read. Returns 1 at the end of the input (stdin closed).
_ask_r() {
    local a rc=0
    read -r -p "$1${2:+ [$2]}: " a || rc=1
    _A_RAW="$a" _A="${a:-${2:-}}"
    return "$rc"
}

# _setup_eof PROMPT: the input ended at PROMPT. The wizard stops here with 64
# (a usage error: the answers were short), in this shell: a default is never
# taken for an answer nobody gave, so a script piping too few answers cannot
# set up a host with defaults it did not choose. What earlier questions wrote
# stays (each step writes as it goes), nothing after PROMPT is changed.
_setup_eof() {
    printf '\n  %sThe input ended at the question "%s": setup stops in the %s step (exit 64).%s\n' \
        "$C_R" "$1" "${SETUP_STEP:-first}" "$C_0"
    printf '  What the answers before it set is written; nothing after this question was changed. Run pbo setup again to go on.\n'
    exit "${EX_USAGE:-64}"
}

# _setup_read PROMPT [DEFAULT] → _A (as _ask_r): the end of the input stops
# the wizard (_setup_eof). A last line without a newline is still an answer:
# the question after it stops.
_setup_read() {
    (( ! SETUP_EOF )) || _setup_eof "$1"
    if ! _ask_r "$1" "${2:-}"; then
        [[ -n "$_A_RAW" ]] || _setup_eof "$1"
        SETUP_EOF=1
    fi
    return 0
}

# _setup_askpw PROMPT → _A: a secret, read without echo (as _setup_read).
_setup_askpw() {
    local a rc=0
    (( ! SETUP_EOF )) || _setup_eof "$1"
    read -r -s -p "$1: " a || rc=1
    echo >&2
    if (( rc )); then [[ -n "$a" ]] || _setup_eof "$1"; SETUP_EOF=1; fi
    _A="$a"
}

# _setup_pick PROMPT DEFAULT LABEL... → _PI: a numbered list of the labels,
# then the chosen 1-based index (Enter: DEFAULT). Returns 1 on an answer that
# is no choice. The wizard's _pick_index: it reads in this shell, so the end of
# the input stops the wizard instead of choosing the default.
_setup_pick() {
    local prompt="$1" def="$2" i=1 lbl
    shift 2
    for lbl in "$@"; do printf '    %s[%d]%s %s\n' "$C_B" "$i" "$C_0" "$lbl"; i=$((i+1)); done
    _setup_read "$prompt" "$def"
    _PI="$_A"
    [[ "$_PI" =~ ^[0-9]+$ ]] && (( 10#$_PI >= 1 && 10#$_PI <= $# ))
}

# _setup_yn PROMPT DEFAULT(y|n): yes or no.
_setup_yn() { _setup_read "$1 (y/n)" "${2:-n}"; [[ "$_A" == [yYjJ]* ]]; }

# _setup_ask PROMPT DEFAULT CHECK → _SV: ask until `CHECK ANSWER` accepts it
# (it prints why not).
_setup_ask() {
    local p="$1" d="$2" chk="$3" msg
    while true; do
        _setup_read "$p" "$d"
        if msg="$("$chk" "$_A")"; then _SV="$_A"; return 0; fi
        printf '  %s%s: try again%s\n' "$C_Y" "$msg" "$C_0"
    done
}

# _setup_ask_keep PROMPT CURRENT CHECK → _SV: as _setup_ask for a secret:
# CURRENT is not shown, Enter keeps it.
_setup_ask_keep() {
    local p="$1" cur="$2" chk="$3" msg
    [[ -z "$cur" ]] || p+=" (Enter keeps the current one)"
    while true; do
        _setup_read "$p" ""
        [[ -n "$_A" ]] || _A="$cur"
        if msg="$("$chk" "$_A")"; then _SV="$_A"; return 0; fi
        printf '  %s%s: try again%s\n' "$C_Y" "$msg" "$C_0"
    done
}

# _setup_ask_key KEY PROMPT [DEFAULT] → _SV: a value the schema accepts for KEY
# (type, bounds, enum values: _cs_validate), asked until it is one. DEFAULT:
# KEY's effective value.
_setup_ask_key() {
    local k="$1" p="$2" d
    if (( $# >= 3 )); then d="$3"; else d="${!k-}"; fi
    _SETUP_K="$k"
    _setup_ask "$p" "$d" _setup_chk_key
}
_setup_chk_key() { _cs_validate "$_SETUP_K" "$1"; }
_setup_chk_key_set() { [[ -n "$1" ]] || { printf 'a value, please'; return 1; }; _cs_validate "$_SETUP_K" "$1"; }

# the checks _setup_ask runs on an answer (each prints why it refuses one)
_setup_chk_abs() { [[ "$1" == /* ]] || { printf "'%s' is not an absolute path" "$1"; return 1; }; }
# a path that goes into the ssh command line (split on blanks)
_setup_chk_abs_nb() { _setup_chk_abs "$1" || return 1; [[ "$1" != *[[:space:]]* ]] || { printf 'a path without blanks, please'; return 1; }; }
_setup_chk_abs_opt() { [[ -z "$1" ]] || _setup_chk_abs_nb "$1"; }
_setup_chk_host() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] && return 0
    _setup_is_v6 "$1" && return 0
    printf "'%s' is not a host name, IPv4 or IPv6 address" "$1"; return 1
}
# _setup_is_v6 HOST: an IPv6 literal, bare or in brackets (2001:db8::5, [2001:db8::5])
_setup_is_v6() {
    local re='^(\[[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*\]|[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*)$'
    [[ "$1" =~ $re ]]
}
# _setup_unbracket HOST: HOST without the brackets of an IPv6 literal
_setup_unbracket() { local h="$1"; [[ "$h" == \[*\] ]] && { h="${h#\[}"; h="${h%\]}"; }; printf '%s' "$h"; }
_setup_chk_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )) || { printf "'%s' is not a port (1-65535)" "$1"; return 1; }; }
_setup_chk_user() { [[ "$1" =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]] || { printf "'%s' is not a user name" "$1"; return 1; }; }
_setup_chk_user_opt() { [[ -z "$1" ]] || _setup_chk_user "$1"; }
_setup_chk_set() { [[ -n "$1" ]] || { printf 'a value, please'; return 1; }; }
_setup_chk_rpath() { [[ -n "$1" && "$1" != *[[:space:]]* ]] || { printf 'a path without blanks, please'; return 1; }; }
_setup_chk_rest_url() {
    [[ "$1" =~ ^https?://[^[:space:]/]+(/[^[:space:]]*)?$ ]] || { printf "'%s' is not an http(s) URL" "$1"; return 1; }
    # the login goes into RESTIC_REST_USERNAME and a password file, so that it
    # is in no repo string pbo logs or shows
    [[ ! "$1" =~ ^https?://[^/]*@ ]] || { printf 'give the URL without the login: the wizard asks for the user and keeps the password in a file'; return 1; }
}
_setup_chk_repo_other() {
    [[ "$1" =~ ^[A-Za-z][A-Za-z0-9+.-]*:[^[:space:]]+$ ]] || { printf "'%s' is not a restic repository string (<backend>:<location>)" "$1"; return 1; }
    case "$1" in
        sftp:*|rest:*) printf "choose the %s type for it (the wizard sets up its login)" "${1%%:*}"; return 1 ;;
        local:*) printf 'choose the directory type for it'; return 1 ;;
    esac
}
_setup_chk_envname() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf "'%s' is not a variable name" "$1"; return 1; }
    if declare -F _restic_env_refused >/dev/null && _restic_env_refused "$1"; then
        printf "%s cannot be set there: pbo sets it for restic itself, it changes what runs, or it is a config key" "$1"; return 1
    fi
}
_setup_chk_ntfy_url() { [[ -n "$1" ]] || { printf 'a URL, please'; return 1; }; _cs_validate NTFY_URL "$1"; }

# _setup_set KEY VALUE [KEY VALUE...]: _cfg_set the pairs whose value differs
# from the effective one, so that keeping an answer writes nothing.
_setup_set() {
    local -a pairs=()
    while (( $# >= 2 )); do
        [[ "${!1-}" == "$2" ]] || pairs+=("$1" "$2")
        shift 2
    done
    (( ${#pairs[@]} )) || return 0
    _cfg_set "${pairs[@]}"
}

# _setup_change OP...: as _setup_set for `set KEY VALUE` and `unset KEY` ops,
# in one transaction; an unset of a key that already has its default value is
# left out (there is nothing to remove). The writer only removes lines from the
# local file, so a key that another config file (the cluster-shared one) or
# the environment sets is written back to its default there instead: a local
# line wins over both (load_config), and removing nothing would leave the
# other value in effect while the wizard says it is off.
_setup_change() {
    local -a ops=() unsets=()
    local k d
    while (( $# )); do
        case "$1" in
            set)   [[ "${!2-}" == "$3" ]] || ops+=(set "$2" "$3"); shift 3 ;;
            unset) k="$2"; shift 2
                   _cs_default_r "$k"; d="$_CS_R"
                   [[ "${!k-}" != "$d" ]] || continue
                   unsets+=("$k")
                   if _cfg_key_elsewhere "$k" "${PBO_CONFIG_LOCAL:-}"; then ops+=(set "$k" "$d"); else ops+=(unset "$k"); fi ;;
            *) shift ;;
        esac
    done
    (( ${#ops[@]} )) || return 0
    _cfg_change_local "${ops[@]}" || return 1
    # the safety net: a key still not at its default is said, not hidden
    for k in "${unsets[@]+"${unsets[@]}"}"; do
        _cs_default_r "$k"
        [[ "${!k-}" == "$_CS_R" ]] || { printf 'pbo: %s is still %s (set outside the local config): change it there\n' "$k" "$(_mask_url "${!k-}")" >&2; return 1; }
    done
    return 0
}

# _setup_cfg_has KEY: the config files or the environment give KEY its value
# (load_config's CFG_SRC, CFG_ENV), i.e. it is not at its default.
_setup_cfg_has() {
    declare -p CFG_SRC >/dev/null 2>&1 && [[ -n "${CFG_SRC[$1]+x}" ]] && return 0
    declare -p CFG_ENV >/dev/null 2>&1 && [[ -n "${CFG_ENV[$1]:-}" ]]
}

# _setup_rerun_check: an earlier setup exists: the config (or the environment)
# names an offsite repo, the DR key exists, or the local cache repo does. Taken
# once, before the first step changes any of them (SETUP_RERUN): a re-run's
# defaults keep what is there (the cache step's suggestion is a hint only, a
# timer that is off stays off on Enter).
_setup_rerun_check() {
    _setup_cfg_has RESTIC_OFFSITE_REPO && return 0
    [[ -n "${RESTIC_PASSWORD_FILE:-}" && -s "$RESTIC_PASSWORD_FILE" ]] && return 0
    [[ -n "${RESTIC_CACHE_REPO:-}" && -e "$RESTIC_CACHE_REPO/config" ]]
}

# _setup_pbo ARGS...: run pbo (no input: the wizard's own stdin carries the
# answers), its output indented as it comes and kept in _SETUP_OUT; pbo's
# exit status.
_setup_pbo() {
    local l
    _SETUP_OUT=''
    while IFS= read -r l; do printf '    %s\n' "$l"; _SETUP_OUT+="$l"$'\n'; done < <("$PBO_BIN" "$@" </dev/null 2>&1)
    wait "$!"
}

# _setup_refresh: the effective values of every key that is not a secret, as a
# pbo of its own reads them after a change it made (the cache move): this
# shell still holds the old ones. Secrets keep the values this shell has.
# pbo's JSON masks a login in any value (sftp:***@host:path, https://***@...):
# a value that is only the masked form of the one this shell holds is that one
# (_mask_url is the shell twin of the JSON mask), so the shell keeps it. A key
# the move really changed (CACHE_DIR, a path that follows it) holds no login.
_setup_refresh() {
    local out k v
    out="$("$PBO_BIN" --json config list --all </dev/null 2>/dev/null)" || return 1
    while IFS=$'\x1f' read -r -d $'\x1e' k v; do
        [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        [[ "$v" == *'***'* && -n "${!k-}" && "$(_mask_url "${!k}")" == "$v" ]] && continue
        printf -v "$k" '%s' "$v" 2>/dev/null || true
    done < <(jq -j '.keys[]? | select(.known and (.secret | not)) | .key + "\u001f" + (.value // "") + "\u001e"' <<<"$out" 2>/dev/null)
    return 0
}

# _setup_write_file FILE MODE [CHECK]: FILE replaced by what stdin holds,
# atomically: a temp file in FILE's directory (the directory created 0700 when
# missing) with MODE, `CHECK TEMP` run on it first (it prints why not; nothing
# is replaced then), then renamed over FILE. A symlink or anything but a
# regular file at FILE is refused: root would write where it points.
_setup_write_file() {
    local f="$1" mode="$2" chk="${3:-}" d tmp msg
    [[ "$f" == /* ]] || { printf 'pbo: %s is not an absolute path, not written\n' "$f" >&2; return 1; }
    if [[ -L "$f" ]] || [[ -e "$f" && ! -f "$f" ]]; then printf 'pbo: %s is a symlink or not a regular file, not written\n' "$f" >&2; return 1; fi
    d="$(dirname -- "$f")"
    [[ -d "$d" ]] || ( umask 077; mkdir -p -- "$d" ) || { printf 'pbo: cannot create %s\n' "$d" >&2; return 1; }
    tmp="$(mktemp -- "$d/.${f##*/}.pbo.XXXXXX")" || { printf 'pbo: cannot write in %s\n' "$d" >&2; return 1; }
    if ! cat > "$tmp" || ! chmod "$mode" -- "$tmp"; then rm -f -- "$tmp"; printf 'pbo: cannot write %s\n' "$tmp" >&2; return 1; fi
    if [[ -n "$chk" ]] && ! msg="$("$chk" "$tmp")"; then rm -f -- "$tmp"; printf 'pbo: %s not written: %s\n' "$f" "$msg" >&2; return 1; fi
    sync -- "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$f" || { rm -f -- "$tmp"; printf 'pbo: cannot replace %s\n' "$f" >&2; return 1; }
}

# --- the cache step's view of the local filesystems ---

# _setup_fs_raw: one line per mount of a disk filesystem (SETUP_FS_DISK),
# "target fstype size avail options source" (sizes in bytes; findmnt -r writes
# a blank in a name as \x20). df when there is no findmnt (no options there:
# every mount counts as read-write). The tool filters by type itself: the sizes
# need a statfs of each mount it lists, and one of a hard NFS mount whose
# server is gone never returns (PVE mounts its NFS storages hard), so setup
# would hang before its first question. findmnt fills the columns only for the
# rows that match -t; GNU df drops the other types (and with -l every remote
# filesystem) before it calls statfs.
_setup_fs_raw() {
    local l="${SETUP_FS_DISK# }" t
    local -a dt=()
    l="${l% }"
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -rn -b -t "${l// /,}" -o TARGET,FSTYPE,SIZE,AVAIL,OPTIONS,SOURCE 2>/dev/null
    else
        for t in $l; do dt+=(-t "$t"); done
        df -P -T -B1 -l "${dt[@]}" 2>/dev/null | awk 'NR > 1 { print $7, $2, $3, $5, "rw", $1 }'
    fi
}

# _setup_mount_points: every mount point, one per line (findmnt -r escapes a
# blank as \x20, /proc/self/mounts as \040). Only names: neither source calls
# statfs, so a dead network mount cannot hang it, and a path on a network
# mount is still mapped to that mount, not to the disk mount above it.
_setup_mount_points() {
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -rn -o TARGET 2>/dev/null
    else
        awk '{ print $2 }' /proc/self/mounts 2>/dev/null
    fi
}

# _setup_fs_rows: the filesystems a cache could live on, "target<TAB>fstype<TAB>
# size<TAB>avail", the most free space first: disk filesystems
# (SETUP_FS_DISK), mounted read-write, and not a guest's own volume (the
# subvol-/basevol- datasets PVE mounts for containers). One row per
# filesystem: the datasets of a ZFS pool share its free space, and a bind
# mount is its source again (the row with the shortest mount point stays).
_setup_fs_rows() {
    local t fs sz av op src key
    local -A seen=()
    while read -r t fs sz av op src; do
        printf -v t '%b' "$t"
        [[ "$sz" =~ ^[0-9]+$ && "$av" =~ ^[0-9]+$ ]] || continue
        [[ "$SETUP_FS_DISK" == *" $fs "* && ",$op," != *,ro,* ]] || continue
        case "$t" in */subvol-*-disk-*|*/basevol-*) continue ;; esac
        if [[ "$fs" == zfs ]]; then key="zfs:${src%%/*}"; else key="$fs:${src%%\[*}"; fi
        [[ -z "${seen[$key]+x}" ]] || continue
        seen[$key]=1
        printf '%s\t%s\t%s\t%s\n' "$t" "$fs" "$sz" "$av"
    done < <(_setup_fs_raw | awk '{ print length($1), $0 }' | sort -s -n -k1,1 | cut -d' ' -f2-) | sort -t $'\t' -k4,4nr
}

# _setup_mount_of PATH: the mount point PATH lies on (the longest mount point
# that contains it).
_setup_mount_of() {
    local p="$1" t best=''
    while read -r t; do
        printf -v t '%b' "$t"
        if [[ "$p" == "$t" || "$t" == / || "$p" == "${t%/}"/* ]] && (( ${#t} > ${#best} )); then best="$t"; fi
    done < <(_setup_mount_points)
    printf '%s' "$best"
}

# _setup_cache_suggest ROWS CURRENT: the CACHE_DIR to offer: on the filesystem
# with the most free space (the first of ROWS), CURRENT when it is on that one
# already, the schema default when that lies on that filesystem (a separate,
# smaller /var mount does not count as the root filesystem), else
# <mount>/pbo-cache.
_setup_cache_suggest() {
    local rows="$1" cur="$2" t
    t="${rows%%$'\t'*}"
    [[ -n "$rows" && -n "$t" ]] || return 0
    if [[ -n "$cur" && "$(_setup_mount_of "$cur")" == "$t" ]]; then printf '%s' "$cur"; return 0; fi
    _cs_default_r CACHE_DIR
    if [[ -n "$_CS_R" && "$(_setup_mount_of "$_CS_R")" == "$t" ]]; then printf '%s' "$_CS_R"; return 0; fi
    printf '%s/pbo-cache' "${t%/}"
}

# _setup_largest_guest: the estimated size (bytes) of the largest dump among
# this node's guests (_guest_bytes): every disk of a VM, a container's rootfs
# plus the mpN volumes it backs up. PVE's maxdisk is only a VM's boot disk, the
# lowest estimate exactly for the multi-disk guests the warning is for. Empty
# when the node has no guests.
_setup_largest_guest() {
    local v b max=0
    declare -F _guest_bytes >/dev/null && declare -F _all_local_vmids >/dev/null || return 0
    while read -r v; do
        [[ "$v" =~ ^[0-9]+$ ]] || continue
        b="$(_guest_bytes "$v" </dev/null 2>/dev/null)"
        [[ "$b" =~ ^[0-9]+$ ]] && (( b > max )) && max=$b
    done < <(_all_local_vmids </dev/null 2>/dev/null)
    (( max > 0 )) && printf '%s' "$max"
    return 0
}

# _setup_root_small ROOTSIZE GUEST: the root filesystem (bytes) is smaller than
# 1.5 times the largest guest's dump (bytes): a cache there fills it. Neither
# known (or no guest): no.
_setup_root_small() {
    [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] && (( $2 > 0 && $1 * 2 < $2 * 3 ))
}

# _setup_cache_step: LOCAL_REPO and CACHE_DIR. The local filesystems with their
# free space are listed and the one with the most is suggested. The suggestion
# is the default only on a first setup (SETUP_RERUN=0) when the config names
# no CACHE_DIR and the current one holds no data; otherwise the effective
# CACHE_DIR is the default and the suggestion a hint (an offsite-only host has
# an empty cache between backups: Enter must not move it). A warning when the
# root filesystem is smaller than 1.5 times the largest guest: a cache there
# fills it.
_setup_cache_step() {
    printf '\n%s— Cache —%s\n' "$C_B" "$C_0"
    printf '%sCACHE_DIR holds the dump of a running backup and, with a local cache repo, that repo (fast local restores).%s\n' "$C_D" "$C_0"
    local rows t fs sz av rootsz big cur def sug lr=n
    rows="$(_setup_fs_rows | head -n 8)"
    if [[ -n "$rows" ]]; then
        printf '  Local filesystems, the most free space first:\n'
        while IFS=$'\t' read -r t fs sz av; do
            printf '    %-32s %9s free of %-9s %s\n' "$t" "$(_hsize "$av")" "$(_hsize "$sz")" "$fs"
        done <<<"$rows"
    fi
    rootsz="$(_setup_fs_raw | awk '$1 == "/" { print $3; exit }')"
    big="$(_setup_largest_guest)"
    if _setup_root_small "$rootsz" "$big"; then
        printf '  %sWARN the root filesystem (%s) is smaller than 1.5 x the largest guest (%s): keep the cache off it.%s\n' \
            "$C_Y" "$(_hsize "$rootsz")" "$(_hsize "$big")" "$C_0"
    fi
    [[ "${LOCAL_REPO:-true}" == true ]] && lr=y
    if _setup_yn "Keep a local cache repo (fast local restores; needs room for a copy of the backups)?" "$lr"; then
        _setup_set LOCAL_REPO true || return 1
    else
        _setup_set LOCAL_REPO false || return 1
        printf '  Offsite only: CACHE_DIR holds a dump only while it is uploaded.\n'
    fi
    cur="${CACHE_DIR:-}"
    while [[ "$cur" == */ && "$cur" != / ]]; do cur="${cur%/}"; done
    sug="$(_setup_cache_suggest "$rows" "$cur")"
    def="$cur"
    if (( ! SETUP_RERUN )) && [[ -n "$sug" ]] && ! _setup_cfg_has CACHE_DIR \
       && [[ -z "$(find "$cur" -mindepth 1 ! -type d -print -quit 2>/dev/null)" ]]; then
        def="$sug"
    fi
    [[ -z "$sug" || "$sug" == "$def" ]] || printf '  Suggestion: %s (on the filesystem with the most free space)\n' "$sug"
    _setup_cache_dir "$cur" "$def"
}

# _setup_cache_dir CURRENT DEFAULT: ask for CACHE_DIR and set it through `pbo
# config set CACHE_DIR` (the writer's move-cache hook: an empty cache gets the
# new directory with the permission table's rules, one with data is moved).
# Another path than CURRENT first shows the dry run of that change and runs it
# on a yes; when the plan says an unprivileged CT cannot pass a directory
# above it, --fix-parents is offered (the dry run again with it); doctor --fix
# gets it too (SETUP_FIX_PARENTS) only once the move with it went through. The
# same path writes nothing: a re-run never pins a default, and a CACHE_DIR the
# cluster-shared file sets is not overridden on this node for good (pbo config
# set CACHE_DIR with the same path moves nothing anyway).
_setup_cache_dir() {
    local cur="$1" def="$2" p rc again=0
    local -a fp=()
    while true; do
        if (( ! again )); then
            _setup_ask "Cache directory (CACHE_DIR)" "$def" _setup_chk_abs || return 1
            p="$_SV"; while [[ "$p" == */ && "$p" != / ]]; do p="${p%/}"; done
        fi
        again=0
        if [[ "$p" == "$cur" ]]; then
            printf '  CACHE_DIR stays %s.\n' "$cur"
            return 0
        fi
        printf '  %sWhat changing CACHE_DIR to %s does (dry run, nothing changed yet):%s\n' "$C_B" "$p" "$C_0"
        _setup_pbo --dry-run config set CACHE_DIR "$p" --yes "${fp[@]+"${fp[@]}"}"; rc=$?
        if (( ${#fp[@]} == 0 )) && [[ "$_SETUP_OUT" == *--fix-parents* ]]; then
            if _setup_yn "A directory above $p does not let an unprivileged CT through. Add a traverse-only ACL entry there (--fix-parents)?" y; then
                fp=(--fix-parents); again=1; continue
            fi
        fi
        if (( rc != 0 )); then
            printf '  %spbo would not change CACHE_DIR to %s (see above).%s\n' "$C_Y" "$p" "$C_0"
            if _setup_yn "Choose another directory?" y; then fp=(); continue; fi
            printf '  CACHE_DIR stays %s.\n' "$cur"; return 0
        fi
        if ! _setup_yn "Change CACHE_DIR to $p as shown?" y; then printf '  CACHE_DIR stays %s.\n' "$cur"; return 0; fi
        if _setup_pbo config set CACHE_DIR "$p" --yes "${fp[@]+"${fp[@]}"}"; then
            # (an empty cache: the permission table may name a parent the
            # dry run did not check; doctor --fix offers it at the end)
            (( ${#fp[@]} )) || [[ "$_SETUP_OUT" != *--fix-parents* ]] || SETUP_PARENTS_HINT=1
            # the operator agreed to the ACL entries for this path, and it is
            # the CACHE_DIR now (not for one declined or refused above)
            (( ! ${#fp[@]} )) || SETUP_FIX_PARENTS=1
            printf '  %sCACHE_DIR is %s.%s\n' "$C_G" "$p" "$C_0"
        else
            printf "  %sCACHE_DIR was not changed, or the move did not finish (see above: 'pbo config set CACHE_DIR %s --resume' or --abort).%s\n" "$C_Y" "$p" "$C_0"
        fi
        _setup_refresh
        return 0
    done
}

# --- the offsite target ---

# Build the ssh command restic uses as its sftp.command. When <khfile> is given
# the host key is pinned (StrictHostKeyChecking=yes); otherwise it is trust-on-
# first-use (accept-new). EXTRA: more ssh options of an existing command the
# wizard keeps (_SP_EXTRA: a ProxyJump, -F, keep-alives), as words, before the
# remote command. The bare command line: _cfg_set quotes it. An IPv6 host goes
# in bare: the port is in -p, so ssh needs no brackets.
_pbo_sftp_command() {   # <user> <host> <port> <key> [khfile] [extra...]
    local user="$1" host="$2" port="$3" key="$4" kh="${5:-}" x=''
    (( $# > 5 )) && { shift 5; x=" $*"; }
    if [[ -n "$kh" ]]; then
        printf 'ssh %s@%s -p %s -i %s -o UserKnownHostsFile=%s -o StrictHostKeyChecking=yes%s -s sftp' \
            "$user" "$host" "$port" "$key" "$kh" "$x"
    else
        printf 'ssh %s@%s -p %s -i %s -o StrictHostKeyChecking=accept-new%s -s sftp' \
            "$user" "$host" "$port" "$key" "$x"
    fi
}

# Probe the SFTP target with the sftp client, using the same key and known_hosts
# restic will use. Returns 0 on a successful login. Pure network I/O, no writes.
# EXTRA: the ssh options the command keeps (_pbo_sftp_command), those that
# change how or where ssh connects in the form sftp takes them (sftp has its
# own meaning for some of ssh's letters: -b, -B, -D, -l, -R, -S); the others
# (forwardings, logging) do not change the login and are left out.
_pbo_sftp_probe() {     # <user> <host> <port> <key> [khfile] [extra...]
    local user="$1" host="$2" port="$3" key="$4" kh="${5:-}" w dest
    local opts=(-P "$port" -i "$key" -o BatchMode=yes -o ConnectTimeout=15)
    if [[ -n "$kh" ]]; then opts+=(-o "UserKnownHostsFile=$kh" -o StrictHostKeyChecking=yes)
    else opts+=(-o StrictHostKeyChecking=accept-new); fi
    if (( $# > 5 )); then
        shift 5
        while (( $# )); do
            w="$1"; shift
            case "$w" in
                -o|-F|-J|-c) (( $# )) && { opts+=("$w" "$1"); shift; } ;;
                -b) (( $# )) && { opts+=(-o "BindAddress=$1"); shift; } ;;
                -B) (( $# )) && { opts+=(-o "BindInterface=$1"); shift; } ;;
                -m) (( $# )) && { opts+=(-o "MACs=$1"); shift; } ;;
                -S) (( $# )) && { opts+=(-o "ControlPath=$1"); shift; } ;;
                -[DEeILOQRWw]) (( $# )) && shift ;;
                -4|-6|-C|-A) opts+=("$w") ;;
            esac
        done
    fi
    # sftp takes an IPv6 destination in brackets
    dest="$host"; [[ "$host" != *:* ]] || dest="[$host]"
    printf 'bye\n' | sftp "${opts[@]}" "${user}@${dest}" >/dev/null 2>&1
}

# _setup_sftp_parse REPO COMMAND → _SP_USER _SP_HOST _SP_PORT _SP_KEY _SP_KH _SP_PATH
# _SP_LABEL: what an sftp repo (sftp:[user@]host:path, sftp://[user@]host[:port]/path)
# and its RESTIC_SFTP_COMMAND say, for the wizard's defaults. restic connects
# with the command when there is one, so its destination, -p, -i, -l and -o
# (Port, User, IdentityFile, UserKnownHostsFile) win; the repo's host is then
# only a label (_SP_LABEL, as 0.5's sftp:storagebox:pbo). Empty where neither
# says: ssh's default (port 22, the default keys). An IPv6 host is given in
# brackets in the repo (sftp:user@[2001:db8::5]:path) and may be bare in the
# command's destination; _SP_HOST holds it without brackets. Every other
# option of the command (-F, -J, -o ProxyJump=, keep-alives, -4, -C, ...)
# goes to _SP_EXTRA as words (an -o option as `-o` and its value), so that a
# rebuilt command keeps it; StrictHostKeyChecking is the wizard's own (set by
# the pinning), the remote command (-s sftp) restic's.
_setup_sftp_parse() {
    local repo="$1" cmd="$2" ru='' rh='' rp='' w dest='' lu='' i=1 n
    local -a t=()
    _SP_USER='' _SP_HOST='' _SP_PORT='' _SP_KEY='' _SP_KH='' _SP_PATH='' _SP_LABEL='' _SP_OUSER=''
    _SP_EXTRA=()
    if [[ "$repo" =~ ^sftp://(([^@/]+)@)?\[([0-9A-Fa-f:.]+)\](:([0-9]+))?/(.*)$ ]]; then
        ru="${BASH_REMATCH[2]}" rh="${BASH_REMATCH[3]}" rp="${BASH_REMATCH[5]}" _SP_PATH="${BASH_REMATCH[6]}"
    elif [[ "$repo" =~ ^sftp:(([^@/]+)@)?\[([0-9A-Fa-f:.]+)\]:(.*)$ ]]; then
        ru="${BASH_REMATCH[2]}" rh="${BASH_REMATCH[3]}" _SP_PATH="${BASH_REMATCH[4]}"
    elif [[ "$repo" =~ ^sftp:(//)?([^@/]+@)?\[ ]]; then
        :   # a bracket that does not close: nothing is guessed from it
    elif [[ "$repo" =~ ^sftp://(([^@/]+)@)?([^/:]+)(:([0-9]+))?/(.*)$ ]]; then
        ru="${BASH_REMATCH[2]}" rh="${BASH_REMATCH[3]}" rp="${BASH_REMATCH[5]}" _SP_PATH="${BASH_REMATCH[6]}"
    elif [[ "$repo" =~ ^sftp:(([^@:/]+)@)?([^:/]+):(.*)$ ]]; then
        ru="${BASH_REMATCH[2]}" rh="${BASH_REMATCH[3]}" _SP_PATH="${BASH_REMATCH[4]}"
    fi
    read -r -a t <<<"$cmd"
    n="${#t[@]}"
    # word 0 is ssh itself. OpenSSH reads options before and after the
    # destination (the wizard writes them after it); the first word that is no
    # option is the destination, later ones the remote command (sftp)
    while (( i < n )); do
        w="${t[i]}"
        if [[ -n "$dest" && "$w" != -* ]]; then i=$((i+1)); continue; fi   # the remote command
        case "$w" in
            -p) _SP_PORT="${t[i+1]-}"; i=$((i+2)); continue ;;
            -p*) _SP_PORT="${w#-p}" ;;
            -i) _SP_KEY="${t[i+1]-}"; i=$((i+2)); continue ;;
            -i*) _SP_KEY="${w#-i}" ;;
            -l) lu="${t[i+1]-}"; i=$((i+2)); continue ;;
            -l*) lu="${w#-l}" ;;
            -o) _setup_sftp_opt "${t[i+1]-}"; i=$((i+2)); continue ;;
            -o*) _setup_sftp_opt "${w#-o}" ;;
            -[BbcDEeFIJLmOQRSWw])                            # options with an argument
                (( i + 1 < n )) && _SP_EXTRA+=("$w" "${t[i+1]}"); i=$((i+2)); continue ;;
            -[BbcDEeFIJLmOQRSWw]*) _SP_EXTRA+=("${w:0:2}" "${w:2}") ;;
            -s) ;;                                           # restic's subsystem
            -*) _SP_EXTRA+=("$w") ;;                         # flags (-4, -C, -A, ...)
            *) dest="$w" ;;
        esac
        i=$((i+1))
    done
    if [[ -n "$dest" ]]; then
        dest="${dest#ssh://}"
        if [[ "$dest" == *@* ]]; then lu="${dest%@*}"; dest="${dest##*@}"; fi
        # [v6] or [v6]:port; a bare IPv6 address has more than one colon and no
        # port in it (a port goes in -p); host:port only with exactly one colon
        if [[ "$dest" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
            dest="${BASH_REMATCH[1]}"; [[ -n "$_SP_PORT" || -z "${BASH_REMATCH[3]}" ]] || _SP_PORT="${BASH_REMATCH[3]}"
        elif [[ "$dest" != *:*:* && "$dest" =~ ^(.+):([0-9]+)$ ]]; then
            dest="${BASH_REMATCH[1]}"; [[ -n "$_SP_PORT" ]] || _SP_PORT="${BASH_REMATCH[2]}"
        fi
        _SP_HOST="$dest"
        [[ "$rh" == "$dest" ]] || _SP_LABEL="$rh"
    else
        _SP_HOST="$rh"
    fi
    _SP_USER="${lu:-${_SP_OUSER:-$ru}}"
    [[ -n "$_SP_PORT" ]] || _SP_PORT="$rp"
    return 0
}
# _setup_sftp_opt NAME=VALUE: one -o option of the command, for _setup_sftp_parse.
_setup_sftp_opt() {
    local k="${1%%[= ]*}" v="${1#*[= ]}"
    case "${k,,}" in
        userknownhostsfile) _SP_KH="$v" ;;
        port) _SP_PORT="$v" ;;
        identityfile) _SP_KEY="$v" ;;
        user) _SP_OUSER="$v" ;;
        stricthostkeychecking) ;;
        *) [[ -z "$1" ]] || _SP_EXTRA+=(-o "$1") ;;
    esac
}

# _setup_sftp_needs_cmd PORT KEY KHFILE HOST: restic needs RESTIC_SFTP_COMMAND:
# a port other than 22, a key ssh does not try by itself, a pinned host key
# file, or (nothing pinned) a host whose key ssh has not recorded in
# ~/.ssh/known_hosts yet: restic's default (`ssh <user>@<host> -s sftp`) runs
# with StrictHostKeyChecking=ask, which fails without a terminal (the timers),
# so trust on first use needs the command with accept-new.
_setup_sftp_needs_cmd() {
    [[ "$1" != 22 || -n "$3" ]] && return 0
    local d known=1
    for d in id_rsa id_ecdsa id_ecdsa_sk id_ed25519 id_ed25519_sk; do [[ "$2" == "${HOME-}/.ssh/$d" ]] && known=0; done
    (( known == 0 )) || return 0
    command -v ssh-keygen >/dev/null 2>&1 && [[ -n "${4:-}" && -s "${HOME-}/.ssh/known_hosts" ]] \
        && ssh-keygen -F "$4" -f "${HOME-}/.ssh/known_hosts" </dev/null >/dev/null 2>&1 && return 1
    return 0
}

# _setup_is_storagebox HOST: a Storage Box (its checks: port 23, the
# user is the (sub-)account, a chrooted relative path, the provider's snapshots).
_setup_is_storagebox() { [[ "${1,,}" == *.your-storagebox.de ]]; }

# _setup_repo_kind REPO: sftp, rest, dir, other, or nothing for no repo.
_setup_repo_kind() {
    case "$1" in
        '') ;;
        sftp:*) printf sftp ;;
        rest:*) printf rest ;;
        /*|local:*) printf dir ;;
        *:*) printf other ;;
        *) printf dir ;;
    esac
}

# _setup_env_names FILE: the names of the variables FILE sets (never a value).
_setup_env_names() {
    local l
    [[ -f "$1" && -r "$1" && ! -L "$1" ]] || return 0
    while IFS= read -r l; do
        [[ "$l" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]] && printf '%s\n' "${BASH_REMATCH[2]}"
    done < "$1"
}

# _setup_repo_describe: the configured offsite repo in one line, its login
# masked (the user in a URL, the rest-server password: never shown).
_setup_repo_describe() {
    local r="${RESTIC_OFFSITE_REPO:-}" names
    case "$(_setup_repo_kind "$r")" in
        sftp)
            _setup_sftp_parse "$r" "${RESTIC_SFTP_COMMAND:-}"
            printf 'SFTP %s, user %s, port %s, key %s, path %s, %s%s' "${_SP_HOST:-?}" "${_SP_USER:-<ssh default>}" "${_SP_PORT:-22}" \
                "${_SP_KEY:-<ssh default>}" "${_SP_PATH:-?}" "$( [[ -n "$_SP_KH" ]] && printf 'host key pinned in %s' "$_SP_KH" || printf 'host key not pinned')" \
                "$( (( ${#_SP_EXTRA[@]} )) && printf ', more ssh options: %s' "${_SP_EXTRA[*]}")" ;;
        rest)
            printf 'rest-server %s%s, %s' "$(_mask_url "${r#rest:}")" "${RESTIC_REST_USERNAME:+, user $RESTIC_REST_USERNAME}" \
                "$( [[ "${OFFSITE_APPEND_ONLY:-false}" == true ]] && printf 'append-only (retention runs on the janitor)' || printf 'not append-only')" ;;
        dir) printf 'directory %s' "${r#local:}" ;;
        other)
            names="$(_setup_env_names "${RESTIC_ENV_FILE:-}" | paste -sd' ' -)"
            printf '%s backend %s, credentials in %s (%s)' "${r%%:*}" "$(_mask_url "$r")" "${RESTIC_ENV_FILE-}" "${names:-no variables}" ;;
    esac
}

# _setup_offsite_step: the offsite target. A configured repo is shown and kept
# (the next steps skipped) unless the operator chooses to change it; then the
# type of target: SFTP, rest-server, a local or mounted directory, another
# restic backend, or (with a local cache repo) none.
_setup_offsite_step() {
    printf '\n%s— Offsite target —%s\n' "$C_B" "$C_0"
    local cur="${RESTIC_OFFSITE_REPO:-}" kind def=1
    local -a labels=()
    kind="$(_setup_repo_kind "$cur")"
    if [[ -n "$cur" ]]; then
        printf '  Configured: %s\n' "$(_setup_repo_describe)"
        [[ "${OFFSITE_ENABLED:-true}" == true ]] || printf '  %s(OFFSITE_ENABLED=false: nothing is copied there now)%s\n' "$C_Y" "$C_0"
        _setup_pick "Offsite" 1 "keep it (the offsite steps are skipped)" "change the target" || _PI=1
        if [[ "$_PI" == 1 ]]; then printf '  Keeping the offsite repo.\n'; return 0; fi
    elif [[ "${OFFSITE_ENABLED:-true}" != true ]]; then
        printf '  None (OFFSITE_ENABLED=false: the local cache repo only).\n'
    fi
    labels=("SFTP server (any host; the port, user and key you choose)"
            "rest-server (restic's REST server, optionally append-only)"
            "a local or mounted directory (a second disk, an NFS share)"
            "another restic backend (s3:, b2:, azure:, gs:, swift:, rclone:)")
    [[ "${LOCAL_REPO:-true}" == true ]] && labels+=("none: the local cache repo only")
    case "$kind" in rest) def=2 ;; dir) def=3 ;; other) def=4 ;; esac
    [[ -n "$cur" || "${OFFSITE_ENABLED:-true}" == true || "${LOCAL_REPO:-true}" != true ]] || def=5
    if ! _setup_pick "Type of target" "$def" "${labels[@]}"; then
        printf '  %sNo such choice: the offsite target is unchanged.%s\n' "$C_Y" "$C_0"; return 0
    fi
    case "$((10#$_PI))" in
        1) _setup_offsite_sftp "$kind" ;;
        2) _setup_offsite_rest "$kind" ;;
        3) _setup_offsite_dir "$kind" ;;
        4) _setup_offsite_other "$kind" ;;
        5) _setup_change set OFFSITE_ENABLED false && printf '  Offsite off: backups go to the local cache repo only.\n' ;;
    esac
}

# _setup_offsite_confirm REPO: a configured offsite repo is replaced only after
# a yes (pbo moves no snapshot: those in the old repo stay there).
_setup_offsite_confirm() {
    local cur="${RESTIC_OFFSITE_REPO:-}" bare="${RESTIC_OFFSITE_REPO:-}"
    # a rest-server login written into the URL moves to its own keys
    # (_setup_offsite_rest): the repo is the same without it
    [[ ! "$bare" =~ ^(rest:https?://)[^/@]*@(.*)$ ]] || bare="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    [[ -n "$cur" && "$1" != "$cur" && "$1" != "$bare" ]] || return 0
    printf '  The offsite repo changes: %s -> %s\n' "$(_mask_url "$cur")" "$(_mask_url "$1")"
    printf '  %spbo moves no snapshot: the ones in the old repo stay there.%s\n' "$C_D" "$C_0"
    _setup_yn "Use the new repo?" y && return 0
    printf '  Kept %s.\n' "$(_mask_url "$cur")"
    return 1
}

# _setup_prev_unsets KIND NEWKIND → _SETUP_OPS (appended): the keys of the
# previous type of target, removed when the type changes (a stale rest-server
# login, an sftp command restic would no longer use).
_setup_prev_unsets() {
    [[ "$1" != "$2" ]] || return 0
    case "$1" in
        sftp) _SETUP_OPS+=(unset RESTIC_SFTP_COMMAND) ;;
        rest) _SETUP_OPS+=(unset RESTIC_REST_USERNAME unset RESTIC_REST_PASSWORD_FILE unset RESTIC_CACERT unset OFFSITE_APPEND_ONLY) ;;
    esac
}

# _setup_offsite_sftp KIND: any SFTP server. The repo is sftp:<user>@<host>:<path>;
# RESTIC_SFTP_COMMAND only when the port, the key or the pinned host key needs
# it (_setup_sftp_needs_cmd). The defaults come from the configured repo and
# its command (_setup_sftp_parse). A Storage Box gets its own defaults, hints
# and the question about its snapshots (STORAGE_BOX_SNAPSHOTS_CONFIRMED). The
# other ssh options of the configured command (_SP_EXTRA) stay in the command
# as long as the host stays: a ProxyJump or an -F config the wizard does not
# ask about must not vanish because the operator pressed Enter.
_setup_offsite_sftp() {
    local kind="$1" host port user key path repo sb=0 dport=22 duser='' sc=n kh
    local -a extra=()
    _SP_USER='' _SP_HOST='' _SP_PORT='' _SP_KEY='' _SP_KH='' _SP_PATH='' _SP_LABEL='' _SP_EXTRA=()
    [[ "$kind" == sftp ]] && _setup_sftp_parse "$RESTIC_OFFSITE_REPO" "${RESTIC_SFTP_COMMAND:-}"
    _setup_ask "SFTP server (host name, IPv4 or IPv6 address)" "$_SP_HOST" _setup_chk_host || return 1
    host="$(_setup_unbracket "$_SV")"
    if (( ${#_SP_EXTRA[@]} )); then
        if [[ "$host" == "$_SP_HOST" ]]; then
            extra=("${_SP_EXTRA[@]}")
            printf '  %sThe current RESTIC_SFTP_COMMAND also has: %s (kept).%s\n' "$C_D" "${extra[*]}" "$C_0"
        else
            printf '  %sThe current RESTIC_SFTP_COMMAND also has: %s; the command for %s does not carry them.%s\n' "$C_Y" "${_SP_EXTRA[*]}" "$host" "$C_0"
        fi
    fi
    if _setup_is_storagebox "$host"; then
        sb=1 dport=23 duser="${host%%.*}"
        printf '  %sA Storage Box: port 23, the user is the (sub-)account, the path is relative (the box is chrooted).%s\n' "$C_D" "$C_0"
    fi
    if [[ "$host" == "$_SP_HOST" ]]; then dport="${_SP_PORT:-$dport}" duser="${_SP_USER:-$duser}"; fi
    _setup_ask "SFTP port" "$dport" _setup_chk_port || return 1; port="$((10#$_SV))"
    _setup_ask "SFTP user" "$duser" _setup_chk_user || return 1; user="$_SV"
    _setup_ask "SSH key file on this host" "${_SP_KEY:-${HOME-}/.ssh/id_ed25519}" _setup_chk_abs_nb || return 1; key="$_SV"
    _setup_ask "Repo path on the server$( (( sb )) && printf ' (relative)')" "${_SP_PATH:-pbo}" _setup_chk_rpath || return 1; path="$_SV"
    # restic takes an IPv6 host in brackets (the path follows a colon)
    if [[ "$host" == *:* ]]; then repo="sftp:${user}@[${host}]:${path}"; else repo="sftp:${user}@${host}:${path}"; fi
    _setup_offsite_confirm "$repo" || return 0
    _setup_sftp_key "$key" "$user" "$host" "$port" "$sb" || return 1
    _setup_sftp_pin "$host" "$port"
    kh="$_SETUP_KH"
    _setup_sftp_test "$user" "$host" "$port" "$key" "$kh" "${extra[@]+"${extra[@]}"}"
    _SETUP_OPS=(set OFFSITE_ENABLED true set RESTIC_OFFSITE_REPO "$repo")
    # the kept options need the command even where the defaults would do
    if (( ${#extra[@]} )) || _setup_sftp_needs_cmd "$port" "$key" "$kh" "$host"; then
        _SETUP_OPS+=(set RESTIC_SFTP_COMMAND "$(_pbo_sftp_command "$user" "$host" "$port" "$key" "$kh" "${extra[@]+"${extra[@]}"}")")
        printf '  RESTIC_SFTP_COMMAND: ssh with port %s, the key %s, %s%s.\n' "$port" "$key" \
            "$( [[ -n "$kh" ]] && printf 'the host key pinned in %s' "$kh" || printf 'the host key trusted on first use (accept-new)')" \
            "$( (( ${#extra[@]} )) && printf ', and %s' "${extra[*]}")"
    else
        _SETUP_OPS+=(unset RESTIC_SFTP_COMMAND)
        printf '  No RESTIC_SFTP_COMMAND: restic runs ssh %s@%s with its defaults (port 22, the default key, the host key ssh recorded in ~/.ssh/known_hosts).\n' "$user" "$host"
    fi
    _setup_prev_unsets "$kind" sftp
    _setup_change "${_SETUP_OPS[@]}" || return 1
    printf '  %sOffsite: %s%s\n' "$C_G" "$(_mask_url "$repo")" "$C_0"
    if (( sb )); then
        [[ "${STORAGE_BOX_SNAPSHOTS_CONFIRMED:-false}" == true ]] && sc=y
        printf '  %sThe snapshots the box takes itself (its snapshot plan) are the backstop against a host that deletes its backups: this host cannot remove them.%s\n' "$C_D" "$C_0"
        if _setup_yn "Does the Storage Box take automatic snapshots?" "$sc"; then
            _setup_set STORAGE_BOX_SNAPSHOTS_CONFIRMED true
        else
            _setup_set STORAGE_BOX_SNAPSHOTS_CONFIRMED false
            printf '  %sTurn them on in the console of the provider, then run pbo setup again (doctor warns until then).%s\n' "$C_Y" "$C_0"
        fi
    fi
    return 0
}

# _setup_keygen KEY TYPE: a new key pair at KEY (no passphrase: the timers use it).
_setup_keygen() {
    local d; d="$(dirname -- "$1")"
    [[ -d "$d" ]] || ( umask 077; mkdir -p -- "$d" ) || return 1
    ssh-keygen -q -t "$2" -N '' -C "pbo@$(hostname -s 2>/dev/null || echo host)" -f "$1" </dev/null >/dev/null
}

# _setup_sftp_key KEY USER HOST PORT SB: the key restic logs in with (made when
# missing) and how to install its public half on the server.
_setup_sftp_key() {
    local key="$1" user="$2" host="$3" port="$4" sb="$5" kt=ed25519
    printf '\n%s— SSH key —%s\n' "$C_B" "$C_0"
    if [[ ! -f "$key" ]]; then
        case "$key" in *rsa*) kt=rsa ;; *ecdsa*) kt=ecdsa ;; esac
        if ! _setup_yn "No key at $key. Generate a new $kt key pair now?" y; then
            printf '  %sPoint the wizard at an existing key, or generate one and run setup again.%s\n' "$C_Y" "$C_0"; return 1
        fi
        _setup_keygen "$key" "$kt" || { printf '  %sssh-keygen failed, setup stops here.%s\n' "$C_R" "$C_0"; return 1; }
        printf '  %screated %s (+ %s.pub)%s\n' "$C_G" "$key" "$key" "$C_0"
    else
        printf '  Using the existing key %s.\n' "$key"
    fi
    [[ -f "$key.pub" ]] || return 0
    printf '\n  %sInstall this public key on the server, so that pbo logs in without a password:%s\n\n' "$C_B" "$C_0"
    printf '  %s%s%s\n\n' "$C_C" "$(cat -- "$key.pub")" "$C_0"
    if (( sb )); then
        printf '  %sStorage Box%s (asks for the box password once):\n' "$C_D" "$C_0"
        printf '      ssh-copy-id -s -p %s -i %s.pub %s@%s\n' "$port" "$key" "$user" "$host"
        printf '  %sor:%s  cat %s.pub | ssh -p%s %s@%s install-ssh-key\n' "$C_D" "$C_0" "$key" "$port" "$user" "$host"
    else
        printf '      ssh-copy-id -p %s -i %s.pub %s@%s\n' "$port" "$key" "$user" "$host"
        printf '  %sor append the line above to ~/.ssh/authorized_keys of %s on the server.%s\n' "$C_D" "$user" "$C_0"
    fi
    # a person reads the key; scripted answers have no line for it
    [[ ! -t 0 ]] || _pause
    return 0
}

# _setup_sftp_pin HOST PORT → _SETUP_KH: the known_hosts file restic's ssh is
# pinned to (PBO_KNOWN_HOSTS), or empty for trust on first use (the command
# then gets accept-new, unless ssh's own known_hosts has the key already:
# _setup_sftp_needs_cmd). A host key the file holds already is kept; a new one
# is added to it.
_setup_sftp_pin() {
    local host="$1" port="$2" kh="${PBO_KNOWN_HOSTS:-}" hk="$1" scan
    _SETUP_KH=''
    printf '\n%s— Host key —%s\n' "$C_B" "$C_0"
    [[ -n "$kh" ]] || { printf '  PBO_KNOWN_HOSTS is empty: not pinned, trust on first use.\n'; return 0; }
    [[ "$port" == 22 ]] || hk="[$host]:$port"
    if [[ -s "$kh" ]] && command -v ssh-keygen >/dev/null 2>&1 && ssh-keygen -F "$hk" -f "$kh" </dev/null >/dev/null 2>&1; then
        printf '  The host key of %s is pinned in %s.\n' "$hk" "$kh"; _SETUP_KH="$kh"; return 0
    fi
    if ! _setup_yn "Pin the server's host key (recommended: no trust on first use)?" y; then
        printf '  Not pinned: trust on first use (ssh accepts the key it sees first).\n'; return 0
    fi
    scan="$(ssh-keyscan -p "$port" -H "$host" </dev/null 2>/dev/null)"
    if [[ -z "$scan" ]]; then
        printf '  %sssh-keyscan returned nothing (is the server reachable?): not pinned, trust on first use.%s\n' "$C_Y" "$C_0"; return 0
    fi
    # added to what the file holds (other servers, an earlier run), once each
    if _setup_write_file "$kh" 644 < <({ [[ ! -f "$kh" ]] || cat -- "$kh"; printf '%s\n' "$scan"; } | sort -u); then
        printf '  %spinned %s in %s%s\n' "$C_G" "$hk" "$kh" "$C_0"; _SETUP_KH="$kh"
    else
        printf '  %scould not write %s: not pinned, trust on first use.%s\n' "$C_Y" "$kh" "$C_0"
    fi
    return 0
}

# _setup_sftp_test USER HOST PORT KEY KHFILE [EXTRA...]: log in once with the sftp client,
# before the repo is written (a failure is said and may be retried; setup goes
# on without a verified connection on a no).
_setup_sftp_test() {
    printf '\n%s— Connection test —%s\n' "$C_B" "$C_0"
    while true; do
        printf '  probing sftp://%s@%s:%s … ' "$1" "$( [[ "$2" != *:* ]] && printf '%s' "$2" || printf '[%s]' "$2")" "$3"
        if _pbo_sftp_probe "$@" </dev/null; then printf '%sOK%s\n' "$C_G" "$C_0"; return 0; fi
        printf '%sFAILED%s\n' "$C_R" "$C_0"
        printf '  The key is not accepted yet, or the host, port or key is wrong.\n'
        if ! _setup_yn "Retry the connection?" y; then
            printf '  %sGoing on without a verified connection: fix it before the first backup (pbo init, pbo doctor).%s\n' "$C_Y" "$C_0"
            return 0
        fi
    done
}

# _setup_offsite_rest KIND: a rest-server: its URL, the user and a password
# file (0600), a pinned certificate, and whether it is append-only (the host
# then never forgets or prunes offsite; the janitor does).
_setup_offsite_rest() {
    local kind="$1" url user='' pf='' pw ca ao=n aov=false dpf
    local durl='' duser="${RESTIC_REST_USERNAME:-}" uuser='' dpw=''
    [[ "$kind" == rest ]] && durl="${RESTIC_OFFSITE_REPO#rest:}"
    # a login written into the URL (restic's user:pass@ form) moves to the user
    # prompt and the password file: it is never shown as a default, and the
    # default passes the URL check
    if [[ "$durl" =~ ^(https?://)([^/@]*)@(.*)$ ]]; then
        durl="${BASH_REMATCH[1]}${BASH_REMATCH[3]}" uuser="${BASH_REMATCH[2]%%:*}"
        [[ "${BASH_REMATCH[2]}" != *:* ]] || dpw="${BASH_REMATCH[2]#*:}"
        [[ -n "$duser" ]] || duser="$uuser"
        # restic reads the URL's login percent-decoded (%40 is @)
        if [[ "$dpw" == *%* ]]; then dpw="${dpw//\\/\\\\}"; printf -v dpw '%b' "${dpw//%/\\x}"; fi
    fi
    _setup_ask "rest-server URL (https://<host>:<port>/<user>/<repo>)" "$durl" _setup_chk_rest_url || return 1
    url="$_SV"
    _setup_offsite_confirm "rest:$url" || return 0
    _setup_ask "rest-server user (empty: none)" "$duser" _setup_chk_user_opt || return 1
    user="$_SV"
    if [[ -n "$user" ]]; then
        dpf="${RESTIC_REST_PASSWORD_FILE:-}"
        [[ -n "$dpf" ]] || dpf="$(dirname -- "${RESTIC_PASSWORD_FILE-}")/rest-pass"
        _setup_ask "File with that user's password" "$dpf" _setup_chk_abs_nb || return 1
        pf="$_SV"
        if [[ -s "$pf" ]]; then
            printf '  Using the password in %s.\n' "$pf"
        elif [[ -n "$dpw" && "$user" == "$uuser" ]] \
             && _setup_yn "The configured URL holds the password of $user: move it to $pf (0600)?" y; then
            _setup_write_file "$pf" 600 < <(printf '%s\n' "$dpw") || return 1
            printf '  %swritten: %s (0600)%s\n' "$C_G" "$pf" "$C_0"
        else
            _setup_askpw "Password of $user on the rest-server (not shown)"; pw="$_A"
            if [[ -z "$pw" ]]; then
                printf '  %sNo password given: put it in %s (0600) before the first backup.%s\n' "$C_Y" "$pf" "$C_0"
            elif _setup_write_file "$pf" 600 < <(printf '%s\n' "$pw"); then
                printf '  %swritten: %s (0600)%s\n' "$C_G" "$pf" "$C_0"
            else
                return 1
            fi
        fi
    fi
    _setup_ask "The server's certificate, for a self-signed one (RESTIC_CACERT; empty: none)" "${RESTIC_CACERT:-}" _setup_chk_abs_opt || return 1
    ca="$_SV"
    [[ -z "$ca" || -f "$ca" ]] || printf '  %s%s does not exist (yet): copy the certificate there before the first backup.%s\n' "$C_Y" "$ca" "$C_0"
    printf '  %sAppend-only (rest-server --append-only): this host can add snapshots but never delete them; retention runs on a janitor next to the repo (install.sh --janitor).%s\n' "$C_D" "$C_0"
    [[ "${OFFSITE_APPEND_ONLY:-false}" == true ]] && ao=y
    _setup_yn "Is the server append-only?" "$ao" && aov=true
    _SETUP_OPS=(set OFFSITE_ENABLED true set RESTIC_OFFSITE_REPO "rest:$url" set OFFSITE_APPEND_ONLY "$aov")
    if [[ -n "$user" ]]; then _SETUP_OPS+=(set RESTIC_REST_USERNAME "$user" set RESTIC_REST_PASSWORD_FILE "$pf")
    else _SETUP_OPS+=(unset RESTIC_REST_USERNAME unset RESTIC_REST_PASSWORD_FILE); fi
    if [[ -n "$ca" ]]; then _SETUP_OPS+=(set RESTIC_CACERT "$ca"); else _SETUP_OPS+=(unset RESTIC_CACERT); fi
    _setup_prev_unsets "$kind" rest
    _setup_change "${_SETUP_OPS[@]}" || return 1
    printf '  %sOffsite: %s%s\n' "$C_G" "$(_mask_url "rest:$url")" "$C_0"
}

# _setup_same_fs A B: A and B are on the same filesystem (each the nearest
# directory of it that exists).
_setup_same_fs() {
    local a="$1" b="$2"
    while [[ ! -e "$a" && "$a" == /?* ]]; do a="$(dirname -- "$a")"; done
    while [[ ! -e "$b" && "$b" == /?* ]]; do b="$(dirname -- "$b")"; done
    [[ "$(stat -c %d -- "$a" 2>/dev/null)" == "$(stat -c %d -- "$b" 2>/dev/null)" ]]
}

# _setup_offsite_dir KIND: a directory restic writes to directly (a second disk,
# a mounted share).
_setup_offsite_dir() {
    local kind="$1" d='' p
    [[ "$kind" == dir ]] && d="${RESTIC_OFFSITE_REPO#local:}"
    _setup_ask "Repo directory (a second disk or a mounted share)" "$d" _setup_chk_abs || return 1
    p="$_SV"
    _setup_offsite_confirm "$p" || return 0
    if _setup_same_fs "$p" "${CACHE_DIR-}"; then
        printf '  %s%s is on the filesystem of CACHE_DIR: a disk that fails takes both copies with it.%s\n' "$C_Y" "$p" "$C_0"
    fi
    _SETUP_OPS=(set OFFSITE_ENABLED true set RESTIC_OFFSITE_REPO "$p")
    _setup_prev_unsets "$kind" dir
    _setup_change "${_SETUP_OPS[@]}" || return 1
    printf '  %sOffsite: %s%s\n' "$C_G" "$p" "$C_0"
}

# _setup_backend_vars SCHEME: "NAME|required|optional|what" per environment
# variable restic's SCHEME backend reads (restic's documentation, "Preparing a
# new repository"); nothing for a backend pbo knows no variables of.
_setup_backend_vars() {
    case "$1" in
        s3)     printf '%s\n' 'AWS_ACCESS_KEY_ID|required|the access key id' 'AWS_SECRET_ACCESS_KEY|required|the secret access key' \
                    'AWS_DEFAULT_REGION|optional|the region, when the service needs one' ;;
        b2)     printf '%s\n' 'B2_ACCOUNT_ID|required|the application key id' 'B2_ACCOUNT_KEY|required|the application key' ;;
        azure)  printf '%s\n' 'AZURE_ACCOUNT_NAME|required|the storage account' 'AZURE_ACCOUNT_KEY|optional|its access key (or a SAS token below)' \
                    'AZURE_ACCOUNT_SAS|optional|a SAS token instead of the key' ;;
        gs)     printf '%s\n' 'GOOGLE_PROJECT_ID|required|the project id' 'GOOGLE_APPLICATION_CREDENTIALS|required|the path of the service account JSON file' ;;
        swift)  printf '%s\n' 'OS_AUTH_URL|required|the Keystone URL' 'OS_USERNAME|required|the user' 'OS_PASSWORD|required|its password' \
                    'OS_PROJECT_NAME|optional|the project (tenant)' 'OS_USER_DOMAIN_NAME|optional|the user domain (Keystone v3)' \
                    'OS_PROJECT_DOMAIN_NAME|optional|the project domain (Keystone v3)' 'OS_REGION_NAME|optional|the region' ;;
        rclone) printf '%s\n' "RCLONE_CONFIG|optional|the rclone config file, when it is not rclone's default" ;;
    esac
}

# _setup_offsite_other KIND: another restic backend: the repository string as
# restic takes it, and the environment variables it needs in RESTIC_ENV_FILE
# (_setup_envfile).
_setup_offsite_other() {
    local kind="$1" d='' repo
    [[ "$kind" == other ]] && d="$RESTIC_OFFSITE_REPO"
    printf '  %sThe repository as restic takes it: s3:<endpoint>/<bucket>/<path>, b2:<bucket>:<path>, azure:<container>:/<path>, gs:<bucket>:/<path>, swift:<container>:/<path>, rclone:<remote>:<path>%s\n' "$C_D" "$C_0"
    _setup_ask "Repository" "$d" _setup_chk_repo_other || return 1
    repo="$_SV"
    _setup_offsite_confirm "$repo" || return 0
    _setup_envfile "${repo%%:*}" || return 1
    _SETUP_OPS=(set OFFSITE_ENABLED true set RESTIC_OFFSITE_REPO "$repo")
    _setup_prev_unsets "$kind" other
    _setup_change "${_SETUP_OPS[@]}" || return 1
    printf '  %sOffsite: %s%s\n' "$C_G" "$(_mask_url "$repo")" "$C_0"
}

# _setup_envfile SCHEME: the backend's credentials in RESTIC_ENV_FILE. The
# variables the backend reads are named with what each is; every value is
# read without echo and never shown; a variable the file has is kept on Enter.
# The file is written whole (the lines of other variables and the comments
# kept), 0600, and only when pbo's reader takes it back with every value as
# given (_setup_envfile_check).
_setup_envfile() {
    local scheme="$1" f n need what v row msg l
    local -a bvars=() order=() lines=()
    local -A have=()
    declare -gA _SETUP_ENV_WANT=()
    printf '\n%s— Backend credentials —%s\n' "$C_B" "$C_0"
    printf '  %srestic reads them from its environment. pbo keeps them in RESTIC_ENV_FILE (0600) and gives them to restic only.\n  Values are read without echo and never shown.%s\n' "$C_D" "$C_0"
    _setup_ask "Credentials file (RESTIC_ENV_FILE)" "${RESTIC_ENV_FILE:-}" _setup_chk_abs_nb || return 1
    f="$_SV"
    while IFS= read -r n; do [[ -z "$n" ]] || have[$n]=1; done < <(_setup_env_names "$f")
    (( ${#have[@]} == 0 )) || printf '  %s sets: %s\n' "$f" "$(printf '%s\n' "${!have[@]}" | sort | paste -sd' ' -)"
    mapfile -t bvars < <(_setup_backend_vars "$scheme")
    if (( ${#bvars[@]} == 0 )); then
        printf '  pbo knows no variables of the %s backend: add the ones the restic documentation names for it below.\n' "$scheme"
    else
        printf '  The %s backend reads:\n' "$scheme"
        for row in "${bvars[@]}"; do IFS='|' read -r n need what <<<"$row"; printf '    %-32s %s, %s\n' "$n" "$need" "$what"; done
    fi
    for row in "${bvars[@]}"; do
        IFS='|' read -r n need what <<<"$row"
        if [[ -n "${have[$n]+x}" ]]; then _setup_askpw "  $n (Enter keeps the value in the file)"
        else _setup_askpw "  $n ($need)"; fi
        v="$_A"
        if [[ -n "$v" ]]; then
            [[ -n "${_SETUP_ENV_WANT[$n]+x}" ]] || order+=("$n")
            _SETUP_ENV_WANT[$n]="$v"
        elif [[ -z "${have[$n]+x}" && "$need" == required ]]; then
            printf '  %s%s is not set: restic cannot open the repo without it (add it to %s, or run pbo setup again).%s\n' "$C_Y" "$n" "$f" "$C_0"
        fi
    done
    while true; do
        _setup_read "Another variable for restic (its name; Enter when done)" ""
        n="$_A"
        [[ -n "$n" ]] || break
        if ! msg="$(_setup_chk_envname "$n")"; then
            printf '  %s%s%s\n' "$C_Y" "$msg" "$C_0"
        else
            _setup_askpw "  $n"; v="$_A"
            if [[ -n "$v" ]]; then
                [[ -n "${_SETUP_ENV_WANT[$n]+x}" ]] || order+=("$n")
                _SETUP_ENV_WANT[$n]="$v"
            fi
        fi
    done
    if (( ${#order[@]} == 0 )); then
        printf '  %s is not changed.\n' "$f"
    else
        # the lines that set another variable stay as they are
        if [[ -f "$f" && -r "$f" ]]; then
            while IFS= read -r l; do
                if [[ "$l" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= && -n "${_SETUP_ENV_WANT[${BASH_REMATCH[2]}]+x}" ]]; then continue; fi
                lines+=("$l")
            done < "$f"
        else
            lines+=("# restic's environment (pbo setup): KEY=VALUE lines pbo gives to restic only, 0600")
        fi
        for n in "${order[@]}"; do _cfg_qval "${_SETUP_ENV_WANT[$n]}"; lines+=("$n=$_CFG_Q"); done
        _setup_write_file "$f" 600 _setup_envfile_check < <(printf '%s\n' "${lines[@]}") || { _SETUP_ENV_WANT=(); return 1; }
        printf '  %swritten: %s (0600): %s%s\n' "$C_G" "$f" "${order[*]}" "$C_0"
    fi
    _SETUP_ENV_WANT=()
    _setup_set RESTIC_ENV_FILE "$f"
}

# _setup_envfile_check TEMP: pbo's reader of RESTIC_ENV_FILE (lib/restic.sh)
# takes TEMP and reads each value the wizard was given back as given. Names
# what is wrong, never a value.
_setup_envfile_check() {
    local RESTIC_ENV_FILE="$1" n
    _restic_env_read >/dev/null 2>&1
    if (( ${#RENV_ERRORS[@]} )); then printf 'pbo would refuse the file: %s' "${RENV_ERRORS[0]}"; return 1; fi
    for n in "${!_SETUP_ENV_WANT[@]}"; do
        [[ "${_RENV_VAL[$n]-}" == "${_SETUP_ENV_WANT[$n]}" ]] || { printf '%s would not read back as given' "$n"; return 1; }
    done
    return 0
}

# --- the other steps ---

# _setup_repo_targets: the repos `pbo init` creates or opens, "tier<TAB>repo"
# per line (the cache repo with LOCAL_REPO, the offsite one when it is on).
_setup_repo_targets() {
    [[ "${LOCAL_REPO:-true}" != true || -z "${RESTIC_CACHE_REPO:-}" ]] || printf 'cache\t%s\n' "$RESTIC_CACHE_REPO"
    [[ "${OFFSITE_ENABLED:-true}" != true || -z "${RESTIC_OFFSITE_REPO:-}" ]] || printf 'offsite\t%s\n' "$RESTIC_OFFSITE_REPO"
    return 0
}

# _setup_probe_all MODE [VALUE] → SETUP_PROBE: what the targets hold, from a
# read-only probe of each repo (_restic_probe, lib/restic.sh). MODE: none (no
# key: is a repo there?), file VALUE (a password file), key VALUE (a key, held
# in no file). SETUP_PROBE is wrongkey (the key does not open a repo there:
# SETUP_PROBE_BAD names it), exists (a repo is there; with a key: each one
# opens with it), unknown (a target cannot be checked: SETUP_PROBE_MSG), or
# absent (no repo anywhere).
_setup_probe_all() {
    local mode="$1" val="${2:-}" tier repo any=0 unk='' bad='' what
    SETUP_PROBE=absent SETUP_PROBE_MSG='' SETUP_PROBE_BAD=''
    if ! declare -F _restic_probe >/dev/null; then SETUP_PROBE=unknown SETUP_PROBE_MSG='no probe loaded'; return 0; fi
    while IFS=$'\t' read -r tier repo; do
        [[ -n "$repo" ]] || continue
        case "$mode" in
            file) _restic_probe "$repo" "$val" </dev/null ;;
            key)  _restic_probe "$repo" <(printf '%s\n' "$val") </dev/null ;;
            *)    _restic_probe "$repo" "" </dev/null ;;
        esac
        case "$RPROBE" in
            exists)   any=1; what='a repo is there'; [[ "$mode" == none ]] || what='a repo is there, the key opens it' ;;
            wrongkey) any=1; bad+="${bad:+, }the $tier repo $(_mask_url "$repo")"; what='a repo is there, the key does NOT open it' ;;
            absent)   what='no repo yet' ;;
            *)        unk+="${unk:+; }$tier: $RPROBE_MSG"; what="cannot tell ($RPROBE_MSG)" ;;
        esac
        printf '  %s repo %s: %s\n' "$tier" "$(_mask_url "$repo")" "$what"
    done < <(_setup_repo_targets)
    if [[ -n "$bad" ]]; then SETUP_PROBE=wrongkey SETUP_PROBE_BAD="$bad"
    elif (( any )); then SETUP_PROBE=exists
    elif [[ -n "$unk" ]]; then SETUP_PROBE=unknown SETUP_PROBE_MSG="$unk"
    fi
    return 0
}

# _setup_key_from_file FILE: the DR key FILE holds: the value of its
# RESTIC_PASSWORD= line (an export of the menu), else the whole file (a
# password file, as restic reads one).
_setup_key_from_file() {
    local l
    # || [[ -n $l ]]: an edited export may lack its final newline, and read
    # fails on that last line although it filled l
    while IFS= read -r l || [[ -n "$l" ]]; do
        l="${l#"${l%%[![:space:]]*}"}"
        if [[ "$l" == RESTIC_PASSWORD=* ]]; then printf '%s' "${l#RESTIC_PASSWORD=}"; return 0; fi
    done < "$1"
    cat -- "$1"
}

# _setup_drkey_existing: the key of the repo the target holds already: from a
# file (a password file or an export) or typed without echo. It is written to
# RESTIC_PASSWORD_FILE (0600) only once it opens every repo the target holds;
# a key that does not is refused and asked again, and nothing is written.
# When the target cannot be reached, the key is taken unchecked only when the
# operator picks that (init then checks it before it creates anything).
# _setup_drkey_existing unknown: called after the operator said a target that
# cannot be checked holds a repo; a key that cannot be checked then also
# offers the way back ("there is no repo there"), returning 2 with nothing
# written so the caller generates a key. Without it (a repo was found) a new
# key is never offered: no new key opens that repo.
_setup_drkey_existing() {
    local pf="${RESTIC_PASSWORD_FILE:-}" src key how="${1:-}"
    printf '  %sGive the DR key that repo was made with (the export of the first host, or its password file).%s\n' "$C_D" "$C_0"
    while true; do
        _setup_ask "File with the DR key (Enter: type the key instead)" "" _setup_chk_abs_opt
        src="$_SV"
        if [[ -n "$src" ]]; then
            if [[ ! -f "$src" || ! -r "$src" ]]; then printf '  %s%s is not a readable file: try again%s\n' "$C_Y" "$src" "$C_0"; continue; fi
            key="$(_setup_key_from_file "$src")"
        else
            _setup_askpw "The DR key (the repo password; not shown)"; key="$_A"
        fi
        [[ -n "$key" ]] || { printf '  %san empty key: try again%s\n' "$C_Y" "$C_0"; continue; }
        _setup_probe_all key "$key"
        case "$SETUP_PROBE" in
            exists|absent) break ;;
            wrongkey) printf '  %sThat key does not open %s: not written, try again.%s\n' "$C_Y" "$SETUP_PROBE_BAD" "$C_0" ;;
            *)
                if [[ "$how" != unknown ]]; then
                    if _setup_yn "The key cannot be checked now ($SETUP_PROBE_MSG). Use it unchecked (pbo init checks it before it creates anything)?" n; then break; fi
                    continue
                fi
                printf '  %sThe key cannot be checked now (%s).%s\n' "$C_Y" "$SETUP_PROBE_MSG" "$C_0"
                _setup_pick "What now" 1 "give another key" "use this key unchecked (pbo init checks it before it creates anything)" \
                    "there is no repo there: make a new key instead" || _PI=1
                case "$_PI" in
                    2) break ;;
                    3) return 2 ;;
                esac ;;
        esac
    done
    _setup_write_file "$pf" 600 < <(printf '%s\n' "$key") || return 1
    printf '  %swritten: %s (0600)%s\n' "$C_G" "$pf" "$C_0"
}

# _setup_drkey_step: the repo password (DR key). The targets are probed first
# (read only): a repo that is there already has a key, and only that key opens
# it, so a new one is never offered for it (the second node of a cluster, a
# host restoring after a loss); the wizard asks for that key and checks it.
# A new target: generating one is the default. A probe that cannot tell (the
# target unreachable) asks whether a repo is there, yes by default; a key
# that cannot be checked there either can still be dropped for a new one
# (the operator says there is no repo after all). An
# existing key file is never replaced (the repos it opens would be lost
# without it; menu → Rotate DR key changes it); setup stops when it does not
# open a repo the target holds.
_setup_drkey_step() {
    printf '\n%s— DR key (repo password) —%s\n' "$C_B" "$C_0"
    local pass='' pf="${RESTIC_PASSWORD_FILE:-}"
    if [[ -s "$pf" ]]; then
        _setup_probe_all file "$pf"
        if [[ "$SETUP_PROBE" == wrongkey ]]; then
            printf '  %sThe DR key in %s does not open %s: only the key it was made with does. Put that key in %s, or choose the target this key belongs to; nothing was changed.%s\n' \
                "$C_R" "$pf" "$SETUP_PROBE_BAD" "$pf" "$C_0"
            return 1
        fi
        printf '  %sKeeping the existing DR key in %s%s (to change it: menu → Rotate DR key).\n' "$C_G" "$pf" "$C_0"; return 0
    fi
    _setup_probe_all none
    case "$SETUP_PROBE" in
        exists)
            printf '  %sA repo exists there already: it has its DR key, and no new key can open it.%s\n' "$C_Y" "$C_0"
            _setup_drkey_existing; return ;;
        unknown)
            printf '  %sWhether a repo exists there cannot be told now (%s).%s\n' "$C_Y" "$SETUP_PROBE_MSG" "$C_0"
            if _setup_yn "Does the target hold a repo already (made by another node, or an earlier install)?" y; then
                # 2: the operator took that back (no repo there): a new key below
                local rc=0
                _setup_drkey_existing unknown || rc=$?
                (( rc == 2 )) || return "$rc"
            fi ;;
    esac
    if _setup_yn "Generate a random repo password (recommended)?" y; then
        pass="$(openssl rand -base64 30 2>/dev/null || head -c22 /dev/urandom | base64)"
        printf '  Generated: export it afterwards (menu → Export DR key) and store it safely.\n'
    else
        while true; do
            _setup_askpw "Enter the restic repo password (this IS your DR key)"; pass="$_A"
            [[ -z "$pass" ]] || break
            printf '  %san empty password: try again%s\n' "$C_Y" "$C_0"
        done
    fi
    _setup_write_file "$pf" 600 < <(printf '%s\n' "$pass") || return 1
    printf '  %swritten: %s (0600)%s\n' "$C_G" "$pf" "$C_0"
}

_setup_mode_step() {
    printf '\n%s— Backup mode —%s\n' "$C_B" "$C_0"
    _setup_ask_key BACKUP_MODE "Back up all guests one by one (stream) or all at once (batch)" || return 1
    _setup_set BACKUP_MODE "$_SV"
}

# _setup_retention_step: the KEEP_* keys of the tiers in use, each checked
# against the schema and asked again until valid.
_setup_retention_step() {
    printf '\n%s— Retention —%s (what prune keeps, per guest)\n' "$C_B" "$C_0"
    local k
    local -a ops=() keys=()
    [[ "${LOCAL_REPO:-true}" == true ]] && printf '  local cache repo: the last %s\n' "${KEEP_LOCAL:-}"
    [[ "${OFFSITE_ENABLED:-true}" == true ]] && printf '  offsite: %s daily, %s weekly, %s monthly, %s yearly\n' \
        "${KEEP_OFFSITE_DAILY:-}" "${KEEP_OFFSITE_WEEKLY:-}" "${KEEP_OFFSITE_MONTHLY:-}" "${KEEP_OFFSITE_YEARLY:-}"
    _setup_yn "Change it?" n || return 0
    [[ "${LOCAL_REPO:-true}" == true ]] && keys+=(KEEP_LOCAL)
    [[ "${OFFSITE_ENABLED:-true}" == true ]] && keys+=(KEEP_OFFSITE_DAILY KEEP_OFFSITE_WEEKLY KEEP_OFFSITE_MONTHLY KEEP_OFFSITE_YEARLY)
    for k in "${keys[@]}"; do
        case "$k" in
            KEEP_LOCAL) _setup_ask_key "$k" "Local cache: keep the last N" ;;
            KEEP_OFFSITE_DAILY) _setup_ask_key "$k" "Offsite: keep N daily" ;;
            KEEP_OFFSITE_WEEKLY) _setup_ask_key "$k" "Offsite: keep N weekly" ;;
            KEEP_OFFSITE_MONTHLY) _setup_ask_key "$k" "Offsite: keep N monthly" ;;
            KEEP_OFFSITE_YEARLY) _setup_ask_key "$k" "Offsite: keep N yearly (0: none)" ;;
        esac || return 1
        ops+=("$k" "$_SV")
    done
    _setup_set "${ops[@]}"
}

# _setup_ntfy_step: ntfy. A configured server is shown (masked) and kept,
# changed or turned off; nothing is written when the operator keeps it.
_setup_ntfy_step() {
    printf '\n%s— Notifications —%s\n' "$C_B" "$C_0"
    local url topic lvl="${NOTIFY_LEVEL-}"
    # an empty NOTIFY_LEVEL is fail, or all with the deprecated NTFY_ON_SUCCESS=true (lib/notify.sh)
    if [[ -z "$lvl" ]]; then lvl=fail; [[ "${NTFY_ON_SUCCESS-}" != true ]] || lvl=all; fi
    if [[ -n "${NTFY_URL:-}" ]]; then
        printf '  ntfy: %s, topic %s, notify on: %s\n' "$(_mask_url "$NTFY_URL")" \
            "$( [[ -n "${NTFY_TOPIC:-}" ]] && printf '<set>' || printf '<none>')" "$lvl"
        _setup_pick "ntfy" 1 "keep it" "change it" "turn ntfy off" || _PI=1
        case "$((10#$_PI))" in
            1) return 0 ;;
            3) _setup_change unset NTFY_URL unset NTFY_TOPIC || return 1; printf '  ntfy off.\n'; return 0 ;;
        esac
    else
        [[ ! -f "${NTFY_CREDS_FILE:-}" ]] || printf '  (pbo reads ntfy settings from %s too.)\n' "$NTFY_CREDS_FILE"
        _setup_yn "Enable ntfy notifications (an alert on failure)?" n || { printf '  ntfy stays off.\n'; return 0; }
    fi
    _setup_ask_keep "ntfy server (https://<server>)" "${NTFY_URL:-}" _setup_chk_ntfy_url || return 1; url="$_SV"
    _setup_ask_keep "ntfy topic" "${NTFY_TOPIC:-}" _setup_chk_set || return 1; topic="$_SV"
    _setup_ask_key NOTIFY_LEVEL "Notify on: fail, warn (and warnings) or all (and every success)" "$lvl" || return 1
    _setup_set NTFY_URL "$url" NTFY_TOPIC "$topic" NOTIFY_LEVEL "$_SV" || return 1
    printf '  ntfy on (a server that needs a token: NTFY_TOKEN, or NTFY_CREDS_FILE).\n'
}

# _setup_guests_step: BACKUP_ORDER.
_setup_guests_step() {
    printf '\n%s— Guests —%s (this node backs up its own guests into the shared repo)\n' "$C_B" "$C_0"
    local ln ao=y; ln="$(_local_node 2>/dev/null)"
    printf '  Discovered on %s:\n' "${ln:-this node}"
    _menu_guests_tsv | awk -F'\t' -v n="$ln" 'n=="" || $4==n {printf "    %-6s %-22s %-4s %s\n",$1,$2,$3,$5}'
    [[ "${BACKUP_ORDER:-auto}" == auto ]] || ao=n
    if _setup_yn "Back up ALL of this node's guests automatically (BACKUP_ORDER=auto)?" "$ao"; then
        _setup_set BACKUP_ORDER auto || return 1
        printf '  %sBACKUP_ORDER=auto%s (new guests are picked up automatically).\n' "$C_G" "$C_0"
    else
        _SETUP_K=BACKUP_ORDER
        _setup_ask "Explicit vmid list (comma-separated, critical first)" "$( [[ "${BACKUP_ORDER:-auto}" == auto ]] || printf '%s' "$BACKUP_ORDER")" _setup_chk_key_set || return 1
        _setup_set BACKUP_ORDER "$_SV" || return 1
        printf '  BACKUP_ORDER=%s\n' "$_SV"
    fi
}

# _setup_schedule_step: the timer schedules (SCHEDULE_*, systemd calendar
# expressions checked by the schema and asked again until valid; the writer's
# apply-schedule hook writes the drop-ins), then the timers that are not
# enabled yet, each with the schedule it runs on: yes by default on a first
# setup, no on a re-run.
_setup_schedule_step() {
    printf '\n%s— Schedule —%s\n' "$C_B" "$C_0"
    local k u what mode def=y
    local -a ops=()
    # a re-run: a timer that is off was left off (Enter must not start a
    # restore test the operator declined on the first run)
    (( ! SETUP_RERUN )) || def=n
    mode="$(_integration_mode 2>/dev/null)"
    printf '  nightly backup %s · prune %s · verify %s · restore test %s\n' \
        "${SCHEDULE_BACKUP:-}" "${SCHEDULE_PRUNE:-}" "${SCHEDULE_VERIFY:-}" "${SCHEDULE_TEST_RESTORE:-}"
    if _setup_yn "Change when the timers run (systemd calendar expressions, man systemd.time)?" n; then
        for k in SCHEDULE_BACKUP SCHEDULE_PRUNE SCHEDULE_VERIFY SCHEDULE_TEST_RESTORE; do
            _setup_ask_key "$k" "  $k" || return 1
            ops+=("$k" "$_SV")
        done
        _setup_set "${ops[@]}" || return 1
    fi
    if [[ "$mode" == integrated ]]; then
        printf '  %sIntegrated mode: PVE backup jobs back up the guests. pbo.timer backs up nothing itself;\n  it only retries spool leftovers (ingest --pending) and refreshes the catalogue.%s\n' "$C_D" "$C_0"
    elif [[ "$mode" == both ]]; then
        printf '  %sBoth: pbo.timer backs up the guests no PVE backup job to pbo selects.%s\n' "$C_D" "$C_0"
    fi
    for u in pbo.timer pbo-prune.timer pbo-verify.timer pbo-test-restore.timer; do
        case "$u" in
            pbo.timer) k=SCHEDULE_BACKUP what='the nightly backup'
                       [[ "$mode" != integrated ]] || what='spool leftovers and the catalogue, no backups of its own' ;;
            pbo-prune.timer) k=SCHEDULE_PRUNE what='retention' ;;
            pbo-verify.timer) k=SCHEDULE_VERIFY what="the integrity check, 1/${VERIFY_ROTATE:-12} of the data per run" ;;
            pbo-test-restore.timer) k=SCHEDULE_TEST_RESTORE what='the restore test: restores and boots one guest' ;;
        esac
        if systemctl is-enabled --quiet "$u" </dev/null >/dev/null 2>&1; then
            printf '  %s is enabled (%s, %s).\n' "$u" "$what" "${!k-}"; continue
        fi
        _setup_yn "Enable $u ($what, ${!k-})?" "$def" || continue
        if systemctl enable --now "$u" </dev/null >/dev/null 2>&1; then printf '  %s%s enabled%s\n' "$C_G" "$u" "$C_0"
        else printf '  %scould not enable %s (systemctl enable --now %s).%s\n' "$C_Y" "$u" "$u" "$C_0"; fi
    done
    return 0
}

# _setup_doctor_step: `pbo doctor --fix` (the permission table applied: the
# config, the DR key, the cache, the credentials files) and its report; its
# exit status (69: doctor found a problem).
_setup_doctor_step() {
    printf '\n%s— Health check (pbo doctor --fix) —%s\n' "$C_B" "$C_0"
    local -a fp=()
    if (( SETUP_FIX_PARENTS )); then fp=(--fix-parents)
    elif (( SETUP_PARENTS_HINT )) && _setup_yn "Let doctor add the traverse-only ACL entries the cache step named (--fix-parents)?" y; then fp=(--fix-parents); fi
    "$PBO_BIN" doctor --fix "${fp[@]+"${fp[@]}"}" </dev/null
}

# --- SETUP WIZARD (used by `pbo setup`, install.sh, and the menu) ---
# One pass sets up everything needed to back up: the cache, the offsite target
# (SFTP with a key, a pinned host key and a tested connection; a rest-server; a
# directory; another restic backend with its credentials), the DR key, the
# backup mode, retention, ntfy, the repos, the guest set, the Proxmox
# integration, the schedule and the timers, and last `pbo doctor --fix`. Run
# again, it changes only what the operator changes.
# Exit status: 0 only when every step worked. A step that cannot go on stops
# the wizard (1, the init's own status when the repos cannot be made, 64 when
# the input ends); a failed integration step or a doctor that found problems
# lets the steps after it run, and the wizard ends with the status of the
# first of them and says what failed instead of "Setup complete".
run_setup_wizard() {
    set +e +u
    SETUP_EOF=0 SETUP_FIX_PARENTS=0 SETUP_PARENTS_HINT=0 SETUP_RERUN=0 SETUP_STEP='' SETUP_RC=0
    SETUP_FAILS=()
    # the steps run pbo of their own (the cache move, init, doctor --fix) and
    # write files: a global --dry-run would reach none of them
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        printf "pbo: setup has no --dry-run: it shows what each step changes and asks first (or try a change with 'pbo --dry-run config set KEY VALUE', and 'pbo --dry-run init' for the repos)\n" >&2
        return "$EX_USAGE"
    fi
    command -v jq >/dev/null 2>&1 || { printf 'jq is required for the setup (apt install jq)\n' >&2; return 1; }
    _cfg_write_ensure
    _setup_rerun_check && SETUP_RERUN=1
    printf '\n%s=== PBO · Proxmox Backup Offsite, setup ===%s\n' "$C_B" "$C_0"
    printf '%sEvery question offers the current setting: Enter keeps it, so running setup again changes only what you change.%s\n' "$C_D" "$C_0"
    local step rc
    for step in cache offsite; do
        SETUP_STEP="$step"
        "_setup_${step}_step" || { _setup_stopped "$step"; return 1; }
    done
    if [[ "${LOCAL_REPO:-true}" != true && ( "${OFFSITE_ENABLED:-true}" != true || -z "${RESTIC_OFFSITE_REPO:-}" ) ]]; then
        printf '  %sNo local cache repo and no offsite repo: there is nothing to back up into.%s\n' "$C_R" "$C_0"
        _setup_stopped offsite; return 1
    fi
    for step in drkey mode retention ntfy; do
        SETUP_STEP="$step"
        "_setup_${step}_step" || { _setup_stopped "$step"; return 1; }
    done

    SETUP_STEP=init
    printf '\n%s— Repo init —%s\n' "$C_B" "$C_0"
    printf '  Creating/verifying the restic repo(s)…\n'
    _setup_pbo init; rc=$?
    if (( rc != 0 )); then
        printf '  %sinit failed (exit %s): fix the target above and run pbo setup again (it keeps what is set).%s\n' "$C_R" "$rc" "$C_0"
        _setup_stopped init; return "$rc"
    fi

    SETUP_STEP=guests
    _setup_guests_step || { _setup_stopped guests; return 1; }
    # --- Proxmox integration (ADR 0007) ---
    SETUP_STEP=integration
    _setup_integration_step; rc=$?
    (( rc == 0 )) || _setup_fail "$rc" "the Proxmox integration: ${SETUP_INTEG_FAIL:-the step failed} (exit $rc)"
    SETUP_STEP=schedule
    _setup_schedule_step || { _setup_stopped schedule; return 1; }
    SETUP_STEP=doctor
    _setup_doctor_step; rc=$?
    if (( rc != 0 )); then
        local why="pbo doctor found problems (exit $rc, the FAIL lines above)"
        # (a guest is a FAIL until its first snapshot: expected right after a first setup)
        (( SETUP_RERUN )) || why+="; a guest with no snapshot yet stays a FAIL until the first backup ran"
        _setup_fail "$rc" "the health check: $why"
    fi

    if (( ${#SETUP_FAILS[@]} )); then
        printf '\n  %sSetup ran to the end, but not everything worked:%s\n' "$C_R" "$C_0"
        local f; for f in "${SETUP_FAILS[@]}"; do printf '    - %s\n' "$f"; done
        printf '  Fix that, then run pbo setup again (it keeps what is set) or pbo doctor.\n'
        printf '  %sExport your DR key%s → password manager (menu → Export DR key): without it, a restore on a new host is impossible.\n' "$C_B" "$C_0"
        # the list above says what failed: no "stopped unexpectedly" from
        # pbo's exit on top (and no alert); in the menu the session goes on
        [[ "${PBO_COMMAND:-}" != setup ]] || PBO_ERROR_LOGGED=1
        return "$SETUP_RC"
    fi
    printf '\n%s  Setup complete.%s Recommended next step:\n' "$C_G" "$C_0"
    printf '    %sExport your DR key%s → password manager (menu → Export DR key).\n' "$C_B" "$C_0"
    printf '    Without it, a restore on a new host is impossible.\n'
    return 0
}

# _setup_fail RC WHAT: a step that failed but let the wizard go on: named in
# the closing text, and the wizard's exit status is the first such RC.
_setup_fail() {
    (( SETUP_RC != 0 )) || SETUP_RC="$1"
    SETUP_FAILS+=("$2")
}

# _setup_stopped STEP: what a stop in STEP leaves (each step wrote its own
# changes, nothing after it ran).
_setup_stopped() {
    printf '\n  %sSetup stopped in the %s step: what the steps before it set is written, nothing after it changed. Run pbo setup again to go on.%s\n' "$C_R" "$1" "$C_0"
}

# _setup_integration_step: the wizard's "Proxmox integration" step. Choose
# standalone | both | integrated (default: the current mode, or the one install.sh
# was given, PBO_SETUP_INTEGRATION). Without the storage plugin it says how to
# install it on this layout (_integ_install_hint) and stays as it is.
# Otherwise it shows the dry run of `pbo integrate enable|disable` and
# applies it after a yes. Returns non-zero (SETUP_INTEG_FAIL says what) when
# the mode chosen could not be set: the plugin is missing, or enable or
# disable failed; a no to the dry run is no failure.
_setup_integration_step() {
    printf '\n%s— Proxmox integration —%s\n' "$C_B" "$C_0"
    printf '%sstandalone: pbo.timer backs up every guest (as before).\n' "$C_D"
    printf 'both:       a PVE backup job (Datacenter -> Backup) to the pbo storage owns the guests it selects, pbo.timer backs up the rest.\n'
    printf 'integrated: only PVE backup jobs back up guests; pbo still prunes, verifies and tests restores.%s\n' "$C_0"
    local cur want def=1 m rc
    SETUP_INTEG_FAIL=''
    cur="$(_integration_mode)"; want="${PBO_SETUP_INTEGRATION:-$cur}"
    case "$want" in both) def=2 ;; integrated) def=3 ;; esac
    if ! _setup_pick "Mode" "$def" "standalone$([[ $cur == standalone ]] && echo ' (current)')" \
            "both$([[ $cur == both ]] && echo ' (current)')" "integrated$([[ $cur == integrated ]] && echo ' (current)')"; then
        echo "  ${C_Y}No such choice, keeping $cur.${C_0}"; return 0
    fi
    case "$((10#$_PI))" in 1) m=standalone ;; 2) m=both ;; *) m=integrated ;; esac
    if [[ "$m" == standalone ]]; then
        if [[ "$cur" == standalone ]]; then echo "  Standalone: pbo.timer backs up every guest."; return 0; fi
        "$PBO_BIN" --dry-run integrate disable </dev/null
        if _setup_yn "Turn the Proxmox integration off (as shown above)?" n; then
            "$PBO_BIN" integrate disable --yes </dev/null; rc=$?
            if (( rc == 0 )); then PBO_INTEGRATION=standalone; echo "  ${C_G}Standalone.${C_0}"
            else
                echo "  ${C_Y}'pbo integrate disable' did not finish, still $cur (see above).${C_0}"
                SETUP_INTEG_FAIL="'pbo integrate disable' did not finish, still $cur"; return "$rc"
            fi
        fi
        return 0
    fi
    if [[ ! -f "$(_integ_plugin_path)" ]]; then
        echo "  ${C_Y}The pbo storage plugin is not installed ($(_integ_plugin_path)), staying $cur.${C_0}"
        echo "  Install it, then run 'pbo setup' or 'pbo integrate enable $m':"
        if declare -F _integ_install_hint >/dev/null; then echo "    $(_integ_install_hint "$m")"
        else echo "    install.sh --integration $m (an install.sh host), or apt install pbo-pve-storage (a package host)"; fi
        SETUP_INTEG_FAIL="the storage plugin is not installed, still $cur"
        return "${EX_UNAVAILABLE:-69}"
    fi
    "$PBO_BIN" --dry-run integrate enable "$m" </dev/null
    if _setup_yn "Apply this (adds the pbo storage to PVE, the hook to /etc/vzdump.conf, pbo-catalog.timer)?" y; then
        "$PBO_BIN" integrate enable "$m" --yes </dev/null; rc=$?
        if (( rc == 0 )); then
            PBO_INTEGRATION="$m"
            echo "  ${C_G}Proxmox integration: $m.${C_0} Add backup jobs to the storage '${PVE_STORAGE_ID:-pbo}' in Datacenter -> Backup (compression none)."
        else
            echo "  ${C_Y}'pbo integrate enable $m' did not finish, still $cur (see above).${C_0}"
            SETUP_INTEG_FAIL="'pbo integrate enable $m' did not finish, still $cur"; return "$rc"
        fi
    else
        echo "  Not applied, still $cur."
    fi
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
    local rest_lines=()
    if [[ -n "${RESTIC_REST_USERNAME:-}" ]]; then
        rest_lines+=("RESTIC_REST_USERNAME=${RESTIC_REST_USERNAME}" "RESTIC_REST_PASSWORD=$(_rest_password)")
        [[ -n "${RESTIC_CACERT:-}" ]] && rest_lines+=("# RESTIC_CACERT: the server's TLS certificate (the same file the rest-server uses)")
    fi
    local l; for l in "${rest_lines[@]}"; do echo "  $l"; done
    echo "  ${C_B}RESTIC_PASSWORD=${pw}${C_0}"
    echo
    if _yn "Save a copy to /root/pbo-dr-key.txt (0600)?" n; then
        ( umask 077; { echo "RESTIC_OFFSITE_REPO=${RESTIC_OFFSITE_REPO}";
          echo "RESTIC_SFTP_COMMAND=${RESTIC_SFTP_COMMAND}"; printf '%s\n' "${rest_lines[@]}"; echo "RESTIC_PASSWORD=${pw}"; } > /root/pbo-dr-key.txt )
        echo "  ${C_G}saved: /root/pbo-dr-key.txt${C_0}, move it offline and delete it from this host."
    fi
    _pause
}

# --- 6. RESTORE ---
menu_restore() {
    _menu_header
    printf '%s Restore%s\n\n' "$C_B" "$C_0"
    echo "  Fetching offsite archives…"
    local listing; listing="$("$PBO_BIN" --json list --reasons 2>/dev/null)"
    jq -e '.archives|length>0' <<<"$listing" >/dev/null 2>&1 \
        || { echo "  ${C_R}No offsite archives.${C_0}"; _pause; return; }

    local now; now="$(date +%s)"
    local names; names="$(_menu_guests_tsv | awk -F'\t' '{print $1"\t"$2}')"

    # --- STEP 1: pick a guest (vmid · name · #snapshots · newest age) ---
    local gv=() glabel=() vmid nsnap newest nm
    while IFS=$'\t' read -r vmid nsnap newest; do
        [[ -n "$vmid" ]] || continue
        nm="$(awk -F'\t' -v v="$vmid" '$1==v{print $2}' <<<"$names")"
        [[ "$vmid" == host-* ]] && nm="host config"
        gv+=("$vmid")
        glabel+=("$(printf '%-14s %-18s %2d snapshots · newest %s' \
            "$vmid" "${nm:-–}" "$nsnap" "$(_ago "$newest" "$now")")")
    done < <(jq -r '.archives | group_by(.vmid)[]
        | [ .[0].vmid, length, ([.[].modtime]|max) ] | @tsv' <<<"$listing")

    printf '\n  %sGuests with backups:%s\n' "$C_B" "$C_0"
    local gi; gi="$(_pick_index "Guest" 1 "${glabel[@]}")" || { _pause; return; }
    local src="${gv[gi-1]}"

    # --- STEP 2: pick a snapshot of that guest (newest first) ---
    # The [code] shows which retention bucket keeps it: d/w/m/y=daily/weekly/
    # monthly/yearly, L=keep-last. Empty = the next prune would drop it.
    local sv=() slabel=() ts size modt snap code
    while IFS=$'\t' read -r ts size modt snap code; do
        [[ -n "$ts" ]] || continue
        sv+=("$ts")
        slabel+=("$(printf '%-9s · %7s · %s · %s' \
            "$(_ago "$modt" "$now")" "$(_hsize "$size")" "$(sed 's/T/ /;s/\..*//' <<<"$modt")" "[${code:-–}]")")
    done < <(jq -r --arg v "$src" '.archives[] | select(.vmid==$v)
        | (.reasons // []) as $r
        | ( [ (if any($r[];test("daily"))   then "d" else empty end),
              (if any($r[];test("weekly"))  then "w" else empty end),
              (if any($r[];test("monthly")) then "m" else empty end),
              (if any($r[];test("yearly"))  then "y" else empty end),
              (if any($r[];test("last"))    then "L" else empty end) ] | join("") ) as $code
        | [ (.archive|capture("(?<t>[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2})").t),
            .size_bytes, .modtime, .snapshot, $code ] | @tsv' <<<"$listing" | sort -rk3)
    [[ ${#sv[@]} -gt 0 ]] || { echo "  ${C_R}No snapshots for $src.${C_0}"; _pause; return; }

    printf '\n  %sSnapshots of %s · %s (newest first):%s\n' \
        "$C_B" "$src" "$(awk -F'\t' -v v="$src" '$1==v{print $2}' <<<"$names")" "$C_0"
    local si; si="$(_pick_index "Snapshot" 1 "${slabel[@]}")" || { _pause; return; }
    local ts="${sv[si-1]}"

    # Host snapshots restore to a directory (file restore), never pct/qmrestore.
    if [[ "$src" == host-* ]]; then
        local dir; dir="$(_ask "Extract to directory" "/var/tmp/pbo-restore-${src}-${ts}")"
        local onefile; onefile="$(_ask "Single path to restore (blank = everything)" "")"
        _yn "Restore host snapshot $src ($ts) → files under $dir?" y || return
        if [[ -n "$onefile" ]]; then
            "$PBO_BIN" restore-host "$src" "$ts" --to "$dir" --path "$onefile"
        else
            "$PBO_BIN" restore-host "$src" "$ts" --to "$dir"
        fi
        _pause; return
    fi

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
    printf '  %s[7]%s Unlock repo (stale lock) %s[8]%s Restore-test report\n' "$C_B" "$C_0" "$C_B" "$C_0"
    printf '  %s[0]%s back\n\n' "$C_B" "$C_0"
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
        8) "$PBO_BIN" restore-report; _pause ;;
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
        shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
    else
        # never throw the new key away on a failure: if a rollback did not complete,
        # a repo may accept it. The log says which.
        echo "  ${C_R}rotation failed.${C_0} Normally nothing changed and the OLD key is still the one in use."
        echo "  The new key was NOT discarded, in case the log reports a failed rollback:"
        echo "    ${C_B}RESTIC_PASSWORD=${newpass}${C_0}   (also in $tmp, root only)"
        echo "  Check the log, then delete $tmp."
    fi
    _pause
}

# --- HELP: what every menu action does ---
menu_help() {
    _menu_header
    printf '%s Help — what each action does%s\n\n' "$C_B" "$C_0"
    local B="$C_B" D="$C_D" Z="$C_0"
    printf '  %sConcepts%s\n' "$B" "$Z"
    printf '    %sTiers%s     Local = a cache repo on fast local disk; Offsite = the remote\n' "$D" "$Z"
    printf '              restic repo (SFTP, rest-server, ...). Cached mode backs up locally, then copies offsite.\n'
    printf '    %sDR key%s    The restic repo password (%s%s%s). It is the ONLY\n' "$D" "$Z" "$D" "${RESTIC_PASSWORD_FILE-}" "$Z"
    printf '              thing that can decrypt the offsite data. Lose it and the backup is gone.\n'
    printf '    %sSnapshot%s  One backup of one guest at one time, tagged by vmid. Restores never\n' "$D" "$Z"
    printf '              overwrite: a guest is always restored to a NEW vmid.\n\n'

    printf '  %sMain menu%s\n' "$B" "$Z"
    printf '    %s1 Setup%s        Guided wizard: cache, offsite target (SFTP, rest-server, a directory\n' "$B" "$Z"
    printf '                  or another restic backend), DR key (the key of a repo that exists\n'
    printf '                  already), mode, retention, ntfy, the repos, guests, the Proxmox\n'
    printf '                  integration, schedule, doctor --fix. Safe to run again: Enter keeps each setting.\n'
    printf '    %s2 Guests%s       Scan the cluster and choose which guests are backed up\n' "$B" "$Z"
    printf '                  (writes BACKUP_ORDER). "protected" = included in the nightly run.\n'
    printf '    %s3 Back up%s      Run a backup now: all protected guests (stream/batch), a single\n' "$B" "$Z"
    printf '                  guest, or THIS host (its config + rebuild metadata).\n'
    printf '    %s4 Export DR key%s Show/save the repo password so you can store it offline. Do this\n' "$B" "$Z"
    printf '                  once after setup; without it a restore on a new host is impossible.\n'
    printf '    %s5 Status%s       Both tiers at a glance: guests, snapshots, size, dedup, newest\n' "$B" "$Z"
    printf '                  backup, and the next scheduled run.\n'
    printf '    %s6 Restore%s      Pick a guest, then a snapshot (newest first), then a new vmid and\n' "$B" "$Z"
    printf '                  storage. A host snapshot instead extracts its files to a directory.\n'
    printf '    %s7 Maintenance%s  See below.\n\n' "$B" "$Z"

    printf '  %sMaintenance%s\n' "$B" "$Z"
    printf '    %sPrune%s         Apply retention (KEEP_* policy). Dry run shows what would go.\n' "$B" "$Z"
    printf '    %sVerify%s        restic check on both tiers: proves the repo is intact.\n' "$B" "$Z"
    printf '    %sTest-restore%s  Restore a guest to a throwaway copy, boot it, destroy it — proves\n' "$B" "$Z"
    printf '                  a restore actually works.\n'
    printf '    %sDoctor%s        Health check: repo reachable, DR key perms, timer, provider\n' "$B" "$Z"
    printf '                  snapshots, and per-guest snapshot age (catches a silently missed guest).\n'
    printf '    %sRotate DR key%s Change the repo password (old one stops working). Export it after.\n' "$B" "$Z"
    printf '    %sUnlock%s        Clear a stale repo lock left by a killed run.\n\n' "$B" "$Z"

    printf '  %sHost backup%s excludes SSH keys and the DR key on purpose — keep your own\n' "$B" "$Z"
    printf '  offline copy. Everything here is also a CLI command: run %spbo help%s.\n\n' "$D" "$Z"
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
        printf '  %s[7]%s Maintenance (prune/verify) %s[8]%s Help\n' "$C_B" "$C_0" "$C_B" "$C_0"
        printf '  %s[0]%s Quit\n\n' "$C_B" "$C_0"
        local c; c="$(_ask "Choice")"
        case "$c" in
            1) menu_setup ;;
            2) menu_guests ;;
            3) menu_backup ;;
            4) menu_export ;;
            5) menu_status ;;
            6) menu_restore ;;
            7) menu_maint ;;
            8|h|H|help|\?) menu_help ;;
            0|q|"") clear 2>/dev/null || true; return "$EX_OK" ;;
            *) : ;;
        esac
    done
}
