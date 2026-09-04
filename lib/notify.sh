# shellcheck shell=bash
# lib/notify.sh — ntfy-notiser. Ersätter stubbarna i common.sh (definieras efter
# → vinner). Larmar VID FEL; framgång är tyst om inte NTFY_ON_SUCCESS=true.
#
# Läser NTFY_URL/NTFY_TOKEN/topic från config, faller tillbaka på NTFY_CREDS_FILE
# (/etc/ntfy.creds: NTFY_URL, NTFY_TOKEN, NTFY_TOPIC_WARN). Token ekas aldrig.

_ntfy_load() {
    local f="${NTFY_CREDS_FILE:-/etc/ntfy.creds}"
    [[ -f "$f" ]] || return 0
    [[ -z "${NTFY_URL:-}"   ]] && NTFY_URL="$(awk -F= '/^NTFY_URL=/{print $2; exit}'   "$f" 2>/dev/null | tr -d '"'\' )"
    [[ -z "${NTFY_TOKEN:-}" ]] && NTFY_TOKEN="$(awk -F= '/^NTFY_TOKEN=/{print $2; exit}' "$f" 2>/dev/null | tr -d '"'\' )"
    [[ -z "${NTFY_TOPIC:-}" ]] && NTFY_TOPIC="$(awk -F= '/^NTFY_TOPIC_WARN=/{print $2; exit}' "$f" 2>/dev/null | tr -d '"'\' )"
}

# _ntfy_publish <priority> <title> <meddelande>
_ntfy_publish() {
    _ntfy_load
    [[ -n "${NTFY_URL:-}" && -n "${NTFY_TOPIC:-}" ]] || return 0
    local url="${NTFY_URL%/}/${NTFY_TOPIC}"
    local hdr=(-H "Title: $2" -H "Priority: $1" -H "Tags: floppy_disk")
    [[ -n "${NTFY_TOKEN:-}" ]] && hdr+=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    curl -fsS -m 10 "${hdr[@]}" -d "$3" "$url" >/dev/null 2>&1 || true
}

notify_failure() { _ntfy_publish high    "lxc-offsite: FEL" "$1"; }
notify_success() {
    [[ "${NTFY_ON_SUCCESS:-false}" == "true" ]] || return 0
    _ntfy_publish default "lxc-offsite: OK" "$1"
}
