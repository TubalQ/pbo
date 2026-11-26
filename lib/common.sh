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
# Default values: the schema's (lib/config_schema.sh), for every key the config
# and the environment left unset or empty; then the paths pbo derives itself.
# ---------------------------------------------------------------------------
# set_defaults: every schema key that is unset or empty gets its default, in
# table order (a derived default such as ${CACHE_DIR}/repo sees the keys before
# it; @fn defaults are computed). The same rule as the `: "${...:=default}"`
# lines of the 0.5 set_defaults (tests/config.sh compares with a frozen copy).
# It runs on every pbo start: only the core of the schema is loaded
# (_cs_core: the keys and their raw defaults), a ${REF} is expanded here from
# the value just assigned, and nothing forks.
set_defaults() {
    _cs_ensure core
    local _sd_i _sd_k _sd_d _sd_out _sd_ref
    for _sd_i in "${!CS_ORDER[@]}"; do
        _sd_k="${CS_ORDER[_sd_i]}"
        [[ -z "${!_sd_k-}" ]] || continue
        _sd_d="${_CS_DEFV[_sd_i]}"
        if [[ "$_sd_d" == @fn ]]; then "_cfgdef_$_sd_k"; _sd_d="$_CS_R"
        elif [[ "$_sd_d" == *'${'*'}'* ]]; then
            # ${REF}: an earlier key, assigned above (as _cs_default_r expands it)
            _sd_out=''
            while [[ "$_sd_d" == *'${'*'}'* ]]; do
                _sd_out+="${_sd_d%%\$\{*}"; _sd_d="${_sd_d#*\$\{}"
                _sd_ref="${_sd_d%%\}*}"; _sd_d="${_sd_d#*\}}"
                [[ -z "${CS_FLAGS[$_sd_ref]+x}" ]] || _sd_out+="${!_sd_ref-}"
            done
            _sd_d="$_sd_out$_sd_d"
        fi
        printf -v "$_sd_k" '%s' "$_sd_d"
    done
    # Derived paths: not config keys, always below the directories they follow.
    LOG_FILE="${LOG_DIR}/pbo.log"
    AUDIT_FILE="${LOG_DIR}/audit.log"
    GLOBAL_LOCK_FILE="${LOCK_DIR}/pbo.global"
    GLOBAL_HOLDER_FILE="${STATE_DIR}/global.holder"
    SCHED_LOCK_FILE="${LOCK_DIR}/pbo.schedule"
    SCHED_HOLDER_FILE="${STATE_DIR}/schedule.holder"
    JOBS_DIR="${STATE_DIR}/jobs"
}

# ---------------------------------------------------------------------------
# Config loading (0.6 M3, ADR 0009 "Loading"). The files are READ with the
# strict reader (lib/config_parse.sh), never run as code, and only schema keys
# become shell variables. The owner and mode rules stay: exec keys still name
# programs root runs. Keep the file 0600: it can hold an ntfy topic and the
# SFTP command.
# ---------------------------------------------------------------------------
# _config_file_check <file>: 0 when pbo may read it, 1 when it does not exist, 2
# when pbo must refuse it (_CFC_MSG says why): group- or world-WRITABLE (it
# decides what root runs; readable by others is no reason to refuse), or owned
# by anyone but root or the user pbo runs as (the janitor user on a janitor;
# /etc/pve files belong to root via pmxcfs).
_config_file_check() {
    local cfg="$1" st perms owner grp oth
    _CFC_MSG='' _CFC_ID=''
    [[ -f "$cfg" ]] || return 1
    # one stat for all three: this runs on every pbo start (the file's device
    # and inode, _CFC_ID, tell a process later whether the writer replaced it)
    st="$(stat -c '%a %u %d:%i' -- "$cfg" 2>/dev/null)" || { _CFC_MSG="cannot stat the config: $cfg"; return 2; }
    perms="${st%% *}"; owner="${st#* }"; _CFC_ID="${owner#* }"; owner="${owner%% *}"
    grp="${perms: -2:1}" oth="${perms: -1:1}"
    if (( (grp & 2) || (oth & 2) )); then
        _CFC_MSG="REFUSING to read a group-/world-writable config ($perms): $cfg"; return 2
    fi
    # EUID: what `id -u` prints, without the fork
    if [[ "$owner" != 0 && "$owner" != "$EUID" ]]; then
        _CFC_MSG="REFUSING to read a config owned by uid $owner: $cfg"; return 2
    fi
    return 0
}

# _cfg_parse_ensure: the strict reader (lib/config_parse.sh) and the schema
# loaded; ./pbo sources both, a caller that sourced only this file gets them here.
_cfg_parse_ensure() {
    _cs_ensure core
    if ! declare -F _cfg_parse_file >/dev/null; then
        local d="${SELF_DIR:-}"; [[ -n "$d" ]] && d+=/lib || d="$(dirname -- "${BASH_SOURCE[0]}")"
        # shellcheck source=lib/config_parse.sh
        source "$d/config_parse.sh"
    fi
}

# _cfg_apply: what the reader accepted becomes shell variables. Schema keys
# only: an unknown key is never assigned, so a PATH, IFS, BASH_ENV or one of
# pbo's own (readonly) names in the file changes nothing. printf -v, as an
# assignment in a sourced file did: a key the environment exported stays
# exported with the file's value. The proxy variables the config exports
# (CFG_EXPORT) are exported to the programs pbo runs.
_cfg_apply() {
    local _ca_k
    for _ca_k in "${!CFG_VAL[@]}"; do
        [[ -n "${CS_FLAGS[$_ca_k]+x}" ]] || continue
        printf -v "$_ca_k" '%s' "${CFG_VAL[$_ca_k]}"
    done
    for _ca_k in "${!CFG_EXPORT[@]}"; do export "$_ca_k=${CFG_EXPORT[$_ca_k]}"; done
}

# _cfg_key_source KEY → config | shared | env | default: where KEY's value
# comes from, as `pbo config list` names it (the reader's CFG_SRC, the
# environment snapshot CFG_ENV; a caller without load_config: default).
_cfg_key_source() {
    local s=''
    declare -p CFG_SRC >/dev/null 2>&1 && s="${CFG_SRC[$1]-}"
    if [[ -n "$s" ]]; then if [[ "${s%%:*}" == shared ]]; then printf shared; else printf config; fi
    elif declare -p CFG_ENV >/dev/null 2>&1 && [[ -n "${CFG_ENV[$1]:-}" ]]; then printf env
    else printf default; fi
}

# _config_refuse: the config has lines the reader refuses. pbo stops (78)
# rather than run on the rest: a lost line would silently fall back to a
# default (another repo, another retention). The first three errors, the way
# to see them all, and for a file bash accepts the hint that 0.6 no longer
# runs it as code. stderr only: the logs are not set up yet.
_config_refuse() {
    local e n=0 f
    printf 'pbo: the config has %d line(s) pbo cannot read:\n' "${#CFG_ERRORS[@]}" >&2
    for e in "${CFG_ERRORS[@]}"; do
        (( n++ < 3 )) || break
        printf '  %s\n' "$(_mask_url "$e")" >&2
    done
    printf "pbo: run 'pbo config check' for all of them\n" >&2
    for f in "${PBO_CONFIG_FILES[@]}"; do
        [[ " ${CFG_ERRORS[*]}" == *" $f:"* ]] || continue
        "${BASH:-bash}" -n -- "$f" 2>/dev/null || continue
        printf 'pbo: %s is valid bash, but pbo 0.6 no longer runs the config as code; see the 0.6.0 migration notes in CHANGELOG.md\n' "$f" >&2
    done
    exit "$EX_CONFIG"
}

# _cfg_test_log: test hook (tests/all.sh sets PBO_TEST_CONFIG_LOG). Every file a
# test run loads is logged with the reader's verdict and, for a file it accepts,
# the keys bash reads differently (_cfg_compare_bash), so the whole suite proves
# the reader agrees with bash on every config the tests write. A file the
# reader refuses is not compared: it may hold code a test proves pbo never runs.
# Values are not logged.
_cfg_test_log() {
    local f e k
    declare -ga CFG_DIFF=()
    (( ${#CFG_ERRORS[@]} )) || _cfg_compare_bash
    {
        for f in "${PBO_CONFIG_FILES[@]}"; do printf 'FILE\t%s\n' "$f"; done
        for e in "${CFG_ERRORS[@]}"; do printf 'ERROR\t%s\n' "$e"; done
        for k in "${CFG_DIFF[@]}"; do printf 'DIFF\t%s\t%s\n' "${CFG_SRC[$k]#*:}" "$k"; done
    } >> "$PBO_TEST_CONFIG_LOG" 2>/dev/null || true
}

# _cfg_test_log_files: test hook, after set_defaults: where this load resolved
# the files that hold secrets (their paths, never their content), so tests/all.sh
# can prove that no suite reads or fixes the machine's own files.
_cfg_test_log_files() {
    local k p
    for k in RESTIC_ENV_FILE RESTIC_PASSWORD_FILE RESTIC_REST_PASSWORD_FILE NTFY_CREDS_FILE; do
        p="${!k:-}"; [[ -n "$p" ]] || continue
        [[ "$p" == /* ]] || p="${PWD%/}/$p"
        printf 'SECRETFILE\t%s\t%s\t%s\n' "$k" "$p" "${PBO_CONFIG_LOADED:-(no config file)}"
    done >> "$PBO_TEST_CONFIG_LOG" 2>/dev/null || true
}

# load_config: the config files, merged as 0.5 sourced them: with PBO_CONFIG
# unset the cluster-shared /etc/pve/pbo/config (a non-secret base replicated by
# pmxcfs, edited once for the whole cluster), then the local /etc/pbo/config,
# which wins; with PBO_CONFIG set that file alone. A file value beats the
# environment, which beats the default; an empty value means the default.
# Sets:
#   PBO_CONFIG_LOCAL   the local file (/etc/pbo/config or PBO_CONFIG), whether
#                      it exists or not: the only file pbo ever writes
#   PBO_CONFIG_FILES   the files read, in order
#   PBO_CONFIG_LOADED  the last file read (the shared one when no local file
#                      exists). Kept for 0.5 callers that only READ it; a writer
#                      must use PBO_CONFIG_LOCAL, never this
#   PBO_CONFIG_SHARED_LOADED  the shared file, when it was read
#   PBO_CONFIG_EXPLICIT       PBO_CONFIG as given (jobs pass it on)
# plus the reader's results (CFG_VAL, CFG_SRC, CFG_ENV, ...) for config and
# doctor. PBO_CFG_LENIENT=1 (main(), `pbo config check` and `catalog _umount`
# only): lines the reader refuses are left out instead of stopping pbo, so
# check can report them and the mount cleanup still runs. `help` and `config
# template` never call this (main(), _pbo_stateless): they read no config.
load_config() {
    PBO_CONFIG_EXPLICIT="${PBO_CONFIG:-}"
    # when this process read its config (microseconds, no fork): a process
    # that waits for a lock compares the files with it (lib/lock.sh
    # _lock_reexec_if_changed); before the files are read, so a change while
    # they are read counts too
    PBO_START_US="${EPOCHREALTIME//[!0-9]/}"
    # An explicit PBO_CONFIG that isn't there is a mistake, not "use defaults":
    # defaults point at a different repo (a leaked PBO_CONFIG could make a
    # janitor prune the empty default cache repo).
    if [[ -n "${PBO_CONFIG:-}" && ! -f "$PBO_CONFIG" ]]; then
        printf 'pbo: PBO_CONFIG=%s does not exist\n' "$PBO_CONFIG" >&2
        exit "$EX_CONFIG"
    fi
    _cfg_parse_ensure
    # the schema keys the environment holds, taken before any is assigned: what
    # a ${KEY} no earlier line set refers to, and config list's source=env
    _cfg_env_snapshot
    _cfg_reset
    _cfg_config_files
    PBO_CONFIG_LOCAL='' PBO_CONFIG_LOADED='' PBO_CONFIG_SHARED_LOADED='' PBO_START_ID=''
    local _lc_i _lc_f _lc_o _lc_rc
    for _lc_i in "${!_CFG_FPATH[@]}"; do
        _lc_f="${_CFG_FPATH[_lc_i]}" _lc_o="${_CFG_FORIGIN[_lc_i]}"
        [[ "$_lc_o" == shared ]] || PBO_CONFIG_LOCAL="$_lc_f"
        _lc_rc=0; _config_file_check "$_lc_f" || _lc_rc=$?
        (( _lc_rc != 1 )) || continue
        if (( _lc_rc == 2 )); then printf 'pbo: %s\n' "$_CFC_MSG" >&2; exit "$EX_CONFIG"; fi
        # the local file's identity, taken by the same stat (lib/lock.sh)
        [[ "$_lc_o" == shared ]] || PBO_START_ID="$_CFC_ID"
        # pmxcfs gives the cluster-shared file root:www-data 0640: a non-root
        # caller outside that group runs on the rest, as with a local file it
        # cannot reach (0.5's source failed the same way and went on). Root reads
        # everything, so a node's backups never skip it.
        if [[ "$_lc_o" == shared && "$EUID" != 0 && ! -r "$_lc_f" ]]; then
            printf 'pbo: note: %s is not readable by uid %s (pmxcfs: root:www-data 0640); skipped\n' "$_lc_f" "$EUID" >&2
            continue
        fi
        PBO_CONFIG_FILES+=("$_lc_f")
        _cfg_parse_file "$_lc_f" "$_lc_o" || true
        PBO_CONFIG_LOADED="$_lc_f"
        [[ "$_lc_o" != shared ]] || PBO_CONFIG_SHARED_LOADED="$_lc_f"
    done
    [[ -z "${PBO_TEST_CONFIG_LOG:-}" ]] || _cfg_test_log
    (( ${#CFG_ERRORS[@]} == 0 )) || [[ "${PBO_CFG_LENIENT:-0}" == 1 ]] || _config_refuse
    _cfg_apply
    set_defaults
    [[ -z "${PBO_TEST_CONFIG_LOG:-}" ]] || _cfg_test_log_files
    # a start that must write nothing (main(): `pbo --dry-run init`) makes no directory
    [[ "${PBO_READONLY_START:-0}" == 1 ]] || ensure_dirs
    # RESTIC_ENV_FILE (lib/restic.sh): checked once here, its values are read
    # only in the subshell of each restic call
    if declare -F _restic_env_check >/dev/null; then _restic_env_check; fi
}

# Config schema version. Bump when a key is renamed or changes meaning, and mark
# the old key deprecated=<NEW> in lib/config_schema.sh. A config may declare
# PBO_CONFIG_VERSION.
readonly PBO_CONFIG_SCHEMA=1

# _cfg_int_r KEY: KEY's value into _CI_R when it is a whole number, else the
# schema default. For the thresholds in arithmetic: a typo in an advanced key
# must not break a backup with a bash arithmetic error (doctor names the bad
# value, _config_check). A global result: no fork.
_cfg_int_r() {
    _CI_R="${!1-}"
    if [[ "$_CI_R" =~ ^[0-9]{1,15}$ ]]; then _CI_R=$(( 10#$_CI_R )); return 0; fi
    _cs_ensure; _cs_default_r "$1"; _CI_R="$_CS_R"
}

# _cs_ensure [core]: the schema (lib/config_schema.sh) loaded, the whole table or
# (core) just what load_config needs (_cs_core). ./pbo sources the file; a
# caller that sourced only this file (tests, helpers) gets it here.
_cs_ensure() {
    if ! declare -F _cs_load >/dev/null; then
        local d="${SELF_DIR:-}"; [[ -n "$d" ]] && d+=/lib || d="$(dirname -- "${BASH_SOURCE[0]}")"
        # shellcheck source=lib/config_schema.sh
        source "$d/config_schema.sh"
    fi
    if [[ "${1:-}" == core ]]; then _cs_core; else _cs_load; fi
}

# _config_check <file> [<shared file>]: lines for doctor, driven by the schema.
# Unknown keys are usually typos (KEEP_OFSITE_DAILY silently falls back to the
# default), so name them, per file: the local one and the cluster-shared one
# load_config also read. An environment switch set in a file (PBO_REPO=cache)
# is named as one: pbo 0.5 honoured it (it sourced the file), 0.6 ignores it.
# The effective values are checked once: a value of the wrong type is named
# with what pbo does instead; a deprecated key in use names its replacement; a
# config newer than this pbo says so.
_config_check() {
    local f="$1" sf="${2:-}"; CC_LINES=(); CC_WARNS=0
    [[ -r "$f" ]] || return 0
    _cs_ensure
    local keys k v msg unknown=() switches=() cf files=("$f") hasx=0
    [[ -n "$sf" && "$sf" != "$f" && -r "$sf" ]] && files+=("$sf")
    # the proxy variables a file exports (CFG_EXPORT, load_config's read) reach
    # the programs pbo runs: not unknown. A bare HTTPS_PROXY= line still is (the
    # reader warns about it too). A caller without load_config has none.
    declare -p CFG_EXPORT >/dev/null 2>&1 && hasx=1
    for cf in "${files[@]}"; do
        unknown=() switches=()
        keys="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Z][A-Z0-9_]*)=.*/\2/p' "$cf" | sort -u)"
        while read -r k; do
            [[ -n "$k" ]] || continue
            _cs_has "$k" && continue
            (( hasx )) && [[ -n "${CFG_EXPORT[$k]+x}" ]] && continue
            if _cs_env_switch "$k"; then switches+=("$k"); else unknown+=("$k"); fi
        done <<<"$keys"
        if (( ${#unknown[@]} )); then
            CC_LINES+=("unknown config key(s) in $cf: ${unknown[*]} (typo? pbo ignores them)"); CC_WARNS=1
        fi
        if (( ${#switches[@]} )); then
            CC_LINES+=("environment switch(es) in $cf: ${switches[*]} (pbo 0.6 ignores them in the config: set them in pbo's environment)"); CC_WARNS=1
        fi
    done
    # Every key's effective value (file, environment or default) against its
    # type. Defaults are valid by construction (tests/config.sh).
    for k in "${CS_ORDER[@]}"; do
        v="${!k-}"
        [[ -n "$v" ]] || continue
        [[ "$k" == PBO_CONFIG_VERSION ]] && continue   # below, with its own message
        _cs_validate "$k" "$v" >/dev/null && continue   # no fork for the common case
        msg="$(_cs_validate "$k" "$v")" || true   # it fails on purpose; errexit must not end doctor
        case "$k" in   # what pbo does with the bad value, where it says so
            NOTIFY_LEVEL)    msg+=": only failures are sent" ;;
            PBO_INTEGRATION) msg+=": treated as standalone (pbo.timer backs up every guest)" ;;
            VZDUMP_STOP_VMIDS) msg+=": pbo splits it on commas only, a guest in it may not be forced to --mode stop" ;;
            RETENTION_GROUP_BY) msg+=": retained per path as in 0.5 (split guests are not pruned)" ;;
        esac
        CC_LINES+=("$msg"); CC_WARNS=1
    done
    # RETENTION_GROUP_BY=paths still works (the 0.5 grouping) and goes in 0.8:
    # said now, with the fix, so that the release that drops it changes no
    # host's retention unannounced
    if [[ "${RETENTION_GROUP_BY:-}" == paths ]]; then
        CC_LINES+=("RETENTION_GROUP_BY=paths (the 0.5 grouping per snapshot path) is deprecated and will be removed in pbo 0.8, which retains per guest only: check what changes with 'pbo --dry-run prune', then 'pbo config unset RETENTION_GROUP_BY' (or set it to guest)")
        CC_WARNS=1
    fi
    # Deprecated keys that still change something: name the replacement.
    local new
    for k in "${CS_ORDER[@]}"; do
        [[ ",${CS_FLAGS[$k]}" == *",deprecated="* ]] || continue
        new="$(_cs_flag "$k" deprecated)"
        _cs_value_r "$k"; v="$_CS_R"; _cs_default_r "$k"
        [[ "$v" != "$_CS_R" && -z "${!new-}" ]] || continue
        _cs_validate "$k" "$v" >/dev/null || continue   # named above already
        msg="$k is replaced by $new"
        [[ "${CS_TYPE[$new]}" == enum:* ]] && msg+="=$(_cs_enum_values "$new")"
        [[ "$k" == NTFY_ON_SUCCESS ]] && msg+=" (still honoured: true means all)"
        CC_LINES+=("$msg"); CC_WARNS=1
    done
    v="${PBO_CONFIG_VERSION:-$PBO_CONFIG_SCHEMA}"
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v > PBO_CONFIG_SCHEMA )); then
        CC_LINES+=("$f is written for config schema $v, this pbo knows $PBO_CONFIG_SCHEMA: upgrade pbo"); CC_WARNS=1
    elif ! msg="$(_cs_validate PBO_CONFIG_VERSION "$v")"; then
        CC_LINES+=("$msg"); CC_WARNS=1
    fi
    return 0
}

# Create the directories we own. The log directory falls back to stderr-only
# if it cannot be created (e.g. isolated dev without a root install).
# Every pbo start runs this: an existing directory costs no mkdir fork.
ensure_dirs() {
    if ! [[ -d "$STATE_DIR" && -d "$JOBS_DIR" && -d "$CACHE_DIR" ]]; then
        mkdir -p "$STATE_DIR" "$JOBS_DIR" 2>/dev/null || true
        # not a CACHE_DIR a finished cache move left (a process that read the
        # config before the move would make it again); a missing journal costs
        # no fork
        if [[ ! -d "$CACHE_DIR" ]] && { [[ ! -e "${STATE_DIR%/}/cache-move.json" ]] || ! declare -F _cm_old_location >/dev/null || ! _cm_old_location "$CACHE_DIR"; }; then
            mkdir -p "$CACHE_DIR" 2>/dev/null || true
        fi
    fi
    [[ -d "$LOCK_DIR" ]] || { mkdir -p "$LOCK_DIR" 2>/dev/null && chmod 0700 "$LOCK_DIR"; } || true
    # logs hold repo paths, guest names, errors: root (or the janitor user) only
    # (created here with umask 077; no global umask: vzdump of an unprivileged CT
    # runs tar as the mapped uid and must traverse CACHE_DIR)
    # A janitor started as root creates none: its LOG_DIR belongs to the
    # janitor user, and root re-execs as that user or writes no log file at
    # all (_role_check, lib/appendonly.sh).
    local lf; for lf in "${LOG_FILE:-}" "${AUDIT_FILE:-}"; do
        [[ -n "$lf" ]] || continue
        [[ "$EUID" != 0 || "${PBO_ROLE:-host}" != janitor || "${PBO_JANITOR_ALLOW_ROOT:-0}" == 1 ]] || break
        [[ -e "$lf" ]] || ( umask 077; : >> "$lf" ) 2>/dev/null || true
        [[ -f "$lf" ]] && chmod 0600 "$lf" 2>/dev/null || true
    done
    if ! { [[ -d "$LOG_DIR" ]] || mkdir -p "$LOG_DIR" 2>/dev/null; } || [[ ! -w "$LOG_DIR" ]]; then
        LOG_FILE=""   # signal: log only to stderr/stdout
        AUDIT_JSON=""
    fi
}

# _ct_root_uid <vmid> → the host uid that an unprivileged CT's root maps to: its
# first "lxc.idmap: u 0 <host> <n>" line in the main section, else 100000.
# Without such a line pve-container always maps CT root to 100000 and never
# reads /etc/subuid (parse_id_maps), so neither does pbo: a uid from there
# would put the CACHE_DIR ACL on a uid the CT does not run as. Fails for a
# privileged CT or no such CT.
_ct_root_uid() {
    local f="${PBO_PVE_LXC_DIR:-/etc/pve/lxc}/$1.conf" cfg u
    [[ "$1" =~ ^[0-9]+$ && -r "$f" ]] || return 1
    cfg="$(sed -n '/^\[/q;p' -- "$f" 2>/dev/null)"
    grep -qE '^unprivileged:[[:space:]]*1[[:space:]]*$' <<<"$cfg" || return 1
    u="$(awk '$1 == "lxc.idmap:" && $2 == "u" && $3 == "0" { print $4; exit }' <<<"$cfg")"
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
# warns instead. The CACHE_DIR rule of the permission table (lib/perms.sh) does
# the work; this keeps the backup paths' contract: only a directory this user
# owns, never in a dry run, never fails the caller.
_cache_dir_protect() {
    _is_janitor && return 0
    [[ "${DRY_RUN:-0}" == 1 ]] && return 0
    local d="${CACHE_DIR%/}"
    [[ -n "$d" && -d "$d" && ! -L "$d" ]] || return 0
    [[ "$(stat -c %u -- "$d" 2>/dev/null)" == "$(id -u)" ]] || return 0
    _perm_ensure
    # dynamic scope: _perm_ct_uids also lets these vmids' CTs through
    local PERM_EXTRA_VMIDS=("$@") c f lv n p what from to applied
    _perm_apply --fix --only CACHE_DIR:dir || return 0
    for c in "${PERM_CHANGES[@]+"${PERM_CHANGES[@]}"}"; do
        IFS=$'\t' read -r n p what from to applied <<<"$c"
        case "$what" in
            mode) log_info "CACHE_DIR $p closed to other users (mode ${to#0}; unprivileged CTs pass through an ACL)" ;;
            acl)  log_info "CACHE_DIR $p: ACL entry ${to} added (vzdump of an unprivileged CT runs tar as its mapped root)" ;;
            *)    log_info "CACHE_DIR $p: $what $from -> $to" ;;
        esac
    done
    for c in "${PERM_FIX_ERRORS[@]+"${PERM_FIX_ERRORS[@]}"}"; do log_warn "$c"; done
    for f in "${PERM_FINDINGS[@]+"${PERM_FINDINGS[@]}"}"; do
        lv="${f%%$'\t'*}"
        [[ "$lv" == ok ]] || log_warn "${f##*$'\t'}"
    done
    return 0
}

# _cfg_write_ensure: the config writer (_cfg_write, lib/config.sh) loaded with
# what it needs; ./pbo sources them, a caller that sourced only some gets them here.
_cfg_write_ensure() {
    _cfg_parse_ensure
    _cs_ensure
    _perm_ensure
    if ! declare -F _cfg_write >/dev/null; then
        local d="${SELF_DIR:-}"; [[ -n "$d" ]] && d+=/lib || d="$(dirname -- "${BASH_SOURCE[0]}")"
        # shellcheck source=lib/config.sh
        source "$d/config.sh"
    fi
}

# _sched_ensure: the timer schedules (lib/timers.sh) loaded; ./pbo sources it,
# a caller that sourced only some libraries (a test, lib/integrate.sh's job
# window) gets it here.
_sched_ensure() {
    if ! declare -F _sched_apply >/dev/null; then
        local d="${SELF_DIR:-}"; [[ -n "$d" ]] && d+=/lib || d="$(dirname -- "${BASH_SOURCE[0]}")"
        # shellcheck source=lib/timers.sh
        source "$d/timers.sh"
    fi
}

# _perm_ensure: the permission engine (lib/perms.sh) loaded; ./pbo sources it,
# a caller that sourced only this file gets it here.
_perm_ensure() {
    if ! declare -F _perm_apply >/dev/null; then
        local d="${SELF_DIR:-}"; [[ -n "$d" ]] && d+=/lib || d="$(dirname -- "${BASH_SOURCE[0]}")"
        # shellcheck source=lib/perms.sh
        source "$d/perms.sh"
    fi
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
