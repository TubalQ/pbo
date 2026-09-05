#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/run.sh — unit tests for the skeleton (subcommands, config, two-level locking).
# Pure bash tests, no external dependencies. Runs nothing against real hardware.
# Real vzdump/pct/restic are mocked in later stages.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BIN=./pbo
export PBO_CONFIG="$PWD/etc/config.dev"
LOCKDIR="$PWD/run/lock"
GLOBAL_LOCK="$LOCKDIR/pbo.global"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

# check_exit <description> <expected exit> <command...>
check_exit() {
    local desc="$1" want="$2"; shift 2
    "$@" >/dev/null 2>&1; local got=$?
    [[ "$got" == "$want" ]] && ok "$desc (exit $got)" || bad "$desc (got $got, wanted $want)"
}

printf 'pbo — skeleton tests\n'
rm -rf "$PWD/run"

# --- the tool must create LOCK_DIR itself (regression: ensure_dirs) ---
$BIN --json status >/dev/null 2>&1
[[ -d "$LOCKDIR" ]] && ok "creates LOCK_DIR itself on an empty environment" || bad "LOCK_DIR auto-created"

# --- basic CLI ---
$BIN --help    2>&1 | grep -q 'Usage' && ok "help shows usage" || bad "help"
$BIN --version 2>&1 | grep -q '0.1.0'      && ok "version" || bad "version"
check_exit "unknown command gives EX_USAGE" 64 $BIN nonsense
check_exit "no command gives EX_USAGE" 64 $BIN

# --- --json contract: pure JSON on stdout ---
out="$($BIN --json status 2>/dev/null)"
[[ "$out" == '{'*'}' ]] && ok "status --json returns a JSON object" || bad "status --json ($out)"
grep -q '"status":"ok"' <<<"$out" && ok "status --json contains status:ok" || bad "status json field"

# verify is not yet implemented → tests the not_implemented envelope.
out="$($BIN --json verify 9001 2>/dev/null)"
grep -q '"status":"not_implemented"' <<<"$out" && ok "verify returns not_implemented (json)" || bad "verify json ($out)"
# the dry_run field is tested via status (stable, implemented).
out="$($BIN --json status 2>/dev/null)"
grep -q '"dry_run":false' <<<"$out" && ok "dry_run field present (false)" || bad "dry_run field"
out="$($BIN --json --dry-run status 2>/dev/null)"
grep -q '"dry_run":true' <<<"$out" && ok "--dry-run reflected in json" || bad "dry_run true"

# --- vmid validation ---
check_exit "invalid vmid (too small) rejected" 64 $BIN backup 5
check_exit "invalid vmid (non-numeric) rejected" 64 $BIN backup abc
check_exit "backup without vmid rejected" 64 $BIN backup

# --- global lock: now mode exits IMMEDIATELY when the lock is busy ---
exec {H}>"$GLOBAL_LOCK"; flock -n "$H" || { bad "could not take the test lock"; }
t0=$SECONDS
$BIN backup 9002 >/dev/null 2>&1; got=$?
elapsed=$((SECONDS - t0))
[[ "$got" == 75 ]] && ok "now mode: EX_TEMPFAIL when the global lock is busy" || bad "now mode exit ($got)"
[[ "$elapsed" -lt 3 ]] && ok "now mode does NOT wait (${elapsed}s)" || bad "now mode waited ${elapsed}s"

# --- global lock: queue mode WAITS and times out (config.dev: 5s) ---
t0=$SECONDS
$BIN backup --queue 9003 >/dev/null 2>&1; got=$?
elapsed=$((SECONDS - t0))
[[ "$got" == 75 ]] && ok "queue mode: EX_TEMPFAIL after timeout" || bad "queue mode exit ($got)"
[[ "$elapsed" -ge 4 ]] && ok "queue mode waited for the lock (${elapsed}s)" || bad "queue mode only waited ${elapsed}s"
flock -u "$H"; exec {H}>&-

# --- per-vmid lock: double-queueing the SAME vmid is rejected ---
VLOCK="$LOCKDIR/pbo.vmid-9004.lock"
exec {V}>"$VLOCK"; flock -n "$V"
check_exit "per-vmid lock prevents double-queueing" 75 $BIN backup 9004
flock -u "$V"; exec {V}>&-

# --- fetch/restore do NOT take the global lock (they run during an ongoing backup) ---
exec {H}>"$GLOBAL_LOCK"; flock -n "$H"
# fetch does not take the global lock → it runs past the lock and fails on archive
# lookup (the dev mock remote has no archive) with EX_DATAERR, not EX_TEMPFAIL(lock).
$BIN fetch 9005 2026_09_04-00_00_00 >/dev/null 2>&1; got=$?
[[ "$got" == 65 ]] && ok "fetch ignores the global lock (runs on, fails on lookup)" || bad "fetch global lock ($got)"
flock -u "$H"; exec {H}>&-

# --- config: unsafe permissions are refused ---
tmpcfg="$PWD/run/badcfg"; echo 'CACHE_DIR=/tmp/x' > "$tmpcfg"; chmod 666 "$tmpcfg"
PBO_CONFIG="$tmpcfg" $BIN status >/dev/null 2>&1
[[ $? == 78 ]] && ok "config with 666 is refused (EX_CONFIG)" || bad "unsafe config not refused"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
