#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/ownership.sh: guest ownership between PVE backup jobs and pbo.timer
# (ADR 0007, lib/ownership.sh). PVE is mocked (tests/mocks/pvesh answers
# /cluster/resources, /cluster/backup and /storage from files); no restic repo
# is needed: guests --json still lists the guests when the repo is unreachable.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start) are the
# machine's own files: point them into the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.creds" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
    PBO_PVE_CFS_DIR="$PWD/run-none/pve" PVE_STORAGE_CFG="$PWD/run-none/pve/storage.cfg"
BIN=./pbo; ROOT="$PWD"
RUN="$ROOT/run/ownership"; rm -rf "$RUN"; mkdir -p "$RUN"/{bin,conf,log,state,cache,lock}
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm "$RUN/bin/"
export PATH="$RUN/bin:$PATH" MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/mock-calls"
# the sourced harness below reads these through set_defaults (never the real dirs)
export CACHE_DIR="$RUN/cache" LOG_DIR="$RUN/log" STATE_DIR="$RUN/state" LOCK_DIR="$RUN/lock"
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
printf 'pbo: guest ownership tests\n'

node="$(jq -r '.nodename // empty' /etc/pve/.members 2>/dev/null)"; [[ -n "$node" ]] || node="$(hostname -s)"
for id in 101 102 103 104; do printf 'arch: amd64\nhostname: g%s\nrootfs: teststore:vm-%s-disk-0,size=1G\nunprivileged: 1\n' "$id" "$id" > "$MOCK_CONF_DIR/$id.conf"; done
# the cluster view: 101-104 here (101 in pool prod, 104 tagged pbo-skip), 201 elsewhere
printf '[{"vmid":101,"node":"%s","type":"lxc","name":"g101","pool":"prod"},
 {"vmid":102,"node":"%s","type":"lxc","name":"g102"},
 {"vmid":103,"node":"%s","type":"lxc","name":"g103"},
 {"vmid":104,"node":"%s","type":"lxc","name":"g104","tags":"pbo-skip"},
 {"vmid":201,"node":"other","type":"lxc","name":"far","pool":"prod"}]\n' "$node" "$node" "$node" "$node" > "$RUN/res.json"
printf '[{"storage":"local","type":"dir"},{"storage":"pbo","type":"pbo"},{"storage":"pbo2","type":"pbo"}]\n' > "$RUN/storage.json"
export MOCK_PVESH_JSON="$RUN/res.json" MOCK_PVESH_STORAGE_JSON="$RUN/storage.json"
export VZDUMP_CONF="$RUN/vzdump.conf" PVE_STORAGE_CFG="$RUN/storage.cfg"
: > "$VZDUMP_CONF"

cfg() { { echo "CACHE_DIR=$RUN/cache"; echo "LOG_DIR=$RUN/log"; echo "STATE_DIR=$RUN/state"; echo "LOCK_DIR=$RUN/lock"
          echo "NTFY_URL="; echo "NTFY_CREDS_FILE=/nonexistent"; echo "RESTIC_CACHE_REPO=$RUN/norepo"
          echo "RESTIC_PASSWORD_FILE=$RUN/nopass"; echo "OFFSITE_ENABLED=false"; echo "RESTIC_CACHE_DIR=$RUN/rcache"
          for l in "$@"; do echo "$l"; done; } > "$RUN/config"; chmod 600 "$RUN/config"; }
export PBO_CONFIG="$RUN/config"
jobs() { printf '%s\n' "$1" > "$RUN/jobs.json"; export MOCK_PVESH_BACKUP_JSON="$RUN/jobs.json"; }

# H <mode> <bash>: run a snippet with pbo's libraries sourced (mocked PVE).
H() {
    PBO_INTEGRATION="$1" bash -c '
        set -uo pipefail; SELF_DIR="$PWD"
        for l in common json cluster policy ownership; do source "lib/$l.sh"; done
        set_defaults; '"$2"
}
# owners <mode>: "vmid=owner" for 101-104, space separated
owners() { H "$1" '_pve_jobs_load; for i in 101 102 103 104; do printf "%s=%s " "$i" "$(_guest_owner "$i")"; done' 2>/dev/null; }
expect() { local got; got="$(owners "${3:-both}")"; [[ "$got" == "$2 " ]] && ok "$1" || bad "$1: got '$got', want '$2'"; }

# --- selection forms -----------------------------------------------------------
jobs '[{"id":"j-all","all":1,"exclude":"102,103","storage":"pbo","enabled":1}]'
expect "all minus exclude; pbo-skip guest still selected by the job" "101=pve:j-all 102=pbo 103=pbo 104=pve:j-all"
jobs '[{"id":"j-v","vmid":"101,103,999","storage":"pbo"}]'
expect "vmid list (and enabled missing = on); 999 is not on this node" "101=pve:j-v 102=pbo 103=pve:j-v 104=none"
jobs '[{"id":"j-p","pool":"prod","storage":"pbo2"}]'
expect "pool: its members on this node (201 in the pool lives elsewhere)" "101=pve:j-p 102=pbo 103=pbo 104=none"
jobs '[{"id":"j-pv","pool":"prod","vmid":"102","all":1,"storage":"pbo"}]'
expect "pool wins over vmid and all, as in vzdump" "101=pve:j-pv 102=pbo 103=pbo 104=none"
jobs '[{"id":"j-none","storage":"pbo"}]'
expect "a job without pool, vmid or all selects nothing" "101=pbo 102=pbo 103=pbo 104=none"
jobs '[{"id":"j-node","all":1,"node":"elsewhere","storage":"pbo"}]'
expect "a job pinned to another node is ignored" "101=pbo 102=pbo 103=pbo 104=none"
jobs "[{\"id\":\"j-here\",\"vmid\":\"102\",\"node\":\"$node\",\"storage\":\"pbo\"}]"
expect "a job pinned to this node counts" "101=pbo 102=pve:j-here 103=pbo 104=none"
jobs '[{"id":"j-off","vmid":"101","storage":"pbo","enabled":0},{"id":"j-offb","vmid":"102","storage":"pbo","enabled":false},{"id":"j-on","vmid":"103","storage":"pbo","enabled":"1"}]'
expect "enabled 0 / false do not own, enabled 1 does" "101=pbo 102=pbo 103=pve:j-on 104=none"
jobs '[{"id":"j-local","vmid":"101","storage":"local"},{"id":"j-pbo","vmid":"102","storage":"pbo"}]'
expect "job to local is not a pbo job, job to pbo is" "101=pbo 102=pve:j-pbo 103=pbo 104=none"
jobs '[{"id":"j-dd","vmid":"101","dumpdir":"/mnt/x","storage":"pbo"}]'
expect "a dumpdir job is ignored" "101=pbo 102=pbo 103=pbo 104=none"

# --- effective storage from vzdump.conf ------------------------------------------
jobs '[{"id":"j-def","vmid":"101"}]'
: > "$VZDUMP_CONF"
expect "no storage anywhere → local → not a pbo job" "101=pbo 102=pbo 103=pbo 104=none"
printf '# defaults\nstorage: pbo\nmode: snapshot\n' > "$VZDUMP_CONF"
expect "vzdump.conf storage: pbo makes a job without storage a pbo job" "101=pve:j-def 102=pbo 103=pbo 104=none"
printf 'dumpdir: /mnt/dumps\n' > "$VZDUMP_CONF"
expect "vzdump.conf with only a dumpdir: no storage, not a pbo job" "101=pbo 102=pbo 103=pbo 104=none"
printf 'dumpdir: /mnt/dumps\nstorage: pbo\n' > "$VZDUMP_CONF"
expect "vzdump.conf with dumpdir and storage: storage wins" "101=pve:j-def 102=pbo 103=pbo 104=none"
rm -f "$VZDUMP_CONF"
expect "missing vzdump.conf → local" "101=pbo 102=pbo 103=pbo 104=none"
: > "$VZDUMP_CONF"

# --- overlap: first job wins --------------------------------------------------------
jobs '[{"id":"j-first","vmid":"101","storage":"pbo"},{"id":"j-second","all":1,"storage":"pbo"}]'
expect "a guest in two jobs belongs to the first" "101=pve:j-first 102=pve:j-second 103=pve:j-second 104=pve:j-second"
out="$(H both '_pve_jobs_load; _pve_overlap_guests' 2>/dev/null)"
[[ "$out" == $'101\tj-first j-second' ]] && ok "overlap recorded with both job ids" || bad "overlap: '$out'"

# --- the sets --------------------------------------------------------------------------
jobs '[{"id":"j1","vmid":"101,104","storage":"pbo"}]'
S='_pve_jobs_load; printf "%s|%s|%s|%s" "$(_backup_set | paste -sd, -)" "$(_timer_set | paste -sd, -)" "$(_backup_set_skipped | paste -sd, -)" "$(_backup_set_unowned | paste -sd, -)"'
out="$(BACKUP_ORDER=103,102,101 H both "$S" 2>/dev/null)"
[[ "$out" == "103,102,101,104|103,102||" ]] && ok "both: backup set keeps BACKUP_ORDER and adds PVE-owned; timer set leaves them out" || bad "both sets: '$out'"
out="$(BACKUP_ORDER=103,102,101,104 H standalone "$S" 2>/dev/null)"
[[ "$out" == "103,102,101|103,102,101|104|" ]] && ok "standalone: sets as before (pbo-skip 104 left out)" || bad "standalone sets: '$out'"
out="$(BACKUP_ORDER=auto H integrated "$S" 2>/dev/null)"
[[ "$out" == "101,102,103,104|||102,103" ]] && ok "integrated: empty timer set, 102/103 unowned" || bad "integrated sets: '$out'"
jobs '[{"id":"j1","vmid":"101","storage":"pbo"}]'
out="$(BACKUP_ORDER=auto H both "$S" 2>/dev/null)"
[[ "$out" == "101,102,103|102,103|104|" ]] && ok "pbo-skip guest without a job is reported skipped" || bad "skipped: '$out'"

# --- fail open ------------------------------------------------------------------------------
jobs '[{"id":"j1","all":1,"storage":"pbo"}]'
out="$(MOCK_PVESH_FAIL_PATH=/cluster/backup BACKUP_ORDER=auto H both "$S" 2>"$RUN/err")"
[[ "$out" == "101,102,103|101,102,103|104|" ]] && ok "pvesh /cluster/backup fails: timer backs up every guest" || bad "fail open sets: '$out'"
grep -q 'ownership: cannot read the PVE backup jobs.*fail open' "$RUN/err" && ok "fail open: a warning is logged" || bad "fail open warning: $(cat "$RUN/err")"
out="$(MOCK_PVESH_FAIL_PATH=/cluster/backup BACKUP_ORDER=auto H integrated "$S" 2>/dev/null)"
[[ "$out" == "101,102,103|101,102,103|104|" ]] && ok "fail open holds in integrated too" || bad "integrated fail open: '$out'"
printf '[{"id":"j1","all":1,"storage":"pbo"}' > "$RUN/jobs.json"
out="$(BACKUP_ORDER=auto H both "$S" 2>/dev/null)"
[[ "$out" == "101,102,103|101,102,103|104|" ]] && ok "unparseable job list: fail open" || bad "bad json: '$out'"
jobs '[{"id":"j1","vmid":"102","storage":"pbo"}]'
printf 'dir: local\n\tpath /var/lib/vz\n\npbo: pbo\n\tcontent backup\n' > "$PVE_STORAGE_CFG"
expect "pbo storages from the API list" "101=pbo 102=pve:j1 103=pbo 104=none" both
export MOCK_PVESH_FAIL_PATH=/storage
expect "pvesh /storage fails: pbo storages read from storage.cfg" "101=pbo 102=pve:j1 103=pbo 104=none" both
rm -f "$PVE_STORAGE_CFG"
expect "storage list unreadable everywhere: fail open" "101=pbo 102=pbo 103=pbo 104=none" both
unset MOCK_PVESH_FAIL_PATH
jobs '[{"id":"j-p","pool":"prod","storage":"pbo"}]'
out="$(MOCK_PVESH_FAIL_PATH=/cluster/resources BACKUP_ORDER=101,102 H both "$S" 2>"$RUN/err")"
[[ "$out" == "101,102|101,102||" ]] && grep -q 'pool' "$RUN/err" && ok "pool job without a resource view: fail open" || bad "pool fail open: '$out' $(cat "$RUN/err")"

# --- doctor section ---------------------------------------------------------------------------
D='_pve_jobs_load; _doctor_integration OK FAIL WARN; printf "%s\n" "${DI_LINES[@]}"; echo "P=$DI_PROBLEMS W=$DI_WARNS"'
out="$(H standalone "$D" 2>/dev/null)"
grep -q '^OK  integration: standalone' <<<"$out" && grep -q '^P=0 W=0$' <<<"$out" && ok "doctor: standalone mode line" || bad "doctor standalone: $out"
jobs '[{"id":"j1","vmid":"101,104","storage":"pbo"},{"id":"j2","vmid":"101","storage":"pbo"}]'
out="$(BACKUP_ORDER=auto H integrated "$D" 2>/dev/null)"
grep -q '^OK  integration: integrated, 2 enabled PVE job(s) to pbo, PVE owns: 101 104' <<<"$out" && ok "doctor: mode line with the owned guests" || bad "doctor mode line: $out"
grep -q '^FAIL  guest 102 has no owner' <<<"$out" && grep -q '^FAIL  guest 103 has no owner' <<<"$out" && ok "doctor: integrated + unowned guest → FAIL" || bad "doctor unowned: $out"
grep -q '^WARN  guest 104 is tagged pbo-skip but PVE job j1' <<<"$out" && ok "doctor: pbo-skip on a PVE-owned guest → WARN" || bad "doctor skip: $out"
grep -q '^WARN  guest 101 is selected by more than one PVE job to pbo (j1, j2); j1 owns it' <<<"$out" && ok "doctor: guest in two jobs → WARN" || bad "doctor overlap: $out"
grep -q '^P=2 W=2$' <<<"$out" && ok "doctor: counters" || bad "doctor counters: $out"
out="$(BACKUP_ORDER=auto H both "$D" 2>/dev/null)"
! grep -q 'has no owner' <<<"$out" && ok "doctor: no unowned FAIL in both" || bad "doctor both: $out"
out="$(MOCK_PVESH_FAIL_PATH=/cluster/backup H both "$D" 2>/dev/null)"
grep -q '^WARN  integration: both, guest ownership unknown' <<<"$out" && grep -q '^P=0 W=1$' <<<"$out" && ok "doctor: ownership unknown → WARN" || bad "doctor unknown: $out"

# --- config check and the janitor -------------------------------------------------------------
printf 'PBO_INTEGRATION=bogus\n' > "$RUN/cc.conf"
out="$(H bogus '_integration_mode; echo; _config_check '"$RUN"'/cc.conf; printf "%s\n" "${CC_LINES[@]}"' 2>/dev/null)"
grep -q '^standalone$' <<<"$out" && grep -q "PBO_INTEGRATION='bogus' is not standalone|both|integrated" <<<"$out" \
    && ok "invalid PBO_INTEGRATION: treated as standalone, doctor names it" || bad "config check: $out"
cfg "PBO_ROLE=janitor" "PBO_INTEGRATION=both"
PBO_JANITOR_ALLOW_ROOT=1 $BIN version >/dev/null 2>"$RUN/err"; rc=$?
[[ $rc == 78 ]] && grep -q 'only standalone' "$RUN/err" && ok "janitor refuses PBO_INTEGRATION!=standalone (EX_CONFIG)" || bad "janitor: rc=$rc $(cat "$RUN/err")"

# --- the CLI: guests --json, status --json, run-schedule ---------------------------------------
jobs '[{"id":"j1","vmid":"101,104","storage":"pbo"}]'
cfg "PBO_INTEGRATION=both"
out="$($BIN --json guests 2>/dev/null)"
jq -e '(.guests[] | select(.vmid=="101") | .owner == "pve" and .owner_job == "j1" and .in_backup_set)
    and (.guests[] | select(.vmid=="102") | .owner == "pbo" and .owner_job == null and .in_backup_set)
    and (.guests[] | select(.vmid=="104") | .owner == "pve" and .owner_job == "j1" and .policy.skip and .in_backup_set)' >/dev/null 2>&1 <<<"$out" \
    && ok "guests --json: owner and owner_job" || bad "guests owner: $(head -c 600 <<<"$out")"
cfg "PBO_INTEGRATION=both" "BACKUP_ORDER=102"
out="$($BIN --json guests 2>/dev/null)"
jq -e '[.guests[].vmid] == ["102","101","104"]' >/dev/null 2>&1 <<<"$out" && ok "guests --json: PVE-owned guests outside BACKUP_ORDER are listed" || bad "guests ids: $(jq -c '[.guests[].vmid]' <<<"$out")"
out="$($BIN --json status 2>/dev/null)"
jq -e '.integration == "both"' >/dev/null 2>&1 <<<"$out" && ok "status --json: integration" || bad "status: $out"
cfg
: > "$MOCK_LOG"
out="$($BIN --json guests 2>/dev/null)"
jq -e '(.guests[] | select(.vmid=="101") | .owner == "pbo" and .owner_job == null)
    and (.guests[] | select(.vmid=="104") | .owner == "none" and (.in_backup_set | not))' >/dev/null 2>&1 <<<"$out" \
    && ok "guests --json standalone: pbo owns, pbo-skip = none" || bad "guests standalone: $(head -c 600 <<<"$out")"
jq -e '.integration == "standalone"' >/dev/null 2>&1 <<<"$($BIN --json status 2>/dev/null)" && ok "status --json: standalone by default" || bad "status standalone"
export FAKE_LOG="$RUN/calls"; printf '#!/usr/bin/env bash\necho "$*" >> "$FAKE_LOG"\n' > "$RUN/fakebin"; chmod +x "$RUN/fakebin"
PBO_SELF_BIN="$RUN/fakebin" $BIN run-schedule >/dev/null 2>&1
H standalone '_pve_jobs_load; _backup_set; _timer_set; _guest_owner 101; _doctor_integration a b c' >/dev/null 2>&1
if ! grep -qE '^pvesh get (/cluster/backup|/storage)' "$MOCK_LOG"; then ok "standalone: zero /cluster/backup and /storage calls (guests, status, run-schedule, helpers)"
else bad "standalone made calls: $(grep -E '/cluster/backup|/storage' "$MOCK_LOG" | head -3)"; fi
cfg "PBO_INTEGRATION=both"; : > "$MOCK_LOG"
$BIN --json guests >/dev/null 2>&1
[[ "$(grep -c '^pvesh get /cluster/backup' "$MOCK_LOG")" == 1 && "$(grep -c '^pvesh get /storage' "$MOCK_LOG")" == 1 ]] \
    && ok "both: one /cluster/backup and one /storage call per guests view" || bad "calls: $(grep -E '/cluster/backup|/storage' "$MOCK_LOG" | tr '\n' ' ')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
