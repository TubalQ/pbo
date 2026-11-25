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
# The wrappers replace functions pbo sourced at start; none of them is loaded
# lazily again later (each loader checks that its function exists first).
[[ "${TEST_RUN:-}" == /*/run* ]] || { echo "run_dir_guard: TEST_RUN must be set to the suite's run directory" >&2; exit 99; }
GUARD_KEYS='LOCK_DIR STATE_DIR LOG_DIR CACHE_DIR RESTIC_CACHE_DIR RESTIC_PASSWORD_FILE RESTIC_ENV_FILE NTFY_CREDS_FILE
    PBO_SYSTEMD_DIR PBO_PVE_CFS_DIR PVE_STORAGE_CFG PBO_PVE_STORAGE_CFG VZDUMP_CONF VZDUMP_LOCK PBO_PVE_LXC_DIR
    PBO_PVE_QEMU_DIR PBO_CATALOG PVE_SPOOL_DIR PVE_STAGING_DIR PVE_CATALOG_MOUNT_DIR PBO_PERMS_CONFIG_DIR
    PVE_TEMPLATE_DIR'

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
