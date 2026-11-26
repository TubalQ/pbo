#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
export PBO_JANITOR_ALLOW_ROOT=1   # the suite may run as root; the janitor case needs it
# tests/names_retention.sh: retention is unchanged by the guest name tags (0.6.2,
# lib/guest.sh; the names themselves: tests/names.sh). Two REAL repos with the
# same history, one with name tags on some snapshots (and a name that changes
# on the way), one without, keep exactly the same snapshots in every forget
# path (offsite GFS with a keep= override, the cache tier, a split guest's
# per-guest pass, RETENTION_GROUP_BY=paths, the janitor's bound forget, list
# --reasons), and pbo makes the same restic forget calls on both. pbo runs
# through tests/fixtures/run_dir_guard.sh with every path below
# run-names-retention/ (tests/fixtures/names_env.sh); a stop of the guard fails
# the suite.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
command -v jq >/dev/null 2>&1 || { echo "jq not installed, skipping name retention tests"; exit 0; }
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping name retention tests"; exit 0; }

printf 'pbo: retention with and without guest name tags\n'
RUN="$ROOT/run-names-retention"
# shellcheck source=tests/fixtures/names_env.sh
source tests/fixtures/names_env.sh

# --- retention is unchanged by the name tags ------------------------------------------------------------
# Two repos with the same history: P without any name tag (0.6.1), T with name
# tags on some snapshots, a name that changes (plain, base64, another plain) and
# none on others. Each forget path must keep the same snapshots in both, with the
# same restic forget calls.
D="$RUN/d"
bk() {   # <repo> <day> <time> <tags, comma-separated or empty> <dir>...
    local repo="$1" t; t="$(printf '2026-01-%02d %s' "$2" "$3")"; local tags="$4"; shift 4
    local d; for d in "$@"; do mkdir -p "$d"; [[ -e "$d/f" ]] || echo "$d" > "$d/f"; done
    R "$repo" backup -q --time "$t" --host pve1 ${tags:+--tag "$tags"} "$@" >/dev/null 2>&1 || echo "seed failed: $repo $t $tags" >&2
}
seed() {   # <repo> <with names: 0|1>
    local r="$1" n="$2" i nm
    R "$r" init >/dev/null 2>&1
    for i in 1 2 3 4 5; do   # 101 under a/, then (cache moved) under b/: a split guest
        nm=""; (( n )) && case $i in 1|2) nm=",name=old101" ;; 4|5) nm=",nameb64=bmV3IDEwMQ==" ;; esac
        bk "$r" "$i" 12:00:00 "vmid=101,ts=101-a$i,type=lxc$nm" "$D/a/101"
    done
    for i in 6 7 8; do nm=""; (( n )) && nm=",name=new101"; bk "$r" "$i" 10:00:00 "vmid=101,ts=101-b${i}x,type=lxc$nm" "$D/b/101"; done
    nm=""; (( n )) && nm=",name=new101"; bk "$r" 7 14:00:00 "vmid=101,ts=101-b7y,type=lxc$nm" "$D/b/101"
    for i in 1 2 3 4 5 6 7 8; do nm=""; (( n && i % 2 == 0 )) && nm=",name=ct102"
        local k=""; (( i == 8 )) && k=",keep=d2"; bk "$r" "$i" 12:00:00 "vmid=102,ts=102-a$i,type=lxc$k$nm" "$D/a/102"; done
    for i in 1 2 3 4 5 6; do nm=""; (( n )) && nm=",name=vm103"; bk "$r" "$i" 12:00:00 "vmid=103,ts=103-a$i,type=qemu$nm" "$D/a/103"; done
    for i in 1 2 3 4; do nm=""; (( n )) && nm=",name=pve1"; bk "$r" "$i" 12:00:00 "vmid=host-pve1,ts=h$i,type=host$nm" "$D/etc1" "$D/meta"; done
    for i in 5 6; do nm=""; (( n )) && nm=",name=pve1"; bk "$r" "$i" 12:00:00 "vmid=host-pve1,ts=h$i,type=host$nm" "$D/etc1" "$D/etc2" "$D/meta"; done
    for i in 1 2 3; do bk "$r" "$i" 12:00:00 "" "$D/u"; done
}
seed "$RUN/P" 0; seed "$RUN/T" 1
np="$(R "$RUN/P" snapshots --json | jq '[.[] | select((.tags // []) | any(startswith("name")))] | length')"
nt="$(R "$RUN/T" snapshots --json | jq '[.[] | select((.tags // []) | any(startswith("name")))] | length')"
na="$(R "$RUN/T" snapshots --json | jq length)"
[[ "$np" == 0 && "$nt" -gt 0 && "$nt" -lt "$na" && "$na" == "$(R "$RUN/P" snapshots --json | jq length)" ]] \
    && ok "retention seeds: the same $na snapshots, $nt of them with a name tag in T, none in P" || bad "seeds: P names $np, T names $nt of $na"
cpr() { rm -rf "$2"; cp -a "$1" "$2"; }
# kept <repo>: what is left, by ts tag (untagged by time), sorted
kept() { R "$1" snapshots --json 2>/dev/null | jq -r '[.[] | (((.tags // []) | map(select(startswith("ts="))) | .[0]) // ("untagged@" + .time[0:19]))] | sort | join(" ")'; }
# fcalls <repo>: the recorded forget/prune calls on it, the repo as REPO and the
# snapshot ids of a forget-by-id as their count (ids differ between the repos)
fcalls() { grep -F -- "-r $1 " "$ARGV_LOG" | grep -E ' (forget|prune)( |$)' | sed "s#$1#REPO#g; s/ *$//" \
           | awk '{ n = 0; o = ""; for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-f]{64}$/) n++; else o = o (o == "" ? "" : " ") $i; print o (n ? " <" n " ids>" : "") }'; }
# same <label> <repo key> <config lines...>: prune copies of P and T (at <repo key>) with the same config
same() {
    local label="$1" key="$2"; shift 2
    cpr "$RUN/P" "$RUN/Px"; cpr "$RUN/T" "$RUN/Tx"; rm -f "$W/state"/janitor-seen-*
    cfg "$RUN/p.cfg" "$@" "$key=$RUN/Px"; cfg "$RUN/t.cfg" "$@" "$key=$RUN/Tx"
    : > "$ARGV_LOG"
    local r1=0 r2=0
    PBO_CONFIG="$RUN/p.cfg" "$BIN" --json prune > "$RUN/p.out" 2>&1 || r1=$?
    PBO_CONFIG="$RUN/t.cfg" "$BIN" --json prune > "$RUN/t.out" 2>&1 || r2=$?
    (( r1 != 99 && r2 != 99 )) || echo "prune $label" >> "$RUN/guard-hits"
    local kp kt; kp="$(kept "$RUN/Px")"; kt="$(kept "$RUN/Tx")"
    if [[ $r1 == 0 && $r2 == 0 && -n "$kp" && "$kp" == "$kt" && "$(wc -w <<<"$kp")" -lt "$na" && "$(fcalls "$RUN/Px")" == "$(fcalls "$RUN/Tx")" ]]; then
        ok "retention, $label: the same $(wc -w <<<"$kp") of $na snapshots kept with and without name tags, the same forget calls"
    else
        bad "retention, $label: rc=$r1/$r2 kept P [$kp] T [$kt]; calls $(diff <(fcalls "$RUN/Px") <(fcalls "$RUN/Tx") | head -5) $(tail -2 "$RUN/t.out")"
    fi
}
GFS=("LOCAL_REPO=false" "OFFSITE_ENABLED=true" "KEEP_OFFSITE_DAILY=3" "KEEP_OFFSITE_WEEKLY=0" "KEEP_OFFSITE_MONTHLY=0" "KEEP_OVERRIDE_MIN_LAST=1")
same "offsite GFS (paths pass, a keep= override, the split guest's pass)" RESTIC_OFFSITE_REPO "${GFS[@]}"
grep -q -- "--group-by '' " "$ARGV_LOG" && ok "retention: the split guest's per-guest pass (--group-by '' --tag vmid=101) ran" || bad "no guest pass ran: $(fcalls "$RUN/Tx")"
same "offsite, RETENTION_GROUP_BY=paths" RESTIC_OFFSITE_REPO "${GFS[@]}" "RETENTION_GROUP_BY=paths"
same "cache tier (keep-last, split guest from the forget output)" RESTIC_CACHE_REPO "LOCAL_REPO=true" "OFFSITE_ENABLED=false" "KEEP_LOCAL=2"
same "janitor (bound forget)" RESTIC_OFFSITE_REPO "${GFS[@]}" "PBO_ROLE=janitor"
# list --reasons: the same plan, snapshot by snapshot
cpr "$RUN/P" "$RUN/Px"; cpr "$RUN/T" "$RUN/Tx"
cfg "$RUN/p.cfg" "${GFS[@]}" "RESTIC_OFFSITE_REPO=$RUN/Px"; cfg "$RUN/t.cfg" "${GFS[@]}" "RESTIC_OFFSITE_REPO=$RUN/Tx"
plan() { PBO_CONFIG="$1" "$BIN" --json list --reasons 2>/dev/null | jq -c '[.archives[] | {ts, keep, reasons: (.reasons | sort)}] | sort_by(.ts)'; }
pp="$(plan "$RUN/p.cfg")"; pt="$(plan "$RUN/t.cfg")"
[[ -n "$pp" && "$pp" == "$pt" && "$pp" == *'"keep":false'* ]] \
    && ok "retention, list --reasons: the same keep and reasons for every snapshot with and without name tags" || bad "list --reasons: P $pp T $pt"
nm101="$(PBO_CONFIG="$RUN/t.cfg" "$BIN" --json list 2>/dev/null | jq -r '[.archives[] | select(.vmid == "101") | .name | select(. != null)] | unique | join("|")')"
[[ "$nm101" == "new 101|new101|old101" ]] && ok "the renamed guest is one guest whose snapshots keep the names they were taken under" || bad "names of 101: $nm101"

if [[ -s "$RUN/guard-hits" ]]; then bad "the run-dir guard stopped pbo (a path outside $RUN): $(cat "$RUN/guard-hits")"; fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
