# shellcheck shell=bash
# lib/common.sh: shared helper functions: config, logging, JSON, notify stub.
# Sourced by the main script. Must never be run standalone.
#
# Conventions:
#   - Comments in English, code and variable names in English.
#   - Every value that can fail returns a meaningful exit code (sysexits).
#   - No secrets in logs or error messages.

# ---------------------------------------------------------------------------
# Exit codes (subset of sysexits.h), consistent across the whole tool.
# ---------------------------------------------------------------------------
readonly EX_OK=0
readonly EX_USAGE=64        # incorrect argument usage
readonly EX_DATAERR=65      # bad input data (corrupt archive, config)
readonly EX_UNAVAILABLE=69  # a service/resource is missing (rclone remote down)
readonly EX_SOFTWARE=70     # internal error
readonly EX_TEMPFAIL=75     # temporary failure, lock busy, queue full
readonly EX_CANTCREAT=73    # cannot create/open file (lock file, holder)
readonly EX_CONFIG=78       # configuration error

# ---------------------------------------------------------------------------
# Default values. Overridden by the config file (KEY=VALUE) sourced afterwards.
# ---------------------------------------------------------------------------
set_defaults() {
    : "${CACHE_DIR:=/var/cache/pbo}"
    : "${LOG_DIR:=/var/log/pbo}"
    : "${STATE_DIR:=/var/lib/pbo}"
    : "${LOCK_DIR:=/var/lock}"
    : "${RCLONE_REMOTE:=hetzner-crypt}"
    : "${REMOTE_PATH:=lxc}"
    : "${VZDUMP_MODE:=snapshot}"
    : "${VZDUMP_STOP_VMIDS:=}"         # these (+ auto-detected fuse CTs) → --mode stop
    : "${VZDUMP_COMPRESS:=zstd}"
    : "${VZDUMP_ZSTD_THREADS:=4}"
    : "${RCLONE_TRANSFERS:=4}"
    : "${RCLONE_CHECKERS:=4}"
    : "${RCLONE_BWLIMIT:=}"
    : "${BACKUP_ORDER:=auto}"          # auto = all guests on THIS node; or an explicit csv (critical-first)
    : "${PRUNE_OWNER:=}"               # cluster: restrict prune to this nodename (empty = any node may prune)
    : "${GLOBAL_LOCK_TIMEOUT:=7200}"
    : "${KEEP_LOCAL:=2}"
    : "${KEEP_OFFSITE_DAILY:=7}"
    : "${KEEP_OFFSITE_WEEKLY:=4}"
    : "${KEEP_OFFSITE_MONTHLY:=6}"
    : "${NTFY_URL:=}"                  # ntfy server (base URL); empty = no notifications
    : "${NTFY_TOKEN:=}"                # otherwise read from NTFY_CREDS_FILE
    : "${NTFY_TOPIC:=}"                # otherwise NTFY_TOPIC_WARN from the creds file
    : "${NTFY_CREDS_FILE:=/etc/ntfy.creds}"
    : "${NTFY_ON_SUCCESS:=false}"
    : "${OFFSITE_ENABLED:=true}"       # false = dump+verify locally, skip upload
    : "${RCLONE_CONFIG_FILE:=}"        # own rclone.conf (otherwise rclone's default)
    : "${TR_WAIT_TRIES:=30}"           # test-restore: number of attempts to reach CT
    : "${TR_WAIT_SLEEP:=2}"            # test-restore: seconds between attempts
    : "${STORAGE_BOX_SNAPSHOTS_CONFIRMED:=false}"  # confirm that Hetzner snapshots are on
    : "${MAX_AGE_WARN:=172800}"   # 48h, dashboard warns if the latest push is older

    # --- engine (ADR 0001): tar (current) | restic (new track) ---
    : "${ENGINE:=tar}"                                    # tar | restic
    : "${BACKUP_MODE:=stream}"                            # stream (one-by-one) | batch (dump all→upload), SAME repo
    : "${RESTIC_BIN:=restic}"                             # override in tests (scratch binary)
    : "${LOCAL_REPO:=true}"                               # true=cached (local repo+copy), false=offsite-only
    : "${RESTIC_CACHE_REPO:=${CACHE_DIR}/repo}"           # local restic repo (cache tier)
    : "${RESTIC_OFFSITE_REPO:=}"                          # sftp:user@host:port/path (native) or local dir (test)
    : "${RESTIC_PASSWORD_FILE:=/etc/pbo/restic-pass}"  # repo password (DR key), 0600
    : "${RESTIC_CACHE_DIR:=${STATE_DIR}/restic-cache}"    # restic's own metadata cache
    : "${RESTIC_KEEP_LAST:=${KEEP_LOCAL}}"               # local repo: keep N latest per guest
    : "${RESTIC_SFTP_COMMAND:=}"                          # full ssh command for native sftp (port/key); empty=restic default
    : "${RESTIC_SFTP_CONNECTIONS:=8}"                     # parallel sftp connections (Storage Box ~10 max), speeds up restore considerably

    # Derived paths.
    LOG_FILE="${LOG_DIR}/pbo.log"
    AUDIT_FILE="${LOG_DIR}/audit.log"
    GLOBAL_LOCK_FILE="${LOCK_DIR}/pbo.global"
    GLOBAL_HOLDER_FILE="${STATE_DIR}/global.holder"
    JOBS_DIR="${STATE_DIR}/jobs"
}

# ---------------------------------------------------------------------------
# Config loading. The file must be root-owned and 0600; we refuse to source it
# if it is group-/world-writable (it may contain paths but never secrets).
# ---------------------------------------------------------------------------
# Source one config file if it exists. Refuse it if group-/world-WRITABLE, it
# controls what root runs. (Readable by others is fine; it holds no secrets.)
_source_config_file() {
    local cfg="$1"
    [[ -f "$cfg" ]] || return 1
    local perms; perms="$(stat -c '%a' "$cfg")"
    local grp="${perms: -2:1}" oth="${perms: -1:1}"
    if (( (grp & 2) || (oth & 2) )); then
        printf 'pbo: REFUSING to source group-/world-writable config (%s): %s\n' "$perms" "$cfg" >&2
        exit "$EX_CONFIG"
    fi
    # shellcheck disable=SC1090
    source "$cfg"
    return 0
}

load_config() {
    local cfg="${PBO_CONFIG:-/etc/pbo/config}" loaded=""
    # Cluster: a shared, non-secret base config replicated by pmxcfs (edit once for
    # the whole cluster). The local config overrides it; secrets stay local only.
    # Skipped when PBO_CONFIG is set explicitly (that file stands alone).
    if [[ -z "${PBO_CONFIG:-}" ]] && _source_config_file /etc/pve/pbo/config; then
        loaded="/etc/pve/pbo/config"
    fi
    _source_config_file "$cfg" && loaded="$cfg"
    PBO_CONFIG_LOADED="$loaded"
    set_defaults
    # Point rclone at our own config if given (rclone reads the RCLONE_CONFIG env).
    [[ -n "${RCLONE_CONFIG_FILE:-}" ]] && export RCLONE_CONFIG="$RCLONE_CONFIG_FILE"
    ensure_dirs
}

# Create the directories we own. The log directory falls back to stderr-only
# if it cannot be created (e.g. isolated dev without a root install).
ensure_dirs() {
    mkdir -p "$STATE_DIR" "$JOBS_DIR" "$LOCK_DIR" "$CACHE_DIR" 2>/dev/null || true
    if ! mkdir -p "$LOG_DIR" 2>/dev/null || [[ ! -w "$LOG_DIR" ]]; then
        LOG_FILE=""   # signal: log only to stderr/stdout
    fi
}

# ---------------------------------------------------------------------------
# Logging. Format: "2026-09-04T11:00:00+02:00 [INFO] message".
# In --json mode the human log goes to stderr so stdout stays pure JSON.
# ---------------------------------------------------------------------------
_log() {
    local level="$1"; shift
    local line; line="$(date --iso-8601=seconds) [$level] $*"
    # File: always if we have a writable log file.
    [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
    # Terminal: stderr in json mode, otherwise stderr for WARN/ERROR and stdout for INFO.
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        printf '%s\n' "$line" >&2
    elif [[ "$level" == "INFO" ]]; then
        printf '%s\n' "$line"
    else
        printf '%s\n' "$line" >&2
    fi
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
# Errors are logged AND trigger a notification (stub in step 1, real in step 8/notify.sh).
log_error() { _log ERROR "$@"; notify_failure "$*" 2>/dev/null || true; }

# Audit log for destructive/outbound actions (who did what).
# Line: "2026-09-04T.. user=<sudo/uid> restore src=110 target=9010 …".
audit_log() {
    local who="${SUDO_USER:-$(id -un 2>/dev/null || echo root)}"
    local line; line="$(date --iso-8601=seconds) user=${who} $*"
    [[ -n "${AUDIT_FILE:-}" ]] && printf '%s\n' "$line" >> "$AUDIT_FILE" 2>/dev/null || true
    _log INFO "audit: $*"
}

# die <exit-code> <message...>
die() {
    local code="$1"; shift
    log_error "$*"
    exit "$code"
}

# ---------------------------------------------------------------------------
# Notify stub. Replaced by lib/notify.sh (ntfy) in step 8. Here just a no-op
# that honors the NTFY_ON_SUCCESS contract so the call sites already line up.
# ---------------------------------------------------------------------------
notify_failure() { :; }   # sends ntfy on failure, implemented in step 8
notify_success() {        # silent unless NTFY_ON_SUCCESS=true
    [[ "${NTFY_ON_SUCCESS:-false}" == "true" ]] || return 0
    :
}

# ---------------------------------------------------------------------------
# JSON output WITHOUT a jq dependency (jq is only needed to PARSE rclone lsjson
# later, never to build our own output). Manual string escaping.
# ---------------------------------------------------------------------------
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # backslash first
    s="${s//\"/\\\"}"   # quote character
    s="${s//$'\n'/\\n}" # newline
    s="${s//$'\t'/\\t}" # tab
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# json_result <status> <ok:true|false> [k v k v ...]
# Writes a flat JSON object to stdout. Values are treated as strings.
json_result() {
    local status="$1" ok="$2"; shift 2
    local out; out="$(printf '{"command":"%s","status":"%s","ok":%s' \
        "$(json_escape "${PBO_COMMAND:-}")" "$(json_escape "$status")" "$ok")"
    out+="$(printf ',"dry_run":%s' "$( [[ "${DRY_RUN:-0}" == 1 ]] && echo true || echo false )")"
    while [[ $# -ge 2 ]]; do
        out+="$(printf ',"%s":"%s"' "$(json_escape "$1")" "$(json_escape "$2")")"
        shift 2
    done
    out+='}'
    printf '%s\n' "$out"
}

# Uniform "not yet implemented" response (step 1: all operations).
not_implemented() {
    local cmd="${PBO_COMMAND:-?}"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "not_implemented" "false"
    else
        log_warn "'$cmd' is not yet implemented (step 1: skeleton only)."
    fi
    return "$EX_OK"
}

# Validate that an argument looks like a vmid (integer 100-999999999).
is_vmid() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 100 )); }
require_vmid() {
    is_vmid "${1:-}" || die "$EX_USAGE" "invalid vmid: '${1:-<missing>}'"
}
