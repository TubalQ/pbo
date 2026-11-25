# shellcheck shell=bash
# tests/fixtures/cachemove_hook.sh: sourced by the copy of ./pbo that
# tests/cachemove.sh runs (right before main). A cache move renames, copies and
# removes whole directory trees and runs pvesm and systemctl, so this harness
# makes sure that no change in the code under test can make it touch anything
# outside TEST_RUN:
#  1. the reader is sourced first (load_config sources lib/config_parse.sh only
#     when it is not loaded yet, which would undo what follows);
#  2. ensure_dirs (the end of load_config) is wrapped: the config files and every path pbo resolves
#     (its directories, the repos, the spool and staging, the catalogue, the PVE
#     files it reads) must be below TEST_RUN, or pbo stops (99) before any
#     command runs. The check runs again before the cache move itself, on the
#     old and the new directory;
#  3. the writer is wrapped: a config outside TEST_RUN stops pbo (99);
#  4. the node name and the vzdump processes come from the test (TEST_NODE,
#     TEST_RUN/vzdump.pids), not from the host;
#  5. fault injection, each only when its variable is set: TEST_PAUSE_DIR,
#     TEST_CM_DAMAGE, TEST_CFG_MV_FAIL, TEST_TR_TOUCH_CONFIG (see below).
[[ "${TEST_RUN:-}" == /*/run-* && -d "$TEST_RUN" ]] \
    || { echo "cachemove_hook: TEST_RUN must name the test's run-* directory" >&2; exit 99; }
[[ "${PBO_CONFIG:-}" == "$TEST_RUN"/* ]] \
    || { echo "cachemove_hook: PBO_CONFIG must be below $TEST_RUN" >&2; exit 99; }
# shellcheck source=lib/config_parse.sh
source "${SELF_DIR}/lib/config_parse.sh"

# _test_inside VALUE NAME: VALUE (a path, or a local repo) is below TEST_RUN
_test_inside() {
    local v="${1#local:}"
    [[ -z "$v" ]] && return 0
    [[ "$v" == "$TEST_RUN" || "$v" == "$TEST_RUN"/* ]] && return 0
    echo "cachemove_hook: $2=$1 is outside $TEST_RUN: refusing to run" >&2
    exit 99
}
_test_paths() {
    local k f
    for f in "$PBO_CONFIG_LOCAL" "${PBO_CONFIG_FILES[@]+"${PBO_CONFIG_FILES[@]}"}"; do _test_inside "$f" config; done
    for k in CACHE_DIR STATE_DIR LOCK_DIR LOG_DIR RESTIC_CACHE_REPO RESTIC_CACHE_DIR RESTIC_PASSWORD_FILE PVE_SPOOL_DIR \
             PVE_STAGING_DIR PBO_CATALOG PVE_CATALOG_MOUNT_DIR PVE_STORAGE_CFG PBO_PVE_STORAGE_CFG PBO_PVE_LXC_DIR \
             PBO_PVE_QEMU_DIR PBO_SUBUID_FILE PBO_PVE_CFS_DIR PBO_PERMS_CONFIG_DIR VZDUMP_CONF VZDUMP_LOCK METRICS_FILE \
             AUDIT_JSON TR_HISTORY PBO_PVE_PLUGIN_PATH NTFY_CREDS_FILE MOCK_STORAGE_CFG MOCK_SYSTEMCTL_DIR; do
        _test_inside "${!k-}" "$k"
    done
    # a remote offsite repo is never used by this suite
    [[ -z "${RESTIC_OFFSITE_REPO:-}" ]] || _test_inside "$RESTIC_OFFSITE_REPO" RESTIC_OFFSITE_REPO
}
# load_config ends in ensure_dirs, which creates directories: the paths are
# checked right before it, once every value is resolved
eval "_test_real_ensure_dirs() $(declare -f ensure_dirs | tail -n +2)"
ensure_dirs() {
    _test_paths
    _test_real_ensure_dirs
}
eval "_test_real_load_config() $(declare -f load_config | tail -n +2)"
load_config() {
    _test_real_load_config
    _test_paths
}
eval "_test_real_cfg_write_locked() $(declare -f _cfg_write_locked | tail -n +2)"
_cfg_write_locked() {
    _test_inside "$1" "the config target"
    _test_real_cfg_write_locked "$@"
}
eval "_test_real_cm_hook() $(declare -f _cm_hook | tail -n +2)"
_cm_hook() {
    _test_inside "$1" "the old CACHE_DIR"; _test_inside "$2" "the new CACHE_DIR"
    _test_paths
    _test_real_cm_hook "$@"
}
# --resume and --abort take the directories from the journal
eval "_test_real_cm_from_journal() $(declare -f _cm_from_journal | tail -n +2)"
_cm_from_journal() {
    _test_real_cm_from_journal
    _test_inside "$CM_OLD" "the journal's old CACHE_DIR"; _test_inside "$CM_NEW" "the journal's new CACHE_DIR"
}
# TEST_PAUSE_DIR: hold the move before its data step, with every lock taken,
# until the test says go (a backup queued meanwhile must wait for it)
if [[ -n "${TEST_PAUSE_DIR:-}" ]]; then
    _test_inside "$TEST_PAUSE_DIR" TEST_PAUSE_DIR
    eval "_test_real_cm_step_data() $(declare -f _cm_step_data | tail -n +2)"
    _cm_step_data() {
        local _tw=0
        touch "$TEST_PAUSE_DIR/in"
        while [[ ! -e "$TEST_PAUSE_DIR/go" ]]; do
            (( ++_tw <= 600 )) || { echo "cachemove_hook: no go within 60 s" >&2; exit 99; }
            sleep 0.1
        done
        _test_real_cm_step_data "$@"
    }
fi
# TEST_CM_DAMAGE=drop|flip: damage the copy right after cp -a has copied the
# cache repo into the new directory, before the move compares and checks it
# (drop: one pack file less; flip: a few bytes of one pack changed, its size
# kept, so only restic check --read-data can see it)
if [[ -n "${TEST_CM_DAMAGE:-}" ]]; then
    cp() {
        command cp "$@" || return
        local dst="${!#}" src="${*: -2:1}" f
        [[ "$dst" == "${CM_NEW:-}/" && "$src" == */repo ]] || return 0
        f="$(find "${CM_NEW}/repo/data" -type f -size +1k 2>/dev/null | LC_ALL=C sort | head -n 1)"
        _test_inside "$f" "the damaged pack"
        [[ -n "$f" ]] || { echo "cachemove_hook: no pack to damage" >&2; exit 99; }
        case "$TEST_CM_DAMAGE" in
            drop) rm -f -- "$f" ;;
            flip)   # restic writes packs read-only: root writes anyway, another user
                    # needs the write bit for a moment (the mode is put back)
                    local m; m="$(stat -c %a -- "$f")"; chmod u+w -- "$f"
                    printf 'XXXXXXXX' | dd of="$f" bs=1 seek=600 conv=notrunc status=none \
                        || { echo "cachemove_hook: cannot damage $f" >&2; exit 99; }
                    chmod "$m" -- "$f" ;;
        esac
    }
fi
# TEST_CFG_MV_FAIL=1: the writer's final rename onto the config fails (after
# its hooks ran: the move's data is in place), every other mv works
if [[ -n "${TEST_CFG_MV_FAIL:-}" ]]; then
    mv() {
        [[ "${!#}" == "$PBO_CONFIG" ]] && { echo "test: mv to $PBO_CONFIG fails" >&2; return 1; }
        command mv "$@"
    }
fi
# TEST_TR_TOUCH_CONFIG=1: after the first guest of a test-restore, the local
# config gets a newer mtime (a `config set` while a scheduled run goes on)
if [[ -n "${TEST_TR_TOUCH_CONFIG:-}" ]]; then
    eval "_test_real_do_test_restore() $(declare -f do_test_restore | tail -n +2)"
    do_test_restore() {
        local rc=0
        _test_real_do_test_restore "$@" || rc=$?
        [[ -e "$TEST_RUN/tr-touched" ]] || { : > "$TEST_RUN/tr-touched"; touch -- "$PBO_CONFIG"; }
        return "$rc"
    }
fi
_local_node() { printf '%s' "${TEST_NODE:-pve1}"; }
_cm_vzdump_pids() { cat "$TEST_RUN/vzdump.pids" 2>/dev/null || true; }
