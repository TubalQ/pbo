#!/usr/bin/env bash
# tests/testrestore.sh — steg 8 (test-restore), mockade pct + rclone.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN=./lxc-offsite
ROOT="$PWD"; export PATH="$ROOT/tests/mocks:$PATH"
export MOCK_CONF_DIR="$ROOT/run/conf"
rm -rf "$ROOT/run"; mkdir -p "$ROOT/run/cache" "$MOCK_CONF_DIR"
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
mkcfg() { local f="$1"; { echo "CACHE_DIR=$ROOT/run/cache"; echo "LOG_DIR=$ROOT/run/log"; echo "STATE_DIR=$ROOT/run/state"; echo "LOCK_DIR=$ROOT/run/lock"; echo "RCLONE_REMOTE=hetzner-crypt"; echo "REMOTE_PATH=lxc"; echo "NTFY_URL="; echo "NTFY_CREDS_FILE=/nonexistent"; echo "TR_WAIT_TRIES=2"; echo "TR_WAIT_SLEEP=0"; } > "$f"; chmod 600 "$f"; }
mkcfg "$ROOT/run/cfg"; export LXCO_CONFIG="$ROOT/run/cfg"

# Simulerat offsite för 8002.
OFF="$ROOT/run/offsite/8002"; mkdir -p "$OFF"
tmp="$(mktemp -d)"; echo d > "$tmp/x"; B="vzdump-lxc-8002-2026_09_04-03_00_00.tar.zst"
tar --zstd -cf "$OFF/$B" -C "$tmp" .; ( cd "$OFF" && sha256sum "$B" > "$B.sha256" )
printf 'unprivileged: 1\n' > "$OFF/$B.conf"
printf '{"source_volumes":["nvmepool|nvmepool/subvol-8002-disk-0"]}\n' > "$OFF/$B.meta.json"
export MOCK_OFFSITE_DIR="$ROOT/run/offsite"
printf '%s\n%s.sha256\n%s.conf\n%s.meta.json\n' "$B" "$B" "$B" "$B" > "$ROOT/run/files"
export MOCK_LSF_FILES="$ROOT/run/files"
export MOCK_LOG="$ROOT/run/calls"

# --- A: happy path → test_ok + destroy anropat ---
: > "$MOCK_LOG"
out="$($BIN --json test-restore 8002 2>/dev/null)"; rc=$?
grep -q '"status":"test_ok"' <<<"$out" && [[ $rc == 0 ]] && ok "happy: test_ok (exit 0)" || bad "A ($rc: $out)"
grep -q '"throwaway":"9099"' <<<"$out" && ok "A: högsta lediga vmid (9099)" || bad "A target ($out)"
grep -q '^pct restore 9099 ' "$MOCK_LOG" && ok "A: pct restore till engångs-vmid" || bad "A restore"
grep -q '^pct start 9099' "$MOCK_LOG" && ok "A: startade CT:n" || bad "A start"
grep -q '^pct destroy 9099' "$MOCK_LOG" && ok "A: destruerade engångs-CT:n (städat)" || bad "A destroy"

# --- B: start misslyckas → test_failed + ändå destroy ---
: > "$MOCK_LOG"
MOCK_START_OK=0 $BIN --json test-restore 8002 >/dev/null 2>&1; rc=$?
[[ $rc == 70 ]] && ok "B: startfel → EX_SOFTWARE" || bad "B exit ($rc)"
grep -q '^pct destroy 9099' "$MOCK_LOG" && ok "B: städar även vid fel" || bad "B destroy saknas"

# --- C: svarar aldrig → test_failed ---
MOCK_EXEC_OK=0 $BIN test-restore 8002 >/dev/null 2>&1; rc=$?
[[ $rc == 70 ]] && ok "C: svarar ej → EX_SOFTWARE" || bad "C exit ($rc)"

# --- D: inga offsite-arkiv → EX_DATAERR ---
printf '' > "$ROOT/run/files"
$BIN test-restore 8002 >/dev/null 2>&1; rc=$?
[[ $rc == 65 ]] && ok "D: inga arkiv → EX_DATAERR" || bad "D exit ($rc)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
