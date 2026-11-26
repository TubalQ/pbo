#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/jobs.sh: the job model with the direct runner (no systemd
# units are created by the unit tests; the integration test covers systemd).
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
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping job tests"; exit 0; }

printf 'pbo: job model tests\n'
RUN="$ROOT/run-jobs"; rm -rf "$RUN"; mkdir -p "$RUN"/{cache,state,log,lock,conf,bin}
export MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/calls"; : > "$MOCK_LOG"
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm "$RUN/bin/"
export PATH="$RUN/bin:$PATH" JOB_RUNNER=direct
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
cat > "$RUN/config" <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
BACKUP_ORDER="8001"
OFFSITE_ENABLED=false
LOCAL_REPO=true
RESTIC_CACHE_REPO=$RUN/repo
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
GLOBAL_LOCK_TIMEOUT=60
EOF
chmod 600 "$RUN/config"; export PBO_CONFIG="$RUN/config"
printf 'arch: amd64\nhostname: web\nrootfs: teststore:8001/vm-8001-disk-0.raw,size=1G\nunprivileged: 1\n' > "$MOCK_CONF_DIR/8001.conf"
$BIN init >/dev/null 2>&1

# wait_job <id> [timeout]: until the job has a result
wait_job() { local i; for (( i=0; i < ${2:-60}; i++ )); do [[ -e "$RUN/state/runs/$1/result.json" ]] && return 0; sleep 1; done; return 1; }
st() { $BIN --json job show "$1" 2>/dev/null | jq -r '.job.state'; }

# --- start returns at once with an id ---
t0=$(date +%s)
out="$(PBO_AUDIT_USER=alice@pve PBO_AUDIT_VIA=web $BIN --json job start backup 8001 2>/dev/null)"
id="$(jq -r '.job.id' <<<"$out")"
[[ "$id" =~ ^[0-9]+$ ]] && jq -e '.status == "started" and .job.command == "backup" and .job.args == ["--queue","8001"] and .job.started_by == "alice@pve" and .job.via == "web"' >/dev/null <<<"$out" \
    && ok "job start: id, command, args (backup queues), who and via" || bad "job start: $out"
(( $(date +%s) - t0 < 5 )) && ok "job start returns at once" || bad "job start blocked"
wait_job "$id" && ok "job ran to the end" || bad "job $id never finished"
j="$($BIN --json job show "$id" 2>/dev/null)"
jq -e '.job.state == "ok" and .job.exit == 0 and .job.result.status == "uploaded" and (.job.duration_s|type) == "number"' >/dev/null <<<"$j" \
    && ok "job show: state ok, exit 0, the command's own JSON result" || bad "job show: $j"
[[ "$($BIN --json list 2>/dev/null | jq '.archives|length')" -ge 1 ]] && ok "the job really made the backup" || bad "no snapshot"
jq -e "select(.command==\"backup\") | .user == \"alice@pve\" and .via == \"web\" and .job == $id" "$RUN/log/audit.jsonl" >/dev/null 2>&1 \
    && ok "audit: the backup is attributed to the user and the job" || bad "audit: $(grep backup "$RUN/log/audit.jsonl" | tail -1)"
! grep -q '"command":"_job-run"' "$RUN/log/audit.jsonl" && ok "audit: no extra line for the runner" || bad "runner audited"

# --- log: offsets for polling ---
l="$($BIN --json job log "$id" 2>/dev/null)"
jq -e '.from == 0 and .done == true and (.lines|length) > 3 and .next == (.lines|length)' >/dev/null <<<"$l" && ok "job log: lines, next offset, done" || bad "job log: $(head -c 300 <<<"$l")"
n="$(jq -r .next <<<"$l")"
l2="$($BIN --json job log "$id" --from "$n" 2>/dev/null)"
jq -e '(.lines|length) == 0 and .from == '"$n" >/dev/null <<<"$l2" && ok "job log --from: only new lines" || bad "job log --from: $l2"
grep -q 'global lock acquired' <<<"$($BIN job log "$id" 2>/dev/null)" && ok "job log (text): the command's log" || bad "text log"

# --- a failing job ---
id2="$($BIN --json job start fetch 8001 1999_01_01-00_00_00 2>/dev/null | jq -r .job.id)"
wait_job "$id2"
jq -e '.job.state == "failed" and .job.exit != 0 and .job.result.status == "error"' >/dev/null <<<"$($BIN --json job show "$id2" 2>/dev/null)" \
    && ok "failed job: state failed, exit code, the error object" || bad "failed job: $($BIN --json job show "$id2")"

# --- queued behind a held global lock, then cancel ---
mkdir -p "$RUN/lock"
exec 8>"$RUN/lock/pbo.global"; flock -x 8
printf '0|backup|%s|%s\n' "$$" "$(date +%s)" > "$RUN/state/global.holder"
id3="$($BIN --json job start backup 8001 2>/dev/null | jq -r .job.id)"
for _ in $(seq 1 20); do [[ "$(st "$id3")" == queued ]] && break; sleep 0.5; done
[[ "$(st "$id3")" == queued ]] && ok "job waiting for the lock shows as queued" || bad "queued: $(st "$id3") / $(tail -3 "$RUN/state/runs/$id3/log")"
jq -e '[.jobs_active[] | .id] | index('"$id3"') != null' >/dev/null 2>&1 <<<"$($BIN --json status 2>/dev/null)" \
    && ok "status lists the active job" || bad "status jobs_active: $($BIN --json status 2>/dev/null)"
$BIN --json job cancel "$id3" >/dev/null 2>&1
sleep 1
jq -e '.job.state == "cancelled" and .job.cancelled' >/dev/null <<<"$($BIN --json job show "$id3" 2>/dev/null)" && ok "job cancel: cancelled" || bad "cancel: $($BIN --json job show "$id3")"
pid3="$(cat "$RUN/state/runs/$id3/pid")"; ! kill -0 "$pid3" 2>/dev/null && ok "job cancel: the process is gone" || bad "runner still alive"
$BIN job cancel "$id3" >/dev/null 2>&1; [[ $? == 64 ]] && ok "cancel a finished job: usage error" || bad "double cancel"
flock -u 8; exec 8>&-; rm -f "$RUN/state/global.holder"

# --- one prune at a time ---
exec 8>"$RUN/lock/pbo.global"; flock -x 8
printf '0|backup|%s|%s\n' "$$" "$(date +%s)" > "$RUN/state/global.holder"
ida="$($BIN --json job start prune 2>/dev/null | jq -r .job.id)"; sleep 1
out="$($BIN --json job start prune 2>/dev/null)"; rc=$?
[[ $rc == 75 ]] && jq -e '.status == "error" and (.error | test("already active"))' >/dev/null 2>&1 <<<"$out" \
    && ok "single-flight: a second prune job is refused while one is active" || bad "single-flight rc=$rc $out"
idd="$($BIN --json --dry-run job start prune 2>/dev/null | jq -r '.job.id // empty')"
[[ -n "$idd" ]] && ok "single-flight is per (command, dry run): a plan may start next to a real prune" || bad "dry-run blocked by real prune"
wait_job "$idd" 30 >/dev/null 2>&1
$BIN job cancel "$ida" >/dev/null 2>&1; flock -u 8; exec 8>&-; rm -f "$RUN/state/global.holder"; sleep 1
# job log --from with a leading zero is a number, not octal
$BIN --json job log "$ida" --from 08 >/dev/null 2>&1 && ok "job log --from 08 accepted (base 10)" || bad "--from 08"

# --- list, validation ---
jq -e '(.jobs|length) == 5 and .jobs[0].id > .jobs[-1].id and all(.jobs[]; (.state|type) == "string")' >/dev/null <<<"$($BIN --json job list 2>/dev/null)" \
    && ok "job list: newest first" || bad "job list: $($BIN --json job list)"
$BIN job start doctor >/dev/null 2>&1; [[ $? == 64 ]] && ok "job start: read-only views are not jobs" || bad "doctor as job"
$BIN job start 'backup;id' >/dev/null 2>&1; [[ $? == 64 ]] && ok "job start: unknown command rejected" || bad "odd command"
$BIN job show 'abc' >/dev/null 2>&1; [[ $? == 64 ]] && ok "job show: non-numeric id rejected" || bad "id validation"
$BIN job show '../../etc' >/dev/null 2>&1; [[ $? == 64 ]] && ok "job show: path in id rejected" || bad "path id"
$BIN job show 99999 >/dev/null 2>&1; [[ $? == 65 ]] && ok "job show: unknown id → data error" || bad "unknown id"
# an argument with shell syntax stays one argv element and is never evaluated
id4="$($BIN --json job start fetch 8001 '$(touch '"$RUN"'/pwned)' 2>/dev/null | jq -r .job.id)"; wait_job "$id4"
[[ ! -e "$RUN/pwned" ]] && jq -e '.args[1] | startswith("$(touch")' "$RUN/state/runs/$id4/meta.json" >/dev/null && ok "job args: passed as data, never evaluated" || bad "arg injection"
# dry-run carries into the job
id5="$($BIN --json --dry-run job start prune 2>/dev/null | jq -r .job.id)"; wait_job "$id5"
jq -e '.job.dry_run == true and .job.result.dry_run == true' >/dev/null <<<"$($BIN --json job show "$id5" 2>/dev/null)" && ok "dry-run carries into the job" || bad "dry-run job"
# retention
JOB_KEEP=2 $BIN job start notify-test >/dev/null 2>&1; sleep 2
[[ "$(find "$RUN/state/runs" -mindepth 1 -maxdepth 1 -type d | wc -l)" -le 3 ]] && ok "JOB_KEEP: old finished jobs pruned" || bad "retention: $(ls "$RUN/state/runs")"
jq -e 'select(.command=="job") | select(.args | index("list")) | .read_only' "$RUN/log/audit.jsonl" >/dev/null 2>&1 && ok "audit: job list is read-only" || bad "job list audit"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ -n "${KEEP_RUN:-}" ]] || rm -rf "$RUN"
(( fail == 0 ))
