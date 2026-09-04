#!/usr/bin/env bash
# tests/list.sh — steg 5-tester (list + fetch), mockad rclone.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
BIN=./lxc-offsite
ROOT="$PWD"; export PATH="$ROOT/tests/mocks:$PATH"
rm -rf "$ROOT/run"; mkdir -p "$ROOT/run/cache"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
mkcfg() { local f="$1"; { echo "CACHE_DIR=$ROOT/run/cache"; echo "LOG_DIR=$ROOT/run/log"; echo "STATE_DIR=$ROOT/run/state"; echo "LOCK_DIR=$ROOT/run/lock"; echo "RCLONE_REMOTE=hetzner-crypt"; echo "REMOTE_PATH=lxc"; } > "$f"; chmod 600 "$f"; }
mkcfg "$ROOT/run/cfg"; export LXCO_CONFIG="$ROOT/run/cfg"

# --- list: mocka lsjson för vmid 9003 ---
cat > "$ROOT/run/lsjson" <<'EOF'
[
 {"Name":"vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst","Size":167768548,"ModTime":"2026-09-04T11:34:10+02:00","IsDir":false},
 {"Name":"vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst.sha256","Size":110,"ModTime":"2026-09-04T11:34:11+02:00","IsDir":false}
]
EOF
export MOCK_LSJSON_FILE="$ROOT/run/lsjson"

out="$($BIN --json list 9003 2>/dev/null)"
python3 -m json.tool <<<"$out" >/dev/null 2>&1 && ok "list --json: giltig JSON" || bad "list json ogiltig ($out)"
n="$(python3 -c 'import sys,json; print(len(json.load(sys.stdin)["archives"]))' <<<"$out" 2>/dev/null)"
[[ "$n" == 1 ]] && ok "list: sidecars filtreras bort, 1 arkiv" || bad "list antal ($n)"
grep -q '"size_bytes": *167768548' <<<"$out" && ok "list: storlek med" || bad "list storlek"
grep -q '"age_seconds"' <<<"$out" && ok "list: ålder beräknad" || bad "list ålder"
$BIN list 9003 2>/dev/null | grep -q 'vzdump-lxc-9003' && ok "list: människotabell" || bad "list tabell"

# --- fetch: simulerat offsite med RIKTIGT litet arkiv + korrekt sha256 ---
OFF="$ROOT/run/offsite/9003"; mkdir -p "$OFF"
tmp="$(mktemp -d)"; echo "restore-data" > "$tmp/x"; tar --zstd -cf "$OFF/vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst" -C "$tmp" .
( cd "$OFF" && sha256sum "vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst" > "vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst.sha256" )
export MOCK_OFFSITE_DIR="$ROOT/run/offsite"
printf 'vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst\nvzdump-lxc-9003-2026_09_04-11_34_04.tar.zst.sha256\n' > "$ROOT/run/lsf_files"
export MOCK_LSF_FILES="$ROOT/run/lsf_files"

out="$($BIN --json fetch 9003 2026_09_04-11_34_04 2>/dev/null)"; rc=$?
grep -q '"status":"fetched"' <<<"$out" && [[ $rc == 0 ]] && ok "fetch: status fetched" || bad "fetch ($rc: $out)"
[[ -f "$ROOT/run/cache/restore/vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst" ]] && ok "fetch: arkiv i cache/restore" || bad "fetch arkiv saknas"
grep -q '"verified":"sha256"' <<<"$out" && ok "fetch: sha256-verifierad" || bad "fetch verified"

# --- fetch korrupt: fördärva sha256-sidecaren → fetch ska faila + radera ---
echo "0000000000000000000000000000000000000000000000000000000000000000  vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst" > "$OFF/vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst.sha256"
rm -rf "$ROOT/run/cache/restore"
$BIN --json fetch 9003 2026_09_04-11_34_04 >/dev/null 2>&1; rc=$?
[[ $rc == 65 ]] && ok "fetch korrupt sha256 → EX_DATAERR (65)" || bad "fetch korrupt exit ($rc)"
[[ ! -f "$ROOT/run/cache/restore/vzdump-lxc-9003-2026_09_04-11_34_04.tar.zst" ]] && ok "fetch: korrupt arkiv raderat" || bad "korrupt arkiv kvar"

# --- fetch okänd ts → fel ---
printf '' > "$ROOT/run/lsf_files"
$BIN fetch 9003 9999_99_99 >/dev/null 2>&1; rc=$?
[[ $rc == 65 ]] && ok "fetch okänt ts → EX_DATAERR" || bad "fetch okänt ts ($rc)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
