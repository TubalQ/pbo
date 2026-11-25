#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/restic.sh: end-to-end tests of the restic engine against a REAL local
# restic repo (offsite disabled), with Proxmox (pct/qm/vzdump) mocked. Covers
# backup → list → prune → verify → fetch → unlock → doctor, plus guest-type
# detection and preflight volume classification. No real host is touched.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start) are the
# machine's own files: point them into the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.env" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
    PBO_PVE_CFS_DIR="$PWD/run-none/pve" PVE_STORAGE_CFG="$PWD/run-none/pve/storage.cfg"
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
# systemctl mocked too: prune/verify never reach the host's units (pbo-mount.service)
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm tests/mocks/systemctl "$RUN/bin/"
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

# --- list --reasons annotates each snapshot with its retention bucket + keep flag ---
sleep 1; $BIN backup 8001 >/dev/null 2>&1   # now two snapshots of 8001
$BIN --json list --reasons > "$RUN/lr.json" 2>/dev/null
jq -e '.archives[0]|has("reasons") and has("keep")' "$RUN/lr.json" >/dev/null \
    && ok "list --reasons: adds reasons + keep fields" || bad "list --reasons fields"
jq -e '[.archives[]|select(.keep==true and (.reasons|length>0))]|length>=1' "$RUN/lr.json" >/dev/null \
    && ok "list --reasons: a kept snapshot has a reason" || bad "list --reasons kept reason"
# KEEP_LOCAL=1 → the older of the two is outside policy (keep=false)
jq -e '[.archives[]|select(.keep==false)]|length>=1' "$RUN/lr.json" >/dev/null \
    && ok "list --reasons: over-policy snapshot flagged keep=false" || bad "list --reasons keep=false"

# --- a repo held by an exclusive lock (what prune takes). Hold one with a
# real restic process: `key passwd` locks exclusively, then blocks reading a fifo. ---
hold_lock() {
    mkfifo "$RUN/lockfifo"
    RESTIC_PASSWORD_FILE="$RUN/pass" RESTIC_CACHE_DIR="$RUN/rcache" \
        restic -r "$RUN/repo" key passwd --new-password-file "$RUN/lockfifo" >/dev/null 2>&1 &
    LOCKPID=$!
    for _ in $(seq 50); do restic -r "$RUN/repo" --password-file "$RUN/pass" list locks --no-lock 2>/dev/null | grep -q . && break; sleep 0.1; done
}
release_lock() { printf 'testpass\n' > "$RUN/lockfifo"; wait "$LOCKPID" 2>/dev/null; rm -f "$RUN/lockfifo"; }

hold_lock
$BIN preflight 8001 >/dev/null 2>&1 && ok "preflight: repo check passes while the repo is locked (--no-lock)" || bad "preflight fails on a locked repo"
RESTIC_RETRY_LOCK=2s $BIN backup 8001 > "$RUN/lk.out" 2>&1; rc=$?
[[ $rc == 75 ]] && ok "backup on a locked repo → EX_TEMPFAIL" || bad "locked backup rc=$rc"
grep -q 'repo locked (repository is already locked' "$RUN/lk.out" && ok "backup on a locked repo says 'repo locked'" || bad "lock reason missing ($(grep -i error "$RUN/lk.out" | tail -1))"
grep -q 'init failed' "$RUN/lk.out" && bad "locked repo still reported as 'init failed'" || ok "locked repo is not reported as 'init failed'"
release_lock

# --retry-lock: a short overlap waits instead of failing
hold_lock
( sleep 3; release_lock ) &
RESTIC_RETRY_LOCK=1m $BIN backup 8001 > "$RUN/rl.out" 2>&1; rc=$?
wait
[[ $rc == 0 ]] && ok "backup waits out a short repo lock (--retry-lock)" || bad "retry-lock backup rc=$rc ($(tail -2 "$RUN/rl.out"))"

# --- second backup already ran above; prune keep-last=1 leaves exactly one ---
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

# --- prune surfaces a FAILED tier (non-zero exit + ok:false) instead of a silent 0 ---
cat > "$RUN/config-fail" <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
OFFSITE_ENABLED=true
LOCAL_REPO=false
RESTIC_OFFSITE_REPO=$RUN/bogus-not-a-repo
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
EOF
chmod 600 "$RUN/config-fail"
PBO_CONFIG="$RUN/config-fail" PBO_NO_NOTIFY=1 $BIN --json prune > "$RUN/pf.json" 2>/dev/null; rc=$?
[[ $rc != 0 ]] && ok "prune: unreachable tier → non-zero exit" || bad "prune failure exit ($rc)"
jq -e '.ok==false and (.failed_tiers|index("offsite")) != null' "$RUN/pf.json" >/dev/null 2>&1 \
    && ok "prune: failure surfaced in envelope (not a silent 0)" || bad "prune failure envelope ($(cat "$RUN/pf.json"))"

# --- _conf_unpriv: sidecar first, else the archive's own pct.conf; no line = privileged ---
# shellcheck disable=SC1090  # only the one function, cut out of lib/restic.sh
source <(sed -n '/^_conf_unpriv() {/,/^}/p' lib/restic.sh)
cu="$RUN/cu"; mkdir -p "$cu/src/etc/vzdump"
printf 'arch: amd64\nunprivileged: 1\n' > "$cu/u.tar.conf";  : > "$cu/u.tar"
printf 'arch: amd64\nhostname: p\n[snap1]\nunprivileged: 1\n' > "$cu/p.tar.conf"; : > "$cu/p.tar"
printf 'arch: amd64\nhostname: a\n' > "$cu/src/etc/vzdump/pct.conf"; tar -C "$cu/src" -cf "$cu/a.tar" ./etc/vzdump/pct.conf; : > "$cu/a.tar.conf"
printf 'arch: amd64\nunprivileged: 1\n' > "$cu/src/etc/vzdump/pct.conf"; tar -C "$cu/src" -cf "$cu/b.tar" ./etc/vzdump/pct.conf
: > "$cu/none.tar"
r="$(_conf_unpriv "$cu/u.tar") $(_conf_unpriv "$cu/p.tar") $(_conf_unpriv "$cu/a.tar") $(_conf_unpriv "$cu/b.tar") $(_conf_unpriv "$cu/none.tar")"
[[ "$r" == "1 0 0 1 1" ]] && ok "_conf_unpriv: sidecar 1, no line 0 (snapshot section ignored), empty sidecar → archive, unreadable → 1" \
    || bad "_conf_unpriv got '$r', want '1 0 0 1 1'"

rm -rf "$RUN"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
