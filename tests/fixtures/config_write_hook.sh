# shellcheck shell=bash
# tests/fixtures/config_write_hook.sh: sourced by the copy of ./pbo that
# tests/config_write.sh runs (right before main), so that the files pbo reads
# and writes are TEST_SHARED (as the cluster-shared file) and TEST_LOCAL, both
# below TEST_RUN. Three layers, so that no change in the code under test can
# make this harness read or write the real /etc/pve/pbo/config or
# /etc/pbo/config:
#  1. the reader is sourced first: load_config sources lib/config_parse.sh only
#     when it is not loaded yet, and that would replace the override below;
#  2. load_config is wrapped: the files it read and the local file must be the
#     test files, or pbo stops (99) before any command runs;
#  3. the writer is wrapped: a target outside TEST_RUN stops pbo (99) before
#     anything is created.
[[ -n "${TEST_SHARED:-}" && -n "${TEST_LOCAL:-}" && "${TEST_RUN:-}" == /*/run-* ]] \
    || { echo "config_write_hook: TEST_SHARED, TEST_LOCAL and TEST_RUN must be set" >&2; exit 99; }
[[ "$TEST_SHARED" == "$TEST_RUN"/* && "$TEST_LOCAL" == "$TEST_RUN"/* ]] \
    || { echo "config_write_hook: the test files must be below $TEST_RUN" >&2; exit 99; }
# shellcheck source=lib/config_parse.sh
source "${SELF_DIR}/lib/config_parse.sh"
_cfg_config_files() { _CFG_FPATH=("$TEST_SHARED" "$TEST_LOCAL"); _CFG_FORIGIN=(shared local); }
eval "_test_real_load_config() $(declare -f load_config | tail -n +2)"
load_config() {
    _test_real_load_config
    local f
    for f in "$PBO_CONFIG_LOCAL" "${PBO_CONFIG_FILES[@]+"${PBO_CONFIG_FILES[@]}"}"; do
        [[ "$f" == "$TEST_RUN"/* ]] || { echo "config_write_hook: pbo would use $f, not a test file" >&2; exit 99; }
    done
}
eval "_test_real_cfg_write_locked() $(declare -f _cfg_write_locked | tail -n +2)"
_cfg_write_locked() {
    [[ "$1" == "$TEST_RUN"/* ]] || { echo "config_write_hook: refusing to write $1 (not below $TEST_RUN)" >&2; exit 99; }
    # TEST_PAUSE_DIR: hold the writer here, under the config lock, until the
    # test says go (a second writer meanwhile must find the lock busy)
    if [[ -n "${TEST_PAUSE_DIR:-}" ]]; then
        [[ "$TEST_PAUSE_DIR" == "$TEST_RUN"/* ]] || { echo "config_write_hook: TEST_PAUSE_DIR must be below $TEST_RUN" >&2; exit 99; }
        local _tw=0
        touch "$TEST_PAUSE_DIR/in"
        while [[ ! -e "$TEST_PAUSE_DIR/go" ]]; do
            (( ++_tw <= 100 )) || { echo "config_write_hook: no go within 10 s" >&2; exit 99; }
            sleep 0.1
        done
    fi
    _test_real_cfg_write_locked "$@"
}
# TEST_QVAL=cr|other|open: the writer quotes a value wrongly, so the read-back
# (_cfg_verify) has a candidate it must refuse: cr ends the line in a CR (the
# strict reader drops it, bash keeps it), other writes another value, open
# leaves a quote open (the strict reader refuses the line)
if [[ -n "${TEST_QVAL:-}" ]]; then
    eval "_test_real_cfg_qval() $(declare -f _cfg_qval | tail -n +2)"
    _cfg_qval() {
        _test_real_cfg_qval "$@"
        case "$TEST_QVAL" in
            cr)    _CFG_Q+=$'\r' ;;
            other) _CFG_Q+='0' ;;
            open)  _CFG_Q="\"$1" ;;
        esac
    }
fi
# TEST_SHARED_EDIT=LINE: another node changes the shared file (appends LINE)
# while this writer checks its candidate, after the writer read the file
if [[ -n "${TEST_SHARED_EDIT:-}" ]]; then
    eval "_test_real_cfg_verify() $(declare -f _cfg_verify | tail -n +2)"
    _cfg_verify() {
        local _tr=0
        _test_real_cfg_verify "$@" || _tr=$?
        [[ "$1" == "$TEST_SHARED" ]] && printf '%s\n' "$TEST_SHARED_EDIT" >> "$1"
        return "$_tr"
    }
fi
