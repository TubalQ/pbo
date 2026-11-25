# shellcheck shell=bash
# lib/notify.sh: notifications. Replaces the stubs in common.sh (defined later →
# wins). What is sent follows NOTIFY_LEVEL (fail | warn | all; the old
# NTFY_ON_SUCCESS=true still means all).
#
# Two backends:
#  - ntfy: NTFY_URL/NTFY_TOKEN/topic from config, falling back to NTFY_CREDS_FILE
#    (/etc/ntfy.creds: NTFY_URL, NTFY_TOKEN, NTFY_TOPIC_WARN). Token never echoed.
#  - Proxmox's notification system (PVE::Notify, PVE >= 8.1): events land in the
#    same targets and matchers as the cluster's other alerts, with the fields
#    type=pbo and hostname=<node> to match on. Templates: templates/pbo-*.hbs,
#    installed into /etc/pve/notification-templates/default/.
# NOTIFY_PVE=auto (default) uses Proxmox's system when no ntfy is configured, so an
# existing ntfy setup keeps working unchanged. true = both, false = ntfy only.
# PBO_NO_NOTIFY=1 silences everything (tests/CI).

PVE_TEMPLATE_DIR="${PBO_PVE_TEMPLATE_DIR:-/etc/pve/notification-templates/default}"

_ntfy_load() {
    local f="${NTFY_CREDS_FILE:-/etc/ntfy.creds}"
    [[ -f "$f" ]] || return 0
    [[ -z "${NTFY_URL:-}"   ]] && NTFY_URL="$(awk -F= '/^NTFY_URL=/{print $2; exit}'   "$f" 2>/dev/null | tr -d '"'\' )"
    [[ -z "${NTFY_TOKEN:-}" ]] && NTFY_TOKEN="$(awk -F= '/^NTFY_TOKEN=/{print $2; exit}' "$f" 2>/dev/null | tr -d '"'\' )"
    [[ -z "${NTFY_TOPIC:-}" ]] && NTFY_TOPIC="$(awk -F= '/^NTFY_TOPIC_WARN=/{print $2; exit}' "$f" 2>/dev/null | tr -d '"'\' )"
}
_ntfy_configured() { _ntfy_load; [[ -n "${NTFY_URL:-}" && -n "${NTFY_TOPIC:-}" ]]; }

# _ntfy_publish <priority> <title> <message>
_ntfy_publish() {
    _ntfy_configured || return 0
    local url="${NTFY_URL%/}/${NTFY_TOPIC}"
    local hdr=(-H "Title: $2" -H "Priority: $1" -H "Tags: floppy_disk")
    # the token goes to curl on stdin (-K -), never on its command line (ps)
    if [[ -n "${NTFY_TOKEN:-}" ]]; then
        printf 'header = "Authorization: Bearer %s"\n' "${NTFY_TOKEN//\"/}" \
            | curl -fsS -m 10 -K - "${hdr[@]}" -d "$3" "$url" >/dev/null 2>&1 || true
    else
        curl -fsS -m 10 "${hdr[@]}" -d "$3" "$url" >/dev/null 2>&1 || true
    fi
}

_pve_notify_available() {
    [[ "$(id -u)" == 0 ]] || return 1
    "${PBO_PERL_BIN:-perl}" -MPVE::Notify -e 1 >/dev/null 2>&1
}
_pve_templates_installed() { [[ -f "$PVE_TEMPLATE_DIR/pbo-subject.txt.hbs" && -f "$PVE_TEMPLATE_DIR/pbo-body.txt.hbs" ]]; }

# Which backends are on, given NOTIFY_PVE and what is configured/available.
_notify_use_pve() {
    case "${NOTIFY_PVE:-auto}" in
        false) return 1 ;;
        true)  _pve_notify_available ;;
        *)     ! _ntfy_configured && _pve_notify_available ;;
    esac
}

# _pve_publish <severity: info|notice|warning|error> <title> <message>
_pve_publish() {
    _pve_templates_installed || { _log WARN "notify: pbo templates missing in $PVE_TEMPLATE_DIR (run install.sh), Proxmox notification not sent"; return 0; }
    local node; node="$(_local_node 2>/dev/null || hostname -s)"
    # Arguments go in via @ARGV, never interpolated into the perl source.
    "${PBO_PERL_BIN:-perl}" -MPVE::Notify -e '
        my ($sev, $title, $msg, $node) = @ARGV;
        PVE::Notify::notify($sev, "pbo",
            { title => $title, message => $msg, node => $node, severity => $sev },
            { type => "pbo", hostname => $node });
    ' -- "$1" "$2" "$3" "$node" >/dev/null 2>&1 \
        || _log WARN "notify: Proxmox notification failed to queue"
    return 0
}

# _notify <ntfy-priority> <pve-severity> <title> <message>
_notify() {
    [[ "${PBO_NO_NOTIFY:-0}" == 1 ]] && return 0
    _ntfy_publish "$1" "$3" "$4"
    _notify_use_pve && _pve_publish "$2" "$3" "$4"
    return 0
}

# NOTIFY_LEVEL: fail = failures only (default), warn = + warnings,
# all = + successes. The older NTFY_ON_SUCCESS=true still means "all" when
# NOTIFY_LEVEL is not set. An unknown value falls back to "fail" (doctor warns).
_notify_level() {
    case "${NOTIFY_LEVEL:-}" in
        fail|warn|all) printf '%s' "$NOTIFY_LEVEL" ;;
        "") [[ "${NTFY_ON_SUCCESS:-false}" == "true" ]] && printf all || printf fail ;;
        *) printf fail ;;
    esac
}
notify_failure() { _notify high    error "pbo: FAILURE" "$1"; }
notify_warning() {
    [[ "$(_notify_level)" == warn || "$(_notify_level)" == all ]] || return 0
    _notify default warning "pbo: warning" "$1"
}
notify_success() {
    [[ "$(_notify_level)" == all ]] || return 0
    _notify default info "pbo: OK" "$1"
}

# notify-test: send one warning through every active backend, report which.
rdo_notify_test() {
    local used=()
    _ntfy_configured && used+=("ntfy")
    _notify_use_pve && used+=("proxmox")
    if (( ${#used[@]} == 0 )); then
        log_warn "notify-test: no backend active (no ntfy configured; Proxmox notifications ${NOTIFY_PVE:-auto}/$(_pve_notify_available && echo available || echo unavailable))"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "failed" "false" "backends" "" "level" "$(_notify_level)"
        return "$EX_UNAVAILABLE"
    fi
    PBO_NO_NOTIFY=0 _notify default warning "pbo: test" "Test notification from pbo on $(_local_node). If you see this, alerts reach you."
    log_info "notify-test: sent via ${used[*]} (NOTIFY_LEVEL=$(_notify_level): $(case "$(_notify_level)" in fail) echo "failures only";; warn) echo "failures and warnings";; all) echo "every run";; esac))"
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "ok" "true" "backends" "${used[*]}" "level" "$(_notify_level)"
    return "$EX_OK"
}
