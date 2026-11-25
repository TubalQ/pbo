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
readonly EX_UNAVAILABLE=69  # a service/resource is missing (repo unreachable)
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
    # locks in a directory only pbo can write: /var/lock is world-writable, and
    # a local user could pre-create or hold a lock file (fs.protected_regular)
    if [[ "$(id -u)" == 0 ]]; then : "${LOCK_DIR:=/run/pbo}"; else : "${LOCK_DIR:=${STATE_DIR}/lock}"; fi
    : "${VZDUMP_MODE:=snapshot}"
    : "${VZDUMP_STOP_VMIDS:=}"         # these (+ auto-detected fuse CTs) → --mode stop
    : "${BACKUP_ORDER:=auto}"          # auto = all guests on THIS node; or an explicit csv (critical-first)
    : "${PRUNE_OWNER:=}"               # cluster: restrict prune to this nodename (empty = any node may prune)
    : "${GLOBAL_LOCK_TIMEOUT:=7200}"
    : "${SCHEDULE_LOCK_TIMEOUT:=${GLOBAL_LOCK_TIMEOUT}}"   # how long a queued prune/run-schedule waits for the other
    : "${KEEP_LOCAL:=2}"
    : "${KEEP_OFFSITE_DAILY:=7}"
    : "${KEEP_OFFSITE_WEEKLY:=4}"
    : "${KEEP_OFFSITE_MONTHLY:=6}"
    : "${KEEP_OVERRIDE_MIN_LAST:=3}"   # a per-guest keep tag never keeps fewer than this many
    : "${KEEP_OFFSITE_YEARLY:=0}"      # 0 = no yearly bucket
    : "${FUTURE_SKEW:=3600}"           # seconds a snapshot may be dated ahead before it counts as "from the future"
    : "${NTFY_URL:=}"                  # ntfy server (base URL); empty = no notifications
    : "${NTFY_TOKEN:=}"                # otherwise read from NTFY_CREDS_FILE
    : "${NTFY_TOPIC:=}"                # otherwise NTFY_TOPIC_WARN from the creds file
    : "${NTFY_CREDS_FILE:=/etc/ntfy.creds}"
    : "${NTFY_ON_SUCCESS:=false}"      # deprecated: NOTIFY_LEVEL=all
    : "${NOTIFY_LEVEL:=}"              # fail | warn | all (empty: fail, or all if NTFY_ON_SUCCESS=true)
    : "${NOTIFY_PVE:=auto}"            # Proxmox notification system: auto (when no ntfy) | true (also) | false
    : "${OFFSITE_ENABLED:=true}"       # false = local repo only, no offsite copy
    : "${PBO_ROLE:=host}"              # host = PVE node that backs up guests | janitor = storage-side box that owns offsite retention
    : "${JANITOR_USER:=restic}"         # janitor: the user rest-server runs as; root re-execs as this user
    : "${OFFSITE_APPEND_ONLY:=false}"  # true = offsite refuses deletes (rest-server --append-only); this host never prunes it
    : "${TR_WAIT_TRIES:=30}"           # test-restore: number of attempts to reach the guest
    : "${TR_WAIT_SLEEP:=2}"            # test-restore: seconds between attempts
    : "${TR_PER_RUN:=1}"               # test-restore --scheduled: guests per run
    : "${TR_MAX_AGE:=1814400}"         # 21 days, doctor warns when the last restore test is older
    : "${TR_REPORT_DAYS:=90}"          # restore-report / doctor coverage window (days)
    : "${STORAGE_BOX_SNAPSHOTS_CONFIRMED:=false}"  # confirm that Hetzner snapshots are on
    : "${DOCTOR_MAX_AGE:=172800}"      # 48h, doctor flags a guest whose newest snapshot is older
    : "${VERIFY_ROTATE:=12}"           # verify --scheduled reads 1/N of the data per run, all of it every N runs (0 = structure only)
    : "${VERIFY_MAX_AGE:=3456000}"     # 40 days, doctor warns when the last verify is older

    # --- Proxmox integration (ADR 0006/0007) ---
    : "${PBO_INTEGRATION:=standalone}"                    # standalone (pbo.timer backs up every guest) | both | integrated
    : "${PVE_STORAGE_ID:=pbo}"                            # the pbo storage that `pbo integrate` adds to PVE
    : "${PVE_SPOOL_DIR:=${CACHE_DIR}/spool}"              # where PVE jobs write archives (same filesystem as CACHE_DIR)
    : "${PVE_STAGING_DIR:=${CACHE_DIR}/staging}"          # archives materialised for a PVE restore
    : "${PVE_STAGING_TTL:=21600}"                         # seconds a staged archive is kept (6 h)
    : "${PVE_STAGING_LINK_TTL:=900}"                      # seconds a staged symlink into the mount is kept while nothing reads through it
    : "${PVE_CATALOG_MOUNT:=true}"                        # true = stage cache archives as symlinks into pbo-mount.service (restic mount); false = restic dump
    : "${PVE_CATALOG_MOUNT_DIR:=/run/pbo/mnt}"            # where pbo-mount.service mounts the cache repo
    : "${CATALOG_MOUNT_BUSY_WAIT:=900}"                   # prune/verify wait this long (s) for a restore reading through the mount, then exit 75
    : "${CATALOG_MAX_AGE:=7200}"                          # doctor warns when the catalogue is older (2 h)
    : "${VZDUMP_CONF:=/etc/vzdump.conf}"                  # vzdump defaults (storage: for jobs without one)
    : "${PVE_STORAGE_CFG:=/etc/pve/storage.cfg}"          # read when `pvesh get /storage` fails
    : "${PBO_CATALOG:=/var/lib/pbo/catalog/index.json}"   # fixed path the storage plugin reads; override only in tests
    : "${VZDUMP_LOCK:=/var/run/vzdump.lock}"              # vzdump's node lock: `ingest --pending` leaves the spool alone while it is held
    : "${PBO_PVE_PLUGIN_PATH:=/usr/share/perl5/PVE/Storage/Custom/PboPlugin.pm}"  # where `pbo integrate`/doctor look for the storage plugin
    : "${PBO_PVE_PLUGIN_CHECK:=}"                         # empty: perl -MPVE::Storage load test of the plugin; else this shell command (tests)
    : "${PBO_VZDUMP_HOOK:=}"                              # empty: the vzdump-hook next to this pbo (install.sh /usr/local/lib/pbo, package /usr/lib/pbo)

    # --- restic engine ---
    : "${BACKUP_MODE:=stream}"                            # stream (one-by-one) | batch (dump all→upload), SAME repo
    : "${RESTIC_BIN:=restic}"                             # override in tests (scratch binary)
    : "${LOCAL_REPO:=true}"                               # true=cached (local repo+copy), false=offsite-only
    : "${RESTIC_CACHE_REPO:=${CACHE_DIR}/repo}"           # local restic repo (cache tier)
    : "${RESTIC_OFFSITE_REPO:=}"                          # sftp:user@host:port/path (native) or local dir (test)
    : "${RESTIC_PASSWORD_FILE:=/etc/pbo/restic-pass}"  # repo password (DR key), 0600
    : "${RESTIC_CACHE_DIR:=${STATE_DIR}/restic-cache}"    # restic's own metadata cache
    : "${RESTIC_KEEP_LAST:=${KEEP_LOCAL}}"               # local repo: keep N latest per guest
    : "${RESTIC_SFTP_COMMAND:=}"                          # full ssh command for native sftp (port/key); empty=restic default
    : "${RESTIC_RETRY_LOCK:=10m}"                         # write ops wait this long on a busy repo lock (another node, a manual restic). Empty = fail at once
    : "${RESTIC_SFTP_CONNECTIONS:=8}"                     # parallel sftp connections (Storage Box ~10 max), speeds up restore considerably
    : "${RESTIC_REST_USERNAME:=}"                         # rest-server basic auth user (rest: repos); with --private-repos also the first path segment
    : "${RESTIC_REST_PASSWORD_FILE:=}"                    # file with that user's HTTP password, 0600
    : "${RESTIC_CACERT:=}"                                # pinned cert/CA for a self-signed rest-server (restic --cacert)

    # --- host backup (config + rebuild metadata, manual: `pbo backup-host`) ---
    # Curated, space-separated. Missing paths are skipped (not an error).
    : "${HOST_BACKUP_PATHS:=/etc/pve /etc/network/interfaces /etc/network/interfaces.d /etc/hosts /etc/hostname /etc/resolv.conf /etc/fstab /etc/vzdump.conf /etc/pbo /etc/systemd/system /etc/cron.d /etc/apt/sources.list /etc/apt/sources.list.d}"
    # SSH keys and the DR key are deliberately excluded (secrets never go in the
    # repo they protect / the host must keep its own offline key copy).
    # never into the repo they protect, and no private keys: the DR key, the rest
    # password, the 0.4 pbo-web TLS key (if left), PVE's private dir (root CA key, authkey, tokens),
    # node TLS keys, SSH keys
    : "${HOST_BACKUP_EXCLUDES:=${RESTIC_PASSWORD_FILE} ${RESTIC_REST_PASSWORD_FILE:-/etc/pbo/rest-pass} /etc/pbo/rest-pass /etc/pbo/web-tls /etc/pbo/*.old-* /etc/pve/priv /etc/pve/nodes/*/*.key /etc/pve/local/*.key /etc/pve/*.key /root/.ssh **/.ssh **/id_rsa **/id_ed25519 **/id_ecdsa **/*.key}"

    # Derived paths.
    LOG_FILE="${LOG_DIR}/pbo.log"
    AUDIT_FILE="${LOG_DIR}/audit.log"
    : "${AUDIT_JSON:=${LOG_DIR}/audit.jsonl}"        # one JSON object per line: every command + audit events
    : "${METRICS_ENABLED:=true}"
    : "${METRICS_FILE:=${STATE_DIR}/pbo.prom}"       # node_exporter textfile; point it into --collector.textfile.directory
    GLOBAL_LOCK_FILE="${LOCK_DIR}/pbo.global"
    GLOBAL_HOLDER_FILE="${STATE_DIR}/global.holder"
    SCHED_LOCK_FILE="${LOCK_DIR}/pbo.schedule"
    SCHED_HOLDER_FILE="${STATE_DIR}/schedule.holder"
    JOBS_DIR="${STATE_DIR}/jobs"
}

# ---------------------------------------------------------------------------
# Config loading. The file is sourced as code: refused when group-/world-writable
# or owned by anyone but root (or the user pbo runs as). Keep it 0600: it can hold
# an ntfy token/topic and the SFTP command.
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
    # it is sourced as code: it must belong to root or to whoever runs pbo (the
    # janitor user on a janitor). /etc/pve files are owned by root via pmxcfs.
    local owner; owner="$(stat -c '%u' "$cfg")"
    if [[ "$owner" != 0 && "$owner" != "$(id -u)" ]]; then
        printf 'pbo: REFUSING to source a config owned by uid %s: %s\n' "$owner" "$cfg" >&2
        exit "$EX_CONFIG"
    fi
    # shellcheck disable=SC1090
    source "$cfg"
    return 0
}

load_config() {
    local cfg="${PBO_CONFIG:-/etc/pbo/config}" loaded=""
    PBO_CONFIG_EXPLICIT="${PBO_CONFIG:-}"   # jobs pass this on, so they load the same files
    # An explicit PBO_CONFIG that isn't there is a mistake, not "use defaults":
    # defaults point at a different repo (a leaked PBO_CONFIG could make a
    # janitor prune the empty default cache repo).
    if [[ -n "${PBO_CONFIG:-}" && ! -f "$PBO_CONFIG" ]]; then
        printf 'pbo: PBO_CONFIG=%s does not exist\n' "$PBO_CONFIG" >&2
        exit "$EX_CONFIG"
    fi
    # Cluster: a shared, non-secret base config replicated by pmxcfs (edit once for
    # the whole cluster). The local config overrides it; secrets stay local only.
    # Skipped when PBO_CONFIG is set explicitly (that file stands alone).
    if [[ -z "${PBO_CONFIG:-}" ]] && _source_config_file /etc/pve/pbo/config; then
        loaded="/etc/pve/pbo/config"
    fi
    _source_config_file "$cfg" && loaded="$cfg"
    PBO_CONFIG_LOADED="$loaded"
    set_defaults
    ensure_dirs
}

# Config schema. Bump when a key is renamed or changes meaning, and teach
# _config_check about the old name. A config may declare PBO_CONFIG_VERSION.
readonly PBO_CONFIG_SCHEMA=1

# _config_check <file>: lines for doctor. Unknown keys are usually typos
# (KEEP_OFSITE_DAILY silently falls back to the default), so name them.
# "Known" = every upper-case identifier pbo's own code mentions.
_config_check() {
    local f="$1"; CC_LINES=(); CC_WARNS=0
    [[ -r "$f" ]] || return 0
    local known keys k unknown=()
    known="$(grep -ohE '\b[A-Z][A-Z0-9_]{2,}\b' "${SELF_DIR}/pbo" "${SELF_DIR}"/lib/*.sh 2>/dev/null | sort -u)"
    keys="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Z][A-Z0-9_]*)=.*/\2/p' "$f" | sort -u)"
    while read -r k; do
        [[ -n "$k" ]] || continue
        grep -qx "$k" <<<"$known" || unknown+=("$k")
    done <<<"$keys"
    if (( ${#unknown[@]} )); then
        CC_LINES+=("unknown config key(s) in $f: ${unknown[*]} (typo? pbo ignores them)"); CC_WARNS=1
    fi
    case "${NOTIFY_LEVEL:-}" in
        ""|fail|warn|all) ;;
        *) CC_LINES+=("NOTIFY_LEVEL='${NOTIFY_LEVEL}' is not fail|warn|all: only failures are sent"); CC_WARNS=1 ;;
    esac
    if [[ "${NTFY_ON_SUCCESS:-false}" == true && -z "${NOTIFY_LEVEL:-}" ]]; then
        CC_LINES+=("NTFY_ON_SUCCESS is replaced by NOTIFY_LEVEL=fail|warn|all (still honoured: true means all)"); CC_WARNS=1
    fi
    case "${PBO_INTEGRATION:-standalone}" in
        standalone|both|integrated) ;;
        *) CC_LINES+=("PBO_INTEGRATION='${PBO_INTEGRATION}' is not standalone|both|integrated: treated as standalone (pbo.timer backs up every guest)"); CC_WARNS=1 ;;
    esac
    local v="${PBO_CONFIG_VERSION:-$PBO_CONFIG_SCHEMA}"
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v > PBO_CONFIG_SCHEMA )); then
        CC_LINES+=("$f is written for config schema $v, this pbo knows $PBO_CONFIG_SCHEMA: upgrade pbo"); CC_WARNS=1
    fi
    return 0
}

# Create the directories we own. The log directory falls back to stderr-only
# if it cannot be created (e.g. isolated dev without a root install).
ensure_dirs() {
    mkdir -p "$STATE_DIR" "$JOBS_DIR" "$CACHE_DIR" 2>/dev/null || true
    [[ -d "$LOCK_DIR" ]] || { mkdir -p "$LOCK_DIR" 2>/dev/null && chmod 0700 "$LOCK_DIR"; } || true
    # logs hold repo paths, guest names, errors: root (or the janitor user) only
    # (created here with umask 077; no global umask: vzdump of an unprivileged CT
    # runs tar as the mapped uid and must traverse CACHE_DIR)
    local lf; for lf in "${LOG_FILE:-}" "${AUDIT_FILE:-}"; do
        [[ -n "$lf" ]] || continue
        [[ -e "$lf" ]] || ( umask 077; : >> "$lf" ) 2>/dev/null || true
        [[ -f "$lf" ]] && chmod 0600 "$lf" 2>/dev/null || true
    done
    if ! mkdir -p "$LOG_DIR" 2>/dev/null || [[ ! -w "$LOG_DIR" ]]; then
        LOG_FILE=""   # signal: log only to stderr/stdout
        AUDIT_JSON=""
    fi
}

# _ct_root_uid <vmid> → the host uid that an unprivileged CT's root maps to: its
# first "lxc.idmap: u 0 <host> <n>" line, else root's range in /etc/subuid (what
# Proxmox uses, normally 100000). Fails for a privileged CT or no such CT.
_ct_root_uid() {
    local f="${PBO_PVE_LXC_DIR:-/etc/pve/lxc}/$1.conf" cfg u
    [[ "$1" =~ ^[0-9]+$ && -r "$f" ]] || return 1
    cfg="$(sed -n '/^\[/q;p' -- "$f" 2>/dev/null)"
    grep -qE '^unprivileged:[[:space:]]*1[[:space:]]*$' <<<"$cfg" || return 1
    u="$(awk '$1 == "lxc.idmap:" && $2 == "u" && $3 == "0" { print $4; exit }' <<<"$cfg")"
    [[ "$u" =~ ^[0-9]+$ ]] || u="$(awk -F: '$1 == "root" { print $2; exit }' "${PBO_SUBUID_FILE:-/etc/subuid}" 2>/dev/null)"
    [[ "$u" =~ ^[0-9]+$ ]] || u=100000
    printf '%s' "$u"
}

# _cache_dir_protect [vmid...]: CACHE_DIR holds plaintext vzdump archives while a
# backup runs (pbo's own dumps and the Proxmox spool), so other local users must
# not enter it. vzdump's tar of an unprivileged CT runs as the CT's mapped root
# and reads its tmpdir inside the dump directory: that uid gets an ACL entry
# (u:<uid>:--x) on CACHE_DIR first, and only then is CACHE_DIR closed to others
# (tested: closed without the entry, the backup fails with "Cannot
# open: Permission denied"). It covers every CT on this node plus any vmid given.
# Without setfacl it never closes a directory an unprivileged CT needs; doctor
# warns instead.
_cache_dir_protect() {
    _is_janitor && return 0
    local d="${CACHE_DIR%/}" v u m acl
    [[ -n "$d" && -d "$d" && ! -L "$d" ]] || return 0
    [[ "$(stat -c %u -- "$d" 2>/dev/null)" == "$(id -u)" ]] || return 0
    # every CT on this node, plus the ones named: closing the directory must never
    # lock out a CT whose own backup has not run yet
    local vids=("$@") lv
    while IFS= read -r lv; do [[ -n "$lv" ]] && vids+=("$lv"); done \
        < <(find "${PBO_PVE_LXC_DIR:-/etc/pve/lxc}/" -maxdepth 1 -name '[0-9]*.conf' -printf '%f\n' 2>/dev/null | sed 's/\.conf$//')
    local -A need=()
    for v in "${vids[@]+"${vids[@]}"}"; do u="$(_ct_root_uid "$v")" && need[$u]=1; done
    if (( ${#need[@]} )); then
        if ! command -v setfacl >/dev/null 2>&1 || ! command -v getfacl >/dev/null 2>&1; then
            log_warn "CACHE_DIR $d stays open to local users: setfacl/getfacl (package acl) are needed to let unprivileged CTs' vzdump through"
            return 0
        fi
        acl="$(getfacl -cpn -- "$d" 2>/dev/null)"
        for u in "${!need[@]}"; do
            grep -qE "^user:$u:..x" <<<"$acl" && continue
            setfacl -m "u:$u:x" -- "$d" 2>/dev/null || { log_warn "CACHE_DIR $d: could not add the ACL entry for uid $u (vzdump of unprivileged CTs), left open"; return 0; }
        done
    fi
    m="$(stat -c %a -- "$d" 2>/dev/null)" || return 0
    if (( (8#$m & 8#007) != 0 )); then
        chmod o-rwx -- "$d" 2>/dev/null && log_info "CACHE_DIR $d closed to other users (mode $(stat -c %a -- "$d"); unprivileged CTs pass through an ACL)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Logging. Format: "2026-01-15T05:00:00Z [INFO] message".
# In --json mode the human log goes to stderr so stdout stays pure JSON.
# ---------------------------------------------------------------------------
_log() {
    local level="$1"; shift
    local msg="$*"
    # credentials inside URLs never reach a log line, a job log or an alert
    [[ "$msg" == *"://"*"@"* || "$msg" == *"://"*"?"* || "$msg" == *"sftp:"*"@"* ]] && msg="$(_mask_url "$msg")"
    # PBO_ASCII_LOG=1 (set by the vzdump hook): the line lands in a Proxmox task
    # log, whose API hands bytes out as latin1, so "→" shows up as "â" in the GUI
    if [[ "${PBO_ASCII_LOG:-0}" == 1 ]]; then
        msg="${msg//→/->}"; msg="${msg//←/<-}"; msg="${msg//—/-}"; msg="${msg//…/...}"
    fi
    local line; line="$(date --iso-8601=seconds) [$level] $msg"
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
log_error() { PBO_ERROR_LOGGED=1; _log ERROR "$@"; notify_failure "$*" 2>/dev/null || true; }

# Audit log for destructive/outbound actions (who did what).
# Line: "2026-01-15T.. user=<sudo/uid> restore src=101 target=9010 …".
audit_log() {
    local who; if declare -F _audit_who >/dev/null; then who="$(_audit_who)"; else who="${SUDO_USER:-$(id -un 2>/dev/null || echo root)}"; fi
    local line; line="$(date --iso-8601=seconds) user=${who} $*"
    [[ -n "${AUDIT_FILE:-}" ]] && printf '%s\n' "$line" >> "$AUDIT_FILE" 2>/dev/null || true
    # same event in the JSON audit log (lib/metrics.sh), if loaded
    declare -F _audit_json >/dev/null && _audit_json "$(jq -cn --arg time "$(date --iso-8601=seconds)" --arg user "$who" \
        --arg cmd "${PBO_COMMAND:-}" --arg what "$*" '{time:$time, kind:"event", user:$user, command:$cmd, event:$what}' 2>/dev/null)"
    _log INFO "audit: $*"
}

# die <exit-code> <message...>
die() {
    local code="$1"; shift
    log_error "$*"
    declare -F json_error >/dev/null && json_error "$code" "$*"
    exit "$code"
}

# ---------------------------------------------------------------------------
# Notify stub. Replaced by lib/notify.sh (ntfy) in step 8. Here just a no-op
# that honors the NTFY_ON_SUCCESS contract so the call sites already line up.
# ---------------------------------------------------------------------------
notify_failure() { :; }   # sends ntfy on failure, implemented in step 8
notify_success() {        # silent unless NOTIFY_LEVEL=all (lib/notify.sh)
    [[ "${NOTIFY_LEVEL:-}" == all || "${NTFY_ON_SUCCESS:-false}" == "true" ]] || return 0
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

# _mask_url <value>: drop credentials from anything URL-like before it is shown
# or logged: userinfo (with or without a password), query strings, and the user
# in sftp:user@host.
_mask_url() {
    sed -E 's#(://)[^/@[:space:]]+@#\1***@#g; s#(://[^[:space:]?"]*)\?[^[:space:]"]*#\1?***#g; s#(^|[[:space:]"=])(sftp:)[^@/:[:space:]"]+@#\1\2***@#g' <<<"$1"
}

# json_result / json_emit / json_error: lib/json.sh

# Validate that an argument looks like a vmid (integer 100-999999999).
is_vmid() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 100 )); }
require_vmid() {
    is_vmid "${1:-}" || die "$EX_USAGE" "invalid vmid: '${1:-<missing>}'"
}
