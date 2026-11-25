# shellcheck shell=bash
# tests/fixtures/stateless_guard.sh: sourced by a copy of ./pbo right before
# main (as tests/fixtures/run_dir_guard.sh is), for the commands that must
# neither read a config nor write anything: `help` and `config template`.
# Every function that reads the config, creates pbo's directories, takes a
# lock, or writes a log, audit record, metrics or the JSON marker file is
# replaced by one that stops pbo (99) with its name. A command that reaches
# one fails loudly, before the real function could read the host's
# /etc/pbo/config or write below /var/log/pbo, whatever PBO_CONFIG says.
# A function missing from the source tree stops pbo too, so a rename cannot
# turn the guard off silently. The reader is sourced first: load_config
# sources lib/config_parse.sh lazily, which would replace its overrides.
# shellcheck source=lib/config_parse.sh
source "${SELF_DIR}/lib/config_parse.sh"
for _sg_f in load_config _cfg_config_files _cfg_parse_file set_defaults ensure_dirs \
             audit_command_start audit_command_end _audit_json audit_log json_open \
             _metrics_write _metrics_event _role_check cleanup_locks \
             acquire_global_lock acquire_vmid_lock acquire_schedule_lock acquire_cache_lock; do
    declare -F "$_sg_f" >/dev/null || { echo "stateless_guard: $_sg_f is not defined any more: update the list" >&2; exit 99; }
    eval "$_sg_f() { echo 'stateless_guard: $_sg_f ran' >&2; exit 99; }"
done
unset _sg_f
