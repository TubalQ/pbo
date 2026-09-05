#!/usr/bin/env bash
# tests/preflight.sh — step 2 tests (preflight) with mocked pct/zfs/zpool/rclone.
# Runs nothing against real hardware.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN=./pbo

ROOT="$PWD"; MOCKS="$ROOT/tests/mocks"
export PATH="$MOCKS:$PATH"
export MOCK_CONF_DIR="$ROOT/run/conf"
export MOCK_ZFS_USED="$ROOT/run/zfs_used"
export MOCK_ZPOOL_FREE="$ROOT/run/zpool_free"

rm -rf "$ROOT/run"; mkdir -p "$MOCK_CONF_DIR" "$ROOT/run/cache"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

# A dev config with the given overrides. chmod 600 so it is accepted.
mkcfg() { # <file> <extra-lines...>
    local f="$1"; shift
    { echo "CACHE_DIR=$ROOT/run/cache"
      echo "LOG_DIR=$ROOT/run/log"
      echo "STATE_DIR=$ROOT/run/state"
      echo "LOCK_DIR=$ROOT/run/lock"
      echo "RCLONE_REMOTE=dev-mock"
      for l in "$@"; do echo "$l"; done
    } > "$f"; chmod 600 "$f"
}

# Fixtures: ZFS used/free (bytes).
cat > "$MOCK_ZFS_USED" <<EOF
nvmepool/subvol-8001-disk-0 1073741824
nvmepool/subvol-8002-disk-0 1073741824
newbulk/subvol-8002-disk-1 5368709120
nvmepool/subvol-8003-disk-0 400000000000
EOF
cat > "$MOCK_ZPOOL_FREE" <<EOF
nvmepool 485331534807
newbulk 3497914662912
EOF

# Container config fixtures (mimics `pct config` output).
cat > "$MOCK_CONF_DIR/8001.conf" <<'EOF'
arch: amd64
hostname: friskt
rootfs: nvmepool:subvol-8001-disk-0,size=8G
unprivileged: 1
EOF
cat > "$MOCK_CONF_DIR/8002.conf" <<'EOF'
arch: amd64
hostname: med-mounts
rootfs: nvmepool:subvol-8002-disk-0,size=8G
mp0: newbulk:subvol-8002-disk-1,mp=/data,size=100G
mp1: /srv/host-katalog,mp=/bind
mp2: newbulk:subvol-8002-disk-2,mp=/scratch,backup=0
unprivileged: 1
EOF
cat > "$MOCK_CONF_DIR/8003.conf" <<'EOF'
arch: amd64
hostname: for-stor
rootfs: nvmepool:subvol-8003-disk-0,size=400G
unprivileged: 0
EOF

printf 'pbo — step 2 tests (preflight, mocked)\n'

# --- A: healthy state → ready, exit 0 ---
mkcfg "$ROOT/run/cfgA"
out="$(PBO_CONFIG=$ROOT/run/cfgA $BIN --json preflight 8001 2>/dev/null)"; rc=$?
grep -q '"status":"ready"' <<<"$out" && [[ $rc == 0 ]] && ok "healthy state: ready (exit 0)" || bad "A ready ($rc: $out)"
grep -q '"name":"container_exists","ok":true' <<<"$out" && ok "A: container_exists OK" || bad "A container_exists"
grep -q '"name":"zfs_space","ok":true' <<<"$out" && ok "A: zfs_space OK" || bad "A zfs_space"
grep -q '"name":"rclone_remote","ok":true' <<<"$out" && ok "A: rclone_remote OK" || bad "A rclone"

# --- B: bind-mount + backup=0 → warnings, but still ready ---
mkcfg "$ROOT/run/cfgB"
out="$(PBO_CONFIG=$ROOT/run/cfgB $BIN --json preflight 8002 2>/dev/null)"; rc=$?
grep -q '"status":"ready"' <<<"$out" && [[ $rc == 0 ]] && ok "B: ready despite warnings" || bad "B ready ($rc)"
grep -q 'bind mount' <<<"$out" && ok "B: bind-mount gives warning" || bad "B bind-mount-warning ($out)"
grep -q 'backup=0' <<<"$out" && ok "B: backup=0 gives warning" || bad "B backup=0-warning"

# --- C: too little ZFS space → not_ready, exit 69 ---
# 8003 uses 400G on nvmepool; need 1.5×=600G > free 452G → FAIL.
mkcfg "$ROOT/run/cfgC"
out="$(PBO_CONFIG=$ROOT/run/cfgC $BIN --json preflight 8003 2>/dev/null)"; rc=$?
grep -q '"name":"zfs_space","ok":false' <<<"$out" && ok "C: zfs_space FAIL when too little space" || bad "C zfs_space ($out)"
[[ $rc == 69 ]] && ok "C: exit EX_UNAVAILABLE (69)" || bad "C exit ($rc)"

# --- D: container does not exist → not_ready ---
mkcfg "$ROOT/run/cfgD"
out="$(PBO_CONFIG=$ROOT/run/cfgD $BIN --json preflight 8099 2>/dev/null)"; rc=$?
grep -q '"name":"container_exists","ok":false' <<<"$out" && [[ $rc == 69 ]] && ok "D: unknown container FAIL" || bad "D ($rc: $out)"

# --- E: rclone remote down → FAIL ---
mkcfg "$ROOT/run/cfgE"
out="$(MOCK_RCLONE_OK=0 PBO_CONFIG=$ROOT/run/cfgE $BIN --json preflight 8001 2>/dev/null)"; rc=$?
grep -q '"name":"rclone_remote","ok":false' <<<"$out" && ok "E: rclone down → FAIL" || bad "E rclone ($out)"

# --- F: cache not writable → FAIL (CACHE_DIR under a regular file) ---
touch "$ROOT/run/afile"
mkcfg "$ROOT/run/cfgF" "CACHE_DIR=$ROOT/run/afile/omojligt"
out="$(PBO_CONFIG=$ROOT/run/cfgF $BIN --json preflight 8001 2>/dev/null)"; rc=$?
grep -q '"name":"cache_writable","ok":false' <<<"$out" && ok "F: non-writable cache → FAIL" || bad "F cache ($out)"

# --- G: backup aborts if preflight fails (integration against low level) ---
mkcfg "$ROOT/run/cfgG"
PBO_CONFIG=$ROOT/run/cfgG $BIN backup 8003 >/dev/null 2>&1; rc=$?
[[ $rc == 69 ]] && ok "G: backup aborts on failed preflight (exit 69)" || bad "G backup-abort ($rc)"

# --- H: rootfs on non-ZFS storage (local-lvm) → zfs_space skipped, still ready ---
cat > "$MOCK_CONF_DIR/8004.conf" <<'C'
hostname: pa-lvm
rootfs: local-lvm:vm-8004-disk-0,size=8G
unprivileged: 1
C
mkcfg "$ROOT/run/cfgH"
out="$(PBO_CONFIG=$ROOT/run/cfgH $BIN --json preflight 8004 2>/dev/null)"; rc=$?
grep -q '"name":"zfs_space","ok":true' <<<"$out" && [[ $rc == 0 ]] && ok "H: non-ZFS storage → zfs_space skipped (ready)" || bad "H ($rc: $out)"
grep -q 'ZFS space check skipped' <<<"$out" && ok "H: explanatory detail" || bad "H detail"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
