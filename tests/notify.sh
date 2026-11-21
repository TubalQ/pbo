#!/usr/bin/env bash
# tests/notify.sh: notification backends (issue #11). ntfy and PVE::Notify are
# faked (curl, perl), nothing real is sent. The Proxmox path needs root (it
# queues into PVE's notification system), so those checks skip as non-root.
set -uo pipefail
unset PBO_NO_NOTIFY   # all.sh exports it; this suite tests notifications itself
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
printf 'pbo: notification tests\n'
RUN="$ROOT/run-notify"; rm -rf "$RUN"; mkdir -p "$RUN"/{state,log,lock,cache,bin,tpl}
cat > "$RUN/bin/curl" <<'C'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_CURL_LOG"
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
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh "$RUN/bin/"   # never the real host
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

# false + no ntfy → nothing active
cfg "NOTIFY_PVE=false"; reset
$BIN notify-test >/dev/null 2>&1; rc=$?
[[ $rc == 69 && "$(sent_ntfy)" == 0 && "$(sent_pve)" == 0 ]] && ok "no backend: notify-test fails (EX_UNAVAILABLE), sends nothing" || bad "none: rc=$rc"
out="$($BIN doctor 2>&1)"
grep -q 'WARN.*no alerting' <<<"$out" && ok "doctor warns when nothing would alert" || bad "doctor no-alert: $out"

rm -rf "$RUN"
printf '%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
