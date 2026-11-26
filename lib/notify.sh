# shellcheck shell=bash
# lib/notify.sh: notifications. Replaces the stubs in common.sh (defined later →
# wins). What is sent follows NOTIFY_LEVEL (fail | warn | all; the old
# NTFY_ON_SUCCESS=true still means all).
#
# Two backends:
#  - ntfy: NTFY_URL/NTFY_TOKEN/NTFY_TOPIC from config, falling back to
#    NTFY_CREDS_FILE (see _ntfy_creds_read). Token never echoed.
#  - Proxmox's notification system (PVE::Notify, PVE >= 8.1): events land in the
#    same targets and matchers as the cluster's other alerts, with the fields
#    type=pbo and hostname=<node> to match on. Templates: templates/pbo-*.hbs,
#    installed into /etc/pve/notification-templates/default/.
# NOTIFY_PVE=auto (default) uses Proxmox's system when no ntfy is configured, so an
# existing ntfy setup keeps working unchanged. true = both, false = ntfy only.
# PBO_NO_NOTIFY=1 silences everything (tests/CI).

PVE_TEMPLATE_DIR="${PBO_PVE_TEMPLATE_DIR:-/etc/pve/notification-templates/default}"

# --- NTFY_CREDS_FILE: the ntfy server, token and topic outside the config -------
# KEY=VALUE lines: NTFY_URL, NTFY_TOKEN and the topic, under NTFY_TOPIC or the
# key NTFY_CREDS_TOPIC_KEY names, so that a file other tools already use for
# the same server (with a topic key of their own) can be shared as it is. Each
# of the three is taken from the file only when the config leaves it empty;
# other keys in the file are ignored. The file is read with the strict config
# reader (lib/config_parse.sh, origin envfile: any variable name, nothing is
# run), never sourced, and no message repeats a value from it. A line the
# reader refuses makes pbo leave the whole file unused when it could change
# what pbo reads: a line of one of the three keys, a line that is no
# assignment (source, a command), or a quote or backslash that runs on into
# the next lines. A refused line of another key is skipped with a warning:
# a file in systemd EnvironmentFile or docker env-file form may hold another
# tool's value with an unquoted space. Its mode is a rule of the permission
# table (lib/perms.sh).

# _ntfy_creds_read: read NTFY_CREDS_FILE → _NTFY_CV[url|token|topic] (what the
# file sets; for _ntfy_load only, never printed), NTFY_CREDS_PRESENT (1: the
# file exists), NTFY_CREDS_ERRORS ("file:line: message", never a value: pbo
# does not use the file), NTFY_CREDS_WARNINGS (the same form: pbo uses the file
# anyway), NTFY_CREDS_MISSING (the needed keys it does not set: NTFY_URL and
# the topic key). A missing file is no error: most installs keep ntfy in the
# config or use Proxmox notifications. Returns 1 on errors.
# The config's own NTFY_URL is _NTFY_CFG_URL once _ntfy_load has filled
# NTFY_URL from the file, NTFY_URL before that.
_ntfy_creds_read() {
    local f="${NTFY_CREDS_FILE:-}" tk="${NTFY_CREDS_TOPIC_KEY:-NTFY_TOPIC}" e m n
    local cu="${_NTFY_CFG_URL-${NTFY_URL:-}}" re_key='^[[:blank:]]*(export[[:blank:]]+)?([A-Za-z_][A-Za-z0-9_]*)='
    local re_multi=' \((lines [0-9]+-[0-9]+|from line [0-9]+ to the end of the file)\)$'
    local -a raw=()
    declare -gA _NTFY_CV=()
    declare -ga NTFY_CREDS_ERRORS=() NTFY_CREDS_WARNINGS=() NTFY_CREDS_MISSING=()
    NTFY_CREDS_PRESENT=0
    [[ -n "$f" && -e "$f" ]] || return 0
    NTFY_CREDS_PRESENT=1
    # the type check of config check and doctor, repeated: a bad name here
    # would otherwise read as "the file has no topic"
    [[ "$tk" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
        || { NTFY_CREDS_ERRORS+=("$f:0: NTFY_CREDS_TOPIC_KEY is not a variable name, so no key of the file can hold the topic"); return 1; }
    [[ -f "$f" ]] || { NTFY_CREDS_ERRORS+=("$f:0: not a regular file"); return 1; }
    [[ -r "$f" ]] || { NTFY_CREDS_ERRORS+=("$f:0: cannot read the file as uid $EUID"); return 1; }
    declare -F _cfg_parse_file >/dev/null || _cfg_parse_ensure
    # the reader's own results, scoped to this function (dynamic scope): the
    # config's CFG_* stay as load_config left them. No CFG_ENV: a reference may
    # only name a variable an earlier line of this file set.
    local -A CFG_VAL=() CFG_RAW=() CFG_SRC=() CFG_LINE=() CFG_EXPORT=() CFG_ENV=()
    local -a CFG_UNKNOWN=() CFG_ERRORS=() CFG_WARNINGS=() CFG_IGNORED=()
    local _CFG_CS=0
    _cfg_parse_file "$f" envfile || true
    # Sort the refusals (see the top of this section). A refused line of a key
    # pbo does not read changes nothing pbo takes from the file: the reader
    # records no value for it, and a later line that refers to that key is
    # refused on its own line. A refusal that spans lines (an open quote, a
    # trailing backslash, a function body) can hide the lines after it, and a
    # line that is no assignment may be a source or a command that sets the
    # keys elsewhere: both keep the file unused. The messages name the file,
    # line and key, never a value (an envfile is read without the schema, so
    # the reader never quotes one), which keeps the warning safe to print.
    (( ${#CFG_ERRORS[@]} == 0 )) || { mapfile -t raw < "$f"; } 2>/dev/null || raw=()
    for e in "${CFG_ERRORS[@]+"${CFG_ERRORS[@]}"}"; do
        m="${e#"$f:"}"; n="${m%%:*}"; m=''
        if [[ "$n" =~ ^[1-9][0-9]*$ ]] && ! [[ "$e" =~ $re_multi ]]; then
            m="${raw[n-1]-}"; (( n > 1 )) || m="${m#$'\xef\xbb\xbf'}"
            if [[ "$m" =~ $re_key ]]; then m="${BASH_REMATCH[2]}"; else m=''; fi
        fi
        if [[ -n "$m" && "$m" != NTFY_URL && "$m" != NTFY_TOKEN && "$m" != "$tk" ]]; then
            NTFY_CREDS_WARNINGS+=("$e (pbo does not read $m: the line is skipped)")
        else
            NTFY_CREDS_ERRORS+=("$e")
        fi
    done
    (( ${#NTFY_CREDS_ERRORS[@]} == 0 )) || return 1
    # a URL without a scheme://: a warning, as the same value in the config is
    # (lib/common.sh _config_check), and the file stays in use: curl assumes
    # http:// for it, which is how 0.5 sent with such a file. Only when the
    # file's URL is the one pbo uses: a URL the config sets wins, and a
    # shared file's own URL is then none of pbo's business. The message names
    # the key only (the URL can carry a password or the topic).
    if [[ -n "${CFG_VAL[NTFY_URL]:-}" && -z "$cu" ]] && ! m="$(_cs_validate NTFY_URL "${CFG_VAL[NTFY_URL]}")"; then
        NTFY_CREDS_WARNINGS+=("$f:${CFG_LINE[NTFY_URL]}: $m")
    fi
    [[ -n "${CFG_VAL[NTFY_URL]:-}" ]] || NTFY_CREDS_MISSING+=(NTFY_URL)
    [[ -n "${CFG_VAL[$tk]:-}" ]] || NTFY_CREDS_MISSING+=("$tk")
    _NTFY_CV[url]="${CFG_VAL[NTFY_URL]:-}" _NTFY_CV[token]="${CFG_VAL[NTFY_TOKEN]:-}" _NTFY_CV[topic]="${CFG_VAL[$tk]:-}"
    return 0
}

# _ntfy_load: fill what the config left empty from NTFY_CREDS_FILE, once per
# file and topic key (every alert asks _ntfy_configured).
_ntfy_load() {
    local id="${NTFY_CREDS_FILE:-}|${NTFY_CREDS_TOPIC_KEY:-}"
    [[ "${_NTFY_LOADED-}" == "$id" ]] && return 0
    _NTFY_LOADED="$id"
    # what the config set, before the file fills it in (_ntfy_creds_read
    # warns about the file's URL only when that is the one in use)
    _NTFY_CFG_URL="${NTFY_URL:-}"
    _ntfy_creds_read || { _NTFY_CV=(); return 0; }
    [[ -n "${NTFY_URL:-}"   ]] || NTFY_URL="${_NTFY_CV[url]-}"
    [[ -n "${NTFY_TOKEN:-}" ]] || NTFY_TOKEN="${_NTFY_CV[token]-}"
    [[ -n "${NTFY_TOPIC:-}" ]] || NTFY_TOPIC="${_NTFY_CV[topic]-}"
    _NTFY_CV=()
    return 0
}
_ntfy_configured() { _ntfy_load; [[ -n "${NTFY_URL:-}" && -n "${NTFY_TOPIC:-}" ]]; }

# _ntfy_doctor <ok> <bad> <warn> → NTD_LINES, NTD_WARNS: NTFY_CREDS_FILE as
# doctor sees it. Warnings only: a file pbo does not use (with the first
# reason), what the file has that pbo uses with a warning (a URL without a
# scheme, a refused line of a key pbo does not read), and a file that lacks a
# key the config does not set either. A
# missing file gives no line: ntfy may be set in the config, or not used.
_ntfy_doctor() {
    local warn="$3" more='' e
    NTD_LINES=() NTD_WARNS=0
    _ntfy_creds_read || true
    _NTFY_CV=()
    if (( ${#NTFY_CREDS_ERRORS[@]} )); then
        (( ${#NTFY_CREDS_ERRORS[@]} == 1 )) || more=" (and $(( ${#NTFY_CREDS_ERRORS[@]} - 1 )) more)"
        NTD_LINES+=("$warn  ntfy: NTFY_CREDS_FILE is not used: ${NTFY_CREDS_ERRORS[0]}$more (KEY=VALUE lines only, nothing is run)")
        NTD_WARNS=$((NTD_WARNS+1))
    elif (( NTFY_CREDS_PRESENT )); then
        local k miss=() hint=''
        for e in "${NTFY_CREDS_WARNINGS[@]+"${NTFY_CREDS_WARNINGS[@]}"}"; do
            NTD_LINES+=("$warn  ntfy: $e"); NTD_WARNS=$((NTD_WARNS+1))
        done
        for k in "${NTFY_CREDS_MISSING[@]+"${NTFY_CREDS_MISSING[@]}"}"; do
            # what the config sets itself needs no line in the file
            if [[ "$k" == NTFY_URL ]]; then [[ -n "${NTFY_URL:-}" ]] || miss+=("$k")
            else [[ -n "${NTFY_TOPIC:-}" ]] || miss+=("$k"); fi
        done
        if (( ${#miss[@]} )); then
            [[ " ${miss[*]} " != *" ${NTFY_CREDS_TOPIC_KEY:-NTFY_TOPIC} "* ]] \
                || hint="; a file whose topic key has another name needs NTFY_CREDS_TOPIC_KEY=<that key>"
            NTD_LINES+=("$warn  ntfy: $NTFY_CREDS_FILE sets no ${miss[*]}, and neither does the config: no ntfy alerts$hint")
            NTD_WARNS=$((NTD_WARNS+1))
        fi
    fi
    return 0
}

# _ntfy_creds_warn: once per process, in the log of the run whose alert ntfy
# drops, the reason NTFY_CREDS_FILE is not used (a file the strict reader
# refused), since nothing else in that run's log would say why no alert went
# out. Called when ntfy is not configured, and when it is but has no token
# (one kept in a refused file): the server's refusal of that post is not
# reported either. Silent when the file was not refused.
_ntfy_creds_warn() {
    [[ -z "${_NTFY_WARNED-}" ]] || return 0
    _NTFY_WARNED=1
    [[ -z "${NTFY_CREDS_ERRORS[0]+x}" ]] \
        || _log WARN "notify: NTFY_CREDS_FILE is not used: ${NTFY_CREDS_ERRORS[0]} (pbo doctor)"
    return 0
}

# _ntfy_publish <priority> <title> <message>
_ntfy_publish() {
    _ntfy_configured || { _ntfy_creds_warn; return 0; }
    # a token kept in a refused NTFY_CREDS_FILE is not used: say so in this
    # run's log, since the server's refusal below is not reported
    [[ -n "${NTFY_TOKEN:-}" ]] || _ntfy_creds_warn
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
    _pve_notify_module
}
# _pve_notify_module: Proxmox's notification module loads (a send needs root as well)
_pve_notify_module() { "${PBO_PERL_BIN:-perl}" -MPVE::Notify -e 1 >/dev/null 2>&1; }
_pve_templates_installed() { [[ -f "$PVE_TEMPLATE_DIR/pbo-subject.txt.hbs" && -f "$PVE_TEMPLATE_DIR/pbo-body.txt.hbs" ]]; }

# _pve_templates_src → the directory with the templates this pbo ships: the
# checkout's templates/, else <prefix>/share/pbo/templates next to
# <prefix>/lib/pbo (install.sh: /usr/local/share/pbo/templates, the .deb:
# /usr/share/pbo/templates). Empty when there is none.
_pve_templates_src() {
    local d
    for d in "${SELF_DIR:-}/templates" "${SELF_DIR%/lib/pbo}/share/pbo/templates"; do
        [[ "$d" != /templates && -f "$d/pbo-subject.txt.hbs" ]] && { printf '%s' "$d"; return 0; }
    done
    return 0
}

# _doctor_templates OK FAIL WARN → DTP_LINES, DTP_WARNS, DTP_STATE: the
# Proxmox notification templates pbo ships, in PVE_TEMPLATE_DIR. Only on a
# Proxmox node (pmxcfs, PBO_PVE_CFS_DIR, is there) whose alerts go through
# Proxmox notifications (_notify_pve_planned: not with NOTIFY_PVE=false, nor
# in auto mode with ntfy configured), never on a janitor (DTP_STATE=skip).
# A missing one is a WARN, and --fix (not --perms-only) installs it, as
# install.sh and the .deb do: a plain cp into pmxcfs, which fails without
# quorum (then a WARN). One that is there but differs from the one this pbo
# ships is only reported, never replaced: the directory is shared by the whole
# cluster, and during a rolling upgrade it may hold a newer pbo's templates
# that a --fix here would roll back (and that node's --fix put back again).
# install.sh and the package install their own. pbo writes nowhere else
# (never /usr/share/pve-manager/templates). DTP_STATE: ok, missing, stale or
# skip.
_doctor_templates() {
    local ok="$1" warn="$3" src f n miss=() stale=() fixed=() would=() failed=() fixing=0
    DTP_LINES=() DTP_WARNS=0 DTP_STATE=skip
    { declare -F _is_janitor >/dev/null && _is_janitor; } && return 0
    [[ -d "${PBO_PVE_CFS_DIR:-/etc/pve}" ]] && _notify_pve_planned || return 0
    src="$(_pve_templates_src)"
    if [[ -z "$src" ]]; then
        DTP_LINES+=("$warn  the notification templates this pbo ships are not found next to it (${SELF_DIR:-?}): reinstall pbo"); DTP_WARNS=1; DTP_STATE=missing
        return 0
    fi
    for f in "$src"/pbo-*.hbs; do
        [[ -f "$f" ]] || continue
        n="${f##*/}"
        if [[ ! -f "$PVE_TEMPLATE_DIR/$n" ]]; then miss+=("$n")
        elif ! cmp -s -- "$f" "$PVE_TEMPLATE_DIR/$n"; then stale+=("$n"); fi
    done
    if (( ${#miss[@]} )) && (( ${DOCTOR_FIX:-0} && ! ${DOCTOR_PERMS_ONLY:-0} )); then
        fixing=1
        for n in "${miss[@]}"; do
            if [[ "${DRY_RUN:-0}" == 1 ]]; then would+=("$n"); continue; fi
            if mkdir -p -- "$PVE_TEMPLATE_DIR" 2>/dev/null && cp -- "$src/$n" "$PVE_TEMPLATE_DIR/$n" 2>/dev/null; then
                fixed+=("$n"); audit_log "doctor fix: notification template $PVE_TEMPLATE_DIR/$n installed from $src" >/dev/null 2>&1 || true
            else failed+=("$n"); fi
        done
        (( ${#fixed[@]} )) && DTP_LINES+=("  ${C_G:-}FIXED${C_0:-} notification templates installed in $PVE_TEMPLATE_DIR: ${fixed[*]}")
        (( ${#would[@]} )) && DTP_LINES+=("  ${C_Y:-}WOULD FIX${C_0:-} notification templates to install in $PVE_TEMPLATE_DIR: ${would[*]}")
        if (( ${#failed[@]} )); then
            DTP_LINES+=("$warn  notification templates could not be written to $PVE_TEMPLATE_DIR (no quorum?): ${failed[*]}; Proxmox notifications from pbo need them"); DTP_WARNS=1; DTP_STATE=missing
        else
            DTP_STATE=ok
        fi
        (( ${#would[@]} == 0 )) || DTP_STATE=missing
    fi
    if (( ! fixing )); then
        if (( ${#miss[@]} )); then
            DTP_LINES+=("$warn  Proxmox notification templates missing in $PVE_TEMPLATE_DIR: ${miss[*]} (pbo doctor --fix installs them)"); DTP_WARNS=1; DTP_STATE=missing
        elif (( ! ${#stale[@]} )); then
            DTP_LINES+=("$ok  Proxmox notification templates current in $PVE_TEMPLATE_DIR"); DTP_STATE=ok
        else
            DTP_STATE=stale
        fi
    fi
    # no WARN and no fix: another node's pbo (older or newer) may have installed them
    (( ${#stale[@]} == 0 )) || DTP_LINES+=("$ok  Proxmox notification templates in $PVE_TEMPLATE_DIR differ from the ones this pbo ships: ${stale[*]} (left as they are: the directory is cluster-wide, another node's pbo may have installed them; install.sh or the package installs this one's)")
    return 0
}

# _notify_pve_planned: pbo's alerts go through Proxmox notifications, as
# _notify_use_pve decides for the timers (which run as root), whoever runs
# this: doctor's template check asks it.
_notify_pve_planned() {
    case "${NOTIFY_PVE:-auto}" in
        false) return 1 ;;
        true)  _pve_notify_module ;;
        *)     ! _ntfy_configured && _pve_notify_module ;;
    esac
}

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
    _pve_templates_installed || { _log WARN "notify: pbo templates missing in $PVE_TEMPLATE_DIR (pbo doctor --fix installs them), Proxmox notification not sent"; return 0; }
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
        _ntfy_creds_warn
        log_warn "notify-test: no backend active (no ntfy configured; Proxmox notifications ${NOTIFY_PVE:-auto}/$(_pve_notify_available && echo available || echo unavailable))"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "failed" "false" "backends" "" "level" "$(_notify_level)"
        return "$EX_UNAVAILABLE"
    fi
    PBO_NO_NOTIFY=0 _notify default warning "pbo: test" "Test notification from pbo on $(_local_node). If you see this, alerts reach you."
    log_info "notify-test: sent via ${used[*]} (NOTIFY_LEVEL=$(_notify_level): $(case "$(_notify_level)" in fail) echo "failures only";; warn) echo "failures and warnings";; all) echo "every run";; esac))"
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "ok" "true" "backends" "${used[*]}" "level" "$(_notify_level)"
    return "$EX_OK"
}
