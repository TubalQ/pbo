# shellcheck shell=bash
# lib/common.sh — delade hjälpfunktioner: config, logging, JSON, notify-stub.
# Källas av huvudscriptet. Ska aldrig köras fristående.
#
# Konventioner:
#   - Kommentarer på svenska, kod och variabelnamn på engelska.
#   - Alla värden som kan misslyckas returnerar meningsfull exit-kod (sysexits).
#   - Inga hemligheter i loggar eller felmeddelanden.

# ---------------------------------------------------------------------------
# Exit-koder (delmängd av sysexits.h) — enhetliga i hela verktyget.
# ---------------------------------------------------------------------------
readonly EX_OK=0
readonly EX_USAGE=64        # felaktig argumentanvändning
readonly EX_DATAERR=65      # felaktig indata (korrupt arkiv, config)
readonly EX_UNAVAILABLE=69  # en tjänst/resurs saknas (rclone-remote nere)
readonly EX_SOFTWARE=70     # internt fel
readonly EX_TEMPFAIL=75     # tillfälligt fel — lås upptaget, kön full
readonly EX_CANTCREAT=73    # kan inte skapa/öppna fil (låsfil, holder)
readonly EX_CONFIG=78       # konfigurationsfel

# ---------------------------------------------------------------------------
# Standardvärden. Overridas av config-filen (KEY=VALUE) som källas efteråt.
# ---------------------------------------------------------------------------
set_defaults() {
    : "${CACHE_DIR:=/var/cache/lxc-offsite}"
    : "${LOG_DIR:=/var/log/lxc-offsite}"
    : "${STATE_DIR:=/var/lib/lxc-offsite}"
    : "${LOCK_DIR:=/var/lock}"
    : "${RCLONE_REMOTE:=hetzner-crypt}"
    : "${REMOTE_PATH:=lxc}"
    : "${VZDUMP_MODE:=snapshot}"
    : "${VZDUMP_COMPRESS:=zstd}"
    : "${VZDUMP_ZSTD_THREADS:=4}"
    : "${RCLONE_TRANSFERS:=4}"
    : "${RCLONE_CHECKERS:=4}"
    : "${RCLONE_BWLIMIT:=}"
    : "${BACKUP_ORDER:=}"
    : "${GLOBAL_LOCK_TIMEOUT:=7200}"
    : "${KEEP_LOCAL:=2}"
    : "${KEEP_OFFSITE_DAILY:=7}"
    : "${KEEP_OFFSITE_WEEKLY:=4}"
    : "${KEEP_OFFSITE_MONTHLY:=6}"
    : "${NTFY_URL:=}"                  # ntfy-server (bas-URL); tom = inga notiser
    : "${NTFY_TOKEN:=}"                # annars läses från NTFY_CREDS_FILE
    : "${NTFY_TOPIC:=}"                # annars NTFY_TOPIC_WARN från creds-filen
    : "${NTFY_CREDS_FILE:=/etc/ntfy.creds}"
    : "${NTFY_ON_SUCCESS:=false}"
    : "${OFFSITE_ENABLED:=true}"       # false = dumpa+verifiera lokalt, hoppa upload
    : "${RCLONE_CONFIG_FILE:=}"        # egen rclone.conf (annars rclones default)
    : "${TR_WAIT_TRIES:=30}"           # test-restore: antal försök att nå CT
    : "${TR_WAIT_SLEEP:=2}"            # test-restore: sekunder mellan försök
    : "${MAX_AGE_WARN:=172800}"   # 48h — dashboard varnar om senaste push är äldre

    # Härledda sökvägar.
    LOG_FILE="${LOG_DIR}/lxc-offsite.log"
    AUDIT_FILE="${LOG_DIR}/audit.log"
    GLOBAL_LOCK_FILE="${LOCK_DIR}/lxc-offsite.global"
    GLOBAL_HOLDER_FILE="${STATE_DIR}/global.holder"
    JOBS_DIR="${STATE_DIR}/jobs"
}

# ---------------------------------------------------------------------------
# Config-laddning. Filen ska vara root-ägd och 0600; vi vägrar källa den om
# den är grupp-/världsskrivbar (den kan innehålla sökvägar men aldrig secrets).
# ---------------------------------------------------------------------------
load_config() {
    local cfg="${LXCO_CONFIG:-/etc/lxc-offsite/config}"
    if [[ -f "$cfg" ]]; then
        # Vägra en config som är grupp-/världsSKRIVBAR — den styr vad root kör.
        # (Läsbar för andra är ok; filen innehåller inga secrets.)
        local perms; perms="$(stat -c '%a' "$cfg")"
        local grp="${perms: -2:1}" oth="${perms: -1:1}"
        if (( (grp & 2) || (oth & 2) )); then
            printf 'lxc-offsite: VÄGRAR källa grupp-/världsskrivbar config (%s): %s\n' \
                "$perms" "$cfg" >&2
            exit "$EX_CONFIG"
        fi
        # shellcheck disable=SC1090
        source "$cfg"
        LXCO_CONFIG_LOADED="$cfg"
    else
        LXCO_CONFIG_LOADED=""
    fi
    set_defaults
    # Peka rclone på vår egen config om angiven (rclone läser RCLONE_CONFIG-env).
    [[ -n "${RCLONE_CONFIG_FILE:-}" ]] && export RCLONE_CONFIG="$RCLONE_CONFIG_FILE"
    ensure_dirs
}

# Skapa de kataloger vi äger. Loggkatalogen faller tillbaka till stderr-only
# om den inte går att skapa (t.ex. isolerad dev utan root-install).
ensure_dirs() {
    mkdir -p "$STATE_DIR" "$JOBS_DIR" "$LOCK_DIR" "$CACHE_DIR" 2>/dev/null || true
    if ! mkdir -p "$LOG_DIR" 2>/dev/null || [[ ! -w "$LOG_DIR" ]]; then
        LOG_FILE=""   # signal: logga bara till stderr/stdout
    fi
}

# ---------------------------------------------------------------------------
# Logging. Format: "2026-09-04T11:00:00+02:00 [INFO] meddelande".
# I --json-läge går människologgen till stderr så stdout förblir ren JSON.
# ---------------------------------------------------------------------------
_log() {
    local level="$1"; shift
    local line; line="$(date --iso-8601=seconds) [$level] $*"
    # Fil: alltid om vi har en skrivbar loggfil.
    [[ -n "${LOG_FILE:-}" ]] && printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
    # Terminal: stderr i json-läge, annars stderr för WARN/ERROR och stdout för INFO.
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
# Fel loggas OCH triggar notis (stub i steg 1, riktig i steg 8/notify.sh).
log_error() { _log ERROR "$@"; notify_failure "$*" 2>/dev/null || true; }

# die <exit-kod> <meddelande...>
die() {
    local code="$1"; shift
    log_error "$*"
    exit "$code"
}

# ---------------------------------------------------------------------------
# Notify-stub. Ersätts av lib/notify.sh (ntfy) i steg 8. Här bara en no-op
# som respekterar NTFY_ON_SUCCESS-kontraktet så anropsställena redan stämmer.
# ---------------------------------------------------------------------------
notify_failure() { :; }   # skickar ntfy vid fel — implementeras i steg 8
notify_success() {        # tyst om inte NTFY_ON_SUCCESS=true
    [[ "${NTFY_ON_SUCCESS:-false}" == "true" ]] || return 0
    :
}

# ---------------------------------------------------------------------------
# JSON-utmatning UTAN jq-beroende (jq krävs bara för att PARSA rclone lsjson
# senare, aldrig för att skapa vår egen output). Manuell strängescaping.
# ---------------------------------------------------------------------------
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"   # backslash först
    s="${s//\"/\\\"}"   # citattecken
    s="${s//$'\n'/\\n}" # radbrytning
    s="${s//$'\t'/\\t}" # tab
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# json_result <status> <ok:true|false> [k v k v ...]
# Skriver ett platt JSON-objekt till stdout. Värden behandlas som strängar.
json_result() {
    local status="$1" ok="$2"; shift 2
    local out; out="$(printf '{"command":"%s","status":"%s","ok":%s' \
        "$(json_escape "${LXCO_COMMAND:-}")" "$(json_escape "$status")" "$ok")"
    out+="$(printf ',"dry_run":%s' "$( [[ "${DRY_RUN:-0}" == 1 ]] && echo true || echo false )")"
    while [[ $# -ge 2 ]]; do
        out+="$(printf ',"%s":"%s"' "$(json_escape "$1")" "$(json_escape "$2")")"
        shift 2
    done
    out+='}'
    printf '%s\n' "$out"
}

# Enhetlig "ännu ej implementerat"-svar (steg 1: alla operationer).
not_implemented() {
    local cmd="${LXCO_COMMAND:-?}"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "not_implemented" "false"
    else
        log_warn "'$cmd' är ännu inte implementerat (steg 1: endast skelett)."
    fi
    return "$EX_OK"
}

# Validera att ett argument ser ut som ett vmid (heltal 100–999999999).
is_vmid() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 100 )); }
require_vmid() {
    is_vmid "${1:-}" || die "$EX_USAGE" "ogiltigt vmid: '${1:-<saknas>}'"
}
