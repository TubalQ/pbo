#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/ingest.sh: archives that PVE backup jobs write to the pbo storage
# (lib/ingest.sh, lib/vzdump-hook; ADR 0006 Phase 2). Two REAL local restic
# repos (cache + offsite); vzdump, pct, qm, pvesh and pvesm are mocked, the
# vzdump lock and storage.cfg are files under run/. Nothing on the host is touched.
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
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping ingest tests"; exit 0; }

printf 'pbo: ingest and vzdump hook tests\n'
RUN="$ROOT/run/ingest"; rm -rf "$RUN"
mkdir -p "$RUN"/{cache/spool/dump,state,log,lock,conf,bin,elsewhere}
export MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/calls"; : > "$MOCK_LOG"
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/pvesh tests/mocks/pvesm tests/mocks/vzdump "$RUN/bin/"
export PATH="$RUN/bin:$PATH"
SPOOL="$RUN/cache/spool"; DUMP="$SPOOL/dump"; export MOCK_SPOOL="$SPOOL"
printf 'arch: amd64\nhostname: t8101\nrootfs: teststore:8101/vm-8101-disk-0.raw,size=1G\ntags: pbo-keep-daily-9\nunprivileged: 1\n' > "$MOCK_CONF_DIR/8101.conf"
printf 'arch: amd64\nhostname: t8102\nfeatures: fuse=1,nesting=1\nrootfs: teststore:8102/vm-8102-disk-0.raw,size=1G\nunprivileged: 1\n' > "$MOCK_CONF_DIR/8102.conf"
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
printf 'dir: local\n\tpath /var/lib/vz\n\npbo: pbo\n\tpath %s\n\tcontent backup\n' "$SPOOL" > "$RUN/storage.cfg"
: > "$RUN/vzdump.conf"; : > "$RUN/vzdump.lock"
# restic that fails `backup` while $RUN/fail-backup exists (a cache-side failure)
cat > "$RUN/bin/restic-wrap" <<EOF
#!/usr/bin/env bash
if [[ -e "$RUN/fail-backup" ]]; then for a in "\$@"; do [[ "\$a" == backup ]] && { echo "Fatal: injected backup failure" >&2; exit 1; }; done; fi
# while $RUN/order.on exists: log backup/copy into the hook log, to order them against vzdump's phases
if [[ -e "$RUN/order.on" ]]; then for a in "\$@"; do case "\$a" in backup|copy) echo "INFO: restic \$a" >> "$RUN/order.log"; break ;; esac; done; fi
exec restic "\$@"
EOF
chmod 0755 "$RUN/bin/restic-wrap"

mkcfg() { local f="$1"; shift; { cat <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
BACKUP_ORDER=8101
LOCAL_REPO=true
RESTIC_BIN=$RUN/bin/restic-wrap
RESTIC_CACHE_REPO=$RUN/repo-cache
RESTIC_OFFSITE_REPO=$RUN/repo-offsite
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
RESTIC_RETRY_LOCK=2s
STORAGE_BOX_SNAPSHOTS_CONFIRMED=true
NTFY_URL=
NTFY_CREDS_FILE=/nonexistent
PBO_CATALOG=$RUN/catalog/index.json
PVE_SPOOL_DIR=$SPOOL
PVE_STAGING_DIR=$RUN/staging
VZDUMP_CONF=$RUN/vzdump.conf
PVE_STORAGE_CFG=$RUN/storage.cfg
VZDUMP_LOCK=$RUN/vzdump.lock
EOF
    for l in "$@"; do echo "$l"; done; } > "$f"; chmod 600 "$f"; }
mkcfg "$RUN/config" "PBO_INTEGRATION=both"; export PBO_CONFIG="$RUN/config"
R() { local repo="$1"; shift; RESTIC_PASSWORD_FILE="$RUN/pass" RESTIC_CACHE_DIR="$RUN/rcache" restic -r "$repo" "$@"; }
snaps() { R "$1" snapshots --json --tag "vmid=$2${3:+,ts=$3}" 2>/dev/null; }
# spool_archive <vmid> [extra vzdump args]: a fresh archive in the spool, its path on stdout
spool_archive() {
    local before after
    before="$(ls "$DUMP" 2>/dev/null)"; sleep 1.1   # archives are named by the second
    vzdump "$1" --storage pbo --compress 0 "${@:2}" >/dev/null 2>&1
    after="$(ls "$DUMP")"
    comm -13 <(sort <<<"$before") <(sort <<<"$after") | grep -E '\.(tar|vma)$' | sed "s#^#$DUMP/#" | tail -1
}
tsof() { [[ "$1" =~ ([0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}) ]] && printf '%s' "${BASH_REMATCH[1]}"; }

$BIN init >/dev/null 2>&1 || bad "init"
$BIN catalog refresh >/dev/null 2>&1 || bad "catalog refresh (empty index)"

# --- A: mock vzdump → spool → ingest ---------------------------------------
a1="$(spool_archive 8101)"; ts1="$(tsof "$a1")"; b1="${a1##*/}"
[[ -f "$a1" && "$b1" == vzdump-lxc-8101-*.tar ]] && ok "A: vzdump --storage pbo writes the archive into the spool" || bad "A: spool archive '$a1'"
out="$($BIN --json ingest --vmid 8101 --archive "$a1" 2>"$RUN/a.err")"; rc=$?
[[ $rc == 0 ]] && jq -e '.status == "ingested" and .ok == true and .vmid == "8101" and .archive == "'"$b1"'"' >/dev/null 2>&1 <<<"$out" \
    && ok "A: ingest exits 0 with an 'ingested' result" || bad "A: ingest rc=$rc $out $(tail -3 "$RUN/a.err")"
cj="$(snaps "$RUN/repo-cache" 8101 "$ts1")"; oj="$(snaps "$RUN/repo-offsite" 8101 "$ts1")"
jq -e 'length == 1 and (.[0].tags | index("vmid=8101") and index("ts='"$ts1"'") and index("type=lxc") and index("keep=d9"))' >/dev/null 2>&1 <<<"$cj" \
    && ok "A: cache snapshot tagged vmid/ts/type/keep" || bad "A: cache tags: $cj"
jq -e 'length == 1 and (.[0].tags | index("vmid=8101") and index("ts='"$ts1"'") and index("type=lxc") and index("keep=d9"))' >/dev/null 2>&1 <<<"$oj" \
    && ok "A: offsite snapshot tagged vmid/ts/type/keep" || bad "A: offsite tags: $oj"
jq -e --arg p "$RUN/cache/8101" '.[0].paths == [$p]' >/dev/null 2>&1 <<<"$cj" && jq -e --arg p "$RUN/cache/8101" '.[0].paths == [$p]' >/dev/null 2>&1 <<<"$oj" \
    && ok "A: snapshot path is \$CACHE_DIR/8101 in both repos (same group as pbo's own backups)" || bad "A: paths $(jq -c '.[0].paths' <<<"$cj") $(jq -c '.[0].paths' <<<"$oj")"
files="$(R "$RUN/repo-cache" ls --json "$(jq -r '.[0].id' <<<"$cj")" 2>/dev/null | jq -r 'select(.type == "file") | .name' 2>/dev/null | sort | tr '\n' ' ')"
[[ "$files" == "$b1 $b1.conf " ]] && ok "A: the snapshot holds the archive and its .conf sidecar" || bad "A: snapshot files: $files"
[[ -z "$(ls -A "$DUMP")" ]] && ok "A: the spool is empty" || bad "A: spool: $(ls "$DUMP")"
[[ -z "$(find "$RUN/cache/8101" -maxdepth 1 -name '*vzdump*' 2>/dev/null)" ]] && ok "A: no loose archive left in \$CACHE_DIR/8101" || bad "A: loose: $(ls "$RUN/cache/8101")"
jq -e --arg v "backup/$b1" --arg c "$(jq -r '.[0].id' <<<"$cj")" --arg o "$(jq -r '.[0].id' <<<"$oj")" \
    '[.entries[] | select(.volname == $v and .snapshots.cache == $c and .snapshots.offsite == $o and .keep == "d9" and .offsite_only == false)] | length == 1' \
    "$RUN/catalog/index.json" >/dev/null 2>&1 && ok "A: catalogue entry with both snapshot ids" || bad "A: catalogue: $(jq -c '.entries' "$RUN/catalog/index.json" 2>/dev/null)"
ls "$RUN/state/jobs"/ingest-8101-*.log >/dev/null 2>&1 && ok "A: job log in JOBS_DIR" || bad "A: no ingest job log"
jq -e '.ingest.ok == 1 and (.ingest.time > 0)' "$RUN/state/metrics-state.json" >/dev/null 2>&1 && ok "A: metrics event recorded" || bad "A: metrics state $(cat "$RUN/state/metrics-state.json" 2>/dev/null)"
grep -q "ingest vmid=8101 archive=$b1" "$RUN/log/audit.jsonl" 2>/dev/null && ok "A: audit event written" || bad "A: audit"

# --- B: the guest lock is held → EX_TEMPFAIL at once -------------------------
a2="$(spool_archive 8101)"; ts2="$(tsof "$a2")"
# the holder IS the sleep (exec), so killing it releases the lock at once
( flock 9 && exec sleep 30 ) 9>"$RUN/lock/pbo.vmid-8101.lock" & holder=$!
sleep 0.5
t0="$(date +%s%N)"; $BIN ingest --vmid 8101 --archive "$a2" >/dev/null 2>&1; rc=$?; t1="$(date +%s%N)"
ms=$(( (t1 - t0) / 1000000 ))
[[ $rc == 75 ]] && ok "B: held vmid lock → exit 75 (EX_TEMPFAIL)" || bad "B: rc=$rc"
(( ms < 2000 )) && ok "B: fails fast (${ms} ms), never waits" || bad "B: took ${ms} ms"
[[ -f "$a2" ]] && ok "B: the archive stays in the spool" || bad "B: archive gone"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# --- C: refusals ---------------------------------------------------------------
ln -s "$a2" "$DUMP/vzdump-lxc-8101-2026_01_01-00_00_00.tar"
$BIN ingest --vmid 8101 --archive "$DUMP/vzdump-lxc-8101-2026_01_01-00_00_00.tar" >/dev/null 2>&1; rc=$?
[[ $rc == 65 && -f "$a2" ]] && ok "C: a symlink in the spool is refused (65)" || bad "C: symlink rc=$rc"
rm -f "$DUMP/vzdump-lxc-8101-2026_01_01-00_00_00.tar"
cp "$a2" "$RUN/elsewhere/${a2##*/}"
$BIN ingest --vmid 8101 --archive "$RUN/elsewhere/${a2##*/}" >/dev/null 2>&1; rc=$?
[[ $rc == 65 && -f "$RUN/elsewhere/${a2##*/}" ]] && ok "C: a path outside the spool is refused (65)" || bad "C: outside rc=$rc"
$BIN ingest --vmid 8101 --archive "$DUMP/../../../elsewhere/${a2##*/}" >/dev/null 2>&1; rc=$?
[[ $rc == 65 ]] && ok "C: ../ out of the spool is refused" || bad "C: dotdot rc=$rc"
$BIN ingest --vmid 8102 --archive "$a2" >/dev/null 2>&1; rc=$?
[[ $rc == 65 && -f "$a2" ]] && ok "C: an archive of another vmid is refused" || bad "C: vmid mismatch rc=$rc"
cp "$a2" "$DUMP/vzdump-lxc-8101-2026_01_01-00_00_01.tar.zst"
$BIN ingest --vmid 8101 --archive "$DUMP/vzdump-lxc-8101-2026_01_01-00_00_01.tar.zst" >/dev/null 2>&1; rc=$?
[[ $rc == 65 ]] && ok "C: a compressed archive is refused" || bad "C: zst rc=$rc"
rm -f "$DUMP/vzdump-lxc-8101-2026_01_01-00_00_01.tar.zst"
$BIN ingest --vmid 8101 >/dev/null 2>&1; rc=$?
[[ $rc == 64 ]] && ok "C: --archive missing → usage error (64)" || bad "C: usage rc=$rc"
$BIN ingest --pending --vmid 8101 >/dev/null 2>&1; rc=$?
[[ $rc == 64 ]] && ok "C: --pending with --vmid → usage error" || bad "C: pending usage rc=$rc"
out="$($BIN --json --dry-run ingest --vmid 8101 --archive "$a2" 2>/dev/null)"; rc=$?
[[ $rc == 0 && -f "$a2" ]] && jq -e '.status == "dry_run"' >/dev/null 2>&1 <<<"$out" && ok "C: --dry-run changes nothing" || bad "C: dry-run rc=$rc $out"

# --- D: offsite unreachable → non-zero; --pending copies it -------------------
# "unreachable" = an empty directory: restic fails at once (a plain file in its
# place makes restic retry the backend for many minutes)
mv "$RUN/repo-offsite" "$RUN/repo-offsite.away"; mkdir "$RUN/repo-offsite"
$BIN ingest --vmid 8101 --archive "$a2" >"$RUN/d.out" 2>&1; rc=$?
[[ $rc == 69 ]] && ok "D: offsite down → exit 69, the PVE job fails" || bad "D: rc=$rc $(tail -3 "$RUN/d.out")"
grep -q "ingest --pending" "$RUN/d.out" && ok "D: the error names 'ingest --pending'" || bad "D: message: $(grep ERROR "$RUN/d.out")"
[[ "$(snaps "$RUN/repo-cache" 8101 "$ts2" | jq length)" == 1 && ! -e "$a2" ]] && ok "D: the snapshot is in the cache, the spool archive is gone" || bad "D: cache/spool state"
[[ -z "$(find "$RUN/cache/8101" -maxdepth 1 -name '*vzdump*')" ]] && ok "D: no loose archive left" || bad "D: loose: $(ls "$RUN/cache/8101")"
jq -e --arg v "backup/${a2##*/}" '[.entries[] | select(.volname == $v and .snapshots.cache != null and .snapshots.offsite == null)] | length == 1' \
    "$RUN/catalog/index.json" >/dev/null 2>&1 && ok "D: catalogue: cache id, no offsite id" || bad "D: catalogue $(jq -c '.entries' "$RUN/catalog/index.json")"
[[ -e "$RUN/state/ingest-copy/8101_$ts2" ]] && ok "D: the failed offsite copy is recorded for --pending" || bad "D: no record: $(ls "$RUN/state/ingest-copy" 2>&1)"
rmdir "$RUN/repo-offsite"; mv "$RUN/repo-offsite.away" "$RUN/repo-offsite"
# a cache-only snapshot nobody recorded (offsite retention removed it, say): --pending must not bring it back
mkdir -p "$RUN/stray/8199"; echo x > "$RUN/stray/8199/f"
R "$RUN/repo-cache" backup -q "$RUN/stray/8199" --tag vmid=8199,ts=2001_01_01-00_00_00 >/dev/null 2>&1 || bad "D: stray snapshot"
out="$($BIN --json ingest --pending 2>"$RUN/d2.err")"; rc=$?
[[ "$(snaps "$RUN/repo-offsite" 8199 | jq length)" == 0 ]] && ok "D: --pending copies only recorded snapshots (a cache-only one stays cache-only)" || bad "D: stray copied offsite"
[[ ! -e "$RUN/state/ingest-copy/8101_$ts2" ]] && ok "D: the record is gone after the copy" || bad "D: record left"
[[ $rc == 0 ]] && jq -e '.status == "ok" and .copy == "ok" and .copied == 1 and .ingested == 0' >/dev/null 2>&1 <<<"$out" && ok "D: --pending exits 0, copy ok" || bad "D: pending rc=$rc $out $(tail -3 "$RUN/d2.err")"
oj="$(snaps "$RUN/repo-offsite" 8101 "$ts2")"
jq -e --arg p "$RUN/cache/8101" 'length == 1 and .[0].paths == [$p] and (.[0].tags | index("type=lxc") and index("keep=d9"))' >/dev/null 2>&1 <<<"$oj" \
    && ok "D: --pending copied the snapshot offsite (path and tags kept)" || bad "D: offsite after pending: $oj"
jq -e --arg v "backup/${a2##*/}" '[.entries[] | select(.volname == $v and .snapshots.offsite != null)] | length == 1' \
    "$RUN/catalog/index.json" >/dev/null 2>&1 && ok "D: --pending refreshed the catalogue (offsite id)" || bad "D: catalogue after pending"
$BIN ingest --pending >/dev/null 2>&1; rc=$?
[[ $rc == 0 && "$(snaps "$RUN/repo-offsite" 8101 "$ts2" | jq length)" == 1 ]] && ok "D: --pending again: idempotent" || bad "D: second pending rc=$rc"

# --- E: a cache failure puts the archive back; --pending ingests leftovers ----
a3="$(spool_archive 8101)"; ts3="$(tsof "$a3")"
touch "$RUN/fail-backup"
$BIN ingest --vmid 8101 --archive "$a3" >"$RUN/e.out" 2>&1; rc=$?
rm -f "$RUN/fail-backup"
[[ $rc == 70 && -f "$a3" ]] && ok "E: restic backup fails → exit 70, the archive is back in the spool" || bad "E: rc=$rc $(tail -3 "$RUN/e.out")"
[[ -z "$(find "$RUN/cache/8101" -maxdepth 1 -name '*vzdump*')" ]] && ok "E: nothing left in \$CACHE_DIR/8101" || bad "E: left: $(ls "$RUN/cache/8101")"
a4="$(spool_archive 8101)"   # young: --pending leaves it
touch -d '-20 min' "$a3"
( flock -x 9 && exec sleep 30 ) 9>>"$RUN/vzdump.lock" & holder=$!
sleep 0.5
out="$($BIN --json ingest --pending 2>/dev/null)"; rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[[ $rc == 0 && -f "$a3" ]] && jq -e '.vzdump_running == true and .ingested == 0' >/dev/null 2>&1 <<<"$out" \
    && ok "E: vzdump running → --pending leaves the spool alone" || bad "E: busy rc=$rc $out"
out="$($BIN --json ingest --pending 2>"$RUN/e2.err")"; rc=$?
[[ $rc == 0 && ! -e "$a3" && -f "$a4" ]] && jq -e '.ingested == 1 and .failed == 0' >/dev/null 2>&1 <<<"$out" \
    && ok "E: --pending ingests the old archive, leaves the young one" || bad "E: pending rc=$rc $out $(tail -3 "$RUN/e2.err")"
[[ "$(snaps "$RUN/repo-cache" 8101 "$ts3" | jq length)" == 1 && "$(snaps "$RUN/repo-offsite" 8101 "$ts3" | jq length)" == 1 ]] \
    && ok "E: the leftover reached both repos" || bad "E: repos after pending"
rm -f "$a4"

# --- F: the hook wrapper and pbo _vzdump-hook --------------------------------
HOOK="$ROOT/lib/vzdump-hook"
cat > "$RUN/bin/fakepbo" <<EOF
#!/bin/sh
echo "\$* PATH=\$PATH" >> "$RUN/fakepbo.calls"
EOF
chmod 0755 "$RUN/bin/fakepbo"; : > "$RUN/fakepbo.calls"
env -i PBO_HOOK_BIN="$RUN/bin/fakepbo" PBO_PVE_STORAGE_CFG="$RUN/storage.cfg" "$HOOK" job-start; rc=$?
[[ $rc == 0 && ! -s "$RUN/fakepbo.calls" ]] && ok "F: no STOREID (pbo's own --dumpdir runs) → 0, pbo not started" || bad "F: empty STOREID rc=$rc"
env -i STOREID=local PBO_HOOK_BIN="$RUN/bin/fakepbo" PBO_PVE_STORAGE_CFG="$RUN/storage.cfg" "$HOOK" backup-start snapshot 8101; rc=$?
[[ $rc == 0 && ! -s "$RUN/fakepbo.calls" ]] && ok "F: STOREID=local → 0, pbo not started" || bad "F: local rc=$rc"
env -i STOREID=pb PBO_HOOK_BIN="$RUN/bin/fakepbo" PBO_PVE_STORAGE_CFG="$RUN/storage.cfg" "$HOOK" job-start; rc=$?
[[ $rc == 0 && ! -s "$RUN/fakepbo.calls" ]] && ok "F: a storage id that only prefixes 'pbo' is not ours" || bad "F: prefix rc=$rc"
env -i STOREID=pbo PBO_HOOK_BIN="$RUN/bin/fakepbo" PBO_PVE_STORAGE_CFG="$RUN/storage.cfg" "$HOOK" backup-start snapshot 8101; rc=$?
grep -qE '^_vzdump-hook backup-start snapshot 8101 PATH=.*/usr/bin' "$RUN/fakepbo.calls" && [[ $rc == 0 ]] \
    && ok "F: STOREID=pbo → pbo _vzdump-hook <args>, with a PATH although vzdump passes none" || bad "F: pbo call: $(cat "$RUN/fakepbo.calls")"
H() { env -i PATH="$PATH" PBO_CONFIG="$PBO_CONFIG" MOCK_CONF_DIR="$MOCK_CONF_DIR" PBO_HOOK_BIN="$ROOT/pbo" PBO_PVE_STORAGE_CFG="$RUN/storage.cfg" \
        STOREID=pbo DUMPDIR="$DUMP" VMTYPE=lxc "$@"; }
H "$HOOK" job-start >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ok "F: job-start → 0" || bad "F: job-start rc=$rc"
H TARGET="$DUMP/vzdump-lxc-8101-2026_01_01-00_00_00.tar.zst" "$HOOK" backup-start snapshot 8101 >"$RUN/f.out" 2>&1; rc=$?
[[ $rc == 1 ]] && grep -q 'compression none' "$RUN/f.out" && ok "F: backup-start with .tar.zst → 1 (pbo needs compression none)" || bad "F: zst rc=$rc $(cat "$RUN/f.out")"
H TARGET="$DUMP/vzdump-lxc-8101-2026_01_01-00_00_00.tar" "$HOOK" backup-start snapshot 8101 >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ok "F: backup-start .tar, snapshot, ordinary guest → 0" || bad "F: plain rc=$rc"
H TARGET="$DUMP/vzdump-lxc-8102-2026_01_01-00_00_00.tar" "$HOOK" backup-start snapshot 8102 >"$RUN/f.out" 2>&1; rc=$?
[[ $rc == 1 ]] && grep -q 'fuse' "$RUN/f.out" && ok "F: fuse guest in snapshot mode → 1, the reason is named" || bad "F: fuse snapshot rc=$rc $(cat "$RUN/f.out")"
H TARGET="$DUMP/vzdump-lxc-8102-2026_01_01-00_00_00.tar" "$HOOK" backup-start suspend 8102 >/dev/null 2>&1; rc=$?
[[ $rc == 1 ]] && ok "F: fuse guest in suspend mode → 1" || bad "F: fuse suspend rc=$rc"
H TARGET="$DUMP/vzdump-lxc-8102-2026_01_01-00_00_00.tar" "$HOOK" backup-start stop 8102 >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ok "F: fuse guest in stop mode → 0" || bad "F: fuse stop rc=$rc"
mkcfg "$RUN/config-stopids" "PBO_INTEGRATION=both" "VZDUMP_STOP_VMIDS=8101"
H PBO_CONFIG="$RUN/config-stopids" TARGET="$DUMP/vzdump-lxc-8101-2026_01_01-00_00_00.tar" "$HOOK" backup-start snapshot 8101 >"$RUN/f.out" 2>&1; rc=$?
[[ $rc == 1 ]] && grep -q 'VZDUMP_STOP_VMIDS' "$RUN/f.out" && ok "F: a VZDUMP_STOP_VMIDS guest in snapshot mode → 1" || bad "F: stop vmids rc=$rc"
bp=""
for ph in pre-stop pre-restart post-restart backup-abort job-end job-abort job-init; do
    H TARGET="$DUMP/x.tar" "$HOOK" "$ph" snapshot 8101 >/dev/null 2>&1 || bp+=" $ph"
done
[[ -z "$bp" ]] && ok "F: the other phases → 0" || bad "F: non-zero for$bp"
printf 'log\n' > "$DUMP/vzdump-lxc-8101-2026_01_01-00_00_00.log"; printf 'n\n' > "$DUMP/vzdump-lxc-8101-2026_01_01-00_00_00.tar.notes"
printf 'log\n' > "$RUN/elsewhere/vzdump-lxc-8101-2026_01_01-00_00_00.log"
H TARGET="$DUMP/vzdump-lxc-8101-2026_01_01-00_00_00.tar" "$HOOK" log-end snapshot 8101 >/dev/null 2>&1; rc=$?
[[ $rc == 0 && -z "$(ls -A "$DUMP")" ]] && ok "F: log-end removes the .log and .notes from the spool" || bad "F: log-end rc=$rc: $(ls "$DUMP")"
H DUMPDIR="$RUN/elsewhere" TARGET="$RUN/elsewhere/vzdump-lxc-8101-2026_01_01-00_00_00.tar" "$HOOK" log-end snapshot 8101 >/dev/null 2>&1; rc=$?
[[ $rc == 0 && -f "$RUN/elsewhere/vzdump-lxc-8101-2026_01_01-00_00_00.log" ]] && ok "F: log-end outside the spool removes nothing" || bad "F: log-end elsewhere"

# --- G: end to end: mock vzdump runs the real hook, which runs the real pbo ---
export MOCK_VZDUMP_SCRIPT="$HOOK" PBO_HOOK_BIN="$ROOT/pbo" PBO_PVE_STORAGE_CFG="$RUN/storage.cfg" MOCK_VZDUMP_HOOK_LOG="$RUN/hook.log"
n0="$(snaps "$RUN/repo-offsite" 8101 | jq length)"
: > "$RUN/hook.log"
MOCK_VZDUMP_HOOK=1 vzdump 8101 --storage pbo --compress 0 --mode snapshot >"$RUN/g.out" 2>&1; rc=$?
[[ $rc == 0 ]] && ok "G: PVE job (snapshot, compression none) → vzdump exit 0" || bad "G: rc=$rc $(tail -5 "$RUN/g.out")"
[[ "$(cut -d' ' -f3 "$RUN/hook.log" | tr '\n' ' ')" == "job-init job-start backup-start pre-stop pre-restart post-restart backup-end log-end job-end " ]] \
    && ok "G: the hook saw vzdump's phases in order" || bad "G: phases: $(tr '\n' ' ' <"$RUN/hook.log")"
grep -q 'ingest 8101: DONE' "$RUN/g.out" && ok "G: ingest shows in the task log" || bad "G: task log: $(tail -5 "$RUN/g.out")"
grep -q 'restic backup -> ' "$RUN/g.out" && ! LC_ALL=C grep -q $'[\x80-\xff]' "$RUN/g.out" \
    && ok "G: the task log lines are ASCII (-> instead of →: the PVE API reads task logs as latin1)" || bad "G: non-ASCII in task log: $(LC_ALL=C grep -n $'[\x80-\xff]' "$RUN/g.out" | head -2)"
[[ -z "$(ls -A "$DUMP")" ]] && ok "G: spool empty afterwards (archive ingested, .log removed)" || bad "G: spool: $(ls "$DUMP")"
[[ "$(snaps "$RUN/repo-offsite" 8101 | jq length)" == $((n0+1)) ]] && ok "G: one new snapshot offsite" || bad "G: offsite count"
MOCK_VZDUMP_HOOK=1 vzdump 8101 --storage pbo --mode snapshot >"$RUN/g.out" 2>&1; rc=$?
[[ $rc != 0 && -z "$(find "$DUMP" -maxdepth 1 \( -name '*.tar' -o -name '*.zst' \))" ]] && grep -q 'compression none' "$RUN/g.out" \
    && ok "G: zstd job → the guest fails at backup-start, no archive written" || bad "G: zstd rc=$rc $(ls "$DUMP")"
grep -q 'backup-abort' "$RUN/hook.log" && ok "G: a refused guest gets backup-abort" || bad "G: no backup-abort"
rm -f "$DUMP"/*.log
MOCK_VZDUMP_HOOK=1 vzdump 8102 --storage pbo --compress 0 --mode snapshot >"$RUN/g.out" 2>&1; rc=$?
[[ $rc != 0 ]] && grep -q 'stop mode' "$RUN/g.out" && ok "G: fuse guest in a snapshot job → refused" || bad "G: fuse snapshot rc=$rc"
rm -f "$DUMP"/*.log
MOCK_VZDUMP_HOOK=1 vzdump 8102 --storage pbo --compress 0 --mode stop >"$RUN/g.out" 2>&1; rc=$?
[[ $rc == 0 && "$(snaps "$RUN/repo-offsite" 8102 | jq length)" == 1 ]] && ok "G: fuse guest in a stop job → ingested" || bad "G: fuse stop rc=$rc $(tail -5 "$RUN/g.out")"
sid="$(snaps "$RUN/repo-cache" 8102 | jq -r '.[-1].short_id')"
R "$RUN/repo-cache" ls --json "$sid" 2>/dev/null | jq -r 'select(.type == "file") | .name' > "$RUN/g.ls"
grep -qE '^vzdump-lxc-8102-.*\.log$' "$RUN/g.ls" && grep -qE '^vzdump-lxc-8102-.*\.tar$' "$RUN/g.ls" && [[ -z "$(ls -A "$DUMP")" ]] \
    && ok "G: stop mode: vzdump's .log is in the snapshot (kept at log-end for job-end), spool empty" || bad "G: stop-mode log: $(cat "$RUN/g.ls"); spool: $(ls "$DUMP")"
sid="$(snaps "$RUN/repo-cache" 8101 | jq -r '.[-1].short_id')"
R "$RUN/repo-cache" ls --json "$sid" 2>/dev/null | jq -r 'select(.type == "file") | .name' | grep -qE '\.tar$' && ok "G: snapshot mode: the archive is there (its .log comes after backup-end, PVE keeps it)" || bad "G: snapshot-mode content"
: > "$RUN/fakepbo.calls"
PBO_HOOK_BIN="$RUN/bin/fakepbo" MOCK_VZDUMP_HOOK=1 vzdump 8101 --dumpdir "$RUN/elsewhere/own" --compress 0 >/dev/null 2>&1; rc=$?
[[ $rc == 0 && ! -s "$RUN/fakepbo.calls" ]] && ok "G: pbo's own vzdump (--dumpdir) never starts pbo from the hook" || bad "G: own run rc=$rc $(cat "$RUN/fakepbo.calls")"

# --- I: stop mode: the upload waits for job-end, after vzdump restarted the guest ---
DEFER="$RUN/state/ingest-deferred"
lineof() { grep -n -m1 -- "$1" "$RUN/order.log" | cut -d: -f1; }
n0="$(snaps "$RUN/repo-offsite" 8101 | jq length)"
: > "$RUN/order.log"; touch "$RUN/order.on"; sleep 1.1
MOCK_VZDUMP_HOOK_LOG="$RUN/order.log" MOCK_VZDUMP_HOOK=1 vzdump 8101 --storage pbo --compress 0 --mode stop >"$RUN/i.out" 2>&1; rc=$?
rm -f "$RUN/order.on"
[[ $rc == 0 && "$(snaps "$RUN/repo-offsite" 8101 | jq length)" == $((n0+1)) ]] && ok "I: stop-mode job → exit 0, one new snapshot offsite" || bad "I: rc=$rc $(tail -5 "$RUN/i.out")"
be="$(lineof 'hook backup-end stop 8101')"; pr="$(lineof 'hook post-restart stop 8101')"; je="$(lineof 'hook job-end')"
rb="$(lineof 'restic backup')"; rcp="$(lineof 'restic copy')"
[[ -n "$be" && -n "$pr" && -n "$je" && -n "$rb" && -n "$rcp" ]] && (( be < pr && pr < je && je < rb && rb < rcp )) \
    && ok "I: restic backup and copy run at job-end, after the guest's post-restart (it is not held down)" || bad "I: order: $(tr '\n' '|' <"$RUN/order.log")"
grep -q 'uploaded at job-end' "$RUN/i.out" && ok "I: backup-end says the upload waits for job-end" || bad "I: no defer line: $(grep -i pbo "$RUN/i.out" | head -3)"
[[ -z "$(find "$DUMP" -maxdepth 1 \( -name '*.tar' -o -name '*.vma' \))" && -z "$(ls -A "$DEFER" 2>/dev/null)" ]] \
    && ok "I: spool and job-end records empty afterwards" || bad "I: spool $(ls "$DUMP") records $(ls "$DEFER" 2>/dev/null)"
# offsite down: job-end fails → the job fails; the cache has it, --pending copies it
mv "$RUN/repo-offsite" "$RUN/repo-offsite.away"; mkdir "$RUN/repo-offsite"
: > "$RUN/order.log"; sleep 1.1
MOCK_VZDUMP_HOOK_LOG="$RUN/order.log" MOCK_VZDUMP_HOOK=1 vzdump 8101 --storage pbo --compress 0 --mode stop >"$RUN/i.out" 2>&1; rc=$?
rmdir "$RUN/repo-offsite"; mv "$RUN/repo-offsite.away" "$RUN/repo-offsite"
ts5="$(grep -o 'vzdump-lxc-8101-[0-9_-]*\.tar' "$RUN/i.out" | head -1)"; ts5="$(tsof "$ts5")"
[[ $rc != 0 ]] && grep -q 'hook job-abort' "$RUN/order.log" && grep -q 'stop-mode upload(s) failed at job-end' "$RUN/i.out" \
    && ok "I: offsite down → job-end fails, the job fails (job-abort)" || bad "I: job-end failure rc=$rc $(tail -4 "$RUN/i.out")"
[[ -n "$ts5" && "$(snaps "$RUN/repo-cache" 8101 "$ts5" | jq length)" == 1 && -z "$(ls -A "$DEFER" 2>/dev/null)" ]] \
    && ok "I: ... the snapshot is in the cache, no record left" || bad "I: cache after job-end failure ts=$ts5"
$BIN ingest --pending >/dev/null 2>&1; rc=$?
[[ $rc == 0 && "$(snaps "$RUN/repo-offsite" 8101 "$ts5" | jq length)" == 1 ]] && ok "I: --pending copies it offsite" || bad "I: pending rc=$rc"
# backup-end in stop mode still checks the archive at once
H TARGET="$RUN/elsewhere/vzdump-lxc-8101-2026_01_01-00_00_00.tar" "$ROOT/lib/vzdump-hook" backup-end stop 8101 >/dev/null 2>&1; rc=$?
[[ $rc != 0 && -z "$(ls -A "$DEFER" 2>/dev/null)" ]] && ok "I: stop mode, an archive outside the spool fails the guest at backup-end" || bad "I: bad target rc=$rc"
# a record whose archive is gone is dropped; job-end without records is a no-op
mkdir -p "$DEFER"; : > "$DEFER/vzdump-lxc-8101-2026_01_01-00_00_09.tar"
H "$ROOT/lib/vzdump-hook" job-end >/dev/null 2>&1; rc=$?
[[ $rc == 0 && -z "$(ls -A "$DEFER")" ]] && ok "I: job-end drops a record whose archive left the spool" || bad "I: stale record rc=$rc"
unset MOCK_VZDUMP_SCRIPT PBO_HOOK_BIN PBO_PVE_STORAGE_CFG MOCK_VZDUMP_HOOK_LOG

# --- H: run-schedule picks up leftovers first (integration on only) ----------
cat > "$RUN/bin/fakebackup" <<EOF
#!/bin/sh
echo "\$*" >> "$RUN/fakebackup.calls"
EOF
chmod 0755 "$RUN/bin/fakebackup"
a5="$(spool_archive 8101)"; touch -d '-20 min' "$a5"
mkcfg "$RUN/config-sa"   # standalone
out="$(PBO_SELF_BIN="$RUN/bin/fakebackup" PBO_CONFIG="$RUN/config-sa" $BIN run-schedule 2>&1)"; rc=$?
[[ $rc == 0 && -f "$a5" ]] && ! grep -q 'ingest' <<<"$out" && ok "H: standalone: run-schedule leaves the spool alone" || bad "H: standalone rc=$rc"
out="$(PBO_SELF_BIN="$RUN/bin/fakebackup" $BIN run-schedule 2>&1)"; rc=$?
[[ $rc == 0 && ! -e "$a5" && "$(snaps "$RUN/repo-offsite" 8101 "$(tsof "$a5")" | jq length)" == 1 ]] \
    && ok "H: both: run-schedule ingests the leftover first" || bad "H: both rc=$rc $(tail -5 <<<"$out")"
grep -q 'backup --queue 8101' "$RUN/fakebackup.calls" 2>/dev/null && ok "H: then the timer's guests run as before" || bad "H: no backup call"
a6="$(spool_archive 8101)"; touch -d '-20 min' "$a6"   # its ingest fails offsite → --pending fails
mv "$RUN/repo-offsite" "$RUN/repo-offsite.away"; mkdir "$RUN/repo-offsite"
out="$(PBO_SELF_BIN="$RUN/bin/fakebackup" $BIN run-schedule 2>&1)"; rc=$?
rmdir "$RUN/repo-offsite"; mv "$RUN/repo-offsite.away" "$RUN/repo-offsite"
[[ $rc == 0 ]] && grep -q 'run-schedule: ingest --pending failed' <<<"$out" && ok "H: a failing --pending is only a warning" || bad "H: pending failure rc=$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
