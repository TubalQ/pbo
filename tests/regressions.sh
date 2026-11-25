#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/regressions.sh: regression tests for the 0.4.0 audit fixes. Real local
# restic repos, Proxmox mocked.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE and NTFY_CREDS_FILE are the machine's
# own files: point them into the checkout, at paths nothing creates (a config
# line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.creds"
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping"; exit 0; }

printf 'pbo: regression tests (0.4.0 audit fixes)\n'
RUN="$ROOT/run-regressions"; rm -rf "$RUN"; mkdir -p "$RUN"/{cache,state,log,lock,conf,bin}
export MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/calls"; : > "$MOCK_LOG"
# systemctl mocked too: prune/verify never reach the host's units (pbo-mount.service)
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm tests/mocks/systemctl "$RUN/bin/"
export PATH="$RUN/bin:$PATH"
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
mkcfg() { # <file> [extra lines...]
    local f="$1"; shift
    { cat <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
BACKUP_ORDER="8001"
OFFSITE_ENABLED=false
LOCAL_REPO=true
RESTIC_CACHE_REPO=$RUN/repo
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
PBO_PVE_LXC_DIR=$RUN/conf
EOF
      printf '%s\n' "$@"; } > "$f"; chmod 600 "$f"; }
mkcfg "$RUN/config"; export PBO_CONFIG="$RUN/config"
printf 'arch: amd64\nhostname: web\nrootfs: teststore:8001/vm-8001-disk-0.raw,size=1G\nunprivileged: 1\ntags: pbo-keep-daily-30\n' > "$MOCK_CONF_DIR/8001.conf"
$BIN init >/dev/null 2>&1; $BIN backup 8001 >/dev/null 2>&1

# --- locks and logs ---
[[ "$(stat -c '%a' "$RUN/log/pbo.log")" == 600 && "$(stat -c '%a' "$RUN/log/audit.log")" == 600 ]] \
    && ok "logs are 0600" || bad "log perms: $(stat -c '%a %n' "$RUN"/log/*)"
d="$(bash -c 'source lib/common.sh; set_defaults; echo "$LOCK_DIR"')"
if [[ "$(id -u)" == 0 ]]; then want=/run/pbo; else want="$(bash -c 'source lib/common.sh; set_defaults; echo "$STATE_DIR"')/lock"; fi
[[ "$d" == "$want" ]] && ok "LOCK_DIR defaults to /run/pbo as root, STATE_DIR/lock otherwise (never world-writable /var/lock)" || bad "lock dir default: $d (wanted $want)"
mkcfg "$RUN/ww.cfg" "LOCK_DIR=/var/lock"
grep -q "WARN.*LOCK_DIR /var/lock is world-writable" <<<"$(PBO_CONFIG="$RUN/ww.cfg" $BIN doctor 2>&1)" && ok "doctor warns about a world-writable LOCK_DIR" || bad "lock dir warning"

# --- config ownership ---
if [[ "$(id -u)" == 0 ]]; then
    mkcfg "$RUN/other.cfg"; chown nobody "$RUN/other.cfg"
    PBO_CONFIG="$RUN/other.cfg" $BIN version >/dev/null 2>&1; [[ $? == 78 ]] && ok "a config owned by another user is refused" || bad "config owner check"
else
    printf '  SKIP config owner check (needs root to chown)\n'
fi

# --- verify: an unopenable tier is a failure ---
mkcfg "$RUN/v.cfg" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/no-such-repo"
out="$(PBO_CONFIG="$RUN/v.cfg" $BIN --json verify 2>/dev/null)"; rc=$?
[[ $rc != 0 ]] && jq -e '.ok == false' >/dev/null 2>&1 <<<"$out" && ok "verify fails when a tier cannot be opened (was: skipped + OK)" || bad "verify unreachable rc=$rc $out"

# --- list / unlock on an unreadable repo ---
mkcfg "$RUN/l.cfg" "RESTIC_CACHE_REPO=$RUN/no-such-repo"
out="$(PBO_CONFIG="$RUN/l.cfg" $BIN --json list 2>/dev/null)"; rc=$?
[[ $rc == 69 ]] && jq -e '.status == "error" and .ok == false' >/dev/null 2>&1 <<<"$out" && ok "list on an unreadable repo is an error, not an empty list" || bad "list rc=$rc $out"
PBO_CONFIG="$RUN/l.cfg" $BIN unlock >/dev/null 2>&1; [[ $? != 0 ]] && ok "unlock exits non-zero when it could not unlock" || bad "unlock rc"

# --- JSON: errors inside $(...) are not lost; one object for metrics/help ---
out="$($BIN --json policy get 9999 2>/dev/null)"; rc=$?
[[ $rc == 65 ]] && jq -e '.status == "error" and .exit == 65' >/dev/null 2>&1 <<<"$out" && ok "an error raised inside \$(...) still prints its JSON object" || bad "die in subshell: rc=$rc '$out'"
out="$($BIN --json metrics --no-write 2>/dev/null)"
[[ "$(grep -c . <<<"$out")" == 1 ]] && jq -e '.ok and (.text | test("pbo_info"))' >/dev/null 2>&1 <<<"$out" && ok "--json metrics: one object with the text" || bad "metrics json"
jq -e '.ok and (.usage | test("Exit codes"))' >/dev/null 2>&1 <<<"$($BIN --json help 2>/dev/null)" && ok "--json help: one object" || bad "help json"

# --- the exit fallback: an unexplained failure is never silent ---
# An errexit inside a command, forced in a copy of the source tree (the config
# is not run as code since 0.6, and pbo has no test hook for it): the copied
# lib/views.sh gets an rdo_version that fails.
mkdir -p "$RUN/src"; cp -a pbo lib "$RUN/src/"
printf '\n# tests/regressions.sh: force an errexit inside a command\nrdo_version() { false; }\n' >> "$RUN/src/lib/views.sh"
out="$(PBO_CONFIG="$RUN/config" "$RUN/src/pbo" --json version 2>"$RUN/x.err")"; rc=$?
[[ $rc != 0 ]] && jq -e '.status == "error"' >/dev/null 2>&1 <<<"$out" && grep -q "stopped unexpectedly" "$RUN/x.err" \
    && ok "an errexit deep in a command: logged and a JSON error" || bad "exit fallback rc=$rc '$out' $(tail -1 "$RUN/x.err")"

# --- URL credentials never reach a log line ---
bash -c 'source lib/common.sh; LOG_FILE='"$RUN"'/mask.log; log_info "restic -r rest:https://user:hunter2@h:8000/x --x sftp:u123@box:/p"' 2>/dev/null
! grep -q hunter2 "$RUN/mask.log" && ! grep -q u123@ "$RUN/mask.log" && grep -q 'rest:https://\*\*\*@h' "$RUN/mask.log" \
    && ok "log lines mask URL credentials" || bad "log mask: $(cat "$RUN/mask.log")"

# --- ntfy token on stdin, not argv ---
cat > "$RUN/bin/curl" <<'C'
#!/bin/bash
printf '%s\n' "$*" > "$MOCK_CURL_ARGS"; cat > "$MOCK_CURL_STDIN"
C
chmod 755 "$RUN/bin/curl"
MOCK_CURL_ARGS="$RUN/curl.args" MOCK_CURL_STDIN="$RUN/curl.stdin" NTFY_URL=https://n.invalid NTFY_TOPIC=t NTFY_TOKEN=tk_secret_123 NOTIFY_PVE=false \
    bash -c 'unset PBO_NO_NOTIFY; source lib/common.sh; source lib/notify.sh; notify_failure "x"' 2>/dev/null
! grep -q tk_secret_123 "$RUN/curl.args" && grep -q tk_secret_123 "$RUN/curl.stdin" && ok "ntfy token passed on stdin, not on the command line" || bad "ntfy token: args=$(cat "$RUN/curl.args" 2>/dev/null)"
rm -f "$RUN/bin/curl"

# --- backup-host excludes private keys ---
ex="$(bash -c 'source lib/common.sh; set_defaults; echo "$HOST_BACKUP_EXCLUDES"')"
for k in /etc/pve/priv /etc/pbo/web-tls /etc/pbo/rest-pass '/etc/pve/nodes/*/*.key' '**/*.key'; do
    [[ " $ex " == *" $k "* ]] || bad "backup-host does not exclude $k"
done; ok "backup-host excludes /etc/pve/priv, node keys, pbo-web key, rest password, *.key"

# --- batch keeps the per-guest keep= tag, counts phase-1 failures ---
mkcfg "$RUN/b.cfg" "BACKUP_ORDER=\"8001 8009\""
PBO_CONFIG="$RUN/b.cfg" $BIN --json run-schedule --batch > "$RUN/batch.json" 2>/dev/null; rc=$?
newest_tags="$(RESTIC_PASSWORD_FILE="$RUN/pass" restic -r "$RUN/repo" snapshots --json --tag vmid=8001 2>/dev/null | jq -r 'max_by(.time) | .tags | join(",")')"
[[ "$newest_tags" == *"keep=d30"* ]] && ok "batch: the per-guest keep= tag is stored (was dropped)" || bad "batch keep tag: $newest_tags"
[[ $rc != 0 ]] && jq -e '.backups_failed >= 1' >/dev/null 2>&1 <"$RUN/batch.json" && ok "batch: a guest that could not be dumped counts as failed" || bad "batch phase-1 failure: rc=$rc $(cat "$RUN/batch.json")"

# --- batch holds each guest's lock from dump to upload; a vanished dump is a failure ---
printf 'arch: amd64\nhostname: b2\nrootfs: teststore:8003/vm-8003-disk-0.raw,size=1G\nunprivileged: 1\n' > "$MOCK_CONF_DIR/8003.conf"
mkcfg "$RUN/b2.cfg" "BACKUP_ORDER=\"8001 8003\"" "LOCK_DIR=$RUN/lock"; mkdir -p "$RUN/lock"
nsnap() { RESTIC_PASSWORD_FILE="$RUN/pass" restic -r "$RUN/repo" snapshots --json --tag "vmid=$1" 2>/dev/null | jq length; }
n1="$(nsnap 8001)"; n3="$(nsnap 8003)"
( flock 9 && exec sleep 30 ) 9>"$RUN/lock/pbo.vmid-8001.lock" & holder=$!
sleep 0.5
PBO_CONFIG="$RUN/b2.cfg" $BIN --json run-schedule --batch > "$RUN/batch2.json" 2>/dev/null; rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[[ $rc != 0 && "$(nsnap 8001)" == "$n1" && "$(nsnap 8003)" == $((n3+1)) ]] && jq -e '.failed_vmids == "8001" and .backups_ok == 1' >/dev/null 2>&1 <"$RUN/batch2.json" \
    && ok "batch: a guest whose lock is held (an ingest runs) is skipped and counted as failed" || bad "batch lock: rc=$rc $(cat "$RUN/batch2.json")"
# another process empties CACHE_DIR/8001 between the phases (what an ingest did)
mkdir -p "$RUN/bin-race"
printf '#!/usr/bin/env bash\n[[ " $* " == *" 8003 "* ]] && rm -f "%s"/vzdump-*\nexec "%s" "$@"\n' "$RUN/cache/8001" "$RUN/bin/vzdump" > "$RUN/bin-race/vzdump"
chmod 0755 "$RUN/bin-race/vzdump"
n1="$(nsnap 8001)"
PATH="$RUN/bin-race:$PATH" PBO_CONFIG="$RUN/b2.cfg" $BIN --json run-schedule --batch > "$RUN/batch3.json" 2>/dev/null; rc=$?
[[ $rc != 0 && "$(nsnap 8001)" == "$n1" ]] && jq -e '.failed_vmids == "8001"' >/dev/null 2>&1 <"$RUN/batch3.json" \
    && ok "batch: a dump that vanished before its upload fails, no empty snapshot" || bad "batch vanished dump: rc=$rc snaps $(nsnap 8001) vs $n1 $(cat "$RUN/batch3.json")"

# --- CACHE_DIR closed to local users, unprivileged CTs' mapped root let through ---
printf 'arch: amd64\nunprivileged: 1\nlxc.idmap: u 0 300000 65536\n[snap]\nlxc.idmap: u 0 1 1\n' > "$MOCK_CONF_DIR/8011.conf"
printf 'arch: amd64\nhostname: priv\n' > "$MOCK_CONF_DIR/8012.conf"
r="$(bash -c 'source lib/common.sh; source lib/appendonly.sh; PBO_PVE_LXC_DIR="$1"
      for v in 8001 8011 8012 9999; do _ct_root_uid "$v" || printf -- "-"; printf " "; done' _ "$MOCK_CONF_DIR")"
[[ "$r" == "100000 300000 - - " ]] && ok "_ct_root_uid: 100000 without an idmap (as pve-container), the CT's own idmap first, privileged and missing CTs fail" || bad "_ct_root_uid: '$r'"
rm -f "$MOCK_CONF_DIR/8011.conf" "$MOCK_CONF_DIR/8012.conf"
chmod 0755 "$RUN/cache"; setfacl -b "$RUN/cache" 2>/dev/null || true
out="$($BIN --json doctor 2>/dev/null)"
jq -e '[.findings[] | select(.level == "warn" and (.message | test("CACHE_DIR .* is open to local users")))] | length == 1' >/dev/null 2>&1 <<<"$out" \
    && ok "doctor warns while CACHE_DIR is open to local users" || bad "doctor open cache: $(jq -c '[.findings[] | select(.message | test("CACHE_DIR"))]' <<<"$out")"
if command -v setfacl >/dev/null 2>&1; then
    $BIN backup 8001 >/dev/null 2>&1; rc=$?
    m="$(stat -c %a "$RUN/cache")"
    [[ $rc == 0 && "$m" == 750 ]] && getfacl -cpn "$RUN/cache" 2>/dev/null | grep -qx 'user:100000:--x' \
        && ok "backup of an unprivileged CT: CACHE_DIR closed (0750) with an ACL entry for its mapped root" || bad "cache protect: rc=$rc mode=$m $(getfacl -cpn "$RUN/cache" 2>/dev/null | tr '\n' ' ')"
    out="$($BIN --json doctor 2>/dev/null)"
    jq -e '[.findings[] | select(.level == "ok" and (.message | test("CACHE_DIR closed")))] | length == 1' >/dev/null 2>&1 <<<"$out" \
        && ok "doctor: CACHE_DIR closed, every unprivileged CT has its entry" || bad "doctor closed: $(jq -c '[.findings[] | select(.message | test("CACHE_DIR"))]' <<<"$out")"
    setfacl -b "$RUN/cache"; chmod 0750 "$RUN/cache"
    out="$($BIN --json doctor 2>/dev/null)"
    jq -e '[.findings[] | select(.level == "fail" and (.message | test("no ACL entry .* 8001")))] | length == 1' >/dev/null 2>&1 <<<"$out" \
        && ok "doctor fails when CACHE_DIR is closed without the entry (vzdump of the CT would fail)" || bad "doctor no acl: $(jq -c '[.findings[] | select(.message | test("CACHE_DIR"))]' <<<"$out")"
    chmod 0755 "$RUN/cache"
else
    PATH_NOACL="$RUN/bin-noacl"; mkdir -p "$PATH_NOACL"
    $BIN backup 8001 >/dev/null 2>"$RUN/noacl.err"; rc=$?
    [[ $rc == 0 && "$(stat -c %a "$RUN/cache")" == 755 ]] && grep -q 'setfacl/getfacl (package acl)' "$RUN/noacl.err" \
        && ok "without setfacl: CACHE_DIR stays open (an unprivileged CT's vzdump would fail otherwise) and pbo warns" || bad "noacl: rc=$rc mode=$(stat -c %a "$RUN/cache")"
fi

# --- restore-host never into system paths or a non-empty dir ---
for t in / /etc /root "$RUN/state"; do
    $BIN restore-host somehost 2026_01_01-00_00_00 --to "$t" >/dev/null 2>&1; rc=$?
    [[ $rc != 0 ]] || bad "restore-host accepted $t"
done; ok "restore-host refuses /, /etc, /root and a non-empty directory"

# --- restore --restricted refuses a privileged container ---
printf 'arch: amd64\nhostname: priv\nrootfs: teststore:8002/vm-8002-disk-0.raw,size=1G\nunprivileged: 0\n' > "$MOCK_CONF_DIR/8002.conf"
$BIN backup 8002 >/dev/null 2>&1
ts="$($BIN --json list 8002 2>/dev/null | jq -r '[.archives[].ts] | sort | last')"
out="$($BIN --json restore 8002 "$ts" --to 9401 --yes --restricted 2>/dev/null)"; rc=$?
[[ $rc == 64 && ! -e "$MOCK_CONF_DIR/9401.conf" ]] && jq -e '.error | test("privileged")' >/dev/null 2>&1 <<<"$out" \
    && ok "restore --restricted refuses a privileged container (needs Sys.Modify)" || bad "restricted privileged: rc=$rc $out"

# --- a privileged CT as Proxmox writes it: no "unprivileged:" line at all ---
printf 'arch: amd64\nhostname: priv2\nrootfs: teststore:8004/vm-8004-disk-0.raw,size=1G\n' > "$MOCK_CONF_DIR/8004.conf"
$BIN backup 8004 >/dev/null 2>&1
ts4="$($BIN --json list 8004 2>/dev/null | jq -r '[.archives[].ts] | sort | last')"
out="$($BIN --json restore 8004 "$ts4" --to 9404 --yes --restricted 2>/dev/null)"; rc=$?
[[ $rc == 64 && ! -e "$MOCK_CONF_DIR/9404.conf" ]] && jq -e '.error | test("privileged")' >/dev/null 2>&1 <<<"$out" \
    && ok "restore --restricted refuses a privileged CT whose config has no unprivileged line" || bad "restricted privileged (no line): rc=$rc $out"
: > "$MOCK_LOG"
$BIN restore 8004 "$ts4" --to 9405 --yes >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && grep -q '^pct restore 9405 .* --unprivileged 0' "$MOCK_LOG" \
    && ok "restore of a privileged CT (no unprivileged line) passes --unprivileged 0" || bad "privileged restore: rc=$rc $(grep '^pct restore' "$MOCK_LOG")"
: > "$MOCK_LOG"
$BIN restore 8001 "$($BIN --json list 8001 2>/dev/null | jq -r '[.archives[].ts] | sort | last')" --to 9406 --yes >/dev/null 2>&1
grep -q '^pct restore 9406 .* --unprivileged 1' "$MOCK_LOG" && ok "restore of an unprivileged CT passes --unprivileged 1" || bad "unprivileged restore: $(grep '^pct restore' "$MOCK_LOG")"

# --- no storage found: a clear usage error, never a silent stop (pvesm missing in CI) ---
out="$(MOCK_PVESM_EMPTY=1 $BIN --json restore 8002 "$ts" --to 9402 --yes 2>/dev/null)"; rc=$?
[[ $rc == 64 ]] && jq -e '.error | test("no --storage given")' >/dev/null 2>&1 <<<"$out" && ok "restore without a usable storage: asks for --storage" || bad "no storage: rc=$rc $out"
# pvesm "missing": a stand-in that fails like command-not-found (127), so the real
# one on a PVE host stays shadowed and the rest of PATH (restic in CI) is kept
mv "$RUN/bin/pvesm" "$RUN/pvesm.away"; printf '#!/bin/sh\nexit 127\n' > "$RUN/bin/pvesm"; chmod 755 "$RUN/bin/pvesm"
$BIN restore 8002 "$ts" --to 9403 --yes >/dev/null 2>&1; rc=$?; mv -f "$RUN/pvesm.away" "$RUN/bin/pvesm"
[[ $rc == 64 ]] && ok "restore with pvesm missing: usage error, not exit 127" || bad "pvesm missing rc=$rc"

# --- setup / menu: _cfg_set creates the config, escapes values ---
bash -c 'source lib/common.sh; source lib/menu.sh 2>/dev/null; PBO_CONFIG_LOCAL='"$RUN"'/new/config; _cfg_set A "x&y|z" && _cfg_set A "p&q|r"' 2>/dev/null
[[ "$(stat -c '%a' "$RUN/new/config" 2>/dev/null)" == 600 ]] && grep -qx 'A=p&q|r' "$RUN/new/config" \
    && ok "_cfg_set creates a missing config (0600) and keeps & | in values" || bad "_cfg_set: $(cat "$RUN/new/config" 2>/dev/null)"

# --- rotate-key: a failure on the second repo undoes the first ---
printf 'otherpass\n' > "$RUN/otherpass"; chmod 600 "$RUN/otherpass"
RESTIC_PASSWORD_FILE="$RUN/otherpass" restic -r "$RUN/repo2" init >/dev/null 2>&1   # offsite won't open with our key
mkcfg "$RUN/r.cfg" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/repo2"
printf 'newpass\n' > "$RUN/newpass"; chmod 600 "$RUN/newpass"
PBO_CONFIG="$RUN/r.cfg" $BIN rotate-key "$RUN/newpass" >/dev/null 2>&1; rc=$?
rm -rf "$RUN/repo2"; RESTIC_PASSWORD_FILE="$RUN/pass" restic -r "$RUN/repo2" init >/dev/null 2>&1
nk() { RESTIC_PASSWORD_FILE="$RUN/pass" restic -r "$1" key list --json 2>/dev/null | jq length; }
[[ $rc != 0 && "$(cat "$RUN/pass")" == testpass && "$(nk "$RUN/repo")" == 1 ]] \
    && ok "rotate-key: a failure on one repo leaves every repo on the old key (rolled back)" || bad "rotate rollback rc=$rc keys=$(nk "$RUN/repo") pass=$(cat "$RUN/pass")"
PBO_CONFIG="$RUN/r.cfg" $BIN rotate-key "$RUN/newpass" >/dev/null 2>&1; rc=$?
[[ $rc == 0 && "$(cat "$RUN/pass")" == newpass ]] && [[ "$(RESTIC_PASSWORD_FILE="$RUN/pass" restic -r "$RUN/repo" key list --json | jq length)" == 1 ]] \
    && ! ls "$RUN"/pass.old-* >/dev/null 2>&1 && ok "rotate-key: success installs the new key, removes the old ones and the old password copy" || bad "rotate ok rc=$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ -n "${KEEP_RUN:-}" ]] || rm -rf "$RUN"
(( fail == 0 ))
