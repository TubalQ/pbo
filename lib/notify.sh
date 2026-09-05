# shellcheck shell=bash
# lib/notify.sh: ntfy notifications. Replaces the stubs in common.sh (defined
# later → wins). Alerts ON FAILURE; success is silent unless NTFY_ON_SUCCESS=true.
#
# Reads NTFY_URL/NTFY_TOKEN/topic from config, falls back to NTFY_CREDS_FILE
# (/etc/ntfy.creds: NTFY_URL, NTFY_TOKEN, NTFY_TOPIC_WARN). The token is never echoed.

_ntfy_load() {
    local f="${NTFY_CREDS_FILE:-/etc/ntfy.creds}"
    [[ -f "$f" ]] || return 0
    [[ -z "${NTFY_URL:-}"   ]] && NTFY_URL="$(awk -F= '/^NTFY_URL=/{print $2; exit}'   "$f" 2>/dev/null | tr -d '"'\' )"
    [[ -z "${NTFY_TOKEN:-}" ]] && NTFY_TOKEN="$(awk -F= '/^NTFY_TOKEN=/{print $2; exit}' "$f" 2>/dev/null | tr -d '"'\' )"
    [[ -z "${NTFY_TOPIC:-}" ]] && NTFY_TOPIC="$(awk -F= '/^NTFY_TOPIC_WARN=/{print $2; exit}' "$f" 2>/dev/null | tr -d '"'\' )"
}

# _ntfy_publish <priority> <title> <message>
_ntfy_publish() {
    # Kill-switch, set PBO_NO_NOTIFY=1 to silence all notifications (tests/CI/dry
    # sessions), so a test suite or trial run never reaches a real ntfy server.
    [[ "${PBO_NO_NOTIFY:-0}" == 1 ]] && return 0
    _ntfy_load
    [[ -n "${NTFY_URL:-}" && -n "${NTFY_TOPIC:-}" ]] || return 0
    local url="${NTFY_URL%/}/${NTFY_TOPIC}"
    local hdr=(-H "Title: $2" -H "Priority: $1" -H "Tags: floppy_disk")
    [[ -n "${NTFY_TOKEN:-}" ]] && hdr+=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    curl -fsS -m 10 "${hdr[@]}" -d "$3" "$url" >/dev/null 2>&1 || true
}

notify_failure() { _ntfy_publish high    "pbo: FAILURE" "$1"; }
notify_success() {
    [[ "${NTFY_ON_SUCCESS:-false}" == "true" ]] || return 0
    _ntfy_publish default "pbo: OK" "$1"
}
