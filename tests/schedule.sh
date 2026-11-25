#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/schedule.sh: step 9 (run-schedule + status), fake backup binary.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start) are the
# machine's own files: point them into the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.env" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
    PBO_PVE_CFS_DIR="$PWD/run-none/pve" PVE_STORAGE_CFG="$PWD/run-none/pve/storage.cfg"
BIN=./pbo; ROOT="$PWD"
rm -rf "$ROOT/run/schedule"; mkdir -p "$ROOT/run/schedule/state/jobs" "$ROOT/run/schedule/bin" "$ROOT/run/schedule/conf"
# Proxmox mocked: the test must not see the real host's guests (on a PVE node the
# real pvesh/pct would answer for these vmids, in CI they are missing).
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm "$ROOT/run/schedule/bin/"
export PATH="$ROOT/run/schedule/bin:$PATH" MOCK_CONF_DIR="$ROOT/run/schedule/conf" MOCK_LOG="$ROOT/run/schedule/mock-calls"
for id in 101 102 103; do printf 'arch: amd64\nhostname: t%s\nrootfs: teststore:vm-%s-disk-0,size=1G\nunprivileged: 1\n' "$id" "$id" > "$MOCK_CONF_DIR/$id.conf"; done
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
mkcfg() { local f="$1"; shift; { echo "CACHE_DIR=$ROOT/run/schedule/cache"; echo "LOG_DIR=$ROOT/run/schedule/log"; echo "STATE_DIR=$ROOT/run/schedule/state"; echo "LOCK_DIR=$ROOT/run/schedule/lock"; echo "NTFY_URL="; echo "NTFY_CREDS_FILE=/nonexistent"
    # the catalogue refresh after run-schedule (integration on) reads these: never the host's
    echo "RESTIC_CACHE_REPO=$ROOT/run/schedule/norepo"; echo "RESTIC_PASSWORD_FILE=$ROOT/run/schedule/nopass"; echo "RESTIC_CACHE_DIR=$ROOT/run/schedule/rcache"
    echo "PBO_CATALOG=$ROOT/run/schedule/catalog/index.json"
    for l in "$@"; do echo "$l"; done; } > "$f"; chmod 600 "$f"; }

# Fake backup binary: logs the calls, fails for vmid in $FAILV.
export FAKE_LOG="$ROOT/run/schedule/calls"; : > "$FAKE_LOG"
cat > "$ROOT/run/schedule/fakebin" <<'F'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
[ "$3" = "$FAILV" ] && exit 1 || exit 0
F
chmod +x "$ROOT/run/schedule/fakebin"
export PBO_SELF_BIN="$ROOT/run/schedule/fakebin"

# --- A: all OK, order preserved ---
mkcfg "$ROOT/run/schedule/cfg" "BACKUP_ORDER=101,102,103"; export PBO_CONFIG="$ROOT/run/schedule/cfg"
: > "$FAKE_LOG"; FAILV="" out="$($BIN --json run-schedule 2>/dev/null)"; rc=$?
grep -q '"status":"ok"' <<<"$out" && [[ $rc == 0 ]] && ok "run-schedule: all OK (exit 0)" || bad "A ($rc: $out)"
jq -e '.backups_ok == 3' >/dev/null 2>&1 <<<"$out" && ok "A: 3 backups run" || bad "A count ($out)"
[[ "$(cat "$FAKE_LOG")" == $'backup --queue 101\nbackup --queue 102\nbackup --queue 103' ]] && ok "A: order + queue mode preserved" || bad "A order ($(tr '\n' ' ' <"$FAKE_LOG"))"

# --- B: one CT fails → partial, exit != 0, but the rest run ---
: > "$FAKE_LOG"; out="$(FAILV=102 $BIN --json run-schedule 2>/dev/null)"; rc=$?
grep -q '"status":"partial"' <<<"$out" && ok "B: partial on error" || bad "B status ($out)"
jq -e '.backups_failed == 1' >/dev/null 2>&1 <<<"$out" && ok "B: 1 error counted" || bad "B failc"
[[ "$(wc -l <"$FAKE_LOG")" == 3 ]] && ok "B: the rest ran despite error (3 calls)" || bad "B did not continue"
[[ $rc != 0 ]] && ok "B: exit != 0 on error" || bad "B exit ($rc)"

# --- C: empty BACKUP_ORDER now means auto (all local guests), not a config error ---
mkcfg "$ROOT/run/schedule/cfgC" "BACKUP_ORDER="; PBO_CONFIG="$ROOT/run/schedule/cfgC" $BIN run-schedule >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ok "C: empty BACKUP_ORDER → auto (not an error)" || bad "C exit ($rc)"

# --- D: status shows lock holder + liveness ---
mkdir -p "$ROOT/run/schedule/state"
printf '102|backup|%s|%s\n' "$$" "$(date +%s)" > "$ROOT/run/schedule/state/global.holder"
out="$(PBO_CONFIG=$ROOT/run/schedule/cfg $BIN --json status 2>/dev/null)"
jq -e '.locks.global.state == "held" and .locks.global.vmid == "102" and .locks.global.op == "backup"' >/dev/null 2>&1 <<<"$out" && ok "D: live holder → active" || bad "D active ($out)"
printf '102|backup|999999|%s\n' "$(date +%s)" > "$ROOT/run/schedule/state/global.holder"
out="$(PBO_CONFIG=$ROOT/run/schedule/cfg $BIN --json status 2>/dev/null)"
jq -e '.locks.global.state == "stale"' >/dev/null 2>&1 <<<"$out" && ok "D: dead pid → stale holder" || bad "D stale ($out)"

# --- E-G: Proxmox integration (ADR 0007): guests a PVE job owns are left to it ---
node="$(jq -r '.nodename // empty' /etc/pve/.members 2>/dev/null)"; [[ -n "$node" ]] || node="$(hostname -s)"
printf '[{"vmid":101,"node":"%s","type":"lxc"},{"vmid":102,"node":"%s","type":"lxc"},{"vmid":103,"node":"%s","type":"lxc"}]\n' "$node" "$node" "$node" > "$ROOT/run/schedule/res.json"
printf '[{"storage":"pbo","type":"pbo"}]\n' > "$ROOT/run/schedule/storage.json"
printf '[{"id":"backup-nightly","vmid":"102","storage":"pbo","enabled":1}]\n' > "$ROOT/run/schedule/jobs.json"
export MOCK_PVESH_JSON="$ROOT/run/schedule/res.json" MOCK_PVESH_STORAGE_JSON="$ROOT/run/schedule/storage.json" MOCK_PVESH_BACKUP_JSON="$ROOT/run/schedule/jobs.json"
export VZDUMP_CONF="$ROOT/run/schedule/vzdump.conf"; : > "$VZDUMP_CONF"
mkcfg "$ROOT/run/schedule/cfgE" "BACKUP_ORDER=101,102,103" "PBO_INTEGRATION=both"
: > "$FAKE_LOG"; out="$(PBO_CONFIG=$ROOT/run/schedule/cfgE $BIN run-schedule 2>&1)"; rc=$?
[[ $rc == 0 && "$(cat "$FAKE_LOG")" == $'backup --queue 101\nbackup --queue 103' ]] && ok "E: both: the PVE-owned guest is skipped, the rest run in order" || bad "E calls ($rc: $(tr '\n' ' ' <"$FAKE_LOG"))"
grep -q 'run-schedule: skipping 102 (owned by PVE job backup-nightly)' <<<"$out" && ok "E: skip is logged with the job id" || bad "E log: $out"

printf '[{"id":"backup-all","all":1,"storage":"pbo"}]\n' > "$ROOT/run/schedule/jobs.json"
mkcfg "$ROOT/run/schedule/cfgF" "BACKUP_ORDER=101,102,103" "PBO_INTEGRATION=integrated"
: > "$FAKE_LOG"; out="$(PBO_CONFIG=$ROOT/run/schedule/cfgF $BIN --json run-schedule 2>/dev/null)"; rc=$?
[[ $rc == 0 && ! -s "$FAKE_LOG" ]] && ok "F: integrated: nothing backed up, exit 0" || bad "F ($rc: $(tr '\n' ' ' <"$FAKE_LOG"))"
jq -e '.status == "ok" and .backups_ok == 0 and (.note | test("integrated"))' >/dev/null 2>&1 <<<"$out" && ok "F: ok with an integrated note" || bad "F json: $out"
out="$(PBO_CONFIG=$ROOT/run/schedule/cfgF $BIN run-schedule 2>&1)"; rc=$?
[[ $rc == 0 ]] && grep -q 'run-schedule: catalogue refresh failed' <<<"$out" && [[ ! -e "$ROOT/run/schedule/catalog/index.json" ]] \
    && ok "F: integrated: the catalogue refresh runs, its failure (no repo) is only a warning" || bad "F catalogue hook ($rc): $out"
out="$(PBO_CONFIG=$ROOT/run/schedule/cfg $BIN run-schedule 2>&1)"
! grep -q 'catalogue' <<<"$out" && ok "standalone: run-schedule does not refresh the catalogue" || bad "standalone hook: $out"
printf '[{"id":"backup-some","vmid":"101","storage":"pbo"}]\n' > "$ROOT/run/schedule/jobs.json"
: > "$FAKE_LOG"; out="$(PBO_CONFIG=$ROOT/run/schedule/cfgF $BIN run-schedule 2>&1)"; rc=$?
[[ $rc == 0 && ! -s "$FAKE_LOG" ]] && grep -q 'guest 102 has no owner' <<<"$out" && grep -q 'guest 103 has no owner' <<<"$out" \
    && ok "F: integrated: unowned guests are named, still not backed up by the timer" || bad "F unowned ($rc): $out"

printf '[{"id":"backup-nightly","vmid":"102","storage":"pbo"}]\n' > "$ROOT/run/schedule/jobs.json"
: > "$FAKE_LOG"; out="$(MOCK_PVESH_FAIL_PATH=/cluster/backup PBO_CONFIG=$ROOT/run/schedule/cfgE $BIN run-schedule 2>&1)"; rc=$?
[[ $rc == 0 && "$(cat "$FAKE_LOG")" == $'backup --queue 101\nbackup --queue 102\nbackup --queue 103' ]] && ok "G: pvesh fails: fail open, every guest backed up" || bad "G calls ($rc: $(tr '\n' ' ' <"$FAKE_LOG"))"
grep -q 'fail open' <<<"$out" && ok "G: fail open is logged" || bad "G log: $out"
: > "$FAKE_LOG"; out="$(MOCK_PVESH_FAIL_PATH=/cluster/backup PBO_CONFIG=$ROOT/run/schedule/cfgF $BIN run-schedule 2>&1)"; rc=$?
[[ $rc == 0 && "$(wc -l <"$FAKE_LOG")" == 3 ]] && ok "G: fail open in integrated: every guest backed up" || bad "G integrated ($rc: $(tr '\n' ' ' <"$FAKE_LOG"))"
unset MOCK_PVESH_JSON MOCK_PVESH_STORAGE_JSON MOCK_PVESH_BACKUP_JSON

# --- H: --dry-run runs no backup (the children never saw the flag: real backups) ---
mkcfg "$ROOT/run/schedule/cfgH" "BACKUP_ORDER=101,102,103"
: > "$FAKE_LOG"; out="$(PBO_CONFIG=$ROOT/run/schedule/cfgH $BIN --dry-run --json run-schedule 2>/dev/null)"; rc=$?
[[ $rc == 0 && ! -s "$FAKE_LOG" ]] && ok "H: --dry-run run-schedule starts no backup" || bad "H calls ($rc: $(tr '\n' ' ' <"$FAKE_LOG"))"
jq -e '.status == "dry_run" and .would_backup == "101 102 103"' >/dev/null 2>&1 <<<"$out" && ok "H: --dry-run lists what it would back up" || bad "H json: $out"
# batch runs in-process (no fake binary): the dry-run line proves it returned before rdo_run_batch
: > "$FAKE_LOG"; out="$(PBO_CONFIG=$ROOT/run/schedule/cfgH $BIN --dry-run run-schedule --batch 2>&1)"; rc=$?
[[ $rc == 0 && ! -s "$FAKE_LOG" ]] && grep -q 'dry-run\] run-schedule would back up: 101 102 103 (mode batch)' <<<"$out" && ! compgen -G "$ROOT/run/schedule/cache/*/vzdump-*" >/dev/null && ok "H: --dry-run run-schedule --batch starts no backup" || bad "H batch ($rc)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
