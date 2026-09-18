#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/restic.sh: end-to-end tests of the restic engine against a REAL local
# restic repo (offsite disabled), with Proxmox (pct/qm/vzdump) mocked. Covers
# backup → list → prune → verify → fetch → unlock → doctor, plus guest-type
# detection and preflight volume classification. No real host is touched.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping restic engine tests"; exit 0; }

printf 'pbo: restic engine tests\n'
RUN="$ROOT/run-restic"; rm -rf "$RUN"
mkdir -p "$RUN"/{cache,state,log,lock,conf,bin}
export MOCK_CONF_DIR="$RUN/conf"
export MOCK_LOG="$RUN/calls"; : > "$MOCK_LOG"
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh "$RUN/bin/"
export PATH="$RUN/bin:$PATH"

cat > "$RUN/config" <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
BACKUP_ORDER=8001
OFFSITE_ENABLED=false
LOCAL_REPO=true
RESTIC_CACHE_REPO=$RUN/repo
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
KEEP_LOCAL=1
EOF
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass" "$RUN/config"
export PBO_CONFIG="$RUN/config"

# fake LXC 8001. teststore is not in storage.cfg → treated as non-ZFS → the ZFS
# space check is skipped (no zfs/zpool mocks needed).
cat > "$MOCK_CONF_DIR/8001.conf" <<'EOF'
arch: amd64
hostname: test8001
rootfs: teststore:8001/vm-8001-disk-0.raw,size=2G
mp0: teststore:8001/data,mp=/data,backup=0
mp1: /host/bind,mp=/bind
unprivileged: 1
EOF

# --- init ---
$BIN init >/dev/null 2>&1 && ok "init creates the repo" || bad "init"

# --- guest-type detection (qm says no VM → lxc) ---
out="$($BIN --json preflight 8001 2>/dev/null)"
grep -q '"container_exists","ok":true' <<<"$out" && ok "preflight: guest exists (lxc)" || bad "preflight exists ($out)"
grep -q 'bind mount' <<<"$out" && ok "preflight: bind mount flagged" || bad "preflight bind mount"
grep -q 'backup=0' <<<"$out" && ok "preflight: backup=0 volume flagged" || bad "preflight backup=0"

# --- backup ---
$BIN --json backup 8001 > "$RUN/bk.json" 2>"$RUN/bk.err"; rc=$?
[[ $rc == 0 ]] && ok "backup 8001 succeeds" || bad "backup rc=$rc ($(tail -2 "$RUN/bk.err"))"
grep -q '"status":"uploaded"' "$RUN/bk.json" && ok "backup envelope: uploaded" || bad "backup envelope ($(cat "$RUN/bk.json"))"

# --- list: correct vmid + lxc/.tar archive name derived from tags ---
$BIN --json list > "$RUN/ls.json" 2>/dev/null
jq -e '.archives|length>=1' "$RUN/ls.json" >/dev/null && ok "list shows the snapshot" || bad "list empty"
jq -e '.archives[0].vmid=="8001"' "$RUN/ls.json" >/dev/null && ok "list: vmid tag read back" || bad "list vmid"
jq -e '.archives[0].archive|test("^vzdump-lxc-8001-.*\\.tar$")' "$RUN/ls.json" >/dev/null && ok "list: archive name (lxc/.tar)" || bad "list name"

# --- usage: fields present ---
$BIN --json usage 2>/dev/null | jq -e '.snapshots>=1 and .physical_bytes>=0' >/dev/null && ok "usage: stats fields" || bad "usage fields"

# --- second backup + prune keep-last=1 leaves exactly one ---
sleep 1; $BIN backup 8001 >/dev/null 2>&1
$BIN --json prune >/dev/null 2>&1
n="$($BIN --json list 2>/dev/null | jq '[.archives[]|select(.vmid=="8001")]|length')"
[[ "$n" == 1 ]] && ok "prune: keep-last=1 (one snapshot remains)" || bad "prune keep-last ($n)"

# --- verify both tiers (offsite disabled → cache only) ---
$BIN verify >/dev/null 2>&1 && ok "verify: restic check OK" || bad "verify"

# --- fetch: extract+verify newest snapshot into the cache ---
ts="$($BIN --json list 2>/dev/null | jq -r '.archives[0].archive' | grep -oE '[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}')"
$BIN --json fetch 8001 "$ts" > "$RUN/ft.json" 2>/dev/null && ok "fetch succeeds" || bad "fetch"
jq -e '.verified=="restic" and (.archive|test("\\.tar$"))' "$RUN/ft.json" >/dev/null && ok "fetch: verified archive extracted" || bad "fetch verified"

# --- unlock: no live lock → succeeds ---
$BIN unlock >/dev/null 2>&1 && ok "unlock: clears (no) stale locks" || bad "unlock"

# --- doctor: repo ok + guest 8001 has a fresh snapshot → no hard problems ---
$BIN --json doctor > "$RUN/dr.json" 2>/dev/null
jq -e '(.problems|tonumber)==0' "$RUN/dr.json" >/dev/null && ok "doctor: no problems" || bad "doctor ($(cat "$RUN/dr.json"))"

# --- doctor flags a guest with NO snapshot (add 8002 to the backup set) ---
sed -i 's/^BACKUP_ORDER=.*/BACKUP_ORDER=8001,8002/' "$RUN/config"
cp "$MOCK_CONF_DIR/8001.conf" "$MOCK_CONF_DIR/8002.conf"
$BIN --json doctor > "$RUN/dr2.json" 2>/dev/null
jq -e '(.problems|tonumber)>=1' "$RUN/dr2.json" >/dev/null && ok "doctor: flags a guest with no snapshot" || bad "doctor missing-guest"

rm -rf "$RUN"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
