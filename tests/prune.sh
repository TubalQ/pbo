#!/usr/bin/env bash
# tests/prune.sh — steg 7-tester (prune: cache KEEP_LOCAL + offsite GFS).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN=./lxc-offsite
ROOT="$PWD"; export PATH="$ROOT/tests/mocks:$PATH"
rm -rf "$ROOT/run"; mkdir -p "$ROOT/run/cache"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
mkcfg() { local f="$1"; shift; { echo "CACHE_DIR=$ROOT/run/cache"; echo "LOG_DIR=$ROOT/run/log"; echo "STATE_DIR=$ROOT/run/state"; echo "LOCK_DIR=$ROOT/run/lock"; echo "RCLONE_REMOTE=hetzner-crypt"; echo "REMOTE_PATH=lxc"; echo "KEEP_LOCAL=2"; for l in "$@"; do echo "$l"; done; } > "$f"; chmod 600 "$f"; }

# --- CACHE: 4 arkiv för 8001, KEEP_LOCAL=2 → 2 äldsta raderas ---
mkcfg "$ROOT/run/cfg" "OFFSITE_ENABLED=false"; export LXCO_CONFIG="$ROOT/run/cfg"
mkdir -p "$ROOT/run/cache/8001" "$ROOT/run/cache/restore"
for ts in 2026_09_01-03_00_00 2026_09_02-03_00_00 2026_09_03-03_00_00 2026_09_04-03_00_00; do
    a="$ROOT/run/cache/8001/vzdump-lxc-8001-$ts.tar.zst"; : > "$a"; : > "$a.sha256"; : > "$a.meta.json"
done
: > "$ROOT/run/cache/restore/vzdump-lxc-9999-2026_09_04-03_00_00.tar.zst"   # ska ignoreras

$BIN --json prune >/dev/null 2>&1
n="$(ls "$ROOT/run/cache/8001"/*.tar.zst 2>/dev/null | wc -l)"
[[ "$n" == 2 ]] && ok "cache: KEEP_LOCAL=2 behållna" || bad "cache antal ($n)"
[[ -f "$ROOT/run/cache/8001/vzdump-lxc-8001-2026_09_04-03_00_00.tar.zst" ]] && ok "cache: senaste behållen" || bad "cache senaste raderad!"
[[ ! -f "$ROOT/run/cache/8001/vzdump-lxc-8001-2026_09_01-03_00_00.tar.zst" ]] && ok "cache: äldsta raderad" || bad "cache äldsta kvar"
[[ ! -f "$ROOT/run/cache/8001/vzdump-lxc-8001-2026_09_01-03_00_00.tar.zst.sha256" ]] && ok "cache: sidecars raderade med" || bad "cache sidecar kvar"
[[ -f "$ROOT/run/cache/restore/vzdump-lxc-9999-2026_09_04-03_00_00.tar.zst" ]] && ok "cache: restore/ ignoreras" || bad "cache restore rörd"

# --- CACHE dry-run: inget raderas ---
for ts in 2026_08_01-03_00_00 2026_08_02-03_00_00 2026_08_03-03_00_00; do : > "$ROOT/run/cache/8001/vzdump-lxc-8001-$ts.tar.zst"; done
before="$(ls "$ROOT/run/cache/8001"/*.tar.zst | wc -l)"
$BIN --dry-run prune >/dev/null 2>&1
after="$(ls "$ROOT/run/cache/8001"/*.tar.zst | wc -l)"
[[ "$before" == "$after" ]] && ok "cache: --dry-run raderar inget" || bad "dry-run raderade ($before→$after)"

# --- OFFSITE GFS: två arkiv samma dag → äldre intradag raderas, senaste behålls ---
mkcfg "$ROOT/run/cfgO" "KEEP_OFFSITE_DAILY=7" "KEEP_OFFSITE_WEEKLY=4" "KEEP_OFFSITE_MONTHLY=6"
export LXCO_CONFIG="$ROOT/run/cfgO"
printf '8002/\n' > "$ROOT/run/dirs"; export MOCK_LSF_DIRS="$ROOT/run/dirs"
# arkiv + sha256 för varje
{ for ts in 2026_09_04-15_00_00 2026_09_04-03_00_00 2026_09_03-03_00_00 2026_08_25-03_00_00; do
    echo "vzdump-lxc-8002-$ts.tar.zst"; echo "vzdump-lxc-8002-$ts.tar.zst.sha256"; done; } > "$ROOT/run/files"
export MOCK_LSF_FILES="$ROOT/run/files"
export MOCK_LOG="$ROOT/run/calls"; : > "$MOCK_LOG"
$BIN --json prune >/dev/null 2>&1
grep -q 'delete .*2026_09_04-03_00_00' "$MOCK_LOG" && ok "offsite GFS: äldre samma-dags-arkiv raderas" || bad "GFS intradag ($(grep delete "$MOCK_LOG" || echo inga))"
grep -q 'delete .*2026_09_04-15_00_00' "$MOCK_LOG" && bad "offsite GFS: RADERADE SENASTE!" || ok "offsite GFS: senaste aldrig raderad"
grep -q 'delete .*2026_09_03' "$MOCK_LOG" && bad "offsite: raderade unik dag" || ok "offsite GFS: unika dagar behålls"

# --- OFFSITE skydd: inga sha256-sidecars → hoppa vmid ---
{ for ts in 2026_09_04-15_00_00 2026_09_04-03_00_00; do echo "vzdump-lxc-8002-$ts.tar.zst"; done; } > "$ROOT/run/files"
: > "$MOCK_LOG"
$BIN prune >/dev/null 2>&1
grep -q '^delete ' "$MOCK_LOG" && bad "skydd: raderade utan sha256!" || ok "offsite skydd: hoppar vmid utan sha256"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
