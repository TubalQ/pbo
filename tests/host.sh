#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/host.sh: end-to-end tests of `backup-host`/`restore-host` against a REAL
# local restic repo (offsite disabled). Verifies the type=host tagging, that SSH
# keys and the DR key are excluded, that the security notice is printed, that
# rebuild metadata is captured, and that restore-host extracts files (whole
# snapshot and a single --path) without touching live host paths.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping host tests"; exit 0; }
command -v jq     >/dev/null 2>&1 || { echo "jq not installed, skipping host tests"; exit 0; }

printf 'pbo: host backup tests\n'
RUN="$ROOT/run-host"; rm -rf "$RUN"
mkdir -p "$RUN"/{cache,state,log,lock,fakeetc/.ssh}

# a fake host config tree: one kept file, one secret that must be excluded
echo "iface eth0 inet dhcp"      > "$RUN/fakeetc/interfaces"
echo "SECRET-REPO-PASSWORD"      > "$RUN/fakeetc/restic-pass"
echo "PRIVATE-SSH-KEY"           > "$RUN/fakeetc/.ssh/id_rsa"

cat > "$RUN/config" <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
OFFSITE_ENABLED=false
LOCAL_REPO=true
RESTIC_CACHE_REPO=$RUN/repo
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
KEEP_LOCAL=2
HOST_BACKUP_PATHS="$RUN/fakeetc"
HOST_BACKUP_EXCLUDES="$RUN/fakeetc/restic-pass **/.ssh **/id_rsa"
EOF
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass" "$RUN/config"
export PBO_CONFIG="$RUN/config"

$BIN init >/dev/null 2>&1 || { echo "init failed"; exit 1; }

# --- dry-run makes no snapshot ---
$BIN --dry-run --json backup-host > "$RUN/dry.json" 2>/dev/null
jq -e '.dry_run==true and .type=="host"' "$RUN/dry.json" >/dev/null && ok "dry-run: no-op envelope" || bad "dry-run ($(cat "$RUN/dry.json"))"

# --- real backup-host: envelope + security notice on stderr ---
$BIN --json backup-host > "$RUN/bk.json" 2>"$RUN/bk.err"; rc=$?
[[ $rc == 0 ]] && ok "backup-host succeeds" || bad "backup-host rc=$rc ($(tail -2 "$RUN/bk.err"))"
jq -e '.status=="uploaded" and .type=="host"' "$RUN/bk.json" >/dev/null && ok "backup-host: uploaded envelope" || bad "envelope ($(cat "$RUN/bk.json"))"
HID="$(jq -r '.vmid' "$RUN/bk.json")"
[[ "$HID" == host-* ]] && ok "backup-host: vmid tag is host-<node> ($HID)" || bad "vmid tag ($HID)"
grep -qi 'SSH keys' "$RUN/bk.err" && grep -qi 'excluded' "$RUN/bk.err" \
    && ok "backup-host: prints the SSH-keys-excluded notice" || bad "security notice missing"

# --- list surfaces the host snapshot like a guest ---
$BIN --json list > "$RUN/ls.json" 2>/dev/null
jq -e --arg h "$HID" '[.archives[]|select(.vmid==$h)]|length>=1' "$RUN/ls.json" >/dev/null \
    && ok "list: host snapshot present" || bad "list host ($(jq -c '.archives' "$RUN/ls.json"))"
TS="$(jq -r --arg h "$HID" '.archives[]|select(.vmid==$h)|.archive' "$RUN/ls.json" \
    | grep -oE '[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}' | head -1)"
[[ -n "$TS" ]] && ok "list: host snapshot has a timestamp" || bad "host ts"

# --- restore-host: whole snapshot to a dir ---
OUT="$RUN/restore"; $BIN restore-host "$HID" "$TS" --to "$OUT" >/dev/null 2>&1 \
    && ok "restore-host: extracts" || bad "restore-host failed"
kept="$(find "$OUT" -name interfaces -type f | head -1)"
[[ -n "$kept" ]] && grep -q 'dhcp' "$kept" && ok "restore-host: kept file restored intact" || bad "kept file missing"
[[ -z "$(find "$OUT" -name restic-pass)" ]] \
    && ok "restore-host: DR key was EXCLUDED" || bad "DR key leaked into backup"
[[ -z "$(find "$OUT" -name id_rsa)" ]] && ok "restore-host: SSH key was EXCLUDED" || bad "SSH key leaked into backup"
[[ -n "$(find "$OUT" -name README.txt -path '*meta*')" ]] && ok "restore-host: rebuild metadata captured" || bad "meta missing"

# --- restore-host --path: a single file only ---
OUT2="$RUN/restore-one"; $BIN restore-host "$HID" "$TS" --to "$OUT2" --path "$RUN/fakeetc/interfaces" >/dev/null 2>&1
[[ -n "$(find "$OUT2" -name interfaces -type f)" ]] && ok "restore-host --path: single file restored" || bad "single-file restore"

# --- unknown node/ts fails cleanly ---
$BIN restore-host "$HID" "1999_01_01-00_00_00" --to "$RUN/nope" >/dev/null 2>&1
[[ $? != 0 ]] && ok "restore-host: missing snapshot errors" || bad "missing snapshot not caught"

rm -rf "$RUN"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
