#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/testrestore.sh — step 8 (test-restore), mocked pct + rclone.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN=./pbo
ROOT="$PWD"; export PATH="$ROOT/tests/mocks:$PATH"
export MOCK_CONF_DIR="$ROOT/run/conf"
rm -rf "$ROOT/run"; mkdir -p "$ROOT/run/cache" "$MOCK_CONF_DIR"
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
mkcfg() { local f="$1"; { echo "CACHE_DIR=$ROOT/run/cache"; echo "LOG_DIR=$ROOT/run/log"; echo "STATE_DIR=$ROOT/run/state"; echo "LOCK_DIR=$ROOT/run/lock"; echo "RCLONE_REMOTE=hetzner-crypt"; echo "REMOTE_PATH=lxc"; echo "NTFY_URL="; echo "NTFY_CREDS_FILE=/nonexistent"; echo "TR_WAIT_TRIES=2"; echo "TR_WAIT_SLEEP=0"; } > "$f"; chmod 600 "$f"; }
mkcfg "$ROOT/run/cfg"; export PBO_CONFIG="$ROOT/run/cfg"

# Simulated offsite for 8002.
OFF="$ROOT/run/offsite/8002"; mkdir -p "$OFF"
tmp="$(mktemp -d)"; echo d > "$tmp/x"; B="vzdump-lxc-8002-2026_09_04-03_00_00.tar.zst"
tar --zstd -cf "$OFF/$B" -C "$tmp" .; ( cd "$OFF" && sha256sum "$B" > "$B.sha256" )
printf 'unprivileged: 1\n' > "$OFF/$B.conf"
printf '{"source_volumes":["nvmepool|nvmepool/subvol-8002-disk-0"]}\n' > "$OFF/$B.meta.json"
export MOCK_OFFSITE_DIR="$ROOT/run/offsite"
printf '%s\n%s.sha256\n%s.conf\n%s.meta.json\n' "$B" "$B" "$B" "$B" > "$ROOT/run/files"
export MOCK_LSF_FILES="$ROOT/run/files"
export MOCK_LOG="$ROOT/run/calls"

# --- A: happy path → test_ok + destroy called ---
: > "$MOCK_LOG"
out="$($BIN --json test-restore 8002 2>/dev/null)"; rc=$?
grep -q '"status":"test_ok"' <<<"$out" && [[ $rc == 0 ]] && ok "happy: test_ok (exit 0)" || bad "A ($rc: $out)"
grep -q '"throwaway":"9099"' <<<"$out" && ok "A: highest free vmid (9099)" || bad "A target ($out)"
grep -q '^pct restore 9099 ' "$MOCK_LOG" && ok "A: pct restore to throwaway vmid" || bad "A restore"
grep -q '^pct start 9099' "$MOCK_LOG" && ok "A: started the CT" || bad "A start"
grep -q '^pct destroy 9099' "$MOCK_LOG" && ok "A: destroyed the throwaway CT (cleaned up)" || bad "A destroy"

# --- B: start fails → test_failed + destroy anyway ---
: > "$MOCK_LOG"
MOCK_START_OK=0 $BIN --json test-restore 8002 >/dev/null 2>&1; rc=$?
[[ $rc == 70 ]] && ok "B: start error → EX_SOFTWARE" || bad "B exit ($rc)"
grep -q '^pct destroy 9099' "$MOCK_LOG" && ok "B: cleans up even on error" || bad "B destroy missing"

# --- C: never responds → test_failed ---
MOCK_EXEC_OK=0 $BIN test-restore 8002 >/dev/null 2>&1; rc=$?
[[ $rc == 70 ]] && ok "C: does not respond → EX_SOFTWARE" || bad "C exit ($rc)"

# --- D: no offsite archives → EX_DATAERR ---
printf '' > "$ROOT/run/files"
$BIN test-restore 8002 >/dev/null 2>&1; rc=$?
[[ $rc == 65 ]] && ok "D: no archives → EX_DATAERR" || bad "D exit ($rc)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
