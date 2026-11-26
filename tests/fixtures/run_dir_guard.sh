# shellcheck shell=bash
# tests/fixtures/run_dir_guard.sh: sourced by a copy of ./pbo that a suite runs
# instead of ./pbo (right before main, as tests/fixtures/config_write_hook.sh
# is), so that pbo stops (99) before any command runs when a path it resolved
# lies outside the suite's run directory TEST_RUN: the config files it read and
# the one it would write, the directories it works in, the PVE paths (pmxcfs,
# storage.cfg, vzdump.conf, guest configs, catalogue, spool, staging) and the
# systemd directory the timer drop-ins go to. The test can never read or write
# the host's /etc/pbo/config, /etc/pve or /etc/systemd/system, whatever the
# code under test or its lazy loaders do. Every writer of those files is
# wrapped too: a target outside TEST_RUN stops pbo (99) before it is created.
#   TEST_RUN    the run directory (an absolute path, below a run* directory)
#   TEST_ALLOW  extra prefixes a test may name on purpose (space-separated),
#               e.g. a path that does not exist, for a doctor check
#   TEST_GUARD_KEYS  more config keys whose path must lie in TEST_RUN (the
#               setup wizard's: PBO_KNOWN_HOSTS, RESTIC_REST_PASSWORD_FILE)
#   TEST_GUARD_SHARED  a file below TEST_RUN that pbo reads as the
#               cluster-shared config, before PBO_CONFIG (which still has to
#               be set: it is the local file)
#   TEST_GUARD_CACHE_DEFAULT  a directory below TEST_RUN that is the schema
#               default of CACHE_DIR, so a test config can leave CACHE_DIR out
#               without pbo resolving the host's own cache directory
#   TEST_GUARD_DEFAULTS  the same for other keys: "KEY=PATH ..." (space-
#               separated, each PATH below TEST_RUN), e.g. NTFY_CREDS_FILE for
#               a test of what pbo does when nothing sets it
# The wrappers replace functions pbo sourced at start; none of them is loaded
# lazily again later (each loader checks that its function exists first).
[[ "${TEST_RUN:-}" == /*/run* ]] || { echo "run_dir_guard: TEST_RUN must be set to the suite's run directory" >&2; exit 99; }
if [[ -n "${TEST_GUARD_SHARED:-}" ]]; then
    [[ "$TEST_GUARD_SHARED" == "$TEST_RUN"/* && -n "${PBO_CONFIG:-}" ]] \
        || { echo "run_dir_guard: TEST_GUARD_SHARED must lie below $TEST_RUN, and PBO_CONFIG must be set" >&2; exit 99; }
    # the reader first: load_config sources it only when it is not loaded
    # yet, and that would replace the override
    # shellcheck source=lib/config_parse.sh
    source "${SELF_DIR}/lib/config_parse.sh"
    _cfg_config_files() { _CFG_FPATH=("$TEST_GUARD_SHARED" "$PBO_CONFIG"); _CFG_FORIGIN=(shared local); }
fi
if [[ -n "${TEST_GUARD_CACHE_DEFAULT:-}" ]]; then
    [[ "$TEST_GUARD_CACHE_DEFAULT" == "$TEST_RUN"/* && "$TEST_GUARD_CACHE_DEFAULT" != *[\|\'[:space:]]* ]] \
        || { echo "run_dir_guard: TEST_GUARD_CACHE_DEFAULT must lie below $TEST_RUN (no blank, | or ')" >&2; exit 99; }
    eval "_guard_real_cs_table() $(declare -f _cs_table | tail -n +2)"
    _cs_table() {
        _guard_real_cs_table
        local row=$'\n''CACHE_DIR|dir|/var/cache/pbo|'
        [[ "$_CS_TABLE" == *"$row"* ]] || { echo "run_dir_guard: the schema row of CACHE_DIR changed: update TEST_GUARD_CACHE_DEFAULT" >&2; exit 99; }
        _CS_TABLE="${_CS_TABLE/"$row"/$'\n'"CACHE_DIR|dir|$TEST_GUARD_CACHE_DEFAULT|"}"
    }
fi
if [[ -n "${TEST_GUARD_DEFAULTS:-}" ]]; then
    for _guard_d in $TEST_GUARD_DEFAULTS; do
        [[ "$_guard_d" =~ ^[A-Z][A-Z0-9_]*=/ && "${_guard_d#*=}" == "$TEST_RUN"/* && "$_guard_d" != *[\|\']* ]] \
            || { echo "run_dir_guard: TEST_GUARD_DEFAULTS: $_guard_d is not KEY=<a path below $TEST_RUN> (no | or ')" >&2; exit 99; }
    done
    unset _guard_d
    # wraps whatever _cs_table is now (the CACHE_DIR override above included)
    eval "_guard_real_cs_table_defaults() $(declare -f _cs_table | tail -n +2)"
    _cs_table() {
        _guard_real_cs_table_defaults
        local d k re
        for d in $TEST_GUARD_DEFAULTS; do
            k="${d%%=*}"; re=$'\n'"$k"'[|]([^|]*)[|][^|]*[|]'
            [[ "$_CS_TABLE" =~ $re ]] || { echo "run_dir_guard: TEST_GUARD_DEFAULTS: no schema row for $k" >&2; exit 99; }
            _CS_TABLE="${_CS_TABLE/"${BASH_REMATCH[0]}"/$'\n'"$k|${BASH_REMATCH[1]}|${d#*=}|"}"
        done
    }
fi
GUARD_KEYS='LOCK_DIR STATE_DIR LOG_DIR CACHE_DIR RESTIC_CACHE_DIR RESTIC_PASSWORD_FILE RESTIC_ENV_FILE NTFY_CREDS_FILE
    PBO_SYSTEMD_DIR PBO_PVE_CFS_DIR PVE_STORAGE_CFG PBO_PVE_STORAGE_CFG VZDUMP_CONF VZDUMP_LOCK PBO_PVE_LXC_DIR
    PBO_PVE_QEMU_DIR PBO_CATALOG PVE_SPOOL_DIR PVE_STAGING_DIR PVE_CATALOG_MOUNT_DIR PBO_PERMS_CONFIG_DIR
    PVE_TEMPLATE_DIR'" ${TEST_GUARD_KEYS:-}"

# _guard_ok PATH: empty, below TEST_RUN, or below a TEST_ALLOW prefix
_guard_ok() {
    local p="$1" a
    [[ -z "$p" || "$p" == "$TEST_RUN" || "$p" == "$TEST_RUN"/* ]] && return 0
    for a in ${TEST_ALLOW:-}; do [[ "$p" == "$a" || "$p" == "$a"/* ]] && return 0; done
    return 1
}
_guard_stop() { echo "run_dir_guard: $1 is outside $TEST_RUN: pbo stopped before it ran" >&2; exit 99; }

eval "_guard_real_load_config() $(declare -f load_config | tail -n +2)"
load_config() {
    _guard_real_load_config
    local f k
    for f in "${PBO_CONFIG_LOCAL:-}" "${PBO_CONFIG_FILES[@]+"${PBO_CONFIG_FILES[@]}"}"; do
        _guard_ok "$f" || _guard_stop "the config file $f"
    done
    for k in $GUARD_KEYS; do _guard_ok "${!k-}" || _guard_stop "$k=${!k}"; done
}
eval "_guard_real_cfg_write_locked() $(declare -f _cfg_write_locked | tail -n +2)"
_cfg_write_locked() { _guard_ok "$1" || _guard_stop "the config write to $1"; _guard_real_cfg_write_locked "$@"; }
eval "_guard_real_sched_write() $(declare -f _sched_write | tail -n +2)"
_sched_write() { _guard_ok "$1" || _guard_stop "the drop-in $1"; _guard_real_sched_write "$@"; }
eval "_guard_real_sched_remove() $(declare -f _sched_remove | tail -n +2)"
_sched_remove() { _guard_ok "$1" || _guard_stop "the drop-in $1"; _guard_real_sched_remove "$@"; }
eval "_guard_real_integ_write_file() $(declare -f _integ_write_file | tail -n +2)"
_integ_write_file() { _guard_ok "$1" || _guard_stop "the file $1"; _guard_real_integ_write_file "$@"; }
# the directory a CACHE_DIR change creates (or moves the cache to), and the
# files of its own the setup wizard writes (the DR key, a rest-server
# password, RESTIC_ENV_FILE, known_hosts) and the key pair it generates
eval "_guard_real_cfg_hook_move_cache() $(declare -f _cfg_hook_move_cache | tail -n +2)"
_cfg_hook_move_cache() { _guard_ok "$2" || _guard_stop "the new CACHE_DIR $2"; _guard_real_cfg_hook_move_cache "$@"; }
eval "_guard_real_setup_write_file() $(declare -f _setup_write_file | tail -n +2)"
_setup_write_file() { _guard_ok "$1" || _guard_stop "the file $1"; _guard_real_setup_write_file "$@"; }
eval "_guard_real_setup_keygen() $(declare -f _setup_keygen | tail -n +2)"
_setup_keygen() { _guard_ok "$1" || _guard_stop "the key $1"; _guard_real_setup_keygen "$@"; }
# TEST_GUARD_NO_WRITE=1: the command under test must write nothing at all
# (`pbo --dry-run init`): each of pbo's writers stops pbo (99) when it runs:
# the directories it makes at start, a repo init, the locks, the config, the
# drop-ins, the wizard's files, the cache move's journal, the metrics, and a
# log, audit or JSON marker file that is set (an empty one writes nothing).
# The test compares the run directory before and after as well: this only
# names the writer.
if [[ "${TEST_GUARD_NO_WRITE:-0}" == 1 ]]; then
    _guard_wrote() { echo "run_dir_guard: $1 ran, but this command must write nothing" >&2; exit 99; }
    for _guard_f in ensure_dirs restic_init _restic_ensure acquire_global_lock acquire_vmid_lock acquire_schedule_lock \
                    acquire_cache_lock _integ_lock _cfg_write_locked _sched_write _sched_remove _setup_write_file \
                    _setup_keygen _integ_write_file _cm_jsave _metrics_write _metrics_event json_open; do
        declare -F "$_guard_f" >/dev/null || continue
        eval "$_guard_f() { _guard_wrote $_guard_f; }"
    done
    unset _guard_f
    eval "_guard_real_audit_json() $(declare -f _audit_json | tail -n +2)"
    _audit_json() { [[ -z "${AUDIT_JSON:-}" ]] || _guard_wrote "_audit_json ($AUDIT_JSON)"; _guard_real_audit_json "$@"; }
    eval "_guard_real_log() $(declare -f _log | tail -n +2)"
    _log() { [[ -z "${LOG_FILE:-}" ]] || _guard_wrote "_log ($LOG_FILE)"; _guard_real_log "$@"; }
    eval "_guard_real_audit_log() $(declare -f audit_log | tail -n +2)"
    audit_log() { [[ -z "${AUDIT_FILE:-}" ]] || _guard_wrote "audit_log ($AUDIT_FILE)"; _guard_real_audit_log "$@"; }
fi
