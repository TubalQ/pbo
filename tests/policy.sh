#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
export PBO_JANITOR_ALLOW_ROOT=1
# tests/policy.sh: per-guest policy from Proxmox tags. Mocked
# Proxmox, real local restic repos.
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
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping policy tests"; exit 0; }

printf 'pbo: per-guest policy tests\n'
RUN="$ROOT/run-policy"; rm -rf "$RUN"
mkdir -p "$RUN"/{cache,state,log,lock,conf,bin,data}
export MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/calls"; : > "$MOCK_LOG"
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm "$RUN/bin/"
export PATH="$RUN/bin:$PATH"
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
R() { RESTIC_PASSWORD_FILE="$RUN/pass" RESTIC_CACHE_DIR="$RUN/rcache" restic -r "$1" "${@:2}"; }

ct() {   # <vmid> [tags]
    { echo "arch: amd64"; echo "hostname: t$1"; echo "rootfs: teststore:$1/vm-$1-disk-0.raw,size=1G"
      [[ -n "${2:-}" ]] && echo "tags: $2"; echo "unprivileged: 1"; } > "$MOCK_CONF_DIR/$1.conf"
}
ct 8001 "pbo-keep-daily-3;prod"
ct 8002 "pbo-stop"
ct 8003 "pbo-skip"

cfg() {   # <file> <extra...>
    local f="$1"; shift
    { cat <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
BACKUP_ORDER=8001,8002,8003
RESTIC_CACHE_REPO=$RUN/cache-repo
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
KEEP_LOCAL=1
KEEP_OFFSITE_DAILY=1
KEEP_OFFSITE_WEEKLY=0
KEEP_OFFSITE_MONTHLY=0
STORAGE_BOX_SNAPSHOTS_CONFIRMED=true
EOF
      printf '%s\n' "$@"; } > "$f"; chmod 600 "$f"
}
cfg "$RUN/host.cfg" "LOCAL_REPO=true" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/off-repo"
export PBO_CONFIG="$RUN/host.cfg"
$BIN init >/dev/null 2>&1

# --- run-schedule: skip tag, stop tag, keep tag recorded ---
out="$($BIN run-schedule 2>&1)"
grep -q 'skipping 8003 (Proxmox tag pbo-skip)' <<<"$out" && ok "run-schedule skips the pbo-skip guest and says so" || bad "skip log: $out"
snaps="$(R "$RUN/off-repo" snapshots --json 2>/dev/null)"
[[ "$(jq '[.[]|select(.tags|index("vmid=8003"))]|length' <<<"$snaps")" == 0 ]] && ok "no snapshot of the skipped guest" || bad "8003 was backed up"
[[ "$(jq '[.[]|select(.tags|index("vmid=8001"))]|length' <<<"$snaps")" == 1 ]] && ok "untagged-for-skip guests backed up" || bad "8001 missing"
jq -e '[.[]|select(.tags|index("vmid=8001"))][0].tags|index("keep=d3")' <<<"$snaps" >/dev/null && ok "keep override recorded on the snapshot (keep=d3)" || bad "keep tag: $(jq -c '.[].tags' <<<"$snaps")"
jq -e '[.[]|select(.tags|index("vmid=8002"))][0].tags|map(select(startswith("keep=")))|length==0' <<<"$snaps" >/dev/null && ok "no keep tag without an override" || bad "8002 got a keep tag"
grep -q 'backup 8002: vzdump (stop' "$RUN/log/pbo.log" && ok "pbo-stop forces --mode stop" || bad "8002 mode: $(grep 'backup 8002: vzdump' "$RUN/log/pbo.log")"
grep -q 'backup 8001: vzdump (snapshot' "$RUN/log/pbo.log" && ok "other guests keep the configured mode" || bad "8001 mode"

out="$($BIN backup 8003 2>&1)"
grep -q 'tagged pbo-skip; backing it up anyway' <<<"$out" && ok "manual backup of a skipped guest works, with a warning" || bad "manual skip: $out"

out="$($BIN doctor 2>&1)"
grep -q 'WARN.*guest 8003 is not backed up (Proxmox tag pbo-skip)' <<<"$out" && ok "doctor warns about the skipped guest (not a failure)" || bad "doctor skip: $out"

# --- prune: per-guest GFS from the snapshot tags ---
seed() {   # <repo> <vmid> <keep-tag-or-empty> <days>
    local repo="$1" v="$2" k="$3" n="$4" i
    mkdir -p "$RUN/data/$v"
    for i in $(seq "$n"); do
        echo "$v $i" > "$RUN/data/$v/f"
        R "$repo" backup -q --time "2026-01-$(printf %02d "$i") 12:00:00" --tag "vmid=$v" --tag "ts=s$i" \
            ${k:+--tag "keep=$k"} "$RUN/data/$v" >/dev/null 2>&1
    done
}
cnt() { R "$1" snapshots --json 2>/dev/null | jq --arg v "vmid=$2" '[.[]|select(.tags|index($v))]|length'; }
fresh() { rm -rf "$1"; R "$1" init >/dev/null 2>&1
          seed "$1" 9001 d3 5; seed "$1" 9002 "" 5; seed "$1" 9003 d0 4; seed "$1" 9004 "w2.d2" 6; }

fresh "$RUN/p-repo"
cfg "$RUN/p.cfg" "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/p-repo"
out="$(PBO_CONFIG="$RUN/p.cfg" $BIN --json list --reasons 2>/dev/null)"
[[ "$(jq '[.archives[]|select(.vmid=="9001" and .keep==true)]|length' <<<"$out")" == 3 ]] && ok "list --reasons applies the guest's own policy" || bad "reasons 9001: $(jq -c '[.archives[]|select(.vmid=="9001")|.keep]' <<<"$out")"
PBO_CONFIG="$RUN/p.cfg" $BIN --json prune >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ok "prune ok with mixed policies" || bad "prune rc=$rc"
[[ "$(cnt "$RUN/p-repo" 9001)" == 3 ]] && ok "keep=d3 guest keeps 3 dailies" || bad "9001 has $(cnt "$RUN/p-repo" 9001)"
[[ "$(cnt "$RUN/p-repo" 9002)" == 1 ]] && ok "untagged guest gets the config default (1 daily)" || bad "9002 has $(cnt "$RUN/p-repo" 9002)"
[[ "$(cnt "$RUN/p-repo" 9003)" == 3 ]] && ok "an all-zero tag policy keeps the floor (KEEP_OVERRIDE_MIN_LAST=3), never deletes everything" || bad "9003 has $(cnt "$RUN/p-repo" 9003)"
[[ "$(cnt "$RUN/p-repo" 9004)" -ge 2 ]] && ok "combined override (w2.d2) applied" || bad "9004 has $(cnt "$RUN/p-repo" 9004)"
R "$RUN/p-repo" check >/dev/null 2>&1 && ok "repo consistent after the per-group forgets + one prune" || bad "check after prune"

# the janitor sees no Proxmox, the policy still holds (it lives in the repo)
fresh "$RUN/j-repo"
cfg "$RUN/j.cfg" "PBO_ROLE=janitor" "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/j-repo"
PATH="${PATH#"$RUN/bin:"}" PBO_CONFIG="$RUN/j.cfg" $BIN --json prune >/dev/null 2>&1
[[ "$(cnt "$RUN/j-repo" 9001)" == 3 && "$(cnt "$RUN/j-repo" 9002)" == 1 ]] && ok "janitor applies the same per-guest policy without Proxmox" || bad "janitor: 9001=$(cnt "$RUN/j-repo" 9001) 9002=$(cnt "$RUN/j-repo" 9002)"

# the newest snapshot's tag decides: drop the override and the default applies
fresh "$RUN/n-repo"
echo "9001 new" > "$RUN/data/9001/f"
R "$RUN/n-repo" backup -q --time "2026-01-10 12:00:00" --tag vmid=9001 --tag ts=s10 "$RUN/data/9001" >/dev/null 2>&1
cfg "$RUN/n.cfg" "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/n-repo"
PBO_CONFIG="$RUN/n.cfg" $BIN --json prune >/dev/null 2>&1
[[ "$(cnt "$RUN/n-repo" 9001)" == 1 ]] && ok "removing the tag: newest snapshot has none, default applies" || bad "9001 after tag removal: $(cnt "$RUN/n-repo" 9001)"

# a host that can write the repo must not get code run on the janitor via tags
rm -rf "$RUN/x-repo"; R "$RUN/x-repo" init >/dev/null 2>&1; mkdir -p "$RUN/data/9100"; echo x > "$RUN/data/9100/f"
R "$RUN/x-repo" backup -q --tag vmid=9100 --tag 'keep=d1a[$(touch '"$RUN"'/pwned1)]' "$RUN/data/9100" >/dev/null 2>&1
mkdir -p "$RUN/data/9101"; echo y > "$RUN/data/9101/f"
R "$RUN/x-repo" backup -q --tag 'vmid=9101;touch '"$RUN"'/pwned2' "$RUN/data/9101" >/dev/null 2>&1
cfg "$RUN/x.cfg" "PBO_ROLE=janitor" "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/x-repo"
PATH="${PATH#"$RUN/bin:"}" PBO_CONFIG="$RUN/x.cfg" $BIN --json prune >/dev/null 2>&1
PATH="${PATH#"$RUN/bin:"}" PBO_CONFIG="$RUN/x.cfg" $BIN doctor >/dev/null 2>&1
[[ ! -e "$RUN/pwned1" && ! -e "$RUN/pwned2" ]] && ok "hostile keep=/vmid= tags are not executed on the janitor" || bad "tag injection executed"
[[ "$(cnt "$RUN/x-repo" 9100)" == 1 ]] && ok "malformed keep= falls back to the default policy" || bad "hostile keep: $(cnt "$RUN/x-repo" 9100)"

# --- janitor vs. an untrusted writer ---
jseed() { rm -rf "$1"; R "$1" init >/dev/null 2>&1; seed "$1" 8021 d1 5; seed "$1" 8022 d5 6; }
jseed "$RUN/c-repo"
cfg "$RUN/c.cfg" "PBO_ROLE=janitor" "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/c-repo" "KEEP_OFFSITE_DAILY=3"
PATH="${PATH#"$RUN/bin:"}" PBO_CONFIG="$RUN/c.cfg" $BIN --json prune >/dev/null 2>&1
[[ "$(cnt "$RUN/c-repo" 8021)" == 3 ]] && ok "janitor: a tag can't lower retention below its own config (keep=d1 → still 3)" || bad "lowering on janitor: $(cnt "$RUN/c-repo" 8021)"
[[ "$(cnt "$RUN/c-repo" 8022)" == 5 ]] && ok "janitor: a tag may raise retention (keep=d5)" || bad "raising on janitor: $(cnt "$RUN/c-repo" 8022)"
# the same repo pruned by a host honours the lower tag (the host is trusted)
jseed "$RUN/h-repo"
cfg "$RUN/h.cfg" "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/h-repo" "KEEP_OFFSITE_DAILY=3"
PBO_CONFIG="$RUN/h.cfg" $BIN --json prune >/dev/null 2>&1
[[ "$(cnt "$RUN/h-repo" 8021)" == 3 ]] && ok "host: its own tag may lower retention, down to the floor (keep=d1 → 3 of 5)" || bad "host lowering: $(cnt "$RUN/h-repo" 8021)"

# future-dated snapshot: janitor refuses to prune, doctor fails
jseed "$RUN/f-repo"; mkdir -p "$RUN/data/8023"; echo z > "$RUN/data/8023/f"
R "$RUN/f-repo" backup -q --time "2099-01-01 00:00:00" --tag vmid=8023 "$RUN/data/8023" >/dev/null 2>&1
cfg "$RUN/f.cfg" "PBO_ROLE=janitor" "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/f-repo" "KEEP_OFFSITE_DAILY=1"
before="$(R "$RUN/f-repo" snapshots --json | jq length)"
PATH="${PATH#"$RUN/bin:"}" PBO_CONFIG="$RUN/f.cfg" $BIN --json prune >/dev/null 2>&1; rc=$?
after="$(R "$RUN/f-repo" snapshots --json | jq length)"
[[ $rc != 0 && "$before" == "$after" ]] && ok "janitor refuses to prune while a future-dated snapshot exists" || bad "future: rc=$rc $before→$after"
out="$(PATH="${PATH#"$RUN/bin:"}" PBO_CONFIG="$RUN/f.cfg" $BIN doctor 2>&1)"
grep -q 'FAIL.*dated in the future' <<<"$out" && ok "doctor fails on future-dated snapshots" || bad "doctor future: $out"

# backdated insert: a new snapshot claiming a time before the last janitor run
rm -rf "$RUN/b-repo"; R "$RUN/b-repo" init >/dev/null 2>&1
mkdir -p "$RUN/data/9301"; echo a > "$RUN/data/9301/f"
R "$RUN/b-repo" backup -q --time "$(date -d '-2 day' '+%F %T')" --tag vmid=9301 "$RUN/data/9301" >/dev/null 2>&1
cfg "$RUN/b.cfg" "PBO_ROLE=janitor" "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/b-repo" "KEEP_OFFSITE_DAILY=7"
JB() { PATH="${PATH#"$RUN/bin:"}" PBO_CONFIG="$RUN/b.cfg" $BIN "$@"; }
JB --json prune >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ls "$RUN"/state/janitor-seen-*.json >/dev/null 2>&1 && ok "first janitor prune records a baseline" || bad "baseline rc=$rc"
echo b >> "$RUN/data/9301/f"
R "$RUN/b-repo" backup -q --tag vmid=9301 "$RUN/data/9301" >/dev/null 2>&1          # honest: now
JB --json prune >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ok "an honest new snapshot passes" || bad "honest rc=$rc"
echo c >> "$RUN/data/9301/f"
R "$RUN/b-repo" backup -q --time "$(date -d '-1 day' '+%F %T')" --tag vmid=9301 "$RUN/data/9301" >/dev/null 2>&1   # a day back: far outside the skew tolerance at any time of day
before="$(R "$RUN/b-repo" snapshots --json | jq length)"
JB --json prune >/dev/null 2>&1; rc=$?
after="$(R "$RUN/b-repo" snapshots --json | jq length)"
[[ $rc != 0 && "$before" == "$after" ]] && ok "janitor refuses to prune after a backdated insert" || bad "backdated: rc=$rc $before→$after"
out="$(JB doctor 2>&1)"; grep -q 'FAIL.*backdated snapshots' <<<"$out" && ok "doctor fails on a backdated insert" || bad "doctor backdated: $out"

# malformed baseline: fail closed
for f in "$RUN"/state/janitor-seen-*.json; do echo '{"last_run":"x"}' > "$f"; done
JB --json prune >/dev/null 2>&1; rc=$?
[[ $rc != 0 ]] && ok "malformed janitor baseline blocks prune" || bad "malformed baseline rc=$rc"
out="$(JB doctor 2>&1)"; grep -q 'FAIL.*baseline.*malformed' <<<"$out" && ok "doctor fails on a malformed baseline" || bad "doctor baseline: $out"

# race: a snapshot lands between the janitor's checks and restic's own listing
rm -rf "$RUN/r-repo"; R "$RUN/r-repo" init >/dev/null 2>&1; seed "$RUN/r-repo" 9401 "" 3
cat > "$RUN/bin/racy-restic" <<RR
#!/usr/bin/env bash
# on the forget plan, first slip in a new snapshot, then answer
if [[ " \$* " == *" forget "* && " \$* " == *" --dry-run "* && ! -e "$RUN/raced" ]]; then
    touch "$RUN/raced"; mkdir -p "$RUN/data/9402"; echo r > "$RUN/data/9402/f"
    restic -r "$RUN/r-repo" backup -q --tag vmid=9401 "$RUN/data/9401" >/dev/null 2>&1
fi
exec restic "\$@"
RR
chmod 755 "$RUN/bin/racy-restic"
cfg "$RUN/r.cfg" "PBO_ROLE=janitor" "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/r-repo" "KEEP_OFFSITE_DAILY=1" "RESTIC_BIN=$RUN/bin/racy-restic"
rbefore="$(R "$RUN/r-repo" snapshots --json | jq length)"
PATH="${PATH#"$RUN/bin:"}" PBO_CONFIG="$RUN/r.cfg" $BIN --json prune >/dev/null 2>&1; rc=$?
rafter="$(R "$RUN/r-repo" snapshots --json | jq length)"
[[ -e "$RUN/raced" && $rc != 0 && "$rafter" == $((rbefore+1)) ]] && ok "snapshot arriving mid-run: janitor forgets nothing" || bad "race: rc=$rc $rbefore→$rafter raced=$([[ -e $RUN/raced ]] && echo y)"
newid="$(R "$RUN/r-repo" snapshots --json | jq -r 'max_by(.time).id')"
if grep -qsF "$newid" "$RUN"/state/janitor-seen-*.json; then bad "baseline was written after a failed run"; else ok "no baseline written after a failed run"; fi
# next run without the race: the mid-run snapshot (time = now) is honest and passes
sed -i "/^RESTIC_BIN=/d" "$RUN/r.cfg"
PATH="${PATH#"$RUN/bin:"}" PBO_CONFIG="$RUN/r.cfg" $BIN --json prune >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ok "next run judges it, honest snapshot passes, retention applied" || bad "after race rc=$rc"

# unparsable times count as suspicious
( source lib/policy.sh
  [[ "$(_future_snapshots '[{"time":"garbage","short_id":"g1"}]')" == g1 ]] ) && ok "unparsable snapshot time counts as future" || bad "unparsable time"

# unreadable snapshot list: retention fails closed, nothing is guessed
cfg "$RUN/u.cfg" "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/does-not-exist"
PBO_CONFIG="$RUN/u.cfg" $BIN --json prune >/dev/null 2>&1; rc=$?
[[ $rc != 0 ]] && ok "prune fails closed when the snapshot list can't be read" || bad "unreadable list rc=$rc"

# --- policy get / set ---
export PBO_CONFIG="$RUN/host.cfg"
ct 8010 "prod;pbo-keep-daily-3;web"
pol="$($BIN --json policy get 8010 2>/dev/null)"
jq -e '.vmid == "8010" and .skip == false and .stop == false and .keep == "d3" and .pbo_tags == ["pbo-keep-daily-3"]' >/dev/null 2>&1 <<<"$pol" \
    && ok "policy get: reads the tags" || bad "policy get: $pol"
$BIN policy set 8010 --skip on --stop on --keep d30.w8.m12.y2 >/dev/null 2>&1
ptags="$(sed -n 's/^tags: //p' "$MOCK_CONF_DIR/8010.conf")"
[[ "$ptags" == "prod;web;pbo-skip;pbo-stop;pbo-keep-daily-30;pbo-keep-weekly-8;pbo-keep-monthly-12;pbo-keep-yearly-2" ]] \
    && ok "policy set: pbo tags replaced, other tags kept in order" || bad "policy set tags: $ptags"
pol="$($BIN --json policy get 8010 2>/dev/null)"
jq -e '.skip and .stop and .keep == "d30.w8.m12.y2" and (.keep_effective | test("--keep-daily 30"))' >/dev/null 2>&1 <<<"$pol" \
    && ok "policy get after set: round-trips" || bad "round trip: $pol"
$BIN policy set 8010 --skip off --keep default >/dev/null 2>&1
ptags="$(sed -n 's/^tags: //p' "$MOCK_CONF_DIR/8010.conf")"
[[ "$ptags" == "prod;web;pbo-stop" ]] && ok "policy set: --skip off and --keep default remove only those" || bad "partial set: $ptags"
$BIN policy set 8010 --stop off >/dev/null 2>&1; $BIN policy set 8010 --stop off >/dev/null 2>&1
[[ "$(sed -n 's/^tags: //p' "$MOCK_CONF_DIR/8010.conf")" == "prod;web" ]] && ok "policy set: idempotent" || bad "idempotent"
ct 8011 "pbo-skip"; $BIN policy set 8011 --skip off >/dev/null 2>&1
! grep -q '^tags:' "$MOCK_CONF_DIR/8011.conf" && ok "policy set: last tag removed → tags deleted" || bad "empty tags: $(cat "$MOCK_CONF_DIR/8011.conf")"
pol="$($BIN --json --dry-run policy set 8010 --skip on 2>/dev/null)"
[[ "$(sed -n 's/^tags: //p' "$MOCK_CONF_DIR/8010.conf")" == "prod;web" ]] && jq -e '.dry_run and .tags == "prod;web;pbo-skip"' >/dev/null 2>&1 <<<"$pol" \
    && ok "policy set --dry-run: shows the tags, changes nothing" || bad "dry-run: $pol"
for badkeep in "d30.d40" "x5" "d" "d1234567" "d30;rm" "d30,m12" "w-1"; do
    $BIN policy set 8010 --keep "$badkeep" >/dev/null 2>&1; rc=$?
    [[ $rc == 64 ]] || bad "keep '$badkeep' accepted (rc=$rc)"
done; ok "policy set: malformed --keep rejected (duplicates, letters, length, separators)"
$BIN policy set 8010 >/dev/null 2>&1; [[ $? == 64 ]] && ok "policy set: nothing to change → usage error" || bad "empty set"
$BIN policy set 9999 --skip on >/dev/null 2>&1; [[ $? == 65 ]] && ok "policy set: unknown guest → data error" || bad "unknown guest"
$BIN policy set 8010 --skip maybe >/dev/null 2>&1; [[ $? == 64 ]] && ok "policy set: --skip must be on|off" || bad "skip value"
jq -e 'select(.command=="policy") | .read_only == false' "$RUN/log/audit.jsonl" >/dev/null 2>&1 && ok "policy set: audited as a change" || bad "audit"

rm -rf "$RUN"
printf '%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
