#!/usr/bin/env bash
# tests/notify.sh: notification backends. ntfy and PVE::Notify are
# faked (curl, perl), nothing real is sent. The Proxmox path needs root (it
# queues into PVE's notification system), so those checks skip as non-root.
set -uo pipefail
unset PBO_NO_NOTIFY   # all.sh exports it; this suite tests notifications itself
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start),
# PBO_PVE_LXC_DIR and PBO_PVE_QEMU_DIR (a guest's current name, read for a
# snapshot that records none) are the machine's own files: point them into
# the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.env" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
    PBO_PVE_CFS_DIR="$PWD/run-none/pve" PVE_STORAGE_CFG="$PWD/run-none/pve/storage.cfg" \
    PBO_PVE_LXC_DIR="$PWD/run-none/pve/lxc" PBO_PVE_QEMU_DIR="$PWD/run-none/pve/qemu-server"
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
printf 'pbo: notification tests\n'
RUN="$ROOT/run-notify"; rm -rf "$RUN"; mkdir -p "$RUN"/{state,log,lock,cache,bin,tpl}
cat > "$RUN/bin/curl" <<'C'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_CURL_LOG"
# the token arrives on stdin (-K -): kept when a test asks for it
[[ -z "${MOCK_CURL_STDIN:-}" || " $* " != *" -K - "* ]] || cat >> "$MOCK_CURL_STDIN"
C
cat > "$RUN/bin/perl" <<'P'
#!/usr/bin/env bash
# "-MPVE::Notify -e 1" = availability probe; anything else = a send
if [[ "$*" == "-MPVE::Notify -e 1" ]]; then exit 0; fi
shift 3   # -MPVE::Notify -e <code>
[[ "$1" == "--" ]] && shift
printf '%s\n' "$@" > "$MOCK_PERL_ARGS"; echo sent >> "$MOCK_PERL_LOG"
P
chmod 755 "$RUN/bin/curl" "$RUN/bin/perl"
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm "$RUN/bin/"   # never the real host
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
export MOCK_CURL_LOG="$RUN/curl.log" MOCK_PERL_LOG="$RUN/perl.log" MOCK_PERL_ARGS="$RUN/perl.args"
export PATH="$RUN/bin:$PATH" PBO_PERL_BIN="$RUN/bin/perl" PBO_PVE_TEMPLATE_DIR="$RUN/tpl" NTFY_CREDS_FILE=/nonexistent
cp templates/pbo-*.hbs "$RUN/tpl/"
cfg() { { echo "CACHE_DIR=$RUN/cache"; echo "LOG_DIR=$RUN/log"; echo "STATE_DIR=$RUN/state"; echo "LOCK_DIR=$RUN/lock"
          echo "LOCAL_REPO=false"; echo "OFFSITE_ENABLED=false"; echo "BACKUP_ORDER=8001"
          echo "RESTIC_PASSWORD_FILE=$RUN/pass"; echo "RESTIC_CACHE_DIR=$RUN/rcache"; printf '%s\n' "$@"; } > "$RUN/config"; chmod 600 "$RUN/config"; }
export PBO_CONFIG="$RUN/config"
reset() { : > "$MOCK_CURL_LOG"; : > "$MOCK_PERL_LOG"; rm -f "$MOCK_PERL_ARGS"; }
sent_ntfy() { grep -c . "$MOCK_CURL_LOG"; }
sent_pve()  { grep -c . "$MOCK_PERL_LOG"; }

ROOTOK=0; [[ "$(id -u)" == 0 ]] && ROOTOK=1

# auto + ntfy configured → ntfy only (an existing ntfy setup is unchanged)
cfg "NTFY_URL=https://ntfy.invalid" "NTFY_TOPIC=t"; reset
$BIN notify-test >/dev/null 2>&1
[[ "$(sent_ntfy)" == 1 && "$(sent_pve)" == 0 ]] && ok "auto with ntfy configured: ntfy only" || bad "auto+ntfy: ntfy=$(sent_ntfy) pve=$(sent_pve)"

# PBO_NO_NOTIFY silences a real failure
reset; PBO_NO_NOTIFY=1 $BIN backup abc >/dev/null 2>&1
[[ "$(sent_ntfy)" == 0 ]] && ok "PBO_NO_NOTIFY=1 silences failures" || bad "kill switch"

if (( ROOTOK )); then
    # auto + no ntfy → Proxmox
    cfg; reset
    $BIN backup abc >/dev/null 2>&1
    [[ "$(sent_pve)" -ge 1 && "$(sent_ntfy)" == 0 ]] && ok "auto without ntfy: failure goes to Proxmox notifications" || bad "auto-pve: ntfy=$(sent_ntfy) pve=$(sent_pve)"
    [[ "$(sed -n 1p "$MOCK_PERL_ARGS")" == error && "$(sed -n 2p "$MOCK_PERL_ARGS")" == "pbo: FAILURE" ]] && ok "failure sent as severity error" || bad "pve args: $(cat "$MOCK_PERL_ARGS")"
    # hostile message reaches perl as data, not code
    reset; $BIN backup 'x$(touch '"$RUN"'/pwned)"' >/dev/null 2>&1
    [[ ! -e "$RUN/pwned" ]] && grep -q 'x\$(touch' "$MOCK_PERL_ARGS" && ok "message passed to perl as an argument, not interpolated" || bad "injection: $(cat "$MOCK_PERL_ARGS" 2>/dev/null)"
    # true → both
    cfg "NOTIFY_PVE=true" "NTFY_URL=https://ntfy.invalid" "NTFY_TOPIC=t"; reset
    out="$($BIN --json notify-test 2>/dev/null)"
    [[ "$(sent_ntfy)" == 1 && "$(sent_pve)" == 1 ]] && ok "NOTIFY_PVE=true: both backends" || bad "true: ntfy=$(sent_ntfy) pve=$(sent_pve)"
    [[ "$(jq -r .backends <<<"$out")" == "ntfy proxmox" ]] && ok "notify-test reports the backends used" || bad "notify-test json: $out"
    [[ "$(sed -n 1p "$MOCK_PERL_ARGS")" == warning ]] && ok "notify-test is a warning" || bad "test severity"
    # templates missing → not sent, warned
    rm -f "$RUN/tpl/"*; cfg; reset
    out="$($BIN notify-test 2>&1)"
    [[ "$(sent_pve)" == 0 ]] && grep -q 'templates missing' <<<"$out" && ok "missing templates: warn instead of sending a broken notification" || bad "no templates: $out"
    out="$($BIN doctor 2>&1)"
    grep -q 'WARN.*templates missing' <<<"$out" && ok "doctor flags missing templates" || bad "doctor templates: $out"
    cp templates/pbo-*.hbs "$RUN/tpl/"
    out="$($BIN doctor 2>&1)"
    grep -q 'OK  alerts via proxmox' <<<"$out" && ok "doctor: alerts via proxmox" || bad "doctor alerts: $out"
fi

# NOTIFY_LEVEL: what each level lets through (ntfy backend, faked curl)
send() {   # send <NOTIFY_LEVEL> <NTFY_ON_SUCCESS> <notify_fn> → number of ntfy posts
    reset
    NOTIFY_LEVEL="$1" NTFY_ON_SUCCESS="$2" NTFY_URL=https://ntfy.invalid NTFY_TOPIC=t NOTIFY_PVE=false \
        bash -c 'source lib/common.sh; source lib/notify.sh; '"$3"' "level test"' >/dev/null 2>&1
    sent_ntfy
}
lv() { printf '%s%s%s' "$(send "$1" "$2" notify_failure)" "$(send "$1" "$2" notify_warning)" "$(send "$1" "$2" notify_success)"; }
[[ "$(lv fail false)" == 100 ]] && ok "NOTIFY_LEVEL=fail: failures only" || bad "fail: $(lv fail false)"
[[ "$(lv warn false)" == 110 ]] && ok "NOTIFY_LEVEL=warn: failures + warnings" || bad "warn: $(lv warn false)"
[[ "$(lv all false)" == 111 ]] && ok "NOTIFY_LEVEL=all: everything" || bad "all: $(lv all false)"
[[ "$(lv "" false)" == 100 ]] && ok "unset: failures only (the default)" || bad "default: $(lv "" false)"
[[ "$(lv "" true)" == 111 ]] && ok "NTFY_ON_SUCCESS=true without NOTIFY_LEVEL still means all" || bad "compat: $(lv "" true)"
[[ "$(lv fail true)" == 100 ]] && ok "NOTIFY_LEVEL wins over NTFY_ON_SUCCESS" || bad "precedence: $(lv fail true)"
[[ "$(lv bogus false)" == 100 ]] && ok "unknown level falls back to failures only" || bad "bogus: $(lv bogus false)"
cfg "NTFY_URL=https://ntfy.invalid" "NTFY_TOPIC=t" "NOTIFY_LEVEL=warn"; reset
out="$($BIN --json notify-test 2>/dev/null)"
jq -e '.ok and .level == "warn"' >/dev/null 2>&1 <<<"$out" && ok "notify-test reports the level" || bad "notify-test level: $out"
cfg "NTFY_URL=https://ntfy.invalid" "NTFY_TOPIC=t" "NOTIFY_LEVEL=loud"
out="$($BIN doctor 2>&1)"; grep -q "WARN.*NOTIFY_LEVEL='loud' is not fail|warn|all" <<<"$out" && ok "doctor warns on an unknown NOTIFY_LEVEL" || bad "doctor bogus level"
cfg "NTFY_URL=https://ntfy.invalid" "NTFY_TOPIC=t" "NTFY_ON_SUCCESS=true"
out="$($BIN doctor 2>&1)"; grep -q "WARN.*NTFY_ON_SUCCESS is replaced by NOTIFY_LEVEL" <<<"$out" && ok "doctor suggests NOTIFY_LEVEL for NTFY_ON_SUCCESS=true" || bad "doctor compat hint"

# false + no ntfy → nothing active
cfg "NOTIFY_PVE=false"; reset
$BIN notify-test >/dev/null 2>&1; rc=$?
[[ $rc == 69 && "$(sent_ntfy)" == 0 && "$(sent_pve)" == 0 ]] && ok "no backend: notify-test fails (EX_UNAVAILABLE), sends nothing" || bad "none: rc=$rc"
out="$($BIN doctor 2>&1)"
grep -q 'WARN.*no alerting' <<<"$out" && ok "doctor warns when nothing would alert" || bad "doctor no-alert: $out"

# --- NTFY_CREDS_FILE: ntfy settings outside the config (lib/notify.sh) ----------------------
# pbo runs as a copy of the entry point that sources tests/fixtures/run_dir_guard.sh:
# it stops (99) before any command when a path it resolved lies outside $RUN.
# TEST_GUARD_DEFAULTS moves the schema default of NTFY_CREDS_FILE into $RUN for
# the tests that leave it unset (an empty value is the default).
if [[ "$(tail -n 1 pbo)" != 'main "$@"' ]]; then
    bad "the entry point no longer ends in main \"\$@\": the harness needs a new hook"
    printf '%s passed, %s failed\n' "$pass" "$fail"; exit 1
fi
mkdir -p "$RUN"/{tree,etc,shared,pve,lxc,qemu,none,mnt,units,tmp}; chmod 0700 "$RUN/mnt"
{ sed '$d' pbo; printf '%s\n' 'source "$SELF_DIR/../../tests/fixtures/run_dir_guard.sh"'; tail -n 1 pbo; } > "$RUN/tree/pbo"
chmod 755 "$RUN/tree/pbo"; ln -s "$ROOT/lib" "$RUN/tree/lib"
# the mocks without the fake perl above (PBO_PERL_BIN still names it): doctor
# --fix changes modes through the real perl (lib/perms.sh _perm_fdop)
mkdir -p "$RUN/gbin"; cp "$RUN/bin/curl" "$RUN/gbin/"
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm tests/mocks/systemctl "$RUN/gbin/"
printf '#!/usr/bin/env bash\nfor a; do [[ "$a" == version ]] && { echo "restic 0.18.0"; exit 0; }; done\ncase " $* " in *" snapshots "*) echo "[]" ;; esac\nexit 0\n' > "$RUN/gbin/restic-fake"
chmod 755 "$RUN/gbin/restic-fake"
gpath="$RUN/gbin:${PATH#"$RUN/bin:"}"
gbin="$RUN/tree/pbo"
ccfg() {   # ccfg <extra lines...>: the config of these tests, every path in $RUN
    { printf '%s\n' "CACHE_DIR=$RUN/cache" "LOG_DIR=$RUN/log" "STATE_DIR=$RUN/state" "LOCK_DIR=$RUN/lock" \
        "LOCAL_REPO=false" "OFFSITE_ENABLED=false" "BACKUP_ORDER=8001" "STORAGE_BOX_SNAPSHOTS_CONFIRMED=true" \
        "RESTIC_PASSWORD_FILE=$RUN/pass" "RESTIC_CACHE_DIR=$RUN/rcache" "RESTIC_BIN=$RUN/gbin/restic-fake" \
        "RESTIC_ENV_FILE=$RUN/none/restic.env" "NOTIFY_PVE=false" "PBO_PVE_LXC_DIR=$RUN/lxc" "PBO_PVE_QEMU_DIR=$RUN/qemu" \
        "PBO_PVE_CFS_DIR=$RUN/pve" "PVE_STORAGE_CFG=$RUN/storage.cfg" "PBO_PVE_STORAGE_CFG=$RUN/storage.cfg" \
        "VZDUMP_CONF=$RUN/vzdump.conf" "VZDUMP_LOCK=$RUN/vzdump.lock" "PBO_CATALOG=$RUN/state/catalog/index.json" \
        "PVE_CATALOG_MOUNT_DIR=$RUN/mnt/restic" "PBO_PERMS_PARENTS_TOP=$RUN" "PBO_PERMS_CONFIG_DIR=$RUN" "PBO_SYSTEMD_DIR=$RUN/units"
      printf '%s\n' "$@"; } > "$RUN/config"; chmod 600 "$RUN/config"
}
# G <args>: the guarded pbo, every path in $RUN; output (both streams) in $out.
# The suite exports NTFY_CREDS_FILE=/nonexistent: a test that wants it unset
# passes NTFY_CREDS_FILE='' (empty is the default) together with the default's
# move into $RUN.
G() { out="$(PATH="$gpath" TEST_RUN="$RUN" MOCK_LOG="$RUN/sd.log" \
        TMPDIR="$RUN/tmp" "$gbin" "$@" 2>&1)"; rc=$?; }
ndef="NTFY_CREDS_FILE=$RUN/etc/ntfy.env"   # TEST_GUARD_DEFAULTS: the default, moved into $RUN
posted() { grep -c -- "$1" "$MOCK_CURL_LOG"; }   # posted <url>: ntfy posts to it
# every value these files hold that must never reach pbo's output or logs
secrets='tk_creds_default_1 topic-default-s3cr3t ntfy-default.invalid tk_creds_shared_2 alerts-s3cr3t-topic other-tool-topic ntfy-shared.invalid tk_leak_value_3 topic-leak-4'
leaks() {   # leaks <text>: the secrets found in it and in pbo's logs
    local s; for s in $secrets; do grep -qF -- "$s" <<<"$1" && printf '%s(output) ' "$s"; grep -rqF -- "$s" "$RUN/log" 2>/dev/null && printf '%s(log) ' "$s"; done
}

# the harness: the schema default of NTFY_CREDS_FILE is the host's own path
ccfg; reset
# out of the corpus log (tests/all.sh): this run resolves the default outside
# the run directory on purpose, and the guard stops pbo only after load_config
# logged it (tests/config_parse.sh --corpus fails a secret file at its default)
out="$(env -u PBO_TEST_CONFIG_LOG NTFY_CREDS_FILE='' PATH="$gpath" TEST_RUN="$RUN" "$gbin" config get NTFY_CREDS_FILE 2>&1)"; rc=$?
[[ $rc == 99 && "$out" == *"NTFY_CREDS_FILE=/etc/pbo/ntfy.creds is outside"* ]] \
    && ok "harness: NTFY_CREDS_FILE left at its default stops the guarded pbo (99)" || bad "guard default: rc=$rc $out"
NTFY_CREDS_FILE='' TEST_GUARD_DEFAULTS="$ndef" G config get NTFY_CREDS_FILE
[[ $rc == 0 && "$out" == "$RUN/etc/ntfy.env" ]] && ok "harness: TEST_GUARD_DEFAULTS moves the default into the run directory" || bad "guard defaults: rc=$rc $out"

# the default path: NTFY_URL, NTFY_TOKEN and NTFY_TOPIC from the file, nothing in the config
printf '%s\n' '# ntfy for pbo' 'NTFY_URL=https://ntfy-default.invalid' 'NTFY_TOKEN="tk_creds_default_1"' "NTFY_TOPIC='topic-default-s3cr3t'" > "$RUN/etc/ntfy.env"
chmod 600 "$RUN/etc/ntfy.env"
ccfg; reset; : > "$RUN/curl.stdin"
NTFY_CREDS_FILE='' TEST_GUARD_DEFAULTS="$ndef" MOCK_CURL_STDIN="$RUN/curl.stdin" G notify-test
[[ $rc == 0 && "$(posted 'https://ntfy-default.invalid/topic-default-s3cr3t')" == 1 ]] && grep -q 'Bearer tk_creds_default_1' "$RUN/curl.stdin" \
    && ok "default path: url, token and topic come from NTFY_CREDS_FILE" || bad "default creds: rc=$rc $out $(cat "$MOCK_CURL_LOG")"
l1="$(leaks "$out")"
NTFY_CREDS_FILE='' TEST_GUARD_DEFAULTS="$ndef" G doctor
[[ "$out" == *"OK  alerts via ntfy"* && "$out" != *"ntfy: "* ]] && ok "doctor: a complete default file gives ntfy alerts and no ntfy finding" || bad "doctor default: $out"
l1+="$(leaks "$out")"
NTFY_CREDS_FILE='' TEST_GUARD_DEFAULTS="$ndef" G --json config show
l1+="$(leaks "$out")"
[[ -z "$l1" ]] && ok "the file's values appear in no output (notify-test, doctor, config show) and no log" || bad "leaked: $l1"
# the config wins over the file, key by key: each of the three it sets, and
# what it leaves empty still comes from the file
ccfg "NTFY_URL=https://ntfy-cfg.invalid" "NTFY_TOKEN=tk_cfg_token_5" "NTFY_TOPIC=cfg-topic"; reset; : > "$RUN/curl.stdin"
NTFY_CREDS_FILE='' TEST_GUARD_DEFAULTS="$ndef" MOCK_CURL_STDIN="$RUN/curl.stdin" G notify-test
[[ "$(posted 'https://ntfy-cfg.invalid/cfg-topic')" == 1 && "$(posted ntfy-default.invalid)" == 0 ]] && grep -q 'Bearer tk_cfg_token_5' "$RUN/curl.stdin" \
    && ! grep -q tk_creds_default_1 "$RUN/curl.stdin" && ok "each key the config sets (url, token, topic) wins over the file" \
    || bad "config wins: $(cat "$MOCK_CURL_LOG") $(cat "$RUN/curl.stdin")"
ccfg "NTFY_TOPIC=cfg-topic"; reset; : > "$RUN/curl.stdin"
NTFY_CREDS_FILE='' TEST_GUARD_DEFAULTS="$ndef" MOCK_CURL_STDIN="$RUN/curl.stdin" G notify-test
[[ "$(posted 'https://ntfy-default.invalid/cfg-topic')" == 1 ]] && grep -q 'Bearer tk_creds_default_1' "$RUN/curl.stdin" \
    && ok "the keys the config leaves empty (url, token) still come from the file" || bad "config topic only: $(cat "$MOCK_CURL_LOG")"

# a custom path and topic key: a file shared with other tools, its topic under a key of its own
printf '%s\n' '# shared with other tools' 'export NTFY_URL="https://ntfy-shared.invalid"' 'NTFY_TOKEN=tk_creds_shared_2' \
    'NTFY_TOPIC=other-tool-topic' 'NTFY_TOPIC_ALERTS="alerts-s3cr3t-topic"   # pbo and the others' 'OTHER_TOOL_RETRIES=3' > "$RUN/shared/ntfy.env"
chmod 640 "$RUN/shared/ntfy.env"
ccfg "NTFY_CREDS_FILE=$RUN/shared/ntfy.env" "NTFY_CREDS_TOPIC_KEY=NTFY_TOPIC_ALERTS"; reset
G notify-test
[[ $rc == 0 && "$(posted 'https://ntfy-shared.invalid/alerts-s3cr3t-topic')" == 1 && "$(posted other-tool-topic)" == 0 ]] \
    && ok "custom path + NTFY_CREDS_TOPIC_KEY: the topic comes from the key it names" || bad "topic key: rc=$rc $out $(cat "$MOCK_CURL_LOG")"
l2="$(leaks "$out")"; G doctor; l2+="$(leaks "$out")"
[[ "$out" == *"OK  alerts via ntfy"* && "$out" != *"ntfy: "* && -z "$l2" ]] \
    && ok "doctor: the shared file (0640, export, other keys) is fine, nothing of it is printed" || bad "doctor shared: $l2 $out"
G config check
[[ $rc == 0 ]] && ok "config check accepts NTFY_CREDS_TOPIC_KEY" || bad "config check topic key: rc=$rc $out"
ccfg "NTFY_CREDS_FILE=$RUN/shared/ntfy.env" "NTFY_CREDS_TOPIC_KEY=NTFY-TOPIC"
G config check
[[ "$out" == *"NTFY_CREDS_TOPIC_KEY='NTFY-TOPIC' is not a variable name"* ]] && ok "config check names a topic key that is no variable name" || bad "bad topic key: rc=$rc $out"
G doctor
[[ "$out" == *"WARN  NTFY_CREDS_TOPIC_KEY='NTFY-TOPIC' is not a variable name"* && "$out" == *"WARN  ntfy: NTFY_CREDS_FILE is not used: $RUN/shared/ntfy.env:0: NTFY_CREDS_TOPIC_KEY is not a variable name"* ]] \
    && ok "doctor: a bad topic key is named, and the file is not used" || bad "doctor bad topic key: $out"

# a missing key: the file has no topic under the key the config names
ccfg "NTFY_CREDS_FILE=$RUN/shared/ntfy.env" "NTFY_CREDS_TOPIC_KEY=NTFY_TOPIC_PBO"; reset
G notify-test
[[ $rc == 69 && "$(sent_ntfy)" == 0 ]] && ok "missing topic key: ntfy is not configured, nothing sent" || bad "missing key notify-test: rc=$rc $out"
G doctor
grep -q "WARN  ntfy: $RUN/shared/ntfy.env sets no NTFY_TOPIC_PBO, and neither does the config" <<<"$out" && [[ -z "$(leaks "$out")" ]] \
    && ok "doctor names the missing key (not a value)" || bad "doctor missing key: $out"
printf '%s\n' 'NTFY_TOKEN=tk_creds_shared_2' 'NTFY_TOPIC_ALERTS=alerts-s3cr3t-topic' > "$RUN/shared/nourl.env"; chmod 600 "$RUN/shared/nourl.env"
ccfg "NTFY_CREDS_FILE=$RUN/shared/nourl.env"
G doctor
grep -q "WARN  ntfy: $RUN/shared/nourl.env sets no NTFY_URL NTFY_TOPIC, and neither does the config: no ntfy alerts; a file whose topic key has another name needs NTFY_CREDS_TOPIC_KEY" <<<"$out" \
    && ok "doctor: no URL and no NTFY_TOPIC, with the hint to NTFY_CREDS_TOPIC_KEY" || bad "doctor missing url+topic: $out"
ccfg "NTFY_CREDS_FILE=$RUN/shared/nourl.env" "NTFY_URL=https://ntfy.invalid" "NTFY_TOPIC=t"
G doctor
[[ "$out" != *"ntfy: "* ]] && ok "doctor: keys the config sets need no line in the file" || bad "doctor config covers: $out"

# shell code is refused, never run: the whole file is left unused
printf '%s\n' 'NTFY_URL=https://ntfy-shared.invalid' "NTFY_TOPIC=\$(touch $RUN/pwned)" 'NTFY_TOKEN=tk_leak_value_3 more' "source $RUN/pwned-too" > "$RUN/shared/code.env"
chmod 600 "$RUN/shared/code.env"
ccfg "NTFY_CREDS_FILE=$RUN/shared/code.env"; reset
G notify-test
[[ $rc == 69 && "$(sent_ntfy)" == 0 && ! -e "$RUN/pwned" ]] && grep -q "WARN.*notify: NTFY_CREDS_FILE is not used: $RUN/shared/code.env:2: command substitution" <<<"$out" \
    && ok "shell code in the file: refused (nothing run, nothing sent), notify-test says why" || bad "code file notify-test: rc=$rc $out"
l3="$(leaks "$out")"
G doctor
grep -q "WARN  ntfy: NTFY_CREDS_FILE is not used: $RUN/shared/code.env:2: command substitution .* (and 2 more)" <<<"$out" && [[ ! -e "$RUN/pwned" ]] \
    && ok "doctor: a file the strict reader refuses is not used, with the first reason" || bad "doctor code file: $out"
l3+="$(leaks "$out")"
# only the backup's own log lines: notify-test above logged the same reason.
# The lines dropped here were scanned by the leaks calls above.
: > "$RUN/log/pbo.log"; G backup 8001; l3+="$(leaks "$out")"
[[ -z "$l3" && $rc != 0 ]] && grep -q 'notify: NTFY_CREDS_FILE is not used' "$RUN/log/pbo.log" \
    && ok "a refused file: its values in no message, the reason in the run's log" || bad "code file leaks: rc=$rc $l3 $(cat "$RUN/log/pbo.log")"

# the config sets the server and topic, the token is kept in a file the
# reader refuses: the alert goes out without it, and the failing run's log
# says why (the server's refusal of that post is not reported)
printf '%s\n' 'NTFY_TOKEN=tk_leak_value_3' "source $RUN/shared/more.env" > "$RUN/shared/token.env"; chmod 600 "$RUN/shared/token.env"
ccfg "NTFY_CREDS_FILE=$RUN/shared/token.env" "NTFY_URL=https://ntfy-cfg.invalid" "NTFY_TOPIC=cfg-topic"; reset; : > "$RUN/curl.stdin"
: > "$RUN/log/pbo.log"; MOCK_CURL_STDIN="$RUN/curl.stdin" G backup 8001; l6="$(leaks "$out")"
[[ $rc != 0 && "$(posted 'https://ntfy-cfg.invalid/cfg-topic')" -ge 1 && ! -s "$RUN/curl.stdin" && -z "$l6" ]] \
    && grep -q "WARN.*notify: NTFY_CREDS_FILE is not used: $RUN/shared/token.env:2: source" "$RUN/log/pbo.log" \
    && ok "a refused file that holds only the token: the alert goes out without it, the run's log says why" \
    || bad "token-only refused file: rc=$rc $l6 $(cat "$MOCK_CURL_LOG") / $(cat "$RUN/log/pbo.log")"
# ... and a configured ntfy without a token and without a file logs nothing about it
ccfg "NTFY_CREDS_FILE=$RUN/none/ntfy.env" "NTFY_URL=https://ntfy-cfg.invalid" "NTFY_TOPIC=cfg-topic"; reset
: > "$RUN/log/pbo.log"; G backup 8001
[[ $rc != 0 && "$(posted 'https://ntfy-cfg.invalid/cfg-topic')" -ge 1 ]] && ! grep -q NTFY_CREDS_FILE "$RUN/log/pbo.log" \
    && ok "... no token and no file: no line about the file" || bad "no token, no file: rc=$rc $(cat "$RUN/log/pbo.log")"

# a file shared in systemd EnvironmentFile / docker env-file form: another
# tool's value with an unquoted space is skipped with a warning, the file
# stays in use; the same error on a line pbo reads, or a quote that runs on,
# still leaves the file unused
printf '%s\n' 'NTFY_URL=https://ntfy-shared.invalid' 'NTFY_TOPIC=alerts-s3cr3t-topic' 'OTHER_TOOL_TITLE=Nightly report' > "$RUN/shared/spaces.env"
chmod 600 "$RUN/shared/spaces.env"
ccfg "NTFY_CREDS_FILE=$RUN/shared/spaces.env"; reset
G notify-test; l7="$(leaks "$out")"
[[ $rc == 0 && "$(posted 'https://ntfy-shared.invalid/alerts-s3cr3t-topic')" == 1 ]] \
    && ok "an unquoted space in another tool's line: the file is still used" || bad "spaces notify-test: rc=$rc $out $(cat "$MOCK_CURL_LOG")"
G doctor; l7+="$(leaks "$out")"
[[ "$(grep -c 'WARN  ntfy: ' <<<"$out")" == 1 && "$out" == *"WARN  ntfy: $RUN/shared/spaces.env:3: a space ends the value"*"(pbo does not read OTHER_TOOL_TITLE: the line is skipped)"* \
   && "$out" != *"is not used"* && "$out" == *"OK  alerts via ntfy"* && -z "$l7" ]] \
    && ok "... doctor: one warning, naming the line and the key it skips" || bad "spaces doctor: $l7 $out"
printf '%s\n' 'NTFY_URL=https://ntfy-shared.invalid' 'NTFY_TOPIC=alerts-s3cr3t-topic' 'NTFY_TOKEN=tk_creds_shared_2 extra' > "$RUN/shared/tokspace.env"
chmod 600 "$RUN/shared/tokspace.env"
ccfg "NTFY_CREDS_FILE=$RUN/shared/tokspace.env"; reset
G doctor; l7+="$(leaks "$out")"; h1="$out"
G notify-test; l7+="$(leaks "$out")"
[[ "$h1" == *"WARN  ntfy: NTFY_CREDS_FILE is not used: $RUN/shared/tokspace.env:3: a space ends the value"* && $rc == 69 && "$(sent_ntfy)" == 0 ]] \
    && ok "... the same error on the NTFY_TOKEN line: the file is not used" || bad "token space: rc=$rc $h1"
printf '%s\n' 'OTHER_TOOL_NOTE="runs on' 'NTFY_URL=https://ntfy-shared.invalid' 'NTFY_TOPIC=alerts-s3cr3t-topic' > "$RUN/shared/runon.env"
chmod 600 "$RUN/shared/runon.env"
ccfg "NTFY_CREDS_FILE=$RUN/shared/runon.env"; reset
G doctor; l7+="$(leaks "$out")"; h1="$out"
G notify-test; l7+="$(leaks "$out")"
[[ "$h1" == *"WARN  ntfy: NTFY_CREDS_FILE is not used: $RUN/shared/runon.env:1: unterminated double quote"* && $rc == 69 && "$(sent_ntfy)" == 0 ]] \
    && ok "... an open quote on another key's line (it may hide the lines below): the file is not used" || bad "run-on quote: rc=$rc $h1"
[[ -z "$l7" ]] && ok "... no value of those files printed or logged" || bad "spaces leaks: $l7"
# a URL without a scheme: a warning, as in the config, and the file stays in
# use (curl assumes http://, as 0.5 sent with it)
printf '%s\n' 'NTFY_URL=ntfy-shared.invalid/topic-leak-4' 'NTFY_TOKEN=tk_leak_value_3' 'NTFY_TOPIC=topic-leak-4' > "$RUN/shared/badurl.env"; chmod 600 "$RUN/shared/badurl.env"
ccfg "NTFY_CREDS_FILE=$RUN/shared/badurl.env"; reset; : > "$RUN/curl.stdin"
G doctor; l4="$(leaks "$out")"
grep -q "WARN  ntfy: $RUN/shared/badurl.env:1: NTFY_URL is not a URL" <<<"$out" && [[ "$out" != *"is not used"* && "$out" == *"OK  alerts via ntfy"* ]] \
    && ok "a URL without a scheme in the file: a doctor warning, the file still used" || bad "bad url doctor: $out"
# once, from the file: the config check must not report the file's URL as the
# config's (it sets none), with or without PBO_NO_NOTIFY
[[ "$(grep -c 'is not a URL' <<<"$out")" == 1 ]] && ! grep -q '^  WARN  NTFY_URL is not a URL' <<<"$out" \
    && ok "... reported once, with the file's line, not as a config value" || bad "bad url twice: $out"
PBO_NO_NOTIFY=1 G doctor; l4+="$(leaks "$out")"
[[ "$(grep -c 'is not a URL' <<<"$out")" == 1 ]] && grep -q "WARN  ntfy: $RUN/shared/badurl.env:1: NTFY_URL is not a URL" <<<"$out" \
    && ok "... the same single line under PBO_NO_NOTIFY=1" || bad "bad url, PBO_NO_NOTIFY: $out"
# the config's own URL wins: the file's is not used, so doctor says nothing of it
ccfg "NTFY_CREDS_FILE=$RUN/shared/badurl.env" "NTFY_URL=https://ntfy.invalid"
G doctor; l4+="$(leaks "$out")"
[[ "$out" != *"is not a URL"* && "$out" == *"OK  alerts via ntfy"* ]] \
    && ok "... no warning about the file's URL when the config sets NTFY_URL" || bad "bad url overridden: $out"
ccfg "NTFY_CREDS_FILE=$RUN/shared/badurl.env"
MOCK_CURL_STDIN="$RUN/curl.stdin" G notify-test; l4+="$(leaks "$out")"
[[ $rc == 0 && "$(posted 'ntfy-shared.invalid/topic-leak-4/topic-leak-4')" == 1 ]] && grep -q 'Bearer tk_leak_value_3' "$RUN/curl.stdin" \
    && ok "... its topic and token are still used" || bad "bad url notify-test: rc=$rc $out $(cat "$MOCK_CURL_LOG")"
[[ -z "$l4" ]] && ok "... and no value of it is printed or logged" || bad "bad url leaks: $l4"

# a file whose topic is under another key than NTFY_TOPIC, with no
# NTFY_CREDS_TOPIC_KEY in the config: no alerts, and doctor names the key
# that points pbo at it
printf '%s\n' 'NTFY_URL=https://ntfy-shared.invalid' 'NTFY_TOKEN=tk_creds_shared_2' 'NTFY_TOPIC_ALERTS=alerts-s3cr3t-topic' > "$RUN/shared/alerts.env"
chmod 600 "$RUN/shared/alerts.env"
ccfg "NTFY_CREDS_FILE=$RUN/shared/alerts.env"; reset
G doctor; l5="$(leaks "$out")"
grep -qF "WARN  ntfy: $RUN/shared/alerts.env sets no NTFY_TOPIC, and neither does the config: no ntfy alerts; a file whose topic key has another name needs NTFY_CREDS_TOPIC_KEY=<that key>" <<<"$out" \
    && ok "doctor: a file without NTFY_TOPIC points at NTFY_CREDS_TOPIC_KEY" || bad "doctor other topic key: $out"
G notify-test; l5+="$(leaks "$out")"
[[ $rc == 69 && "$(sent_ntfy)" == 0 ]] && ok "... and nothing is sent" || bad "other topic key notify-test: rc=$rc $out"
ccfg "NTFY_CREDS_FILE=$RUN/shared/alerts.env" "NTFY_CREDS_TOPIC_KEY=NTFY_TOPIC_ALERTS"; reset
G doctor; l5+="$(leaks "$out")"; h1="$out"
G notify-test; l5+="$(leaks "$out")"
[[ "$h1" != *"ntfy: "* && $rc == 0 && "$(posted 'https://ntfy-shared.invalid/alerts-s3cr3t-topic')" == 1 ]] \
    && ok "... NTFY_CREDS_TOPIC_KEY names that key: no warning, alerts go to its topic" || bad "other topic key set: $h1 $(cat "$MOCK_CURL_LOG")"
[[ -z "$l5" ]] && ok "... no value of the file printed or logged" || bad "other topic key leaks: $l5"

# the mode: 0600, or 0640 for a file shared through its group (the permission rule)
for m in 600 640 644 660; do
    chmod "$m" "$RUN/shared/ntfy.env"
    ccfg "NTFY_CREDS_FILE=$RUN/shared/ntfy.env" "NTFY_CREDS_TOPIC_KEY=NTFY_TOPIC_ALERTS"
    G --json doctor
    f="$(jq -r '[.findings[]? // empty | select((.message // "") | test("NTFY_CREDS_FILE|ntfy credentials"))] | length' <<<"$out" 2>/dev/null)"
    printf '%s=%s ' "$m" "$f"
done > "$RUN/modes"
G doctor
[[ "$(cat "$RUN/modes")" == "600=0 640=0 644=1 660=1 " ]] && ok "doctor: NTFY_CREDS_FILE 0600/0640 accepted, 0644/0660 flagged" || bad "modes: $(cat "$RUN/modes") $out"
chmod 0644 "$RUN/shared/ntfy.env"; G doctor --fix
[[ "$(stat -c %a "$RUN/shared/ntfy.env")" == 640 ]] && ok "doctor --fix takes the other bits away (0644 -> 0640)" || bad "fix mode: $(stat -c %a "$RUN/shared/ntfy.env") $out"

# no file at all (NTFY_CREDS_FILE unset, its default missing): no ntfy finding
# in doctor, config check or the log of a failing run, and nothing is sent
rm -f "$RUN/etc/ntfy.env"; ccfg; reset; : > "$RUN/log/pbo.log"
NTFY_CREDS_FILE='' TEST_GUARD_DEFAULTS="$ndef" G doctor; h1="$out"
NTFY_CREDS_FILE='' TEST_GUARD_DEFAULTS="$ndef" G config check; h2="$out"; rc2=$rc
NTFY_CREDS_FILE='' TEST_GUARD_DEFAULTS="$ndef" G backup 8001
[[ "$h1" != *"ntfy: "* && "$h1" == *"no alerting"* && $rc2 == 0 && "$h2" != *NTFY_CREDS* && $rc != 0 && "$(sent_ntfy)" == 0 ]] \
    && ! grep -q 'NTFY_CREDS_FILE' "$RUN/log/pbo.log" \
    && ok "no credentials file: no ntfy finding (doctor, config check, a failing run's log), nothing sent" \
    || bad "no file: rc=$rc rc2=$rc2 $h1 / $h2 / $(cat "$RUN/log/pbo.log")"

# the notification templates on a Proxmox node (pmxcfs, PBO_PVE_CFS_DIR, is
# there) whose alerts go through Proxmox notifications: doctor checks each one
# pbo ships (present, the same bytes), --fix installs the missing ones and
# leaves one that differs (the directory is cluster-wide: another node's pbo
# may have put it there); nothing with NOTIFY_PVE=false or with ntfy in auto
# mode. As any user (a WARN line, not the root-only send path above).
TD="$RUN/pve/notification-templates/default"; rm -rf "$RUN/pve"; mkdir -p "$RUN/pve"
tpls="$(cd templates && printf '%s ' pbo-*.hbs)"; tpls="${tpls% }"
# the guarded copy of pbo finds the shipped templates next to it, as a checkout does
ln -sfn "$ROOT/templates" "$RUN/tree/templates"
TG() { PBO_PVE_TEMPLATE_DIR="$TD" NTFY_CREDS_FILE="$RUN/none/ntfy.env" G "$@"; }
ccfg "NOTIFY_PVE=auto"
TG doctor
[[ "$out" == *"WARN  Proxmox notification templates missing in $TD: $tpls (pbo doctor --fix installs them)"* && ! -e "$TD" ]] && [[ "$out" != *run_dir_guard* ]] \
    && ok "doctor: the notification templates missing on a Proxmox node: a WARN naming each one and the fix" || bad "doctor templates missing: $out"
TG --dry-run doctor --fix
[[ "$out" == *"WOULD FIX notification templates to install in $TD: $tpls"* && ! -e "$TD" ]] \
    && ok "doctor --fix --dry-run: lists the templates it would install, writes none" || bad "doctor templates dry fix: $out"
TG doctor --fix
tok=1; for f in templates/pbo-*.hbs; do cmp -s "$f" "$TD/${f##*/}" || tok=0; done
[[ "$out" == *"FIXED notification templates installed in $TD: $tpls"* && $tok == 1 ]] && grep -q "doctor fix: notification template $TD/pbo-subject.txt.hbs installed" "$RUN/log/pbo.log" \
    && ok "doctor --fix: installs the templates pbo ships (audit-logged)" || bad "doctor templates fix: $out"
TG doctor
[[ "$out" == *"OK  Proxmox notification templates current in $TD"* ]] && ok "doctor: the templates current: OK" || bad "doctor templates ok: $out"
printf 'another pbo template\n' > "$TD/pbo-body.txt.hbs"; cp "$TD/pbo-body.txt.hbs" "$RUN/body.other"
TG doctor
[[ "$out" == *"OK  Proxmox notification templates in $TD differ from the ones this pbo ships: pbo-body.txt.hbs (left as they are"* \
   && "$out" != *"WARN  Proxmox notification templates"* ]] \
    && ok "doctor: a template that differs from the shipped one (another node's pbo, older or newer): reported, no WARN" || bad "doctor templates differ: $out"
TG doctor --fix
cmp -s "$RUN/body.other" "$TD/pbo-body.txt.hbs" && [[ "$out" != *"FIXED notification templates"* && "$out" == *"differ from the ones this pbo ships: pbo-body.txt.hbs"* ]] \
    && ok "doctor --fix: never replaces a template that is there (no node rolls another one's back)" || bad "doctor templates differ fix: $out"
rm -f "$TD/pbo-subject.txt.hbs"
TG doctor --fix
cmp -s templates/pbo-subject.txt.hbs "$TD/pbo-subject.txt.hbs" && cmp -s "$RUN/body.other" "$TD/pbo-body.txt.hbs" \
   && [[ "$out" == *"FIXED notification templates installed in $TD: pbo-subject.txt.hbs"* ]] \
    && ok "doctor --fix: ... it installs only the missing one" || bad "doctor templates fix missing only: $out"
# ntfy configured in auto mode: Proxmox notifications are never sent, so the
# templates are not checked and never written
rm -rf "$TD"; ccfg "NOTIFY_PVE=auto" "NTFY_URL=https://ntfy.invalid" "NTFY_TOPIC=t"
TG doctor --fix
[[ "$out" != *"notification templates"* && ! -e "$TD" ]] && [[ "$out" != *run_dir_guard* ]] \
    && ok "doctor: auto mode with ntfy configured: no template check, none installed" || bad "doctor templates ntfy: $out"
rm -rf "$TD"; ccfg
TG doctor --fix
[[ "$out" != *"notification templates"* && ! -e "$TD" ]] && ok "doctor: NOTIFY_PVE=false: no template check, none installed" || bad "doctor templates off: $out"

rm -rf "$RUN"
printf '%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
