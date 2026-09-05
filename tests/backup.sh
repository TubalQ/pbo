#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/backup.sh: step 3 tests (dump/sha256/structure check/meta), mocked vzdump.
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

# Fixtures (same style as step 2).
printf 'nvmepool/subvol-8002-disk-0 1073741824\nnewbulk/subvol-8002-disk-1 5368709120\n' > "$MOCK_ZFS_USED"
printf 'nvmepool 485331534807\nnewbulk 3497914662912\n' > "$MOCK_ZPOOL_FREE"
cat > "$MOCK_CONF_DIR/8002.conf" <<'C'
arch: amd64
hostname: med-mounts
rootfs: nvmepool:subvol-8002-disk-0,size=8G
mp0: newbulk:subvol-8002-disk-1,mp=/data
mp1: /srv/host-katalog,mp=/bind
mp2: newbulk:subvol-8002-disk-2,mp=/scratch,backup=0
unprivileged: 1
C
mkcfg() { local f="$1"; { echo "CACHE_DIR=$ROOT/run/cache"; echo "LOG_DIR=$ROOT/run/log"; echo "STATE_DIR=$ROOT/run/state"; echo "LOCK_DIR=$ROOT/run/lock"; echo "RCLONE_REMOTE=dev-mock"; echo "OFFSITE_ENABLED=false"; } > "$f"; chmod 600 "$f"; }
mkcfg "$ROOT/run/cfg"
export PBO_CONFIG="$ROOT/run/cfg"

# --- run backup ---
out="$($BIN --json backup 8002 2>/dev/null)"; rc=$?
grep -q '"status":"dumped"' <<<"$out" && [[ $rc == 0 ]] && ok "backup: status dumped (exit 0)" || bad "status ($rc: $out)"

archive="$(python3 -c 'import sys,json; print(json.load(sys.stdin)["archive"])' <<<"$out" 2>/dev/null)"
[[ -f "$archive" ]] && ok "archive created: $(basename "$archive")" || bad "archive missing ($archive)"
[[ -f "$archive.sha256" ]] && ok "sha256 sidecar exists" || bad "sha256 sidecar missing"
[[ -f "$archive.meta.json" ]] && ok "meta.json exists" || bad "meta.json missing"
[[ -f "$archive.conf" ]] && ok "config sidecar exists" || bad "config sidecar missing"

# sha256 matches the archive
want="$(awk '{print $1}' "$archive.sha256")"
got="$(sha256sum "$archive" | awk '{print $1}')"
[[ "$want" == "$got" ]] && ok "sha256 matches the archive" || bad "sha256 mismatch"

# structure check: the archive is a valid tar.zst
zstd -t "$archive" >/dev/null 2>&1 && ok "archive passes zstd -t" || bad "zstd -t"
tar --zstd -tf "$archive" >/dev/null 2>&1 && ok "archive passes tar -tf" || bad "tar -tf"

# meta.json: valid JSON + bind-mount/backup=0 included
python3 -m json.tool "$archive.meta.json" >/dev/null 2>&1 && ok "meta.json is valid JSON" || bad "meta.json invalid"
grep -q 'bind' "$archive.meta.json" && ok "meta: bind-mount registered" || bad "meta bind-mount"
grep -q 'mp2' "$archive.meta.json" && ok "meta: backup=0 volume registered" || bad "meta backup=0"
grep -q "\"sha256\": \"$got\"" "$archive.meta.json" && ok "meta: sha256 = archive's" || bad "meta sha256"

# job file with real-time log (step 3b)
job="$(python3 -c 'import sys,json; print(json.load(sys.stdin)["job"])' <<<"$out" 2>/dev/null)"
[[ -f "$job" ]] && grep -q 'creating vzdump archive' "$job" && ok "job file has real-time log" || bad "job file ($job)"
grep -qE '\[\+ *[0-9]+s\]' "$job" && ok "job log has progressive timestamps" || bad "timestamps missing"

# KEEP_LOCAL-independent: a second run should produce a new archive (prune in step 7)
sleep 1
out2="$($BIN --json backup 8002 2>/dev/null)"
a2="$(python3 -c 'import sys,json; print(json.load(sys.stdin)["archive"])' <<<"$out2" 2>/dev/null)"
[[ "$a2" != "$archive" && -f "$a2" ]] && ok "second run produces new archive" || bad "second run ($a2)"

# --- fuse-CT forced to --mode stop (deadlock guard) ---
cat > "$MOCK_CONF_DIR/8009.conf" <<'C'
hostname: fuse-ct
rootfs: nvmepool:subvol-8009-disk-0,size=8G
features: nesting=1,keyctl=1,fuse=1
unprivileged: 1
C
printf 'nvmepool/subvol-8009-disk-0 1073741824\n' >> "$MOCK_ZFS_USED"
out="$($BIN --json backup 8009 2>/dev/null)"
a="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["archive"])' <<<"$out" 2>/dev/null)"
grep -q '"mode": "stop"' "$a.meta.json" && ok "fuse-CT → --mode stop (auto-guard)" || bad "fuse mode ($(grep mode "$a.meta.json"))"
# normal CT stays snapshot
grep -q '"mode": "snapshot"' "$archive.meta.json" && ok "non-fuse CT → snapshot" || bad "8002 mode"
# VZDUMP_STOP_VMIDS override
mkcfg "$ROOT/run/cfg2"; echo "VZDUMP_STOP_VMIDS=8002" >> "$ROOT/run/cfg2"
out="$(PBO_CONFIG=$ROOT/run/cfg2 $BIN --json backup 8002 2>/dev/null)"
a2="$(python3 -c 'import sys,json;print(json.load(sys.stdin)["archive"])' <<<"$out" 2>/dev/null)"
grep -q '"mode": "stop"' "$a2.meta.json" && ok "VZDUMP_STOP_VMIDS override → stop" || bad "override mode"

# --- dry-run touches nothing ---
before="$(ls "$ROOT/run/cache/8002" | wc -l)"
$BIN --json --dry-run backup 8002 >/dev/null 2>&1
after="$(ls "$ROOT/run/cache/8002" | wc -l)"
[[ "$before" == "$after" ]] && ok "--dry-run creates no archive" || bad "dry-run wrote ($before→$after)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
