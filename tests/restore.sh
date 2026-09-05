#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/restore.sh: step 6 tests (restore), mocked pct + rclone.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN=./pbo
ROOT="$PWD"; export PATH="$ROOT/tests/mocks:$PATH"
export MOCK_CONF_DIR="$ROOT/run/conf"
rm -rf "$ROOT/run"; mkdir -p "$ROOT/run/cache" "$MOCK_CONF_DIR"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
mkcfg() { local f="$1"; { echo "CACHE_DIR=$ROOT/run/cache"; echo "LOG_DIR=$ROOT/run/log"; echo "STATE_DIR=$ROOT/run/state"; echo "LOCK_DIR=$ROOT/run/lock"; echo "RCLONE_REMOTE=hetzner-crypt"; echo "REMOTE_PATH=lxc"; } > "$f"; chmod 600 "$f"; }
mkcfg "$ROOT/run/cfg"; export PBO_CONFIG="$ROOT/run/cfg"

# Simulated offsite for vmid 9003: real tiny archive + sidecars.
OFF="$ROOT/run/offsite/9003"; mkdir -p "$OFF"
tmp="$(mktemp -d)"; echo "d" > "$tmp/x"
B="vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst"
tar --zstd -cf "$OFF/$B" -C "$tmp" .
( cd "$OFF" && sha256sum "$B" > "$B.sha256" )
cat > "$OFF/$B.conf" <<'C'
hostname: restore-test
rootfs: nvmepool:subvol-9003-disk-0,size=2G
unprivileged: 0
C
cat > "$OFF/$B.meta.json" <<'C'
{"vmid":"9003","source_volumes":["newbulk|newbulk/subvol-9003-disk-0"],"bind_mounts_skipped":["mp1=/srv/x"],"excluded_backup0":["mp0"]}
C
export MOCK_OFFSITE_DIR="$ROOT/run/offsite"
printf '%s\n%s.sha256\n%s.conf\n%s.meta.json\n' "$B" "$B" "$B" "$B" > "$ROOT/run/lsf_files"
export MOCK_LSF_FILES="$ROOT/run/lsf_files"

# --- A: preview (without --yes) ---
out="$($BIN --json restore 9003 2026_09_04-11_34_04 --to 9010 2>/dev/null)"; rc=$?
grep -q '"status":"planned"' <<<"$out" && [[ $rc == 0 ]] && ok "preview: status planned" || bad "A ($rc: $out)"
grep -q '"unprivileged":"0"' <<<"$out" && ok "A: unprivileged read from sidecar (0)" || bad "A unpriv ($out)"
grep -q 'storage":"newbulk"' <<<"$out" && ok "A: storage from meta (newbulk)" || bad "A storage"
grep -q -- '--unprivileged 0' <<<"$out" && ok "A: command sets --unprivileged explicitly" || bad "A cmd"

# --- B: target vmid already exists → refuse ---
echo 'hostname: krock' > "$MOCK_CONF_DIR/9010.conf"
$BIN restore 9003 2026_09_04-11_34_04 --to 9010 >/dev/null 2>&1; rc=$?
[[ $rc == 64 ]] && ok "B: existing target vmid → EX_USAGE (64)" || bad "B exit ($rc)"
rm -f "$MOCK_CONF_DIR/9010.conf"

# --- C: --yes runs pct restore ---
out="$($BIN --json restore 9003 2026_09_04-11_34_04 --to 9010 --yes 2>/dev/null)"; rc=$?
grep -q '"status":"restored"' <<<"$out" && [[ $rc == 0 ]] && ok "C: --yes → status restored" || bad "C ($rc: $out)"

# --- D: pct restore fails → EX_SOFTWARE ---
MOCK_RESTORE_OK=0 $BIN restore 9003 2026_09_04-11_34_04 --to 9011 --yes >/dev/null 2>&1; rc=$?
[[ $rc == 70 ]] && ok "D: pct restore error → EX_SOFTWARE (70)" || bad "D exit ($rc)"

# --- E: --storage override respected ---
out="$($BIN --json restore 9003 2026_09_04-11_34_04 --to 9012 --storage nvmepool 2>/dev/null)"
grep -q '"storage":"nvmepool"' <<<"$out" && ok "E: --storage override" || bad "E storage"

# --- F: missing --to → EX_USAGE ---
$BIN restore 9003 2026_09_04-11_34_04 >/dev/null 2>&1; rc=$?
[[ $rc == 64 ]] && ok "F: missing --to → EX_USAGE" || bad "F exit ($rc)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
