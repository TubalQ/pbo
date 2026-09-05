#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/schedule.sh: step 9 (run-schedule + status), fake backup binary.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN=./pbo; ROOT="$PWD"
rm -rf "$ROOT/run"; mkdir -p "$ROOT/run/state/jobs"
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
mkcfg() { local f="$1"; shift; { echo "CACHE_DIR=$ROOT/run/cache"; echo "LOG_DIR=$ROOT/run/log"; echo "STATE_DIR=$ROOT/run/state"; echo "LOCK_DIR=$ROOT/run/lock"; echo "NTFY_URL="; echo "NTFY_CREDS_FILE=/nonexistent"; for l in "$@"; do echo "$l"; done; } > "$f"; chmod 600 "$f"; }

# Fake backup binary: logs the calls, fails for vmid in $FAILV.
export MOCK_LOG="$ROOT/run/calls"; : > "$MOCK_LOG"
cat > "$ROOT/run/fakebin" <<'F'
#!/usr/bin/env bash
echo "$*" >> "$MOCK_LOG"
[ "$3" = "$FAILV" ] && exit 1 || exit 0
F
chmod +x "$ROOT/run/fakebin"
export PBO_SELF_BIN="$ROOT/run/fakebin"

# --- A: all OK, order preserved ---
mkcfg "$ROOT/run/cfg" "BACKUP_ORDER=110,111,113"; export PBO_CONFIG="$ROOT/run/cfg"
: > "$MOCK_LOG"; FAILV="" out="$($BIN --json run-schedule 2>/dev/null)"; rc=$?
grep -q '"status":"ok"' <<<"$out" && [[ $rc == 0 ]] && ok "run-schedule: all OK (exit 0)" || bad "A ($rc: $out)"
grep -q '"backups_ok":"3"' <<<"$out" && ok "A: 3 backups run" || bad "A count ($out)"
[[ "$(cat "$MOCK_LOG")" == $'backup --queue 110\nbackup --queue 111\nbackup --queue 113' ]] && ok "A: order + queue mode preserved" || bad "A order ($(tr '\n' ' ' <"$MOCK_LOG"))"

# --- B: one CT fails → partial, exit != 0, but the rest run ---
: > "$MOCK_LOG"; out="$(FAILV=111 $BIN --json run-schedule 2>/dev/null)"; rc=$?
grep -q '"status":"partial"' <<<"$out" && ok "B: partial on error" || bad "B status ($out)"
grep -q '"backups_failed":"1"' <<<"$out" && ok "B: 1 error counted" || bad "B failc"
[[ "$(wc -l <"$MOCK_LOG")" == 3 ]] && ok "B: the rest ran despite error (3 calls)" || bad "B did not continue"
[[ $rc != 0 ]] && ok "B: exit != 0 on error" || bad "B exit ($rc)"

# --- C: empty BACKUP_ORDER now means auto (all local guests), not a config error ---
mkcfg "$ROOT/run/cfgC" "BACKUP_ORDER="; PBO_CONFIG="$ROOT/run/cfgC" $BIN run-schedule >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ok "C: empty BACKUP_ORDER → auto (not an error)" || bad "C exit ($rc)"

# --- D: status shows lock holder + liveness ---
mkdir -p "$ROOT/run/state"
printf '111|backup|%s|%s\n' "$$" "$(date +%s)" > "$ROOT/run/state/global.holder"
out="$(PBO_CONFIG=$ROOT/run/cfg $BIN --json status 2>/dev/null)"
grep -q '"lock_state":"active"' <<<"$out" && ok "D: live holder → active" || bad "D active ($out)"
printf '111|backup|999999|%s\n' "$(date +%s)" > "$ROOT/run/state/global.holder"
out="$(PBO_CONFIG=$ROOT/run/cfg $BIN --json status 2>/dev/null)"
grep -q 'stale' <<<"$out" && ok "D: dead pid → stale holder" || bad "D stale ($out)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
