#!/usr/bin/env bash
# tests/upload.sh — steg 4-tester (upload + offsite-verifiering), mockad rclone.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN=./lxc-offsite
ROOT="$PWD"; MOCKS="$ROOT/tests/mocks"
export PATH="$MOCKS:$PATH"
export MOCK_CONF_DIR="$ROOT/run/conf" MOCK_ZFS_USED="$ROOT/run/zfs_used" MOCK_ZPOOL_FREE="$ROOT/run/zpool_free"
rm -rf "$ROOT/run"; mkdir -p "$MOCK_CONF_DIR" "$ROOT/run/cache"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

printf 'nvmepool/subvol-8002-disk-0 1073741824\n' > "$MOCK_ZFS_USED"
printf 'nvmepool 485331534807\n' > "$MOCK_ZPOOL_FREE"
cat > "$MOCK_CONF_DIR/8002.conf" <<'C'
hostname: up-test
rootfs: nvmepool:subvol-8002-disk-0,size=8G
unprivileged: 1
C
mkcfg() { local f="$1"; shift; { echo "CACHE_DIR=$ROOT/run/cache"; echo "LOG_DIR=$ROOT/run/log"; echo "STATE_DIR=$ROOT/run/state"; echo "LOCK_DIR=$ROOT/run/lock"; echo "RCLONE_REMOTE=hetzner-crypt"; echo "REMOTE_PATH=lxc"; for l in "$@"; do echo "$l"; done; } > "$f"; chmod 600 "$f"; }

# --- A: happy path (crypt-remote → cryptcheck) ---
mkcfg "$ROOT/run/cfgA"
export MOCK_LOG="$ROOT/run/rclone.calls"; : > "$MOCK_LOG"
out="$(MOCK_REMOTE_TYPE=crypt LXCO_CONFIG=$ROOT/run/cfgA $BIN --json backup 8002 2>/dev/null)"; rc=$?
grep -q '"status":"uploaded"' <<<"$out" && [[ $rc == 0 ]] && ok "upload: status uploaded (exit 0)" || bad "A status ($rc: $out)"
grep -q '"verified":"offsite"' <<<"$out" && ok "A: verified=offsite" || bad "A verified"
grep -q '^copy ' "$MOCK_LOG" && ok "A: rclone copy anropades" || bad "A copy ej anropad"
grep -q '^cryptcheck ' "$MOCK_LOG" && ok "A: crypt-remote → cryptcheck" || bad "A cryptcheck ej vald ($(cat "$MOCK_LOG"))"
grep -q -- '--include 8002' "$MOCK_LOG" 2>/dev/null || grep -q 'include' "$MOCK_LOG" && ok "A: include-filter används" || bad "A include"

# --- B: icke-crypt remote → check --checksum ---
mkcfg "$ROOT/run/cfgB"; : > "$MOCK_LOG"
MOCK_REMOTE_TYPE=sftp LXCO_CONFIG=$ROOT/run/cfgB $BIN --json backup 8002 >/dev/null 2>&1
grep -q '^check ' "$MOCK_LOG" && ok "B: sftp-remote → check --checksum" || bad "B check ej vald ($(cat "$MOCK_LOG"))"
grep -q 'checksum' "$MOCK_LOG" && ok "B: --checksum flaggan med" || bad "B checksum-flagga"

# --- C: verifiering misslyckas → radera + avbryt (EX_DATAERR 65) ---
mkcfg "$ROOT/run/cfgC"; : > "$MOCK_LOG"
MOCK_REMOTE_TYPE=crypt MOCK_VERIFY_OK=0 LXCO_CONFIG=$ROOT/run/cfgC $BIN --json backup 8002 >/dev/null 2>&1; rc=$?
[[ $rc == 65 ]] && ok "C: verifieringsfel → EX_DATAERR (65)" || bad "C exit ($rc)"
grep -q '^delete ' "$MOCK_LOG" && ok "C: uppladdat raderades vid verifieringsfel" || bad "C delete ($(cat "$MOCK_LOG"))"

# --- D: upload misslyckas → avbryt (EX_UNAVAILABLE 69), ingen verifiering ---
mkcfg "$ROOT/run/cfgD"; : > "$MOCK_LOG"
MOCK_UPLOAD_OK=0 LXCO_CONFIG=$ROOT/run/cfgD $BIN --json backup 8002 >/dev/null 2>&1; rc=$?
[[ $rc == 69 ]] && ok "D: uploadfel → EX_UNAVAILABLE (69)" || bad "D exit ($rc)"
grep -qE '^(check|cryptcheck) ' "$MOCK_LOG" && bad "D: verifiering kördes trots uploadfel" || ok "D: ingen verifiering efter uploadfel"

# --- E: lokala artefakter finns kvar oavsett (arkiv verifierat lokalt före upload) ---
[[ -n "$(ls "$ROOT/run/cache/8002"/*.tar.zst 2>/dev/null)" ]] && ok "E: lokalt arkiv finns" || bad "E arkiv"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
