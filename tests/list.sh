#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/list.sh — step 5 tests (list + fetch), mocked rclone.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN=./pbo
ROOT="$PWD"; export PATH="$ROOT/tests/mocks:$PATH"
rm -rf "$ROOT/run"; mkdir -p "$ROOT/run/cache"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
mkcfg() { local f="$1"; { echo "CACHE_DIR=$ROOT/run/cache"; echo "LOG_DIR=$ROOT/run/log"; echo "STATE_DIR=$ROOT/run/state"; echo "LOCK_DIR=$ROOT/run/lock"; echo "RCLONE_REMOTE=hetzner-crypt"; echo "REMOTE_PATH=lxc"; } > "$f"; chmod 600 "$f"; }
mkcfg "$ROOT/run/cfg"; export PBO_CONFIG="$ROOT/run/cfg"

# --- list: mock lsjson for vmid 9003 ---
cat > "$ROOT/run/lsjson" <<'EOF'
[
 {"Name":"vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst","Size":167768548,"ModTime":"2026-09-04T11:34:10+02:00","IsDir":false},
 {"Name":"vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst.sha256","Size":110,"ModTime":"2026-09-04T11:34:11+02:00","IsDir":false}
]
EOF
export MOCK_LSJSON_FILE="$ROOT/run/lsjson"

out="$($BIN --json list 9003 2>/dev/null)"
python3 -m json.tool <<<"$out" >/dev/null 2>&1 && ok "list --json: valid JSON" || bad "list json invalid ($out)"
n="$(python3 -c 'import sys,json; print(len(json.load(sys.stdin)["archives"]))' <<<"$out" 2>/dev/null)"
[[ "$n" == 1 ]] && ok "list: sidecars filtered out, 1 archive" || bad "list count ($n)"
grep -q '"size_bytes": *167768548' <<<"$out" && ok "list: size included" || bad "list size"
grep -q '"age_seconds"' <<<"$out" && ok "list: age computed" || bad "list age"
$BIN list 9003 2>/dev/null | grep -q 'vzdump-lxc-9003' && ok "list: human table" || bad "list table"

# --- fetch: simulated offsite with a REAL tiny archive + correct sha256 ---
OFF="$ROOT/run/offsite/9003"; mkdir -p "$OFF"
tmp="$(mktemp -d)"; echo "restore-data" > "$tmp/x"; tar --zstd -cf "$OFF/vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst" -C "$tmp" .
( cd "$OFF" && sha256sum "vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst" > "vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst.sha256" )
export MOCK_OFFSITE_DIR="$ROOT/run/offsite"
printf 'vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst\nvzdump-lxc-9003-2026_09_04-11_34_04.tar.zst.sha256\n' > "$ROOT/run/lsf_files"
export MOCK_LSF_FILES="$ROOT/run/lsf_files"

out="$($BIN --json fetch 9003 2026_09_04-11_34_04 2>/dev/null)"; rc=$?
grep -q '"status":"fetched"' <<<"$out" && [[ $rc == 0 ]] && ok "fetch: status fetched" || bad "fetch ($rc: $out)"
[[ -f "$ROOT/run/cache/restore/vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst" ]] && ok "fetch: archive in cache/restore" || bad "fetch archive missing"
grep -q '"verified":"sha256"' <<<"$out" && ok "fetch: sha256-verified" || bad "fetch verified"

# --- fetch corrupt: corrupt the sha256 sidecar → fetch should fail + delete ---
echo "0000000000000000000000000000000000000000000000000000000000000000  vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst" > "$OFF/vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst.sha256"
rm -rf "$ROOT/run/cache/restore"
$BIN --json fetch 9003 2026_09_04-11_34_04 >/dev/null 2>&1; rc=$?
[[ $rc == 65 ]] && ok "fetch corrupt sha256 → EX_DATAERR (65)" || bad "fetch corrupt exit ($rc)"
[[ ! -f "$ROOT/run/cache/restore/vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst" ]] && ok "fetch: corrupt archive deleted" || bad "corrupt archive remains"

# --- fetch unknown ts → error ---
printf '' > "$ROOT/run/lsf_files"
$BIN fetch 9003 9999_99_99 >/dev/null 2>&1; rc=$?
[[ $rc == 65 ]] && ok "fetch unknown ts → EX_DATAERR" || bad "fetch unknown ts ($rc)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
