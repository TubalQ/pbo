#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/restoretest.sh: scheduled restore tests + evidence report.
# Real local restic repo, Proxmox (pct/qm/vzdump/pvesh) mocked.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start),
# PBO_PVE_LXC_DIR and PBO_PVE_QEMU_DIR (a guest's current name, read for a
# snapshot that records none) are the machine's own files: point them into
# the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.env" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
    PBO_PVE_CFS_DIR="$PWD/run-none/pve" PVE_STORAGE_CFG="$PWD/run-none/pve/storage.cfg" \
    PBO_PVE_LXC_DIR="$PWD/run-none/pve/lxc" PBO_PVE_QEMU_DIR="$PWD/run-none/pve/qemu-server"
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping restore-test tests"; exit 0; }

printf 'pbo: restore-test evidence tests\n'
RUN="$ROOT/run-restoretest"; rm -rf "$RUN"; mkdir -p "$RUN"/{cache,state,log,lock,conf,bin}
export MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/calls"; : > "$MOCK_LOG"
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm "$RUN/bin/"
export PATH="$RUN/bin:$PATH"
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
cat > "$RUN/config" <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
BACKUP_ORDER="8001 8002"
OFFSITE_ENABLED=false
LOCAL_REPO=true
RESTIC_CACHE_REPO=$RUN/repo
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
TR_STORAGE=teststore
TR_WAIT_TRIES=1
TR_WAIT_SLEEP=0
PBO_PVE_LXC_DIR=$RUN/conf
EOF
chmod 600 "$RUN/config"; export PBO_CONFIG="$RUN/config"
for id in 8001 8002; do
    printf 'arch: amd64\nhostname: test%s\nrootfs: teststore:%s/vm-%s-disk-0.raw,size=1G\nunprivileged: 1\n' "$id" "$id" "$id" > "$MOCK_CONF_DIR/$id.conf"
done
H="$RUN/state/restore-tests.jsonl"
rec() { jq -cR 'fromjson? // empty' "$H" | sed -n "${1}p"; }   # n-th valid record

$BIN init >/dev/null 2>&1 && ok "init" || bad "init"
$BIN backup 8001 >/dev/null 2>&1 && $BIN backup 8002 >/dev/null 2>&1 && ok "backups of 8001 + 8002" || bad "backups"

# --- before any test ---
j="$($BIN --json restore-report 2>/dev/null)"
jq -e '.coverage.guests==2 and (.coverage.never|sort)==["8001","8002"] and (.tests|length)==0' >/dev/null <<<"$j" \
    && ok "report: nothing tested yet, both guests 'never'" || bad "empty report ($j)"
d="$($BIN doctor 2>&1)"
grep -q "no restore test recorded yet" <<<"$d" && ok "doctor: warns when no restore test exists" || bad "doctor no-test ($d)"

# --- manual test: evidence record ---
$BIN test-restore 8001 >/dev/null 2>"$RUN/tr1.err" && ok "test-restore 8001 succeeds" || bad "test-restore 8001 ($(tail -2 "$RUN/tr1.err"))"
r="$(rec 1)"
jq -e '.kind=="restore-test" and .vmid=="8001" and .ok==true and .trigger=="manual" and .failed_stage==null' >/dev/null <<<"$r" \
    && ok "record: vmid, ok, trigger=manual" || bad "record basics ($r)"
jq -e '[.stages[].name]==["fetch","restore","isolate","start","respond","cleanup"] and all(.stages[]; .ok and (.seconds|type)=="number")' >/dev/null <<<"$r" \
    && ok "record: all six stages timed" || bad "record stages ($r)"
jq -e '(.snapshot.id|length)==64 and (.snapshot.ts|length)>0 and (.snapshot.age_s|type)=="number" and .snapshot.age_s>=0' >/dev/null <<<"$r" \
    && ok "record: snapshot id, ts and age" || bad "record snapshot ($r)"
jq -e '.repo.tier=="cache" and .name=="test8001" and .type=="lxc" and .archive_bytes>0 and .storage=="teststore" and (.throwaway|test("^90[0-9]{2}$"))' >/dev/null <<<"$r" \
    && ok "record: tier, name, type, archive size, storage, throwaway" || bad "record details ($r)"
grep -q "pct set 9099 --onboot 0 --protection 0 --tags pbo-throwaway" "$MOCK_LOG" && ok "throwaway: no autostart + tagged before boot" || bad "throwaway marking"
[[ ! -e "$MOCK_CONF_DIR/9099.conf" ]] && ok "throwaway config gone after the test" || bad "throwaway left behind"
[[ -s "$RUN/state/restore-report.json" && -s "$RUN/state/restore-report.txt" ]] && ok "report files written" || bad "report files"
grep -q "8001  test8001  lxc  OK" "$RUN/state/restore-report.txt" && ok "text report lists the test" || bad "text report ($(cat "$RUN/state/restore-report.txt"))"

# --- scheduled: never-tested first, then oldest ---
$BIN test-restore --scheduled >/dev/null 2>&1 && ok "scheduled run succeeds" || bad "scheduled run"
jq -e '.vmid=="8002" and .trigger=="scheduled"' >/dev/null <<<"$(rec 2)" && ok "scheduled picks the never-tested guest" || bad "scheduled pick 1 ($(rec 2))"
$BIN test-restore --scheduled >/dev/null 2>&1
jq -e '.vmid=="8001"' >/dev/null <<<"$(rec 3)" && ok "next scheduled run picks the oldest-tested guest" || bad "scheduled pick 2 ($(rec 3))"
j="$($BIN --json restore-report 2>/dev/null)"
jq -e '(.coverage.tested_ok|sort)==["8001","8002"] and (.coverage.never|length)==0 and (.tests|length)==3' >/dev/null <<<"$j" \
    && ok "report: both guests covered" || bad "coverage ($j)"
d="$($BIN doctor 2>&1)"
grep -q "last restore test 0d ago (vmid 8001 OK); 2/2 guests tested OK in 90d" <<<"$d" && ok "doctor: OK line with coverage" || bad "doctor ok line ($(grep -i restore <<<"$d"))"

# --- a failing test is recorded, alerts via die, and is a doctor FAIL ---
MOCK_START_OK=0 $BIN test-restore 8002 >/dev/null 2>&1; rc=$?
[[ $rc != 0 ]] && ok "failed test-restore exits non-zero" || bad "failed rc=$rc"
r="$(rec 4)"
jq -e '.vmid=="8002" and .ok==false and .failed_stage=="start" and .cleanup_ok==true and ([.stages[].name]==["fetch","restore","isolate","start","cleanup"])' >/dev/null <<<"$r" \
    && ok "record: failure stage + cleanup still ran" || bad "failure record ($r)"
d="$($BIN doctor 2>&1)"
grep -q "FAIL  restore test of vmid 8002 FAILED at start" <<<"$d" && ok "doctor: latest failed test is a problem" || bad "doctor fail ($(grep -i restore <<<"$d"))"
jq -e '.coverage.failed==["8002"]' >/dev/null <<<"$($BIN --json restore-report 2>/dev/null)" && ok "report: 8002 listed as failed" || bad "report failed list"
m="$($BIN metrics --no-write 2>/dev/null)"
grep -q '^pbo_guest_last_test_restore_success{vmid="8002",type="lxc"} 0$' <<<"$m" \
    && grep -q '^pbo_guest_last_test_restore_success{vmid="8001",type="lxc"} 1$' <<<"$m" \
    && ok "metrics: per-guest restore-test success" || bad "metrics ($(grep test_restore <<<"$m"))"
grep -q '^pbo_test_restore_last_success 0$' <<<"$m" && ok "metrics: last test_restore event" || bad "metrics event ($(grep pbo_test_restore <<<"$m"))"

# --- host bindings are stripped before boot; if that fails, no boot ---
cat > "$RUN/restored.conf" <<'CONF'
arch: amd64
hostname: test8001
meta: rtime=1768453200000,uid=abcdefghij0123456789
net0: name=eth0,bridge=vmbr0,hwaddr=02:00:00:00:00:01,ip=dhcp
onboot: 1
rootfs: teststore:vm-9099-disk-0,size=1G
mp0: teststore:vm-9099-disk-1,mp=/data,backup=0,size=8G
mp1: /srv/example-data,mp=/mnt/data
mp2: /dev/sdz1,mp=/mnt/raw
dev0: /dev/net/tun
hookscript: local:snippets/hook.pl
unprivileged: 1
lxc.idmap: u 0 100000 65536
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
lxc.hook.pre-start: /usr/local/bin/hook
lxc.mount.fstab: /etc/hostfstab
lxc.net.0.type: phys
virtiofs0: hostshare
mp3: teststore:subvol-8999-disk-0,mp=/foreign
#lxc.mount.entry: in the description, not a key
CONF
: > "$MOCK_LOG"
MOCK_RESTORE_CONF="$RUN/restored.conf" MOCK_EXEC_OK=1 $BIN test-restore 8001 >/dev/null 2>&1 && ok "test-restore with host bindings succeeds" || bad "test-restore bindings"
r="$(jq -cR 'fromjson? // empty' "$H" | tail -1)"
jq -e '(.stripped|sort)==(["dev0","hookscript","lxc.cgroup2.devices.allow","lxc.hook.pre-start","lxc.mount.entry","lxc.mount.fstab","lxc.net.0.type","mp1","mp2","mp3","virtiofs0"]|sort)' >/dev/null <<<"$r" \
    && ok "allowlist: everything not known-safe stripped and recorded (bind/dev mounts, devN, hooks, raw lxc mount/net, unknown keys, another guest's volume)" || bad "stripped ($(jq -c .stripped <<<"$r"))"
! grep -q "pct set 9099 --delete mp0" "$MOCK_LOG" && ok "volume mount point (new empty volume) kept" || bad "volume mp deleted"
! grep -q "pct set 9099 --delete meta" "$MOCK_LOG" && ok "meta (read-only metadata of newer pve-container) kept, not deleted" || bad "meta deleted"
grep -q "pct set 9099 --delete net0" "$MOCK_LOG" && ok "network removed" || bad "net0 not removed"
# start must come after every delete
awk '/pct start 9099/{s=NR} /pct set 9099 --delete/ && !/--delete protection/{d=NR} END{exit !(s>d && d>0)}' "$MOCK_LOG" && ok "boot only after isolation" || bad "boot order ($(grep 9099 "$MOCK_LOG"))"
: > "$MOCK_LOG"
MOCK_RESTORE_CONF="$RUN/restored.conf" MOCK_SET_FAIL="mp1" $BIN test-restore 8001 >"$RUN/iso.out" 2>&1; rc=$?
r="$(jq -cR 'fromjson? // empty' "$H" | tail -1)"
[[ $rc != 0 ]] && jq -e '.ok==false and .failed_stage=="isolate"' >/dev/null <<<"$r" && ! grep -q "pct start 9099" "$MOCK_LOG" \
    && ok "isolation failure: recorded, not booted" || bad "isolate fail rc=$rc ($r)"
[[ ! -e "$MOCK_CONF_DIR/9099.conf" ]] && ok "throwaway destroyed after isolation failure" || bad "leftover after isolate fail"
# a host-path rootfs cannot be stripped: not booted
sed 's#^rootfs: .*#rootfs: /srv/hostdir,size=1G#' "$RUN/restored.conf" > "$RUN/restored-hostroot.conf"
: > "$MOCK_LOG"
MOCK_RESTORE_CONF="$RUN/restored-hostroot.conf" $BIN test-restore 8001 >/dev/null 2>&1; rc=$?
r="$(jq -cR 'fromjson? // empty' "$H" | tail -1)"
[[ $rc != 0 ]] && jq -e '.failed_stage=="isolate"' >/dev/null <<<"$r" && ! grep -q "pct start 9099" "$MOCK_LOG" \
    && ok "host-path rootfs: isolation fails, not booted" || bad "hostroot rc=$rc ($r)"
# a pending section (applied at the next start) cannot be checked key by key: not booted
{ cat "$RUN/restored.conf"; printf '\n[pve:pending]\nmp4: /srv/hostdir,mp=/late\n'; } > "$RUN/restored-pending.conf"
: > "$MOCK_LOG"
MOCK_RESTORE_CONF="$RUN/restored-pending.conf" $BIN test-restore 8001 >/dev/null 2>&1; rc=$?
r="$(jq -cR 'fromjson? // empty' "$H" | tail -1)"
[[ $rc != 0 ]] && jq -e '.failed_stage=="isolate"' >/dev/null <<<"$r" && ! grep -q "pct start 9099" "$MOCK_LOG" \
    && ok "pending section: isolation fails, not booted" || bad "pending rc=$rc ($r)"
# restore failed (e.g. the id was taken meanwhile): nothing is destroyed
: > "$MOCK_LOG"
MOCK_RESTORE_OK=0 $BIN test-restore 8001 >/dev/null 2>&1; rc=$?
r="$(jq -cR 'fromjson? // empty' "$H" | tail -1)"
[[ $rc != 0 ]] && ! grep -q "destroy" "$MOCK_LOG" && jq -e '.failed_stage=="restore" and ([.stages[].name]==["fetch","restore"])' >/dev/null <<<"$r" \
    && ok "failed restore: no destroy of a guest this run did not create" || bad "restore-fail destroy ($(grep destroy "$MOCK_LOG"))"
MOCK_RESTORE_OK=1 $BIN test-restore 8001 >/dev/null 2>&1   # back to a passing latest test for 8001

# --- a throwaway that cannot be destroyed is recorded as such (not hidden) ---
MOCK_DESTROY_FAIL=1 $BIN test-restore 8001 >/dev/null 2>&1
r="$(jq -cR 'fromjson? // empty' "$H" | tail -1)"
jq -e '.cleanup_ok == false and (.stages[] | select(.name=="cleanup") | .ok == false)' >/dev/null <<<"$r" \
    && ok "failed cleanup: cleanup_ok false in the record" || bad "cleanup_ok ($(jq -c '{cleanup_ok,stages}' <<<"$r"))"
rm -f "$MOCK_CONF_DIR"/90[0-9][0-9].conf

# --- per-run count: every failure recorded, run exits non-zero ---
n0="$(jq -cR 'fromjson? // empty' "$H" | wc -l)"
MOCK_START_OK=0 TR_PER_RUN=2 $BIN test-restore --scheduled >/dev/null 2>&1; rc=$?
n1="$(jq -cR 'fromjson? // empty' "$H" | wc -l)"
[[ $rc != 0 && $((n1-n0)) == 2 ]] && ok "TR_PER_RUN=2: both guests tried and recorded despite failures" || bad "per-run rc=$rc added=$((n1-n0))"
[[ "$(jq -cR 'fromjson? // empty' "$H" | sed -n "$((n0+1))p" | jq -r .vmid)" == 8002 ]] \
    && ok "rotation: the guest whose latest test failed goes first" || bad "failed-first order ($(jq -cR 'fromjson? // empty' "$H" | sed -n "$((n0+1))p" | jq -r .vmid))"

# picker unit test: failed first (oldest failure), then never tested, then oldest; one failed per run
pick() {   # pick <candidates> <picked> with a fixed history
    bash -c 'source lib/testrestore.sh
        _tr_last_by_vmid() { printf "%s" "{\"1\":{\"epoch\":100,\"ok\":true},\"2\":{\"epoch\":300,\"ok\":false},\"3\":{\"epoch\":200,\"ok\":false},\"4\":{\"epoch\":50,\"ok\":true}}"; }
        _tr_next_guest "$1" "$2"' _ "$1" "$2"
}
c=$'1\n2\n3\n4\n5'
[[ "$(pick "$c" "")" == 3 ]] && ok "picker: oldest failure first" || bad "picker 1: $(pick "$c" "")"
[[ "$(pick "$c" "3")" == 5 ]] && ok "picker: after one failed guest, never-tested next" || bad "picker 2: $(pick "$c" "3")"
[[ "$(pick "$c" "3 5")" == 4 ]] && ok "picker: then oldest-tested; the second failed guest waits its turn" || bad "picker 3: $(pick "$c" "3 5")"

# --- pbo-skip guests are not rotated through ---
printf 'tags: pbo-skip\n' >> "$MOCK_CONF_DIR/8002.conf"
$BIN test-restore --scheduled >/dev/null 2>&1; $BIN test-restore --scheduled >/dev/null 2>&1
[[ "$(jq -cR 'fromjson? // empty' "$H" | tail -2 | jq -r .vmid | sort -u)" == 8001 ]] && ok "pbo-skip guest left out of the rotation" || bad "skip ($(tail -2 "$H" | jq -r .vmid))"
sed -i '/^tags:/d' "$MOCK_CONF_DIR/8002.conf"

# --- hostile / broken history does not break anything ---
printf 'not json\n{"vmid":"1\\"} 1\\npbo_evil 1","epoch":1,"type":"x\\"y","ok":true}\n' >> "$H"
j="$($BIN --json restore-report 2>/dev/null)"; jq -e '.tests' >/dev/null <<<"$j" && ok "report survives a malformed history line" || bad "report malformed"
m="$($BIN metrics --no-write 2>/dev/null)"
! grep -q '^pbo_evil' <<<"$m" && ! grep -q 'vmid="1' <<<"$m" && ok "metrics: history vmid cannot inject lines" || bad "metrics injection ($(grep -n evil <<<"$m"))"

# --- leftovers from a crash show up in doctor ---
node="$(jq -r '.nodename // empty' /etc/pve/.members 2>/dev/null)"; [[ -n "$node" ]] || node="$(hostname -s)"
printf '[{"vmid":8001,"node":"%s","type":"lxc"},{"vmid":8002,"node":"%s","type":"lxc"},{"vmid":9050,"node":"%s","type":"lxc","tags":"pbo-throwaway"}]\n' "$node" "$node" "$node" > "$RUN/res.json"
d="$(MOCK_PVESH_JSON="$RUN/res.json" $BIN doctor 2>&1)"
grep -q "leftover test-restore throwaway guest(s): 9050" <<<"$d" && ok "doctor: leftover throwaway flagged" || bad "leftover ($(grep -i leftover <<<"$d"))"

# --- restore --start: network down unless --keep-network ---
ts="$($BIN --json list 8001 2>/dev/null | jq -r '[.archives[].ts] | sort | last')"
printf 'arch: amd64\nhostname: test8001\nnet0: name=eth0,bridge=vmbr0,hwaddr=02:00:00:00:00:01,ip=dhcp\nnet1: name=eth1,bridge=vmbr1,link_down=0\nonboot: 1\nrootfs: teststore:vm-9300-disk-0,size=1G\nunprivileged: 1\n' > "$RUN/with-net.conf"
{ sed 's/vm-9300-disk-0/vm-9305-disk-0/' "$RUN/with-net.conf"; printf 'mp1: /srv/example-data,mp=/mnt/data\ndev0: /dev/net/tun\nlxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file\n'; } > "$RUN/with-host.conf"
: > "$MOCK_LOG"
out="$(MOCK_RESTORE_CONF="$RUN/with-net.conf" $BIN --json restore 8001 "$ts" --to 9300 --yes --start 2>/dev/null)"
jq -e '.started == true and .network == "disconnected" and .target_vmid == "9300"' >/dev/null 2>&1 <<<"$out" && ok "restore --start: started, network disconnected" || bad "restore --start: $out"
[[ "$(grep -c 'link_down=1' "$MOCK_CONF_DIR/9300.conf")" == 2 ]] && ! grep -q 'link_down=0' "$MOCK_CONF_DIR/9300.conf" \
    && ok "restore --start: every interface link_down=1 (an explicit link_down=0 replaced)" || bad "link_down: $(grep ^net "$MOCK_CONF_DIR/9300.conf")"
awk '/pct set 9300 --lock create/{l=NR} /pct unlock 9300/{u=NR} /pct start 9300/{s=NR} END{exit !(l>0 && u>l && s>u)}' "$MOCK_LOG" \
    && ok "restore --start: locked while isolated, unlocked, then started" || bad "order: $(grep 9300 "$MOCK_LOG")"
grep -q '^onboot: 0' "$MOCK_CONF_DIR/9300.conf" && ok "restore --start: autostart off" || bad "onboot: $(grep onboot "$MOCK_CONF_DIR/9300.conf")"
: > "$MOCK_LOG"
out="$(MOCK_RESTORE_CONF="$RUN/with-host.conf" $BIN --json restore 8001 "$ts" --to 9305 --yes --start 2>/dev/null)"
jq -e '.started and (.stripped | split(" ") | sort) == ["dev0","lxc.mount.entry","mp1"]' >/dev/null 2>&1 <<<"$out" \
    && ! grep -qE '^(mp1|dev0|lxc.mount.entry)' "$MOCK_CONF_DIR/9305.conf" && grep -q '^net0:.*link_down=1' "$MOCK_CONF_DIR/9305.conf" \
    && ok "restore --start: host bindings stripped like test-restore, NICs kept disconnected" || bad "start isolation: $out"
: > "$MOCK_LOG"
sed "s/vm-9305-/vm-9306-/" "$RUN/with-host.conf" > "$RUN/with-host-9306.conf"
MOCK_RESTORE_CONF="$RUN/with-host-9306.conf" MOCK_UNLOCK_OK=0 $BIN restore 8001 "$ts" --to 9306 --yes --start >/dev/null 2>&1; rc=$?
[[ $rc != 0 ]] && ! grep -q "pct start 9306" "$MOCK_LOG" && grep -q "pct destroy 9306" "$MOCK_LOG" && [[ ! -e "$MOCK_CONF_DIR/9306.conf" ]] \
    && ok "restore --start: isolation that cannot finish → not started, copy destroyed" || bad "isolate-fail rc=$rc"
: > "$MOCK_LOG"
# --keep-network is for disaster recovery: refused while the original exists
MOCK_RESTORE_CONF="$RUN/with-host.conf" $BIN restore 8001 "$ts" --to 9307 --yes --start --keep-network >/dev/null 2>&1; rc=$?
[[ $rc == 64 && ! -e "$MOCK_CONF_DIR/9307.conf" ]] && ok "--keep-network refused while the original still exists" || bad "keep-network with original rc=$rc"
mv "$MOCK_CONF_DIR/8001.conf" "$RUN/8001.conf.away"     # the original is gone
: > "$MOCK_LOG"
MOCK_RESTORE_CONF="$RUN/with-host.conf" $BIN restore 8001 "$ts" --to 9307 --yes --start --keep-network >/dev/null 2>&1
grep -q '^mp1:' "$MOCK_CONF_DIR/9307.conf" && grep -q "pct start 9307" "$MOCK_LOG" && ok "--keep-network: started exactly as the original" || bad "keep-network as-is"
: > "$MOCK_LOG"
out="$(MOCK_RESTORE_CONF="$RUN/with-net.conf" $BIN --json restore 8001 "$ts" --to 9301 --yes --start --keep-network 2>/dev/null)"
jq -e '.started and .network == "connected"' >/dev/null 2>&1 <<<"$out" && ! grep -q "pct set 9301 --net" "$MOCK_LOG" && grep -q "pct start 9301" "$MOCK_LOG" \
    && ok "restore --start --keep-network: network untouched" || bad "keep-network: $out"
: > "$MOCK_LOG"
out="$(MOCK_RESTORE_CONF="$RUN/with-net.conf" $BIN --json restore 8001 "$ts" --to 9303 --yes --keep-network 2>/dev/null)"
jq -e '.started == false and .network == "unchanged"' >/dev/null 2>&1 <<<"$out" && grep -q '^onboot: 1' "$MOCK_CONF_DIR/9303.conf" \
    && ok "--keep-network without --start: restored as-is, not started" || bad "keep-network no start: $out"
mv "$RUN/8001.conf.away" "$MOCK_CONF_DIR/8001.conf"     # the original is back
: > "$MOCK_LOG"
sed "s/vm-9305-/vm-9302-/" "$RUN/with-host.conf" > "$RUN/with-host-9302.conf"
out="$(MOCK_RESTORE_CONF="$RUN/with-host-9302.conf" $BIN --json restore 8001 "$ts" --to 9302 --yes 2>/dev/null)"
jq -e '.started == false and .network == "disconnected" and (.stripped | length) > 0' >/dev/null 2>&1 <<<"$out" && ! grep -q "pct start 9302" "$MOCK_LOG" \
    && grep -q '^onboot: 0' "$MOCK_CONF_DIR/9302.conf" && ! grep -qE '^(mp1|dev0)' "$MOCK_CONF_DIR/9302.conf" \
    && ok "a plain restore (CLI, no flags) is isolated: NICs down, no autostart, host bindings gone, not started" || bad "default isolation: $out"
MOCK_RESTORE_CONF="$RUN/with-net.conf" MOCK_SET_FAIL="lock" $BIN restore 8001 "$ts" --to 9304 --yes --start >/dev/null 2>&1; rc=$?
[[ $rc != 0 ]] && ! grep -q "pct start 9304" "$MOCK_LOG" && [[ ! -e "$MOCK_CONF_DIR/9304.conf" ]] \
    && ok "restore --start: cannot lock for isolation → not started, copy destroyed" || bad "lock-fail rc=$rc"
# --isolate without --start: isolated, not started
: > "$MOCK_LOG"
sed "s/vm-9305-/vm-9308-/" "$RUN/with-host.conf" > "$RUN/with-host-9308.conf"
out="$(MOCK_RESTORE_CONF="$RUN/with-host-9308.conf" $BIN --json restore 8001 "$ts" --to 9308 --yes --isolate 2>/dev/null)"
jq -e '.started == false and .network == "disconnected" and (.stripped | length) > 0' >/dev/null 2>&1 <<<"$out" \
    && ! grep -q "pct start 9308" "$MOCK_LOG" && ! grep -qE "^(mp1|dev0)" "$MOCK_CONF_DIR/9308.conf" \
    && ok "restore --isolate: host bindings stripped, NICs down, not started" || bad "isolate no-start: $out"
rm -f "$MOCK_CONF_DIR/9305.conf"
$BIN restore 8001 "$ts" --to 9309 --yes --start --keep-network --isolate >/dev/null 2>&1; [[ $? == 64 ]] && ok "--isolate with --keep-network: usage error" || bad "isolate+keepnet"
rm -f "$MOCK_CONF_DIR"/930[0-9].conf

# --- dry-run records nothing; usage errors ---
n0="$(wc -l < "$H")"; $BIN --dry-run test-restore 8001 >/dev/null 2>&1
[[ "$(wc -l < "$H")" == "$n0" ]] && ok "dry-run writes no evidence" || bad "dry-run recorded"
$BIN test-restore --scheduled 8001 >/dev/null 2>&1; [[ $? == 64 ]] && ok "--scheduled with a vmid: usage error" || bad "scheduled usage"
$BIN restore-report --days x >/dev/null 2>&1; [[ $? == 64 ]] && ok "restore-report --days x: usage error" || bad "report usage"
a="$(tail -1 "$RUN/log/audit.jsonl" 2>/dev/null)"
$BIN restore-report >/dev/null 2>&1
jq -e '.command=="restore-report" and .read_only==true' >/dev/null <<<"$(tail -1 "$RUN/log/audit.jsonl")" && ok "audit: restore-report logged as read-only" || bad "audit ($a)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ -n "${KEEP_RUN:-}" ]] || rm -rf "$RUN"
(( fail == 0 ))
