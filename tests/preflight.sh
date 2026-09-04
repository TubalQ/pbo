#!/usr/bin/env bash
# tests/preflight.sh — steg 2-tester (preflight) med mockade pct/zfs/zpool/rclone.
# Kör inget mot riktig hårdvara.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN=./lxc-offsite

ROOT="$PWD"; MOCKS="$ROOT/tests/mocks"
export PATH="$MOCKS:$PATH"
export MOCK_CONF_DIR="$ROOT/run/conf"
export MOCK_ZFS_USED="$ROOT/run/zfs_used"
export MOCK_ZPOOL_FREE="$ROOT/run/zpool_free"

rm -rf "$ROOT/run"; mkdir -p "$MOCK_CONF_DIR" "$ROOT/run/cache"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

# En dev-config med givna overrides. chmod 600 så den godtas.
mkcfg() { # <fil> <extra-rader...>
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

# Container-config-fixtures (efterliknar `pct config`-utdata).
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

printf 'lxc-offsite — steg 2-tester (preflight, mockad)\n'

# --- A: friskt läge → ready, exit 0 ---
mkcfg "$ROOT/run/cfgA"
out="$(LXCO_CONFIG=$ROOT/run/cfgA $BIN --json preflight 8001 2>/dev/null)"; rc=$?
grep -q '"status":"ready"' <<<"$out" && [[ $rc == 0 ]] && ok "friskt läge: ready (exit 0)" || bad "A ready ($rc: $out)"
grep -q '"name":"container_exists","ok":true' <<<"$out" && ok "A: container_exists OK" || bad "A container_exists"
grep -q '"name":"zfs_space","ok":true' <<<"$out" && ok "A: zfs_space OK" || bad "A zfs_space"
grep -q '"name":"rclone_remote","ok":true' <<<"$out" && ok "A: rclone_remote OK" || bad "A rclone"

# --- B: bind-mount + backup=0 → varningar, men ändå ready ---
mkcfg "$ROOT/run/cfgB"
out="$(LXCO_CONFIG=$ROOT/run/cfgB $BIN --json preflight 8002 2>/dev/null)"; rc=$?
grep -q '"status":"ready"' <<<"$out" && [[ $rc == 0 ]] && ok "B: ready trots varningar" || bad "B ready ($rc)"
grep -q 'bind-mount' <<<"$out" && ok "B: bind-mount ger varning" || bad "B bind-mount-varning ($out)"
grep -q 'backup=0' <<<"$out" && ok "B: backup=0 ger varning" || bad "B backup=0-varning"

# --- C: för lite ZFS-utrymme → not_ready, exit 69 ---
# 8003 använder 400G på nvmepool; behov 1.5×=600G > free 452G → FAIL.
mkcfg "$ROOT/run/cfgC"
out="$(LXCO_CONFIG=$ROOT/run/cfgC $BIN --json preflight 8003 2>/dev/null)"; rc=$?
grep -q '"name":"zfs_space","ok":false' <<<"$out" && ok "C: zfs_space FAIL vid för lite utrymme" || bad "C zfs_space ($out)"
[[ $rc == 69 ]] && ok "C: exit EX_UNAVAILABLE (69)" || bad "C exit ($rc)"

# --- D: container finns ej → not_ready ---
mkcfg "$ROOT/run/cfgD"
out="$(LXCO_CONFIG=$ROOT/run/cfgD $BIN --json preflight 8099 2>/dev/null)"; rc=$?
grep -q '"name":"container_exists","ok":false' <<<"$out" && [[ $rc == 69 ]] && ok "D: okänd container FAIL" || bad "D ($rc: $out)"

# --- E: rclone-remote nere → FAIL ---
mkcfg "$ROOT/run/cfgE"
out="$(MOCK_RCLONE_OK=0 LXCO_CONFIG=$ROOT/run/cfgE $BIN --json preflight 8001 2>/dev/null)"; rc=$?
grep -q '"name":"rclone_remote","ok":false' <<<"$out" && ok "E: rclone nere → FAIL" || bad "E rclone ($out)"

# --- F: cache ej skrivbar → FAIL (CACHE_DIR under en vanlig fil) ---
touch "$ROOT/run/afile"
mkcfg "$ROOT/run/cfgF" "CACHE_DIR=$ROOT/run/afile/omojligt"
out="$(LXCO_CONFIG=$ROOT/run/cfgF $BIN --json preflight 8001 2>/dev/null)"; rc=$?
grep -q '"name":"cache_writable","ok":false' <<<"$out" && ok "F: ej skrivbar cache → FAIL" || bad "F cache ($out)"

# --- G: backup avbryts om preflight underkänns (integration mot low-nivå) ---
mkcfg "$ROOT/run/cfgG"
LXCO_CONFIG=$ROOT/run/cfgG $BIN backup 8003 >/dev/null 2>&1; rc=$?
[[ $rc == 69 ]] && ok "G: backup avbryts vid underkänd preflight (exit 69)" || bad "G backup-avbrott ($rc)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
