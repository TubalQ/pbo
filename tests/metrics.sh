#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/metrics.sh: Prometheus textfile + JSON audit log (issue #12).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping metrics tests"; exit 0; }
printf 'pbo: metrics + audit tests\n'
RUN="$ROOT/run-metrics"; rm -rf "$RUN"; mkdir -p "$RUN"/{cache,state,log,lock,conf,bin}
export MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/calls"; : > "$MOCK_LOG"
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh "$RUN/bin/"
export PATH="$RUN/bin:$PATH"
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
for v in 8001 8002; do printf 'arch: amd64\nhostname: t%s\nrootfs: teststore:%s/d.raw,size=1G\nunprivileged: 1\n' "$v" "$v" > "$MOCK_CONF_DIR/$v.conf"; done
cat > "$RUN/config" <<CFG
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
BACKUP_ORDER=8001,8002
LOCAL_REPO=true
OFFSITE_ENABLED=false
RESTIC_CACHE_REPO=$RUN/repo
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
STORAGE_BOX_SNAPSHOTS_CONFIRMED=true
CFG
chmod 600 "$RUN/config"; export PBO_CONFIG="$RUN/config"
$BIN init >/dev/null 2>&1
$BIN run-schedule >/dev/null 2>&1
P="$RUN/state/pbo.prom"

[[ -s "$P" ]] && ok "run-schedule writes the textfile" || bad "no $P"
grep -qE '^pbo_run_schedule_last_success 1$' "$P" && ok "run_schedule success recorded" || bad "rs success: $(grep run_schedule "$P")"
grep -qE '^pbo_run_schedule_last_failed 0$' "$P" && ok "run_schedule failed count" || bad "rs failed"
grep -qE '^pbo_guest_last_backup_timestamp_seconds\{vmid="8001",type="lxc"\} [0-9]{10}$' "$P" && ok "per-guest last backup timestamp" || bad "guest ts: $(grep last_backup_timestamp "$P")"
grep -qE '^pbo_guest_last_backup_processed_bytes\{vmid="8002",type="lxc"\} [0-9]+$' "$P" && ok "per-guest bytes from the snapshot summary" || bad "guest bytes"
grep -qE '^pbo_guest_last_backup_duration_seconds\{vmid="8001",type="lxc"\} [0-9.]+$' "$P" && ok "per-guest duration" || bad "guest duration"
grep -qE '^pbo_repo_up\{tier="cache"\} 1$' "$P" && ok "repo_up" || bad "repo_up"
grep -qE '^pbo_info\{version="[^"]+",role="host",node="[^"]+"\} 1$' "$P" && ok "pbo_info labels" || bad "info: $(grep pbo_info "$P")"
# every sample line belongs to a declared metric (well-formed exposition)
undeclared="$(awk '/^# TYPE/{t[$3]=1; next} /^#/{next} NF{split($1,a,"{"); if(!(a[1] in t)) print a[1]}' "$P")"
[[ -z "$undeclared" ]] && ok "every sample has a TYPE line" || bad "undeclared: $undeclared"
if command -v promtool >/dev/null 2>&1; then promtool check metrics < "$P" >/dev/null 2>&1 && ok "promtool check metrics" || bad "promtool"; fi

# failure is recorded as such
$BIN verify >/dev/null 2>&1
grep -qE '^pbo_verify_last_success 1$' "$P" && ok "verify recorded" || bad "verify metric"
sed -i "s#^RESTIC_CACHE_REPO=.*#RESTIC_CACHE_REPO=$RUN/nope#" "$RUN/config"
$BIN prune >/dev/null 2>&1
grep -qE '^pbo_prune_last_success 0$' "$P" && ok "failed prune → success 0" || bad "prune failure: $(grep prune "$P")"
grep -qE '^pbo_repo_up\{tier="cache"\} 0$' "$P" && ok "unreachable repo → repo_up 0" || bad "repo_up 0"
sed -i "s#^RESTIC_CACHE_REPO=.*#RESTIC_CACHE_REPO=$RUN/repo#" "$RUN/config"

out="$($BIN metrics --no-write 2>/dev/null)"
grep -q '^pbo_guest_snapshots{vmid="8001",type="lxc"} 1' <<<"$out" && ok "pbo metrics prints the same" || bad "metrics cmd"
METRICS_ENABLED=false $BIN run-schedule >/dev/null 2>&1; :

# --- audit log ---
A="$RUN/log/audit.jsonl"
[[ -s "$A" ]] && ok "audit.jsonl written" || bad "no audit"
jq -e . "$A" >/dev/null 2>&1 && ok "every audit line is JSON" || bad "audit not JSON"
jq -se 'map(select(.kind=="command" and .command=="run-schedule" and .ok==true and .read_only==false and (.user|length>0)))|length>=1' "$A" >/dev/null && ok "run-schedule audited with user and result" || bad "rs audit"
jq -se 'map(select(.kind=="command" and .command=="prune" and .ok==false and .exit!=0))|length>=1' "$A" >/dev/null && ok "failed prune audited with its exit code" || bad "prune audit"
jq -se 'map(select(.command=="metrics" and .read_only==true and .args==["metrics","--no-write"]))|length==1' "$A" >/dev/null && ok "read-only command flagged, args recorded" || bad "metrics audit: $(tail -1 "$A")"
jq -se 'map(select(.command=="backup" and (.args|index("--queue"))))|length>=2' "$A" >/dev/null && ok "each guest backup inside run-schedule audited" || bad "backup --queue audit"
$BIN --dry-run prune >/dev/null 2>&1
jq -se 'map(select(.command=="prune" and .dry_run==true and .read_only==true))|length==1' "$A" >/dev/null && ok "dry-run audited as read-only" || bad "dry-run audit"
[[ "$(stat -c %a "$A")" == 600 ]] && ok "audit.jsonl is 0600" || bad "audit perms $(stat -c %a "$A")"
# restore events go to the JSON log too
MOCK_RESTORE_OK=1 $BIN restore 8001 "$($BIN --json list 8001 2>/dev/null | jq -r '.archives[0].archive' | sed -E 's/^vzdump-lxc-8001-(.*)\.tar$/\1/')" --to 9001 --storage teststore --yes >/dev/null 2>&1
jq -se 'map(select(.kind=="event" and .command=="restore" and (.event|test("restore src=8001"))))|length==1' "$A" >/dev/null && ok "restore detail event in the JSON log" || bad "restore event: $(grep event "$A" | tail -1)"

# hostile tags from the repo can't inject lines into the textfile
mkdir -p "$RUN/hd"; echo h > "$RUN/hd/f"
RESTIC_PASSWORD_FILE="$RUN/pass" RESTIC_CACHE_DIR="$RUN/rcache" restic -r "$RUN/repo" backup -q --tag vmid=8001 \
    --tag "$(printf 'type=lxc"} 1\npbo_injected 1\n#')" "$RUN/hd" >/dev/null 2>&1
out="$($BIN metrics --no-write 2>/dev/null)"
grep -q '^pbo_injected' <<<"$out" && bad "tag injected a metric line" || ok "hostile type= tag can't inject metric lines"
grep -q 'type="unknown"' <<<"$out" && ok "unknown type label normalised" || bad "type normalisation"
# janitor logrotate drops privileges
sed -e "s/create 0600 root root/create 0600 restic restic/" -e '/{$/a\    su restic restic' etc/logrotate.d/pbo > "$RUN/lr"
[[ "$(grep -c '^    su restic restic$' "$RUN/lr")" == 2 ]] && ok "janitor logrotate stanzas get su <user>" || bad "logrotate su: $(cat "$RUN/lr")"

rm -rf "$RUN"
printf '%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
