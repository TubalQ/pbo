#!/usr/bin/env bash
# tests/backup.sh — steg 3-tester (dump/sha256/strukturkontroll/meta), mockad vzdump.
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

# Fixtures (samma stil som steg 2).
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
mkcfg() { local f="$1"; { echo "CACHE_DIR=$ROOT/run/cache"; echo "LOG_DIR=$ROOT/run/log"; echo "STATE_DIR=$ROOT/run/state"; echo "LOCK_DIR=$ROOT/run/lock"; echo "RCLONE_REMOTE=dev-mock"; } > "$f"; chmod 600 "$f"; }
mkcfg "$ROOT/run/cfg"
export LXCO_CONFIG="$ROOT/run/cfg"

# --- kör backup ---
out="$($BIN --json backup 8002 2>/dev/null)"; rc=$?
grep -q '"status":"dumped"' <<<"$out" && [[ $rc == 0 ]] && ok "backup: status dumped (exit 0)" || bad "status ($rc: $out)"

archive="$(python3 -c 'import sys,json; print(json.load(sys.stdin)["archive"])' <<<"$out" 2>/dev/null)"
[[ -f "$archive" ]] && ok "arkiv skapat: $(basename "$archive")" || bad "arkiv saknas ($archive)"
[[ -f "$archive.sha256" ]] && ok "sha256-sidecar finns" || bad "sha256-sidecar saknas"
[[ -f "$archive.meta.json" ]] && ok "meta.json finns" || bad "meta.json saknas"
[[ -f "$archive.conf" ]] && ok "config-sidecar finns" || bad "config-sidecar saknas"

# sha256 stämmer mot arkivet
want="$(awk '{print $1}' "$archive.sha256")"
got="$(sha256sum "$archive" | awk '{print $1}')"
[[ "$want" == "$got" ]] && ok "sha256 matchar arkivet" || bad "sha256 stämmer ej"

# strukturkontroll: arkivet är ett giltigt tar.zst
zstd -t "$archive" >/dev/null 2>&1 && ok "arkivet passerar zstd -t" || bad "zstd -t"
tar --zstd -tf "$archive" >/dev/null 2>&1 && ok "arkivet passerar tar -tf" || bad "tar -tf"

# meta.json: giltig JSON + bind-mount/backup=0 med
python3 -m json.tool "$archive.meta.json" >/dev/null 2>&1 && ok "meta.json är giltig JSON" || bad "meta.json ogiltig"
grep -q 'bind' "$archive.meta.json" && ok "meta: bind-mount registrerad" || bad "meta bind-mount"
grep -q 'mp2' "$archive.meta.json" && ok "meta: backup=0-volym registrerad" || bad "meta backup=0"
grep -q "\"sha256\": \"$got\"" "$archive.meta.json" && ok "meta: sha256 = arkivets" || bad "meta sha256"

# jobbfil med realtidslogg (steg 3b)
job="$(python3 -c 'import sys,json; print(json.load(sys.stdin)["job"])' <<<"$out" 2>/dev/null)"
[[ -f "$job" ]] && grep -q 'creating vzdump archive' "$job" && ok "jobbfil har realtidslogg" || bad "jobbfil ($job)"
grep -qE '\[\+ *[0-9]+s\]' "$job" && ok "jobblogg har progressiva tidsstämplar" || bad "tidsstämplar saknas"

# KEEP_LOCAL-oberoende: en andra körning ska ge ett nytt arkiv (prune i steg 7)
sleep 1
out2="$($BIN --json backup 8002 2>/dev/null)"
a2="$(python3 -c 'import sys,json; print(json.load(sys.stdin)["archive"])' <<<"$out2" 2>/dev/null)"
[[ "$a2" != "$archive" && -f "$a2" ]] && ok "andra körningen ger nytt arkiv" || bad "andra körning ($a2)"

# --- dry-run rör ingenting ---
before="$(ls "$ROOT/run/cache/8002" | wc -l)"
$BIN --json --dry-run backup 8002 >/dev/null 2>&1
after="$(ls "$ROOT/run/cache/8002" | wc -l)"
[[ "$before" == "$after" ]] && ok "--dry-run skapar inget arkiv" || bad "dry-run skrev ($before→$after)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
