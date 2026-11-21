#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
export PBO_JANITOR_ALLOW_ROOT=1
# tests/policy.sh: per-guest policy from Proxmox tags (issue #9). Mocked
# Proxmox, real local restic repos.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping policy tests"; exit 0; }

printf 'pbo: per-guest policy tests\n'
RUN="$ROOT/run-policy"; rm -rf "$RUN"
mkdir -p "$RUN"/{cache,state,log,lock,conf,bin,data}
export MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/calls"; : > "$MOCK_LOG"
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh "$RUN/bin/"
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
grep -q 'guest 8003 skipped (Proxmox tag pbo-skip)' <<<"$out" && ok "doctor lists the skipped guest instead of failing it" || bad "doctor skip: $out"

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
[[ "$(cnt "$RUN/p-repo" 9003)" == 1 ]] && ok "an all-zero policy keeps the newest, never deletes everything" || bad "9003 has $(cnt "$RUN/p-repo" 9003)"
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

rm -rf "$RUN"
printf '%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
