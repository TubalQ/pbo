#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/json.sh: the --json contract. Pins field names and types, not
# wording: every command prints exactly one JSON object on stdout with the
# envelope (schema, command, status, ok, dry_run); read views use real types;
# errors are JSON too; secrets never appear. Real local restic repo, PVE mocked.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start) are the
# machine's own files: point them into the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.creds" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
    PBO_PVE_CFS_DIR="$PWD/run-none/pve" PVE_STORAGE_CFG="$PWD/run-none/pve/storage.cfg"
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping json contract tests"; exit 0; }

printf 'pbo: JSON contract tests\n'
RUN="$ROOT/run-json"; rm -rf "$RUN"; mkdir -p "$RUN"/{cache,state,log,lock,conf,bin}
export MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/calls"; : > "$MOCK_LOG"
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm tests/mocks/dpkg-query "$RUN/bin/"
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
NTFY_TOKEN=tk_supersecret_value
NTFY_TOPIC=topic_is_a_password
NTFY_URL=https://ntfy.example/private_topic_path?auth=qwerty
RESTIC_SFTP_COMMAND="sshpass -p sftp_pw_123 ssh u@h -s sftp"
MY_OWN_KEY_NOBODY_KNOWS=some_unknown_value
RESTIC_OFFSITE_REPO=rest:https://pbouser:hunter2pass@backup.invalid:8000/pbo
TR_STORAGE=teststore
TR_WAIT_TRIES=1
TR_WAIT_SLEEP=0
PBO_PVE_LXC_DIR=$RUN/conf
EOF
chmod 600 "$RUN/config"; export PBO_CONFIG="$RUN/config"
printf 'arch: amd64\nhostname: web\nrootfs: teststore:8001/vm-8001-disk-0.raw,size=1G\nunprivileged: 1\ntags: pbo-keep-daily-30;pbo-stop\n' > "$MOCK_CONF_DIR/8001.conf"
printf 'arch: amd64\nhostname: db\nrootfs: teststore:8002/vm-8002-disk-0.raw,size=1G\nunprivileged: 1\ntags: pbo-skip\n' > "$MOCK_CONF_DIR/8002.conf"

# J <args...>: run pbo --json, keep stdout/rc in $out/$rc
J() { out="$($BIN --json "$@" 2>"$RUN/err")"; rc=$?; }
# envelope <name>: one line, valid JSON, envelope fields with the right types
envelope() {
    local name="$1"
    if [[ "$(printf '%s\n' "$out" | grep -c .)" == 1 ]] \
       && jq -e --arg c "${2:-$name}" '.schema == 1 and .command == $c and (.status|type) == "string" and (.ok|type) == "boolean" and (.dry_run|type) == "boolean"' >/dev/null 2>&1 <<<"$out"; then
        ok "$name: one JSON object with the envelope"
    else bad "$name: envelope (rc=$rc) $(head -c 300 <<<"$out")"; fi
}
has() { if jq -e "$2" >/dev/null 2>&1 <<<"$out"; then ok "$1"; else bad "$1: $(head -c 400 <<<"$out")"; fi; }

J init;                 envelope init
J backup 8001;          envelope backup
has "backup: status uploaded, vmid string" '.status == "uploaded" and .ok == true and (.vmid|type) == "string"'

J version;              envelope version
has "version: fields typed" '(.version|type) == "string" and .json_schema == 1 and (.config_schema|type) == "number" and (.role|type) == "string"'

J status;               envelope status
has "status: locks typed" '.locks.global.state == "free" and .locks.schedule.state == "free" and (.recent_job_logs|type) == "array"'

J guests;               envelope guests
has "guests: one entry per local guest" '(.guests|length) == 2 and ([.guests[].vmid] | sort) == ["8001","8002"]'
has "guests: types" 'all(.guests[]; (.vmid|type) == "string" and (.snapshots|type) == "number" and (.stale|type) == "boolean"
    and (.policy.skip|type) == "boolean" and (.policy.stop|type) == "boolean" and (.in_backup_set|type) == "boolean")'
has "guests: policy from tags" '(.guests[] | select(.vmid=="8001") | .policy) == {skip:false, stop:true, keep:"d30"}
    and (.guests[] | select(.vmid=="8002") | .policy.skip and (.in_backup_set|not))'
has "guests: newest snapshot typed" '(.guests[] | select(.vmid=="8001") | .newest | (.id|length) == 64 and (.age_s|type) == "number" and (.processed_bytes|type) == "number")'
has "guests: skipped guest without snapshot is not stale; name and type" '(.guests[] | select(.vmid=="8002") | .newest == null and .stale == false)
    and (.guests[] | select(.vmid=="8001") | .name == "web" and .type == "lxc" and .stale == false)'

# the same view from the cluster resource cache (one pvesh call; tags/name/type from there)
node="$(jq -r '.nodename // empty' /etc/pve/.members 2>/dev/null)"; [[ -n "$node" ]] || node="$(hostname -s)"
printf '[{"vmid":8001,"node":"%s","type":"lxc","name":"web-from-pvesh","tags":"pbo-keep-daily-30;pbo-stop"},{"vmid":8002,"node":"%s","type":"lxc","name":"db","tags":"pbo-skip"},{"vmid":8003,"node":"elsewhere","type":"lxc","tags":"pbo-skip"}]\n' "$node" "$node" > "$RUN/res.json"
out="$(MOCK_PVESH_JSON="$RUN/res.json" $BIN --json guests 2>/dev/null)"
has "guests via the resource cache: names, policy, other nodes ignored" '(.guests[] | select(.vmid=="8001") | .name == "web-from-pvesh" and .policy == {skip:false, stop:true, keep:"d30"})
    and (.guests[] | select(.vmid=="8002") | .policy.skip) and ([.guests[].vmid] | index("8003") == null)'
: > "$MOCK_LOG"; MOCK_PVESH_JSON="$RUN/res.json" $BIN --json guests >/dev/null 2>&1
[[ "$(grep -c '^pct config' "$MOCK_LOG")" == 0 ]] && ok "guests via the cache: no per-guest pct config calls" || bad "pct config calls: $(grep -c '^pct config' "$MOCK_LOG")"

has "guests: owner fields (standalone: pbo, pbo-skip = none)" '(.guests[] | select(.vmid=="8001") | .owner == "pbo" and .owner_job == null)
    and (.guests[] | select(.vmid=="8002") | .owner == "none" and .owner_job == null)'
# Proxmox integration (ADR 0007): a manual backup of a guest a PVE job owns warns
printf '[{"storage":"pbo","type":"pbo"}]\n' > "$RUN/storage.json"
printf '[{"id":"job-web","vmid":"8001","storage":"pbo"}]\n' > "$RUN/jobs.json"
out="$(PBO_INTEGRATION=both VZDUMP_CONF=/nonexistent MOCK_PVESH_JSON="$RUN/res.json" MOCK_PVESH_STORAGE_JSON="$RUN/storage.json" \
    MOCK_PVESH_BACKUP_JSON="$RUN/jobs.json" $BIN --json backup 8001 2>"$RUN/err")"; rc=$?
has "backup of a PVE-owned guest still runs" '.status == "uploaded" and .ok == true'
grep -q 'guest 8001 is owned by PVE job job-web; this is an extra backup' "$RUN/err" && ok "backup of a PVE-owned guest: warning" || bad "owned backup warning: $(tail -3 "$RUN/err")"
out="$(PBO_INTEGRATION=both VZDUMP_CONF=/nonexistent MOCK_PVESH_JSON="$RUN/res.json" MOCK_PVESH_STORAGE_JSON="$RUN/storage.json" \
    MOCK_PVESH_BACKUP_JSON="$RUN/jobs.json" $BIN --json guests 2>/dev/null)"
has "guests: owner pve with the job id" '(.guests[] | select(.vmid=="8001") | .owner == "pve" and .owner_job == "job-web" and .in_backup_set)'

J doctor;               envelope doctor
has "doctor: counts + findings typed" '(.problems|type) == "number" and (.warnings|type) == "number" and (.findings|length) > 3
    and all(.findings[]; (.level | IN("ok","warn","fail")) and (.message|type) == "string" and ((.vmid == null) or ((.vmid|type) == "string")))'
has "doctor: per-guest finding carries the vmid" 'any(.findings[]; .vmid == "8001")'
has "doctor: ok matches problems" '(.ok == (.problems == 0))'

J timers;               envelope timers
has "timers: four host timers, typed" '(.timers|length) == 4 and all(.timers[]; (.installed|type) == "boolean" and (.enabled|type) == "boolean"
    and ((.next == null) or (.next|type) == "string") and ((.last_exit == null) or (.last_exit|type) == "number"))'

out="$(PBO_INTEGRATION=both $BIN --json timers 2>/dev/null)"; rc=$?
has "timers: five with the Proxmox integration on (pbo-catalog.timer)" '(.timers|length) == 5 and .timers[4].unit == "pbo-catalog.timer" and (.timers[4].installed|type) == "boolean"'

out="$(PBO_PVE_PLUGIN_CHECK=false PBO_PVE_PLUGIN_PATH="$RUN/none.pm" PVE_STORAGE_CFG="$RUN/storage.cfg" VZDUMP_CONF="$RUN/vzdump.conf" \
    $BIN --json integrate status 2>"$RUN/err")"; rc=$?
envelope "integrate status" integrate
has "integrate status: typed" '.mode == "standalone" and (.versions|type) == "array" and (.versions_ok|type) == "boolean"
    and (.plugin.present|type) == "boolean" and (.storage.present|type) == "boolean" and (.hook.configured|type) == "boolean"
    and (.spool.files|type) == "number" and (.catalog.present|type) == "boolean" and ((.jobs == null) or (.jobs|type) == "array")
    and (.ownership|type) == "object" and (.recipe.storage_cfg|type) == "string" and (.recipe.vzdump_conf|type) == "string"'

J config;               envelope config
has "config: keys with source" '(.keys|length) > 20 and any(.keys[]; .key == "CACHE_DIR" and .source == "config") and any(.keys[]; .key == "DOCTOR_MAX_AGE" and .source == "default")'
has "config: secret redacted but marked set" 'any(.keys[]; .key == "NTFY_TOKEN" and .value == null and .secret and .set)'
! grep -q "tk_supersecret_value" <<<"$out" && ok "config: the token appears nowhere" || bad "config leaks the token"
for leak in topic_is_a_password private_topic_path qwerty sftp_pw_123 some_unknown_value; do
    ! grep -q "$leak" <<<"$out" && ok "config: '$leak' not shown" || bad "config leaks $leak"
done
has "config: topic, url, sftp command and unknown keys are reported as set secrets" '[.keys[] | select(.key | IN("NTFY_TOPIC","NTFY_URL","RESTIC_SFTP_COMMAND","MY_OWN_KEY_NOBODY_KNOWS")) | select(.secret and .set and .value == null)] | length == 4'
! grep -q "hunter2pass" <<<"$out" && grep -q 'rest:https://\*\*\*@backup.invalid' <<<"$out" && ok "config: URL credentials masked" || bad "config URL creds: $(grep -o 'rest:[^"]*' <<<"$out")"
# the schema (0.6): LOCK_DIR and the keys with only an inline default are known, not secrets
has "config: LOCK_DIR and inline-only keys shown with their value" 'any(.keys[]; .key == "LOCK_DIR" and .secret == false and .value == "'"$RUN"'/lock")
    and any(.keys[]; .key == "TR_STORAGE" and .secret == false and .value == "teststore" and .source == "config")
    and any(.keys[]; .key == "CATALOG_LOCK_TIMEOUT" and .secret == false and .value == "600" and .source == "default")'
has "config: schema fields per key" 'all(.keys[] | select(.known); (.type|type) == "string" and (.section|type) == "string" and (.flags|type) == "array")
    and any(.keys[]; .key == "PBO_INTEGRATION" and .managed_by == "integrate")
    and any(.keys[]; .key == "MY_OWN_KEY_NOBODY_KNOWS" and .known == false and .type == null)'

J list;                 envelope list
has "list: archives typed, with ts/type/id for restore" '(.archives|type) == "array" and (.archives|length) >= 1
    and all(.archives[]; (.ts|type) == "string" and (.ts|length) > 0 and (.type | IN("lxc","qemu","host")) and (.id|length) == 64 and (.age_seconds|type) == "number" and .age_seconds >= 0)'
# credentials never leave in a URL (usage/doctor show the repo)
src="$(bash -c 'source lib/common.sh; for u in "rest:https://user:pw@h:8000/x" "rest:https://tok@h/x" "https://n.example/t?auth=abc" "sftp:u123@box.example:/pbo" "sftp:storagebox:pbo"; do _mask_url "$u"; done')"
[[ "$src" == $'rest:https://***@h:8000/x\nrest:https://***@h/x\nhttps://n.example/t?***\nsftp:***@box.example:/pbo\nsftp:storagebox:pbo' ]] \
    && ok "_mask_url: userinfo, query and sftp user masked" || bad "_mask_url: $src"
J usage;                envelope usage
has "usage: numbers" '(.physical_bytes|type) == "number" and (.snapshots|type) == "number"'
J restore-report;       envelope restore-report
has "restore-report: coverage typed" '(.coverage.guests|type) == "number" and (.tests|type) == "array"'
J preflight 8001;       envelope preflight
has "preflight: checks array" '(.checks|type) == "array" and (.vmid|type) == "string"'
J verify;               envelope verify
J --dry-run prune 2>/dev/null; out="$($BIN --json --dry-run prune 2>/dev/null)"; rc=$?; envelope prune
has "prune: arrays, dry_run true" '.dry_run == true and (.cache_deleted|type) == "array" and (.offsite_deleted|type) == "array" and (.failed_tiers|type) == "array"'
J run-schedule;         envelope run-schedule
has "run-schedule: counters are numbers" '(.backups_ok|type) == "number" and (.backups_failed|type) == "number" and (.duration_s|type) == "number"'

J job list;             envelope "job list" job
has "job list: jobs array" '(.jobs|type) == "array"'

# audit: who, via and the client address from the environment the helper sets
PBO_AUDIT_USER=carol@pve PBO_AUDIT_VIA=web PBO_AUDIT_CLIENT=192.0.2.7 $BIN --json version >/dev/null 2>&1
jq -e 'select(.command=="version") | .user == "carol@pve" and .via == "web" and .client == "192.0.2.7"' "$RUN/log/audit.jsonl" >/dev/null 2>&1 \
    && ok "audit: user, via, client recorded" || bad "audit client: $(tail -1 "$RUN/log/audit.jsonl")"
PBO_AUDIT_CLIENT='1.2.3.4"x' $BIN --json version >/dev/null 2>&1
jq -c 'select(.command=="version") | .client' "$RUN/log/audit.jsonl" | tail -1 | grep -qx null && ok "audit: a malformed client is dropped" || bad "audit bad client"

# errors
J restore-report --days x; envelope "usage error" restore-report
has "usage error: status error, exit 64, message" '.status == "error" and .ok == false and .exit == 64 and (.error|length) > 0'
[[ $rc == 64 ]] && ok "usage error: exit code unchanged (64)" || bad "usage error rc=$rc"
J nosuchcommand; envelope "unknown command" nosuchcommand
has "unknown command: JSON error" '.status == "error" and .exit == 64'
J fetch 8001 1999_01_01-00_00_00; envelope "failing command" fetch
has "failing command: error object with its exit code" ".status == \"error\" and .ok == false and .exit == $rc"
# a command that prints its own failure object and then dies: still exactly one object
J test-restore 8002; envelope "own failure object, no second error object" test-restore
has "test-restore failure: its own object" '.ok == false'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ -n "${KEEP_RUN:-}" ]] || rm -rf "$RUN"
(( fail == 0 ))
