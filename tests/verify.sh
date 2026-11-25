#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/verify.sh: scheduled deep verify. Real local restic repo.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE and NTFY_CREDS_FILE are the machine's
# own files: point them into the checkout, at paths nothing creates (a config
# line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.creds"
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping verify tests"; exit 0; }

printf 'pbo: scheduled verify tests\n'
RUN="$ROOT/run-verify"; rm -rf "$RUN"; mkdir -p "$RUN"/{cache,state,log,lock,bin,data}
# systemctl mocked: verify never reaches the host's units (pbo-mount.service)
install -m 0755 tests/mocks/systemctl "$RUN/bin/"; export PATH="$RUN/bin:$PATH"
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
cat > "$RUN/config" <<CFG
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
BACKUP_ORDER=8001
LOCAL_REPO=true
OFFSITE_ENABLED=false
RESTIC_CACHE_REPO=$RUN/repo
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
VERIFY_ROTATE=3
CFG
chmod 600 "$RUN/config"; export PBO_CONFIG="$RUN/config"
R() { RESTIC_PASSWORD_FILE="$RUN/pass" RESTIC_CACHE_DIR="$RUN/rcache" restic -r "$RUN/repo" "$@"; }
R init >/dev/null 2>&1; head -c 200000 /dev/urandom > "$RUN/data/f"; R backup -q --tag vmid=8001 "$RUN/data" >/dev/null 2>&1

out="$($BIN doctor 2>&1)"
grep -q 'WARN.*no verify recorded' <<<"$out" && ok "doctor warns before the first verify" || bad "no-verify warn: $out"

for want in 1/3 2/3 3/3 1/3; do
    o="$($BIN --json verify --scheduled 2>/dev/null)"
    [[ "$(jq -r .subset <<<"$o")" == "$want" ]] && ok "scheduled verify reads slice $want" || bad "slice want $want got $(jq -r .subset <<<"$o")"
done
jq -e '.ok==true and .subset=="1/3"' "$RUN/state/verify.last" >/dev/null && ok "verify.last records the result" || bad "verify.last: $(cat "$RUN/state/verify.last")"

o="$($BIN --json verify 2>/dev/null)"
[[ "$(jq -r .subset <<<"$o")" == structure ]] && ok "plain verify stays structure-only" || bad "plain verify subset $(jq -r .subset <<<"$o")"
[[ "$(cat "$RUN/state/verify.slice")" == 1 ]] && ok "plain verify does not advance the slice" || bad "slice moved: $(cat "$RUN/state/verify.slice")"

out="$($BIN doctor 2>&1)"
grep -q 'OK.*last verify 0d ago' <<<"$out" && ok "doctor shows a recent verify" || bad "doctor recent: $out"

# corrupt a data pack: verify fails, doctor fails, the slice is not advanced
echo 5 > "$RUN/state/verify.slice"; before=5   # ROTATE=1 would write 1 if it advanced
pk="$(find "$RUN/repo/data" -type f | head -1)"; chmod u+w "$pk"; printf 'garbage' | dd of="$pk" bs=1 seek=100 conv=notrunc 2>/dev/null
sed -i "s/^VERIFY_ROTATE=.*/VERIFY_ROTATE=1/" "$RUN/config"; $BIN --json verify --scheduled >/dev/null 2>&1; rc=$?
[[ $rc == 65 ]] && ok "corrupted pack → verify EX_DATAERR" || bad "corrupt verify rc=$rc"
jq -e '.ok==false' "$RUN/state/verify.last" >/dev/null && ok "failed verify recorded" || bad "verify.last after failure"
[[ "$(cat "$RUN/state/verify.slice")" == "$before" ]] && ok "failed slice is not advanced (re-read next time)" || bad "slice advanced on failure"
$BIN doctor >/dev/null 2>&1; rc=$?
[[ $rc != 0 ]] && ok "doctor fails after a failed verify" || bad "doctor rc=$rc after failed verify"

$BIN verify --bogus >/dev/null 2>&1; [[ $? == 64 ]] && ok "unknown verify flag → EX_USAGE" || bad "verify flag"

rm -rf "$RUN"
printf '%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
