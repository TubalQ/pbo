#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/config.sh: the config schema (lib/config_schema.sh) and `pbo config`
# (lib/config.sh), ADR 0009 / 0.6 M1 and M3. The schema must describe exactly
# what pbo 0.5 did: same keys, same defaults as the 0.5 set_defaults (a frozen
# copy, tests/fixtures/set_defaults_0.5.sh; as root and as a plain user), the
# generated etc/config.example semantically identical to the config install.sh
# installs. Since M3 set_defaults applies the schema and load_config reads the
# files with the strict reader: its merge, precedence and file rules, and the
# file pbo writes, are tested here too. Nothing outside run-config/ is touched.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start) are the
# machine's own files: point them into the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.env" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
    PBO_PVE_CFS_DIR="$PWD/run-none/pve" PVE_STORAGE_CFG="$PWD/run-none/pve/storage.cfg"
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
printf 'pbo: config schema tests\n'
RUN="$ROOT/run-config"; rm -rf "$RUN"; mkdir -p "$RUN"/{cache,state,log,lock,bin,conf}
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm "$RUN/bin/"   # never the real host
export PATH="$RUN/bin:$PATH" MOCK_CONF_DIR="$RUN/conf"

# S <code>: run bash code with only the schema loaded, in a clean environment
S() { local c="$1"; shift; env -i PATH="$PATH" bash -c 'set -u; source lib/config_schema.sh; _cs_load; '"$c" _ "$@"; }

# --- the table ---------------------------------------------------------------------------------
out="$(S 'echo "${#CS_ORDER[@]}"')"
[[ "$out" =~ ^[0-9]+$ ]] && (( out > 80 )) && ok "schema loads ($out keys)" || bad "schema load: $out"

out="$(S 'n="${#CS_ORDER[@]}"; _cs_load; _CS_LOADED=0; _cs_load; echo "$n ${#CS_ORDER[@]} ${#CS_TYPE[@]}"')"
read -r a b c <<<"$out"; [[ "$a" == "$b" && "$b" == "$c" ]] && ok "_cs_load is idempotent (a reload gives the same table)" || bad "idempotent: $out"

# every row: 7 fields, a known type, role(s), flags, a description; keys unique;
# sections contiguous (the example prints them in table order)
out="$(S '
    seen=" "; secs=" "; prev=""
    for k in "${CS_ORDER[@]}"; do
        [[ "$seen" == *" $k "* ]] && echo "duplicate $k"; seen+="$k "
        case "${CS_TYPE[$k]}" in
            bool|duration|path|dir|string|list|vmids|vmids-csv|url|name|command|version|calendar|timespan) ;;
            int:*) [[ "${CS_TYPE[$k]}" =~ ^int:[0-9]*:[0-9]*$ ]] || echo "bad int type $k" ;;
            decimal:*) [[ "${CS_TYPE[$k]}" =~ ^decimal:[0-9]*:[0-9]*$ ]] || echo "bad decimal type $k" ;;
            enum:*) [[ "${CS_TYPE[$k]}" =~ ^enum:[A-Za-z0-9_,-]+$ ]] || echo "bad enum $k" ;;
            *) echo "unknown type $k: ${CS_TYPE[$k]}" ;;
        esac
        [[ "${CS_ROLES[$k]}" =~ ^(host|janitor)(,(host|janitor))?$ ]] || echo "bad roles $k: ${CS_ROLES[$k]}"
        IFS=, read -ra fl <<<"${CS_FLAGS[$k]}"
        for f in "${fl[@]}"; do
            [[ "$f" =~ ^(secret|exec|local-only|internal|advanced|managed=[a-z-]+|follows=[A-Z_]+|samefs=[A-Z_]+|on_change=[a-z-]+|deprecated=[A-Z_]+|template=.*|template_janitor=.*)$ ]] || echo "bad flag $k: $f"
            case "$f" in follows=*|samefs=*|deprecated=*) _cs_has "${f#*=}" || echo "$k: $f names no key" ;; esac
            case "$f" in template_janitor=*) _cs_has_role "$k" janitor || echo "$k: $f but not a janitor key" ;; esac
        done
        [[ -n "${CS_DESC[$k]}" ]] || echo "no description $k"
        [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || echo "bad key name (a blank or comment row? _cs_core takes every row): $k"
        s="${CS_SECTION[$k]}"
        if [[ "$s" != "$prev" ]]; then [[ "$secs" == *" $s "* ]] && echo "section $s not contiguous ($k)"; secs+="$s "; prev="$s"; fi
    done')"
[[ -z "$out" ]] && ok "every row well-formed, keys unique, sections contiguous" || bad "table: $out"

# derived defaults name only EARLIER keys (no forward references, no cycles); @fn has its function
out="$(S '
    seen=" "
    for k in "${CS_ORDER[@]}"; do
        d="${CS_DEFAULT[$k]}"
        if [[ "$d" == @fn ]]; then declare -F "_cfgdef_$k" >/dev/null || echo "$k: no _cfgdef_$k"; fi
        while [[ "$d" == *"\${"* ]]; do
            d="${d#*\$\{}"; r="${d%%\}*}"; d="${d#*\}}"
            [[ "$seen" == *" $r "* ]] || echo "$k refers to $r, not an earlier key"
        done
        seen+="$k "
    done')"
[[ -z "$out" ]] && ok "every \${REF} refers to an earlier key; every @fn has its function" || bad "refs: $out"

# --- the defaults: the same as the 0.5 set_defaults --------------------------------------------
# The set_defaults of pbo 0.5 (tests/fixtures/set_defaults_0.5.sh, frozen when
# 0.6 M3 replaced it with the schema) next to today's set_defaults (lib/common.sh,
# the schema applied in table order), in a clean env. Every key the old one
# defaulted with := is compared, and the paths it derived; the list is read from
# the frozen function itself. The new one is not compared with itself: the old
# behaviour is the reference.
cmpdefs() {   # cmpdefs <dir with lib/ and tests/fixtures/> [runner...] [-- preset assignments]
    local dir="$1"; shift
    local pre=() run=()
    while [[ $# -gt 0 && "$1" != -- ]]; do run+=("$1"); shift; done
    [[ "${1:-}" == -- ]] && { shift; pre=("$@"); }
    "${run[@]}" env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "${pre[@]}" bash -c '
        set -u; cd "$1" || exit 1
        keys="$(bash -c '\''source tests/fixtures/set_defaults_0.5.sh
            declare -f set_defaults | grep -oE ": \"\\\$\\{[A-Z][A-Z0-9_]*:=" | grep -oE "[A-Z][A-Z0-9_]+"
            echo LOG_FILE AUDIT_FILE GLOBAL_LOCK_FILE GLOBAL_HOLDER_FILE SCHED_LOCK_FILE SCHED_HOLDER_FILE JOBS_DIR'\'')"
        old="$(bash -c '\''source lib/common.sh; source tests/fixtures/set_defaults_0.5.sh; set_defaults
            for k in $1; do printf "%s=%s\n" "$k" "${!k}"; done'\'' _ "$keys")"
        new="$(bash -c '\''set -u; source lib/common.sh; set_defaults
            for k in $1; do printf "%s=%s\n" "$k" "${!k-<unset>}"; done'\'' _ "$keys")"
        n="$(grep -c . <<<"$old")"
        if [[ "$old" == "$new" && "$n" -gt 50 ]]; then echo "same $n"; else diff <(echo "$old") <(echo "$new") | head -20; fi' _ "$dir"
}
out="$(cmpdefs "$ROOT")"
[[ "$out" == same* ]] && ok "set_defaults (the schema) == the 0.5 set_defaults as uid $(id -u) (${out#same } keys)" || bad "defaults as $(id -u): $out"
out="$(cmpdefs "$ROOT" -- CACHE_DIR=/srv/c STATE_DIR=/srv/s LOG_DIR=/srv/l KEEP_LOCAL=5 GLOBAL_LOCK_TIMEOUT=60 \
        RESTIC_PASSWORD_FILE=/k/pass RESTIC_REST_PASSWORD_FILE=/k/rest)"
[[ "$out" == same* ]] && ok "derived defaults follow the keys they derive from, like the 0.5 set_defaults" || bad "derived defaults: $out"
out="$(cmpdefs "$ROOT" -- CACHE_DIR= KEEP_LOCAL= LOCK_DIR=/srv/lk HOST_BACKUP_EXCLUDES=/x JOBS_DIR=/ignored)"
[[ "$out" == same* ]] && ok "... and so do empty values (the default) and the derived paths (set in any case)" || bad "empty/forced defaults: $out"
if [[ "$(id -u)" == 0 ]]; then
    nb=""; id nobody >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1 && nb=1
    if [[ -n "$nb" ]]; then
        # nobody cannot read /root: a world-readable copy of the two files, under
        # /tmp itself (1777): TMPDIR may be private (pam_tmpdir: /tmp/user/0, 0700)
        cp_dir="$(mktemp -d -p /tmp)"; mkdir -p "$cp_dir/lib" "$cp_dir/tests/fixtures"; cp lib/common.sh lib/config_schema.sh "$cp_dir/lib/"
        cp tests/fixtures/set_defaults_0.5.sh "$cp_dir/tests/fixtures/"; chmod -R a+rX "$cp_dir"
        if ! setpriv --reuid=nobody --regid="$(id -g nobody)" --clear-groups test -r "$cp_dir/lib/common.sh"; then
            echo "  (skip: nobody cannot read the temp copy in $cp_dir)"
        else
            out="$(cmpdefs "$cp_dir" setpriv --reuid=nobody --regid="$(id -g nobody)" --clear-groups)"
            [[ "$out" == same* ]] && ok "set_defaults (the schema) == the 0.5 set_defaults as nobody (LOCK_DIR under STATE_DIR)" || bad "defaults as nobody: $out"
            out="$(setpriv --reuid=nobody --regid="$(id -g nobody)" --clear-groups env -i bash -c 'cd "$1" || exit 1; source lib/config_schema.sh; _cs_default LOCK_DIR' _ "$cp_dir")"
            [[ "$out" == /var/lib/pbo/lock ]] && ok "LOCK_DIR default for a plain user: STATE_DIR/lock" || bad "LOCK_DIR as nobody: $out"
        fi
        rm -rf "$cp_dir"
    else echo "  (skip: no nobody/setpriv for the plain-user default check)"; fi
fi

# the keys that only had an inline ${KEY:-...} default before the schema
out="$(S 'STATE_DIR=/var/lib/pbo; for k in CATALOG_LOCK_TIMEOUT CATALOG_MOUNT_WAIT CATALOG_MOUNT_BG_WAIT JOB_KEEP JOB_MAX_ACTIVE JOB_MAX_PER_USER JOB_RUNNER TR_HISTORY TR_STORAGE VERIFY_READ_DATA VERIFY_SUBSET PBO_KNOWN_HOSTS PBO_CONFIG_VERSION; do printf "%s=%s\n" "$k" "$(_cs_default "$k")"; done')"
exp='CATALOG_LOCK_TIMEOUT=600
CATALOG_MOUNT_WAIT=30
CATALOG_MOUNT_BG_WAIT=10
JOB_KEEP=200
JOB_MAX_ACTIVE=20
JOB_MAX_PER_USER=5
JOB_RUNNER=auto
TR_HISTORY=/var/lib/pbo/restore-tests.jsonl
TR_STORAGE=
VERIFY_READ_DATA=0
VERIFY_SUBSET=
PBO_KNOWN_HOSTS=/etc/pbo/known_hosts
PBO_CONFIG_VERSION=1'
[[ "$out" == "$exp" ]] && ok "inline-only keys: schema defaults as in the code" || bad "inline defaults: $(diff <(echo "$exp") <(echo "$out"))"

# the default 0.6 changes on purpose (CHANGELOG 0.6.0; its line is left out of
# the frozen 0.5 copy): the ntfy credentials file lives below /etc/pbo, and its
# topic is under NTFY_TOPIC unless NTFY_CREDS_TOPIC_KEY names another key
out="$(S 'printf "%s %s %s" "$(_cs_default NTFY_CREDS_FILE)" "$(_cs_default NTFY_CREDS_TOPIC_KEY)" "${CS_TYPE[NTFY_CREDS_TOPIC_KEY]}"')"
[[ "$out" == "/etc/pbo/ntfy.creds NTFY_TOPIC name" ]] && ok "NTFY_CREDS_FILE defaults below /etc/pbo, NTFY_CREDS_TOPIC_KEY to NTFY_TOPIC (type name)" \
    || bad "ntfy creds defaults: $out"

# every literal ${KEY:-x} fallback in the code agrees with the schema default
# (empty guards and display placeholders aside)
out="$(S '
    while read -r m; do
        k="${m#\$\{}"; k="${k%%:*}"; lit="${m#*:?}"; lit="${lit%\}}"
        _cs_has "$k" || continue
        [[ -z "$lit" || "${CS_DEFAULT[$k]}" == *\$* || "${CS_DEFAULT[$k]}" == @fn ]] && continue
        case "$m" in "\${CACHE_DIR:-?}"|"\${RESTIC_OFFSITE_REPO:-none}"|"\${RESTIC_OFFSITE_REPO:-<not set>}"|"\${RESTIC_SFTP_COMMAND:-<not set>}"|"\${RESTIC_REST_PASSWORD_FILE:-/etc/pbo/rest-pass}") continue ;; esac
        [[ "$lit" == "${CS_DEFAULT[$k]}" ]] || echo "$m vs schema ${CS_DEFAULT[$k]}"
    done < <(grep -ohE "\\\$\\{[A-Z][A-Z0-9_]*:[-=][^}\$]*\\}" pbo lib/*.sh lib/vzdump-hook | sort -u)')"
[[ -z "$out" ]] && ok "literal fallbacks in the code match the schema defaults" || bad "fallbacks: $out"

# every ${KEY:-...}/${KEY:=...} of an upper-case name in the code is a schema key,
# an environment switch (CS_ENV_SWITCHES) or a known non-config variable (internal state)
allow=' AUDIT_FILE AUDIT_RO_OVERRIDE AUDIT_RW_OVERRIDE AUDIT_T0 BASH C_0 C_G C_R C_Y DRY_RUN DUMPDIR GLOBAL_LOCK_HELD INTEG_CATALOG_ONLY INTEG_YES
    JSON_EMITTED JSON_OUTPUT LIST_NO_LOCK LIST_WITH_REASONS LOG_FILE PATH PBO_COMMAND PBO_CONFIG
    PBO_CFG_LENIENT PBO_SUBCOMMAND PBO_CONFIG_LOCAL PBO_PERMS_FIXED PBO_PERMS_FIX_REPORT PBO_SCHED_FIXED PBO_SCHED_FIX_REPORT
    PBO_CONFIG_EXPLICIT PBO_CONFIG_LOADED PBO_CONFIG_SCHEMA PBO_CONFIG_SHARED_LOADED PBO_ERROR_LOGGED
    PBO_JOB_ID PBO_JSON_FD PBO_JSON_MARK
    PBO_SETUP_INTEGRATION RESTIC_LOCK_MSG RESTORE_ISOLATE RESTORE_KEEP_NET
    RESTORE_RESTRICTED RESTORE_START RX_TAR SCHED_LOCK_HELD SELF_DIR STAGE_LOCK_FD STOREID SUDO_USER TARGET
    TR_ALLOW_LINKDOWN_NET TR_RESPOND_HOW TR_RESTRICTED TR_TRIGGER VERSION VMID_LOCK_HELD
    CFGW_CREATED CFGW_TMP CFG_LOCK_FD CFG_LOCK_HELD PBO_MOUNT_UNIT
    BASHPID CACHE_LOCK_FD CACHE_LOCK_MODE CATALOG_LOCK_FD INTEG_LOCK_FD CFGW_ERR PBO_START_US PBO_START_ID
    CM_ERR CM_FIX_PARENTS CM_INIT_MSG CM_METHOD_WHY CM_ST_NODES CM_USAGE TZDIR '
out="$(S '
    allow="$1"
    for k in $(grep -ohE "\\\$\\{[A-Z][A-Z0-9_]*:[-=]" pbo lib/*.sh lib/vzdump-hook | sed -E "s/^\\\$\\{//; s/:.\$//" | sort -u); do
        _cs_has "$k" && continue
        _cs_env_switch "$k" && continue
        [[ "$allow" == *[[:space:]]"$k"[[:space:]]* || "$k" == PBO_IT_* || "$k" == MOCK_* || "$k" == PBO_AUDIT_* ]] && continue
        printf "%s " "$k"
    done' "$allow")"
[[ -z "$out" ]] && ok "every config key the code reads is in the schema (or a known non-config variable)" || bad "keys missing from the schema: $out"
# the env switch list does not rot: each one is read by the code, none is a schema key
out="$(S 'for k in $CS_ENV_SWITCHES; do _cs_has "$k" && printf "%s(schema) " "$k"
        grep -qE "\\\$\\{$k:-" pbo lib/*.sh lib/vzdump-hook || printf "%s(unread) " "$k"; done')"
[[ -z "$out" ]] && ok "CS_ENV_SWITCHES: every switch is read by the code and is no schema key" || bad "env switches: $out"

# keys the tests put in config files are in the schema too (a test hook is flagged internal)
out="$(S '
    for k in $(cat tests/*.sh | sed -nE "s/^[[:space:]]*(echo \"|printf .)?([A-Z][A-Z0-9_]*)=.*/\2/p" | sort -u); do
        case "$k" in IFS|KEEP_OFSITE_DAILY|PATH|RUN|ROOT|BIN|W|TS|D|H|I|S|P|V|A|BR|OUT|OUT2|LIST|USAGE|TPL|TAG|STO|STORE|SRC|MARK|HOOK|HID|SPOOL|SLOCK|VTS|VMARK|VLOCK|LOCKPID|LOCKDIR|ROOTOK|RE|REAL_PLUGIN|PLUGIN|OFFSITE|DEFER|GLOBAL_LOCK|FAKE_LOG|PATH_NOACL|MY_OWN_KEY_NOBODY_KNOWS|STOREID|CFGH|INTEG_STEPS|SH|TEST_PAUSE_DIR) continue ;; esac
        # tests/portability.sh and tests/hardcode.sh: their shell variables, and the
        # variables of a RESTIC_ENV_FILE fixture (restic'"'"'s environment, not config keys)
        case "$k" in ALLOW|CFG|E|ENVF|FILES|IR|LI|M|PF_BACKUP_VOLUMES|RR|SP|TZ|ZONES|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|XPROBE_TOKEN|REFV|SCHEMA_DEFS) continue ;; esac
        # tests/schedule_config.sh and tests/integrate.sh: shell variables and test hooks (TEST_ALLOW of the run directory guard, PBO_TOOLS_MISSING)
        case "$k" in IU|J|NODE|UNITS|TEST_ALLOW|PBO_TOOLS_MISSING) continue ;; esac
        # tests/menu.sh: the wizard harness'"'"'s shell variables and the run directory guard'"'"'s hooks
        case "$k" in CFGW_CACHE|KH0|WQM|WSFTP_RC|WSHARED|W_ENV|TEST_GUARD_SHARED|TEST_GUARD_CACHE_DEFAULT) continue ;; esac
        [[ "$k" == MOCK_* || "$k" == PBO_INSTALL_* || "$k" == PBO_AUDIT_* ]] && continue
        case "$k" in PBO_CONFIG|PBO_CONFIG_LOADED|PBO_CONFIG_SHARED_LOADED) continue ;; esac   # set by load_config, not keys
        _cs_env_switch "$k" && continue
        _cs_has "$k" || printf "%s " "$k"
    done')"
[[ -z "$out" ]] && ok "keys in the test configs are schema keys" || bad "test config keys not in the schema: $out"
out="$(S 'for k in PBO_PVE_LXC_DIR PBO_PVE_QEMU_DIR PBO_PVE_STORAGE_CFG PBO_PVE_TEMPLATE_DIR PBO_PVE_PLUGIN_CHECK PBO_CATALOG; do _cs_flag "$k" internal >/dev/null || printf "%s " "$k"; done')"
[[ -z "$out" ]] && ok "test hooks are flagged internal" || bad "not internal: $out"

# --- flags ---------------------------------------------------------------------------------------
out="$(S 'for k in NTFY_TOKEN NTFY_TOPIC NTFY_URL RESTIC_SFTP_COMMAND; do _cs_flag "$k" secret >/dev/null || printf "%s " "$k"; done
    _cs_flag RESTIC_SFTP_COMMAND exec >/dev/null && _cs_flag RESTIC_SFTP_COMMAND local-only >/dev/null || printf "sftp-flags "
    for k in PBO_PVE_PLUGIN_CHECK RESTIC_BIN PBO_VZDUMP_HOOK; do _cs_flag "$k" exec >/dev/null || printf "%s-exec " "$k"; done
    [[ "$(_cs_flag PBO_INTEGRATION managed)" == integrate && "$(_cs_flag PBO_ROLE managed)" == install ]] || printf "managed "')"
[[ -z "$out" ]] && ok "secret, exec, local-only and managed flags where expected" || bad "flags: $out"
# the old name rule for secrets: a schema key named like one must carry the flag.
# A key of type name holds the name of another key (NTFY_CREDS_TOPIC_KEY: which
# key of NTFY_CREDS_FILE has the topic), never a value: no secret to hide
out="$(env -i PATH="$PATH" bash -c 'source lib/common.sh; source lib/config_schema.sh; source lib/config.sh 2>/dev/null; _cs_load
    for k in "${CS_ORDER[@]}"; do [[ "${CS_TYPE[$k]}" == name ]] && continue
        _config_secret_name "$k" && ! _cs_flag "$k" secret >/dev/null && printf "%s " "$k"; done; :')"
[[ -z "$out" ]] && ok "every key named like a secret (TOKEN, PASSWORD, COMMAND, TOPIC, ...) is flagged secret" || bad "unflagged secret-like names: $out"

# --- validation ----------------------------------------------------------------------------------
out="$(S 'STATE_DIR=/var/lib/pbo; for k in "${CS_ORDER[@]}"; do m="$(_cs_validate "$k" "$(_cs_default "$k")")" || echo "$m"; done')"
[[ -z "$out" ]] && ok "every default passes its own type check" || bad "invalid defaults: $out"
out="$(S 'for kv in "KEEP_LOCAL=x" "KEEP_LOCAL=0" "OFFSITE_ENABLED=yes" "NOTIFY_LEVEL=loud" "RESTIC_RETRY_LOCK=10 minutes" "BACKUP_ORDER=101;102" "NTFY_URL=ntfy.sh/topic" "VERIFY_READ_DATA=true" "NTFY_CREDS_TOPIC_KEY=1TOPIC" "NTFY_CREDS_TOPIC_KEY=MY-TOPIC" "NTFY_CREDS_TOPIC_KEY=\$X"; do
        _cs_validate "${kv%%=*}" "${kv#*=}" >/dev/null && echo "accepted $kv"; done
    for kv in "KEEP_LOCAL=5" "OFFSITE_ENABLED=false" "NOTIFY_LEVEL=" "NOTIFY_LEVEL=warn" "RESTIC_RETRY_LOCK=1h30m" "BACKUP_ORDER=auto" "BACKUP_ORDER=8001 8002" "VZDUMP_STOP_VMIDS=101,102" "NTFY_URL=https://ntfy.sh" "PBO_ROLE=janitor" "NTFY_CREDS_TOPIC_KEY=NTFY_TOPIC_ALERTS" "NTFY_CREDS_TOPIC_KEY=_topic2"; do
        _cs_validate "${kv%%=*}" "${kv#*=}" >/dev/null || echo "refused $kv"; done
    m="$(_cs_validate NTFY_URL "secret-topic-in-a-bad-url")"; [[ "$m" == *secret-topic* ]] && echo "secret in message: $m"
    m="$(_cs_validate NOTIFY_LEVEL loud)"; [[ "$m" == "NOTIFY_LEVEL='"'"'loud'"'"' is not fail|warn|all" ]] || echo "enum message: $m"
    _cs_validate NO_SUCH_KEY 1 >/dev/null && echo "unknown key valid"; :')"
[[ -z "$out" ]] && ok "_cs_validate: bad values refused with a message, good ones accepted, secrets never echoed" || bad "validate: $out"
# the vmid list types match how the code splits each key: VZDUMP_STOP_VMIDS goes
# through _in_csv (spaces stripped, commas only), BACKUP_ORDER through
# _backup_set_all (commas and whitespace, stray separators harmless)
out="$(env -i PATH="$PATH" bash -c 'set -u; source lib/common.sh; source lib/backup.sh; source lib/cluster.sh; source lib/config_schema.sh
    _cluster_local_vmids() { :; }
    for v in "101,102" "101, 102" " 101 , 102 ," ",101,,102" "101,102,"; do
        _cs_validate VZDUMP_STOP_VMIDS "$v" >/dev/null || echo "stop: refused [$v]"
        for id in 101 102; do _in_csv "$id" "$v" || echo "stop: [$v] accepted but $id not stopped"; done
        VZDUMP_STOP_VMIDS="$v"; [[ "$(_ct_is_fuse() { return 1; }; _effective_mode 102)" == stop ]] || echo "stop: [$v] _effective_mode 102 not stop"
    done
    for v in "101 102" "101,102 103" "$(printf "101,\t102")"; do
        _cs_validate VZDUMP_STOP_VMIDS "$v" >/dev/null && echo "stop: accepted [$v]"
    done
    # why "101 102" is refused (drop the refusal once _in_csv splits on spaces)
    _in_csv 102 "101 102" && echo "_in_csv splits on spaces now: loosen vmids-csv"
    for v in "101,102," " 101" "101 102" "101, 102" "101,,102"; do
        _cs_validate BACKUP_ORDER "$v" >/dev/null || echo "order: refused [$v]"
        BACKUP_ORDER="$v"; got="$(_backup_set_all | tr "\n" " ")"
        [[ "$got" == "101 "* ]] || echo "order: [$v] gives [$got]"
    done; :')"
[[ -z "$out" ]] && ok "vmid lists: the type check accepts what the code reads as intended, refuses what it would misread" || bad "vmid lists: $out"

# --- the generated example -----------------------------------------------------------------------
cat > "$RUN/config" <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
OFFSITE_ENABLED=false
RESTIC_CACHE_REPO=$RUN/repo
RESTIC_PASSWORD_FILE=$RUN/pass
NTFY_URL=
NTFY_CREDS_FILE=/nonexistent
NTFY_TOKEN=tk_supersecret_value
RESTIC_SFTP_COMMAND="sshpass -p sftp_pw_123 ssh u@h -s sftp"
RESTIC_OFFSITE_REPO=rest:https://pbouser:hunter2pass@backup.invalid:8000/pbo
CATALOG_MOUNT_WAIT=7
PBO_PVE_LXC_DIR=$RUN/conf
KEEP_OFSITE_DAILY=9
EOF
chmod 600 "$RUN/config"; export PBO_CONFIG="$RUN/config"

$BIN config template > "$RUN/t1" 2>"$RUN/err"; rc=$?
# a different config, user and environment must not change it
printf 'CACHE_DIR=%s/c2\nSTATE_DIR=%s/s2\nLOG_DIR=%s/log\nLOCK_DIR=%s/lock\nNOTIFY_LEVEL=all\n' "$RUN" "$RUN" "$RUN" "$RUN" > "$RUN/other.cfg"; chmod 600 "$RUN/other.cfg"
PBO_CONFIG="$RUN/other.cfg" RESTIC_PASSWORD_FILE=/x KEEP_LOCAL=9 $BIN config template > "$RUN/t2" 2>/dev/null || true
[[ $rc == 0 ]] && cmp -s "$RUN/t1" "$RUN/t2" && ok "config template is deterministic (independent of the config and environment)" || bad "template not deterministic (rc=$rc): $(diff "$RUN/t1" "$RUN/t2" | head -5)"
if cmp -s "$RUN/t1" etc/config.example; then ok "etc/config.example is the output of 'pbo config template'"
else bad "etc/config.example is stale, regenerate it with: ./pbo config template > etc/config.example
$(diff etc/config.example "$RUN/t1" | head -20)"; fi
[[ "$(head -1 "$RUN/t1")" == "# /etc/pbo/config, KEY=VALUE. chmod 600, root:root." ]] && ok "template keeps the header" || bad "header: $(head -1 "$RUN/t1")"
bash -n etc/config.example && ok "etc/config.example is valid bash" || bad "etc/config.example: bash -n failed"
# install.sh installs it as the first /etc/pbo/config: these keys, these values, nothing else active
vals() { env -i bash --norc --noprofile -c 'source "$1" >/dev/null 2>&1 || exit 1
    for k in $(sed -nE "s/^([A-Z][A-Z0-9_]*)=.*/\1/p" "$1" | sort -u); do printf "%s=%s\n" "$k" "${!k}"; done' _ "$1"; }
exp='BACKUP_MODE=stream
BACKUP_ORDER=auto
CACHE_DIR=/var/cache/pbo
DOCTOR_MAX_AGE=172800
GLOBAL_LOCK_TIMEOUT=7200
KEEP_LOCAL=2
KEEP_OFFSITE_DAILY=7
KEEP_OFFSITE_MONTHLY=6
KEEP_OFFSITE_WEEKLY=4
KEEP_OFFSITE_YEARLY=0
LOG_DIR=/var/log/pbo
NOTIFY_LEVEL=fail
NOTIFY_PVE=auto
NTFY_TOPIC=
NTFY_URL=
PBO_CONFIG_VERSION=1
PRUNE_OWNER=
STATE_DIR=/var/lib/pbo
VZDUMP_MODE=snapshot
VZDUMP_STOP_VMIDS='
out="$(vals etc/config.example)"
[[ "$out" == "$exp" ]] && ok "example: the same active keys and values as the 0.5 example" || bad "example active keys: $(diff <(echo "$exp") <(echo "$out"))"
# every commented key line is valid once uncommented (quoting of HOST_BACKUP_*, ${REF}s)
sed -E 's/^#([A-Z][A-Z0-9_]*=)/\1/' etc/config.example > "$RUN/uncommented"
if bash -n "$RUN/uncommented" && out="$(env -i bash --norc --noprofile -c 'set -u; source "$1" && printf "%s|%s|%s" "$HOST_BACKUP_EXCLUDES" "$RESTIC_CACHE_REPO" "$LOCK_DIR"' _ "$RUN/uncommented" 2>&1)" \
   && [[ "$out" == "/etc/pbo/restic-pass /etc/pbo/rest-pass /etc/pbo/rest-pass /etc/pbo/web-tls /etc/pbo/*.old-* "*"**/*.key|/var/cache/pbo/repo|/run/pbo" ]]; then
    ok "every commented line is a valid assignment once uncommented"
else bad "uncommented example: $out"; fi
$BIN config template --role janitor > "$RUN/tj" 2>/dev/null
# ... and each one on its own, as an admin follows the header and removes one #:
# in the installed file (everything else as shipped), and alone in a file (a
# minimal config, or the cluster-shared one, sourced before the local file that
# may set what it refers to). The config is sourced under set -u before
# set_defaults, so a bare ${REF} to a commented key aborts every pbo command.
# The value is the default the line claims to show.
one_by_one() {   # one_by_one <template>: problems, one per line; "N KEY=value" lines last
    local tpl="$1" ln line k a b n=0
    while IFS=: read -r ln line; do
        k="${line#\#}"; k="${k%%=*}"; n=$((n+1))
        printf '%s\n' "${line#\#}" > "$RUN/one.cfg"
        a="$(env -i bash --norc --noprofile -c 'set -u; source "$1" && printf "%s" "${!2}"' _ "$RUN/one.cfg" "$k" 2>&1)" \
            || { echo "$k alone: $a"; continue; }
        sed "${ln}s/^#//" "$tpl" > "$RUN/one-in.cfg"
        b="$(env -i bash --norc --noprofile -c 'set -u; source "$1" && printf "%s" "${!2}"' _ "$RUN/one-in.cfg" "$k" 2>&1)" \
            || { echo "$k in the file: $b"; continue; }
        [[ "$a" == "$b" ]] || echo "$k: alone [$a], in the file [$b]"
        printf 'V %s=%s\n' "$k" "$a"
    done < <(grep -nE '^#[A-Z][A-Z0-9_]*=' "$tpl")
    echo "N $n"
}
for tpl in etc/config.example "$RUN/tj"; do
    res="$(one_by_one "$tpl")"
    probs="$(grep -vE '^(V|N) ' <<<"$res")"
    n="$(sed -n 's/^N //p' <<<"$res")"
    # the shown value is the schema default (LOCK_DIR: the root one; template= keys write their own)
    probs+="$(grep '^V ' <<<"$res" | cut -c3- | S 'while IFS= read -r l; do k="${l%%=*}"; v="${l#*=}"
        [[ "$k" == LOCK_DIR && "$(id -u)" != 0 ]] && continue
        _cs_flag "$k" template >/dev/null && continue
        d="$(_cs_default "$k")"; [[ "$v" == "$d" ]] || echo "$k: the example shows [$v], the default is [$d]"; done')"
    [[ "$tpl" == etc/config.example ]] && { grep -q '^V HOST_BACKUP_EXCLUDES=/etc/pbo/restic-pass /etc/pbo/rest-pass ' <<<"$res" || probs+="HOST_BACKUP_EXCLUDES: $(grep '^V HOST_BACKUP_EXCLUDES' <<<"$res")"; }
    lbl="$(basename "$tpl")"; [[ "$tpl" == "$RUN/tj" ]] && lbl="janitor template"
    [[ -z "$probs" && "$n" -gt 10 ]] && ok "$lbl: each of the $n commented lines, uncommented on its own, is valid under set -u and shows the default" \
        || bad "$lbl one by one ($n lines): $probs"
done
out="$(S 'for k in "${CS_ORDER[@]}"; do _cs_flag "$k" internal >/dev/null && echo "$k"; done' | while read -r k; do grep -qE "^#?$k=" etc/config.example && printf '%s ' "$k"; done)"
[[ -z "$out" ]] && ok "no internal key in the example" || bad "internal keys in the example: $out"
grep -q '^PBO_ROLE=janitor ' "$RUN/tj" && ! grep -q '^#\?BACKUP_ORDER=' "$RUN/tj" \
    && ok "config template --role janitor: janitor keys, PBO_ROLE=janitor" || bad "janitor template: $(head -5 "$RUN/tj")"
# a janitor reads and prunes the offsite repo, never the default cache repo (ADR 0004):
# the janitor template sets the repo keys actively, like etc/config.janitor.example
out="$(grep -E '^(LOCAL_REPO|OFFSITE_ENABLED|RESTIC_PASSWORD_FILE)=' "$RUN/tj" | sed -E 's/[[:space:]]+#.*//' | tr '\n' ' ')"
grep -q '^RESTIC_OFFSITE_REPO=' "$RUN/tj" && [[ "$out" == "LOCAL_REPO=false OFFSITE_ENABLED=true RESTIC_PASSWORD_FILE=/etc/pbo/restic-pass " ]] \
    && ok "janitor template: LOCAL_REPO=false, OFFSITE_ENABLED=true, the repo and password file active" || bad "janitor template repo keys: $out"
# saved as the config with only the repo filled in, every repo pick is the offsite repo
sed -E "s|^RESTIC_OFFSITE_REPO=.*|RESTIC_OFFSITE_REPO=$RUN/jrepo|" "$RUN/tj" > "$RUN/tj.cfg"
out="$(env -i PATH="$PATH" bash -c 'set -u; source lib/common.sh; source lib/restic.sh; source "$1"; set_defaults
    printf "%s %s" "$(_restic_read_repo)" "$(_restic_write_repo)"' _ "$RUN/tj.cfg" 2>&1)"
[[ "$out" == "$RUN/jrepo $RUN/jrepo" ]] && ok "janitor template as the config: reads and writes the offsite repo, not the cache repo" || bad "janitor repo pick: $out"
$BIN config template --role web >/dev/null 2>&1; rc=$?
[[ $rc == 64 ]] && ok "config template --role <other>: exit 64" || bad "template bad role rc=$rc"

# the hand-written janitor example only uses keys the schema gives the janitor role
out="$(S 'for k in $(sed -nE "s/^#?([A-Z][A-Z0-9_]*)=.*/\1/p" etc/config.janitor.example | sort -u); do _cs_has_role "$k" janitor || printf "%s " "$k"; done')"
[[ -z "$out" ]] && ok "every key in etc/config.janitor.example is a janitor key in the schema" || bad "janitor example keys: $out"

# --- pbo config get / list / show ---------------------------------------------------------------
out="$($BIN config get LOCK_DIR 2>&1)"; [[ "$out" == "$RUN/lock" ]] && ok "config get LOCK_DIR: its value" || bad "get LOCK_DIR: $out"
out="$($BIN config get CATALOG_MOUNT_WAIT 2>&1)"; [[ "$out" == 7 ]] && ok "config get of an inline-only key set in the file" || bad "get CATALOG_MOUNT_WAIT: $out"
out="$($BIN config get CATALOG_LOCK_TIMEOUT 2>&1)"; [[ "$out" == 600 ]] && ok "config get of an unset inline-only key: its default" || bad "get CATALOG_LOCK_TIMEOUT: $out"
out="$($BIN config get TR_HISTORY 2>&1)"; [[ "$out" == "$RUN/state/restore-tests.jsonl" ]] && ok "config get: a derived default follows STATE_DIR" || bad "get TR_HISTORY: $out"
out="$($BIN config get NTFY_TOKEN 2>&1)"; [[ "$out" == "<set>" ]] && ok "config get of a set secret: <set>" || bad "get NTFY_TOKEN: $out"
out="$($BIN config get NTFY_TOPIC 2>&1)"; [[ "$out" == "<unset>" ]] && ok "config get of an unset secret: <unset>" || bad "get NTFY_TOPIC: $out"
out="$($BIN config get RESTIC_OFFSITE_REPO 2>&1)"; [[ "$out" == 'rest:https://***@backup.invalid:8000/pbo' ]] && ok "config get masks URL credentials" || bad "get repo: $out"
$BIN config get KEEP_OFSITE_DAILY >/dev/null 2>&1; rc=$?; [[ $rc == 64 ]] && ok "config get of an unknown key: exit 64" || bad "get unknown rc=$rc"
$BIN config get >/dev/null 2>&1; rc=$?; [[ $rc == 64 ]] && ok "config get without a key: exit 64" || bad "get no key rc=$rc"
out="$($BIN --json config get NTFY_TOKEN 2>/dev/null)"
jq -e '.ok and .key == "NTFY_TOKEN" and .secret and .set and .value == null and .type == "string" and .section == "notifications"' >/dev/null 2>&1 <<<"$out" \
    && ! grep -q tk_supersecret_value <<<"$out" && ok "config get --json: the key object, secret redacted" || bad "get --json: $out"
out="$($BIN --json config get PBO_INTEGRATION 2>/dev/null)"
jq -e '.value == "standalone" and .source == "default" and .managed_by == "integrate" and (.flags | index("advanced")) and .default == "standalone"' >/dev/null 2>&1 <<<"$out" \
    && ok "config get --json: managed_by, flags, default" || bad "get managed: $out"

out="$($BIN --json config list 2>/dev/null)"
jq -e '.ok and .command == "config" and (.keys|length) > 50
    and (.keys | map(.key) | index("JANITOR_USER") | not)
    and (.keys | map(.key) | index("PBO_CATALOG") | not)
    and any(.keys[]; .key == "PBO_PVE_LXC_DIR" and .source == "config")
    and any(.keys[]; .key == "KEEP_OFSITE_DAILY" and .secret and .set and .value == null and .known == false)
    and any(.keys[]; .key == "LOCK_DIR" and .secret == false and .value != null)' >/dev/null 2>&1 <<<"$out" \
    && ok "config list: no internal or janitor-only keys, but every key the file sets (unknown ones as secrets)" || bad "list: $(head -c 400 <<<"$out")"
out="$($BIN --json config list --all 2>/dev/null)"
jq -e 'any(.keys[]; .key == "JANITOR_USER") and any(.keys[]; .key == "PBO_CATALOG" and (.flags | index("internal")))' >/dev/null 2>&1 <<<"$out" \
    && ok "config list --all: internal and other-role keys too" || bad "list --all: $(head -c 300 <<<"$out")"
out="$($BIN config list 2>&1)"
# (column aligns with spaces; without it, tabs)
grep -qE '^KEY[[:space:]]+VALUE[[:space:]]+SOURCE[[:space:]]+TYPE' <<<"$out" && grep -qE '^NTFY_TOKEN[[:space:]]+<set>[[:space:]]+config' <<<"$out" \
    && grep -qE '^KEEP_OFSITE_DAILY[[:space:]]+<set>[[:space:]]+config[[:space:]]+unknown key' <<<"$out" \
    && ! grep -qE 'tk_supersecret_value|sftp_pw_123|hunter2pass' <<<"$out" && ok "config list: a readable table, secrets hidden" || bad "list human: $(head -5 <<<"$out")"
out="$($BIN config 2>&1)"
grep -qx "CACHE_DIR=$RUN/cache" <<<"$out" && grep -qx 'DOCTOR_MAX_AGE=172800   # default' <<<"$out" && grep -qx 'NTFY_TOKEN=<set>' <<<"$out" \
    && grep -qx 'KEEP_OFSITE_DAILY=<set>' <<<"$out" && ok "config (show): the 0.5 KEY=value format" || bad "show human: $(head -5 <<<"$out")"
cfg_jan="$RUN/jan.cfg"; printf 'PBO_ROLE=janitor\nJANITOR_USER=%s\nLOCAL_REPO=false\nCACHE_DIR=%s\nLOG_DIR=%s\nSTATE_DIR=%s\nLOCK_DIR=%s\nRESTIC_PASSWORD_FILE=%s\nNTFY_URL=\n' \
    "$(id -un)" "$RUN/cache" "$RUN/log" "$RUN/state" "$RUN/lock" "$RUN/pass" > "$cfg_jan"; chmod 600 "$cfg_jan"
out="$(PBO_JANITOR_ALLOW_ROOT=1 PBO_CONFIG="$cfg_jan" $BIN --json config list 2>/dev/null)"
jq -e '.role == "janitor" and any(.keys[]; .key == "JANITOR_USER") and (.keys | map(.key) | index("BACKUP_ORDER") | not)' >/dev/null 2>&1 <<<"$out" \
    && ok "config list on a janitor: the janitor keys" || bad "janitor list: $(head -c 300 <<<"$out")"

# cluster: load_config also reads /etc/pve/pbo/config (before the local file,
# which wins). Its keys are labelled shared, its unknown keys listed, and doctor
# names the unknown keys of each file but checks the effective values once. The
# two fixed paths are replaced by test files in _cfg_config_files (the list
# load_config reads), in this shell only; nothing reads the real ones.
printf 'KEEP_OFFSITE_DAILY=14\nCATALOG_MOUNT_WAIT=3\nKEEP_OFSITE_WEEKLY=2\nJANITOR_USER=nobody\nKEEP_LOCAL=x\n' > "$RUN/shared.cfg"; chmod 600 "$RUN/shared.cfg"
out="$(env -i PATH="$PATH" SHARED="$RUN/shared.cfg" LOCAL="$RUN/config" bash -c 'set -u; SELF_DIR="$PWD"
    source lib/common.sh; source lib/json.sh; source lib/config_schema.sh; source lib/config.sh
    source lib/config_parse.sh
    _cfg_config_files() { _CFG_FPATH=("$SHARED" "$LOCAL"); _CFG_FORIGIN=(shared local); }
    load_config
    [[ "$PBO_CONFIG_SHARED_LOADED" == "$SHARED" && "$PBO_CONFIG_LOADED" == "$LOCAL" && "$PBO_CONFIG_LOCAL" == "$LOCAL" && "${PBO_CONFIG_FILES[*]}" == "$SHARED $LOCAL" ]] \
        || echo "load_config: [$PBO_CONFIG_SHARED_LOADED] [$PBO_CONFIG_LOADED] [$PBO_CONFIG_LOCAL] [${PBO_CONFIG_FILES[*]}]"
    _config_envelope "$(_config_rows list)" > "$LOCAL.rows.json"
    _config_check "$PBO_CONFIG_LOADED" "$PBO_CONFIG_SHARED_LOADED"; printf "%s\n" "${CC_LINES[@]}" > "$LOCAL.cc"
    _config_check "$PBO_CONFIG_LOADED" "$PBO_CONFIG_LOADED"; printf "%s\n" "${CC_LINES[@]}" > "$LOCAL.cc-same"' 2>&1)"
jq -e --arg sf "$RUN/shared.cfg" '.shared_file == $sf
    and any(.keys[]; .key == "KEEP_OFFSITE_DAILY" and .value == "14" and .source == "shared")
    and any(.keys[]; .key == "CATALOG_MOUNT_WAIT" and .value == "7" and .source == "config")
    and any(.keys[]; .key == "KEEP_OFSITE_WEEKLY" and .known == false and .source == "shared")
    and any(.keys[]; .key == "KEEP_OFSITE_DAILY" and .known == false and .source == "config")
    and any(.keys[]; .key == "JANITOR_USER" and .source == "shared")
    and any(.keys[]; .key == "KEEP_OFFSITE_WEEKLY" and .source == "default")
    and ([.keys[].key] | length == (unique | length))' "$RUN/config.rows.json" >/dev/null 2>&1 && [[ -z "$out" ]] \
    && ok "cluster: keys from the shared config are labelled shared, the local file wins, unknown keys of both listed once" \
    || bad "cluster rows: $out $(head -c 400 "$RUN/config.rows.json" 2>/dev/null)"
grep -qx "unknown config key(s) in $RUN/config: KEEP_OFSITE_DAILY (typo? pbo ignores them)" "$RUN/config.cc" \
    && grep -qx "unknown config key(s) in $RUN/shared.cfg: KEEP_OFSITE_WEEKLY (typo? pbo ignores them)" "$RUN/config.cc" \
    && [[ "$(grep -c "KEEP_LOCAL='x' is not a whole number" "$RUN/config.cc")" == 1 && "$(grep -c 'unknown config key' "$RUN/config.cc-same")" == 1 ]] \
    && ok "cluster: doctor names the unknown keys of each file, checks the values once" || bad "cluster check: $(cat "$RUN/config.cc" "$RUN/config.cc-same" 2>&1)"

# config set|unset: tests/config_write.sh; here only the usage error
for sub in set unset; do
    out="$($BIN config $sub 2>&1)"; rc=$?
    [[ $rc == 64 ]] && grep -q "config $sub KEY" <<<"$out" && ok "config $sub without a key: usage (exit 64)" || bad "config $sub: rc=$rc $out"
done
out="$($BIN config frobnicate 2>&1)"; rc=$?
[[ $rc == 64 ]] && grep -q 'valid: show, list' <<<"$out" && ok "config <unknown>: exit 64 naming the valid subcommands" || bad "config bogus: rc=$rc $out"
$BIN config show --all >/dev/null 2>&1; rc=$?; [[ $rc == 64 ]] && ok "config show takes no arguments (64)" || bad "show --all rc=$rc"
out="$($BIN --json config frobnicate 2>/dev/null)"; rc=$?
[[ $rc == 64 ]] && jq -e '.ok == false and .exit == 64' >/dev/null 2>&1 <<<"$out" && ok "config usage error --json: the error object" || bad "json usage error: $out"

# --- doctor's config check -----------------------------------------------------------------------
cc() { env -i PATH="$PATH" "$@" bash -c 'set -u; SELF_DIR="$PWD"; source lib/common.sh; _config_check "$0"; (( ${#CC_LINES[@]} )) && printf "%s\n" "${CC_LINES[@]}"; echo "W=$CC_WARNS"' "$RUN/cc.conf"; }
printf 'KEEP_LOCAL=2\nNOTIFY_LEVEL=warn\n' > "$RUN/cc.conf"
out="$(cc KEEP_LOCAL=2 NOTIFY_LEVEL=warn)"; [[ "$out" == "W=0" ]] && ok "config check: a good config, no lines" || bad "check good: $out"
printf 'KEEP_OFSITE_DAILY=3\nKEEP_LOCAL=x\n' > "$RUN/cc.conf"
out="$(cc KEEP_LOCAL=x OFFSITE_ENABLED=yes)"
grep -q 'unknown config key(s) in .*cc.conf: KEEP_OFSITE_DAILY' <<<"$out" && grep -q "KEEP_LOCAL='x' is not a whole number" <<<"$out" \
    && grep -q "OFFSITE_ENABLED='yes' is not true|false" <<<"$out" && grep -q 'W=1' <<<"$out" \
    && ok "config check: unknown keys and every bad value's type named" || bad "check bad: $out"
out="$(cc NTFY_ON_SUCCESS=true)"; grep -qx 'NTFY_ON_SUCCESS is replaced by NOTIFY_LEVEL=fail|warn|all (still honoured: true means all)' <<<"$out" \
    && ok "config check: a deprecated key in use names its replacement" || bad "check deprecated: $out"
out="$(cc NTFY_ON_SUCCESS=true NOTIFY_LEVEL=all)"; ! grep -q 'replaced by' <<<"$out" && ok "config check: no deprecation note once the new key is set" || bad "check deprecated+new: $out"
out="$(cc PBO_CONFIG_VERSION=9)"; grep -q 'written for config schema 9, this pbo knows 1: upgrade pbo' <<<"$out" && ok "config check: a newer config schema" || bad "check version: $out"
out="$(cc NTFY_URL=not-a-url-secret)"; grep -q 'NTFY_URL is not a URL' <<<"$out" && ! grep -q not-a-url-secret <<<"$out" \
    && ok "config check: a bad secret is named, its value is not" || bad "check secret: $out"
# environment switches set in the file: 0.5 honoured them (it sourced the
# file), 0.6 ignores them: named as switches, not as typos
printf 'PBO_NO_NOTIFY=1\nPBO_REPO=cache\nTMPDIR=/var/tmp\n' > "$RUN/cc.conf"
out="$(cc)"; grep -qx "environment switch(es) in $RUN/cc.conf: PBO_NO_NOTIFY PBO_REPO TMPDIR (pbo 0.6 ignores them in the config: set them in pbo's environment)" <<<"$out" \
    && ! grep -q 'unknown config key' <<<"$out" && grep -qx 'W=1' <<<"$out" \
    && ok "config check: environment switches set in the file are named as ignored switches, not unknown keys" || bad "check env switches: $out"
printf 'PBO_NO_NOTIFY=1\nPBO_REPO=cache\nKEEP_OFSITE_DAILY=3\n' > "$RUN/cc.conf"
out="$(cc)"; grep -qx "unknown config key(s) in $RUN/cc.conf: KEEP_OFSITE_DAILY (typo? pbo ignores them)" <<<"$out" && grep -qx 'W=1' <<<"$out" \
    && ok "config check: a typo next to environment switches is still flagged, alone" || bad "check env switches + typo: $out"
printf 'VZDUMP_STOP_VMIDS="101 102"\n' > "$RUN/cc.conf"
out="$(cc VZDUMP_STOP_VMIDS='101 102')"; grep -q "VZDUMP_STOP_VMIDS='101 102' is not a comma-separated list of vmids: pbo splits it on commas only" <<<"$out" \
    && ok "config check: a space-separated VZDUMP_STOP_VMIDS is named with what pbo does" || bad "check stop vmids: $out"

# --- the file pbo writes: PBO_CONFIG_LOCAL, never the shared one -------------------------------------
# 0.5 bug: _cfg_set (setup, menu) and _integ_set_mode (integrate) wrote to
# PBO_CONFIG_LOADED, which names the cluster-shared /etc/pve/pbo/config when no
# local file exists yet: pmxcfs would have copied the value to every node.
printf 'KEEP_OFFSITE_DAILY=14\n' > "$RUN/w-shared.cfg"; chmod 600 "$RUN/w-shared.cfg"; rm -f "$RUN/w-local.cfg"
out="$(env -i PATH="$PATH" SHARED="$RUN/w-shared.cfg" LOCAL="$RUN/w-local.cfg" CACHE_DIR="$RUN/cache" STATE_DIR="$RUN/state" LOG_DIR="$RUN/log" LOCK_DIR="$RUN/lock" \
    bash -c 'set -u; SELF_DIR="$PWD"
    source lib/common.sh; source lib/config_parse.sh; source lib/menu.sh; source lib/integrate.sh
    _cfg_config_files() { _CFG_FPATH=("$SHARED" "$LOCAL"); _CFG_FORIGIN=(shared local); }
    _integration_mode() { printf standalone; }
    load_config
    echo "loaded=$PBO_CONFIG_LOADED local=$PBO_CONFIG_LOCAL"
    _cfg_set BACKUP_ORDER 101 && INTEG_STEPS=() && _integ_set_mode both >/dev/null' 2>&1)"
[[ "$out" == "loaded=$RUN/w-shared.cfg local=$RUN/w-local.cfg" && "$(cat "$RUN/w-shared.cfg")" == KEEP_OFFSITE_DAILY=14 ]] \
    && grep -qx 'BACKUP_ORDER=101' "$RUN/w-local.cfg" && grep -qx 'PBO_INTEGRATION=both' "$RUN/w-local.cfg" && [[ "$(stat -c %a "$RUN/w-local.cfg")" == 600 ]] \
    && ok "_cfg_set and _integ_set_mode write PBO_CONFIG_LOCAL (created 0600), never the shared file PBO_CONFIG_LOADED names" \
    || bad "writer target: $out; shared: $(cat "$RUN/w-shared.cfg"); local: $(cat "$RUN/w-local.cfg" 2>&1)"
out="$(PBO_CONFIG="$RUN/config" $BIN --json config list 2>/dev/null)"
jq -e --arg f "$RUN/config" '.local_file == $f and .file == $f' >/dev/null <<<"$out" && ok "config list: local_file names the file pbo writes" || bad "local_file: $(jq -c '{file, local_file}' <<<"$out")"

# --- the file rules load_config keeps (exec keys still name programs root runs) ---------------------
cp "$RUN/config" "$RUN/ww.cfg"; chmod 620 "$RUN/ww.cfg"
out="$(PBO_CONFIG="$RUN/ww.cfg" $BIN version 2>&1)"; rc=$?
[[ $rc == 78 && "$out" == "pbo: REFUSING to read a group-/world-writable config (620): $RUN/ww.cfg" ]] && ok "a group-writable config is refused (78)" || bad "group-writable: rc=$rc $out"
chmod 602 "$RUN/ww.cfg"; PBO_CONFIG="$RUN/ww.cfg" $BIN version >/dev/null 2>&1; rc=$?
[[ $rc == 78 ]] && ok "a world-writable config is refused (78)" || bad "world-writable: rc=$rc"
chmod 644 "$RUN/ww.cfg"; PBO_CONFIG="$RUN/ww.cfg" $BIN version >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ok "a config readable by others is read (it holds no secret by rule; keep it 0600 anyway)" || bad "0644: rc=$rc"
if [[ "$(id -u)" == 0 ]] && id nobody >/dev/null 2>&1; then
    chmod 600 "$RUN/ww.cfg"; chown nobody "$RUN/ww.cfg"
    out="$(PBO_CONFIG="$RUN/ww.cfg" $BIN version 2>&1)"; rc=$?
    [[ $rc == 78 && "$out" == "pbo: REFUSING to read a config owned by uid $(id -u nobody): $RUN/ww.cfg" ]] && ok "a config owned by another user is refused (78)" || bad "foreign owner: rc=$rc $out"
fi

# --- startup cost: the config is read on every start, the schema only as far as needed --------------
t="$(env -i PATH="$PATH" bash -c 'source lib/config_schema.sh; s=$EPOCHREALTIME; for i in 1 2 3 4 5 6 7 8 9 10; do _CS_LOADED=0 _CS_CORE=0; _cs_load; done; e=$EPOCHREALTIME; echo $(( (${e/./} - ${s/./}) / 10000 ))')"
[[ "$t" =~ ^[0-9]+$ ]] && (( t < 15 )) && ok "_cs_load takes ${t} ms (< 15)" || bad "_cs_load takes ${t} ms"
# the real entry point: parse_global_flags, load_config, audit, the role check.
# load_config needs the core of the table (_cs_core: keys, flags, defaults),
# only a command that shows or checks the schema loads the rest (config list
# proves the trace pattern matches)
# (without tests/all.sh's corpus hook, which compares every config with bash)
tr="$(env -u PBO_TEST_CONFIG_LOG bash -x $BIN version 2>&1 >/dev/null)"
n="$(grep -c '_cs_table$' <<<"$tr")"; l="$(grep -cE '^\++ _cs_load$' <<<"$tr")"
m="$(env -u PBO_TEST_CONFIG_LOG bash -x $BIN config list 2>&1 >/dev/null | grep -cE '^\++ _cs_load$')"
[[ "$n" == 1 && "$l" == 0 && "$m" -ge 1 ]] && ok "pbo version reads the table once and loads only its core (config list loads all of it)" \
    || bad "schema on the main path: _cs_table ran $n time(s), _cs_load $l time(s) for version, _cs_load $m for config list"
# load_config of a config with every key set (the slow end: each line read,
# each key assigned), best of 5 in a fresh shell each, the defaults included
sed -n 's/^#\([A-Z][A-Z0-9_]*=\)/\1/; /^[A-Z]/p' etc/config.example | grep -vE '^(CACHE_DIR|LOG_DIR|STATE_DIR|LOCK_DIR)=' > "$RUN/all.cfg"
printf 'CACHE_DIR=%s\nLOG_DIR=%s\nSTATE_DIR=%s\nLOCK_DIR=%s\n' "$RUN/cache" "$RUN/log" "$RUN/state" "$RUN/lock" >> "$RUN/all.cfg"; chmod 600 "$RUN/all.cfg"
t=999999
for i in 1 2 3 4 5; do
    c="$(env -i PATH="$PATH" PBO_CONFIG="$RUN/all.cfg" bash -c 'set -u; SELF_DIR="$PWD"; source lib/common.sh; source lib/config_schema.sh; source lib/config_parse.sh
        s=$EPOCHREALTIME; load_config; e=$EPOCHREALTIME; echo $(( ${e/./} - ${s/./} ))')"
    [[ "$c" =~ ^[0-9]+$ ]] && (( c < t )) && t="$c"
done
(( t < 120000 )) && ok "load_config of $(grep -c . "$RUN/all.cfg") active keys: $((t/1000)) ms (budget 120 ms)" \
    || bad "load_config of every key: $t us (budget 120 ms)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ -n "${KEEP_RUN:-}" ]] || rm -rf "$RUN"
(( fail == 0 ))
