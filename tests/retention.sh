#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
export PBO_JANITOR_ALLOW_ROOT=1   # the suite may run as root; the janitor cases need it
# tests/retention.sh: retention grouped per guest (0.6 M5, ADR 0009 "Retention per
# guest"). Real local restic repos with dated snapshots (restic backup --time);
# restic runs through a wrapper that records every call's argv, so the tests can
# prove that with no split guest pbo makes exactly the 0.5 calls. The oracle for
# "what 0.5 keeps" is the 0.5 command itself (restic forget --group-by paths)
# run directly on an untouched copy of the repo.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE and NTFY_CREDS_FILE are the machine's
# own files: point them into the checkout, at paths nothing creates (a config
# line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.creds"
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping retention tests"; exit 0; }

printf 'pbo: retention per guest tests\n'
RUN="$ROOT/run-retention"; rm -rf "$RUN"
mkdir -p "$RUN"/{cache,state,log,lock,conf,bin,wrap,d}
export MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/calls"; : > "$MOCK_LOG"
# systemctl mocked too: prune never reaches the host's units (pbo-mount.service)
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm tests/mocks/systemctl "$RUN/bin/"
export PATH="$RUN/bin:$PATH"
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
R() { RESTIC_PASSWORD_FILE="$RUN/pass" RESTIC_CACHE_DIR="$RUN/rcache" restic -r "$1" "${@:2}"; }

# restic wrapper: one line per call, each argument shell-quoted (an empty
# --group-by shows as ''). RACE_REPO set: on the first guest-pass plan (forget
# --group-by '' --dry-run), first slip a new snapshot of vmid 101 into that repo.
export ARGV_LOG="$RUN/argv" REAL_RESTIC; REAL_RESTIC="$(command -v restic)"
cat > "$RUN/wrap/restic" <<'EOF'
#!/usr/bin/env bash
{ printf '%q ' "$@"; printf '\n'; } >> "$ARGV_LOG"
if [[ -n "${RACE_REPO:-}" && ! -e "$RACE_REPO.raced" ]]; then
    a=("$@"); g=0; d=0
    for i in "${!a[@]}"; do
        [[ "${a[$i]}" == --group-by && "${a[$((i+1))]-x}" == "" ]] && g=1
        [[ "${a[$i]}" == --dry-run ]] && d=1
    done
    if (( g && d )); then
        touch "$RACE_REPO.raced"
        "$REAL_RESTIC" -r "$RACE_REPO" backup -q --host n2 --tag vmid=101,ts=101-race "$RACE_DIR" >/dev/null 2>&1
    fi
fi
exec "$REAL_RESTIC" "$@"
EOF
chmod 755 "$RUN/wrap/restic"

cfg() {   # <file> <extra lines...>
    local f="$1"; shift
    { cat <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
BACKUP_ORDER=8001
RESTIC_CACHE_REPO=$RUN/unused-cache-repo
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
RESTIC_BIN=$RUN/wrap/restic
KEEP_LOCAL=2
KEEP_OFFSITE_DAILY=3
KEEP_OFFSITE_WEEKLY=0
KEEP_OFFSITE_MONTHLY=0
STORAGE_BOX_SNAPSHOTS_CONFIRMED=true
EOF
      printf '%s\n' "$@"; } > "$f"; chmod 600 "$f"
}
off_cfg()   { cfg "$1" "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$2" "${@:3}"; }
cache_cfg() { cfg "$1" "LOCAL_REPO=true" "OFFSITE_ENABLED=false" "RESTIC_CACHE_REPO=$2" "${@:3}"; }
jan_cfg()   { cfg "$1" "PBO_ROLE=janitor" "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$2" "${@:3}"; }

# bk <repo> <time> <host> <tags (comma-separated, may be empty)> <dir>...
bk() {
    local repo="$1" t="$2" h="$3" tags="$4" dir; shift 4
    for dir in "$@"; do mkdir -p "$dir"; [[ -e "$dir/f" ]] || echo "$dir" > "$dir/f"; done
    R "$repo" backup -q --time "$t" --host "$h" ${tags:+--tag "$tags"} "$@" >/dev/null 2>&1 || echo "seed failed: $repo $t $tags" >&2
}
day() { printf '2026-01-%02d %s' "$1" "${2:-12:00:00}"; }

# --- the seeds ---------------------------------------------------------------------------
# S, a split guest: 101 under a/101 on node n1 (days 1-5), then under b/101 on n2
# (days 6, 7 twice, 8: CACHE_DIR moved and the guest migrated). 102 only under
# a/102. Untagged snapshots too: u (no tags at all) and u2 (a tag, but no vmid).
seed_s() {   # <repo> [keep tag for 101's newest snapshot]
    R "$1" init >/dev/null 2>&1
    local i
    for i in 1 2 3 4 5; do bk "$1" "$(day $i)" n1 "vmid=101,ts=101-a$i" "$RUN/d/a/101"; done
    bk "$1" "$(day 6)" n2 "vmid=101,ts=101-b6" "$RUN/d/b/101"
    bk "$1" "$(day 7 10:00:00)" n2 "vmid=101,ts=101-b7a" "$RUN/d/b/101"
    bk "$1" "$(day 7 14:00:00)" n2 "vmid=101,ts=101-b7b" "$RUN/d/b/101"
    bk "$1" "$(day 8)" n2 "vmid=101,ts=101-b8${2:+,keep=$2}" "$RUN/d/b/101"
    for i in 1 2 3 4 5 6; do bk "$1" "$(day $i)" n1 "vmid=102,ts=102-a$i" "$RUN/d/a/102"; done
    for i in 1 2 3 4; do bk "$1" "$(day $i)" n1 "" "$RUN/d/u"; done
    for i in 1 2 3; do bk "$1" "$(day $i)" n1 "note=manual$i" "$RUN/d/u2"; done
}
# N, nothing split: 102 and 103 each under one path, plus untagged u.
seed_n() {   # <repo> [keep tag for 103's newest snapshot]
    R "$1" init >/dev/null 2>&1
    local i
    for i in 1 2 3 4 5 6; do bk "$1" "$(day $i)" n1 "vmid=102,ts=102-a$i" "$RUN/d/a/102"; done
    for i in 1 2 3 4; do bk "$1" "$(day $i)" n1 "vmid=103,ts=103-a$i" "$RUN/d/a/103"; done
    bk "$1" "$(day 5)" n1 "vmid=103,ts=103-a5${2:+,keep=$2}" "$RUN/d/a/103"
    for i in 1 2 3; do bk "$1" "$(day $i)" n1 "" "$RUN/d/u"; done
}
seed_s "$RUN/S"
seed_s "$RUN/C" d2;  for i in 1 2 3 4; do bk "$RUN/C" "$(day $i)" n1 "vmid=103,ts=103-a$i" "$RUN/d/a/103"; done
bk "$RUN/C" "$(day 5)" n1 "vmid=103,ts=103-a5,keep=d1" "$RUN/d/a/103"
seed_n "$RUN/N"
seed_n "$RUN/NO" d1
# H, host backups of node pve1 whose path list grew (a new file in /etc) on day 5
R "$RUN/H" init >/dev/null 2>&1
for i in 1 2 3 4; do bk "$RUN/H" "$(day $i)" pve1 "vmid=host-pve1,ts=h$i,type=host" "$RUN/d/etc1" "$RUN/d/meta"; done
for i in 5 6; do bk "$RUN/H" "$(day $i)" pve1 "vmid=host-pve1,ts=h$i,type=host" "$RUN/d/etc1" "$RUN/d/etc2" "$RUN/d/meta"; done
for i in 1 2 3 4 5; do bk "$RUN/H" "$(day $i)" pve1 "vmid=102,ts=102-a$i" "$RUN/d/a/102"; done
[[ "$(R "$RUN/S" snapshots --json | jq length)" == 22 && "$(R "$RUN/H" snapshots --json | jq length)" == 11 ]] \
    && ok "seeded the repos (dated snapshots, two path sets for 101 and host-pve1)" || bad "seeding: S=$(R "$RUN/S" snapshots --json | jq length) H=$(R "$RUN/H" snapshots --json | jq length)"

# --- helpers -----------------------------------------------------------------------------
cpr()   { rm -rf "$2"; cp -a "$1" "$2"; }
# names <repo> <vmid>: the ts= tags of that guest's snapshots, sorted
names() { R "$1" snapshots --json 2>/dev/null | jq -r --arg v "vmid=$2" '[.[] | select((.tags // []) | index($v)) | .tags[] | select(startswith("ts=")) | sub("ts=";"")] | sort | join(" ")'; }
# ids <repo-or-json> <vmid|untagged|all>: sorted short ids (untagged = no vmid tag)
sel() { jq -r --arg v "$1" '[.[] | select(if $v == "all" then true elif $v == "untagged" then ((.tags // []) | map(select(startswith("vmid="))) | length) == 0 else ((.tags // []) | index("vmid=\($v)")) end) | .short_id] | sort | join(" ")'; }
ids() { R "$1" snapshots --json 2>/dev/null | sel "$2"; }
# oracle <repo> <forget args...>: the snapshots (as a list) the given forget keeps, dry run
oracle() { R "$1" forget "${@:2}" --dry-run --json 2>/dev/null | jq -c '[.[] | (.keep // [])[]]'; }
# calls <repo>: the recorded restic calls against that repo, repo path as REPO, --help probes dropped
calls() { grep -F -- "-r $1 " "$ARGV_LOG" | grep -v -- '--help' | sed "s#$1#REPO#g; s/ *$//"; }
# calls_ids: like calls, with the ids of a forget-by-id sorted. restic orders
# snapshots with the same time differently from run to run, so the same plan
# can list the same ids in another order.
calls_ids() {
    calls "$1" | awk '{ n = 0; for (i = 1; i <= NF; i++) if ($i ~ /^[0-9a-f]{64}$/) id[++n] = $i; else w = (w == "" ? $i : w " " $i);
        if (n) { cmd = "printf \"%s\\n\""; for (i = 1; i <= n; i++) cmd = cmd " " id[i]; cmd = cmd " | sort | tr \"\\n\" \" \""; cmd | getline s; close(cmd); print w " " s } else print w; w = ""; delete id }'
}
forgets() { calls "$1" | grep -E ' (forget|prune)( |$)'; }
P() { PBO_CONFIG="$1" $BIN "${@:2}"; }

# --- (a) nothing split: exactly the 0.5 restic calls ---------------------------------------
cpr "$RUN/N" "$RUN/Na"; cpr "$RUN/N" "$RUN/Nb"
off_cfg "$RUN/na.cfg" "$RUN/Na"; off_cfg "$RUN/nb.cfg" "$RUN/Nb" "RETENTION_GROUP_BY=paths"
: > "$ARGV_LOG"; P "$RUN/na.cfg" --json prune > "$RUN/na.out" 2>/dev/null; rc1=$?
P "$RUN/nb.cfg" --json prune > "$RUN/nb.out" 2>/dev/null; rc2=$?
want="-r REPO --retry-lock 10m forget --group-by paths --keep-daily 3 --json
-r REPO --retry-lock 10m prune"
[[ $rc1 == 0 && "$(forgets "$RUN/Na")" == "$want" ]] && ok "no split, no overrides: the one 0.5 forget (--group-by paths) and one prune" \
    || bad "no split argv (rc=$rc1): $(forgets "$RUN/Na")"
[[ $rc2 == 0 && "$(calls "$RUN/Na")" == "$(calls "$RUN/Nb")" ]] && ok "no split: every restic call identical to RETENTION_GROUP_BY=paths (0.5)" \
    || bad "guest vs paths calls differ: $(diff <(calls "$RUN/Na") <(calls "$RUN/Nb"))"
# (sorted: restic orders snapshots with the same time differently from run to run)
[[ "$(ids "$RUN/Na" all)" == "$(ids "$RUN/Nb" all)" && "$(jq -c '.offsite_deleted | sort' "$RUN/na.out")" == "$(jq -c '.offsite_deleted | sort' "$RUN/nb.out")" ]] \
    && ok "no split: the same snapshots forgotten, the same envelope" || bad "no split result: $(ids "$RUN/Na" all) vs $(ids "$RUN/Nb" all); $(jq -c .offsite_deleted "$RUN/na.out") vs $(jq -c .offsite_deleted "$RUN/nb.out")"
[[ "$(ids "$RUN/Na" all)" == "$(oracle "$RUN/N" --group-by paths --keep-daily 3 | sel all)" ]] \
    && ok "no split: kept == what 'restic forget --group-by paths' keeps" || bad "no split vs oracle"

# with per-guest overrides: the same per-keep calls with --tag vmid= filters
cpr "$RUN/NO" "$RUN/NOa"; cpr "$RUN/NO" "$RUN/NOb"
off_cfg "$RUN/noa.cfg" "$RUN/NOa"; off_cfg "$RUN/nob.cfg" "$RUN/NOb" "RETENTION_GROUP_BY=paths"
: > "$ARGV_LOG"; P "$RUN/noa.cfg" --json prune >/dev/null 2>&1; P "$RUN/nob.cfg" --json prune >/dev/null 2>&1
want="-r REPO --retry-lock 10m forget --group-by paths --keep-daily 3 --tag vmid=102 --json
-r REPO --retry-lock 10m forget --group-by paths --keep-daily 1 --keep-last 3 --tag vmid=103 --json
-r REPO --retry-lock 10m prune"
[[ "$(forgets "$RUN/NOa")" == "$want" ]] && ok "no split, overrides: the 0.5 per-keep forgets, unchanged" || bad "override argv: $(forgets "$RUN/NOa")"
[[ "$(calls "$RUN/NOa")" == "$(calls "$RUN/NOb")" && "$(ids "$RUN/NOa" all)" == "$(ids "$RUN/NOb" all)" ]] \
    && ok "no split, overrides: calls and result identical to RETENTION_GROUP_BY=paths" || bad "override guest vs paths: $(diff <(calls "$RUN/NOa") <(calls "$RUN/NOb"))"

# cache tier: the same keep-last forget and nothing else (split guests are found
# in the forget's own output, no listing before it)
cpr "$RUN/N" "$RUN/Nc"; cpr "$RUN/N" "$RUN/Nd"
cache_cfg "$RUN/nc.cfg" "$RUN/Nc"; cache_cfg "$RUN/nd.cfg" "$RUN/Nd" "RETENTION_GROUP_BY=paths"
: > "$ARGV_LOG"; P "$RUN/nc.cfg" --json prune >/dev/null 2>&1; P "$RUN/nd.cfg" --json prune >/dev/null 2>&1
want="-r REPO --retry-lock 10m forget --group-by paths --keep-last 2 --json
-r REPO --retry-lock 10m prune"
[[ "$(forgets "$RUN/Nc")" == "$want" && "$(forgets "$RUN/Nd")" == "$want" ]] && ok "cache, no split: the 0.5 keep-last forget and prune" || bad "cache argv: $(forgets "$RUN/Nc")"
# the full 0.5 sequence: stale-lock check, forget, prune, the catalogue refresh
# (unchanged code around the forget); no listing before the forget
want05="-r REPO list locks
$want
-r REPO --no-lock snapshots --json"
[[ "$(calls "$RUN/Nc")" == "$want05" ]] && ok "cache, no split: every restic call is 0.5's (forget, then prune; no listing before)" || bad "cache calls: $(calls "$RUN/Nc")"
[[ "$(calls "$RUN/Nc")" == "$(calls "$RUN/Nd")" ]] \
    && ok "cache, no split: every restic call identical to RETENTION_GROUP_BY=paths (0.5)" || bad "cache calls: $(diff <(calls "$RUN/Nc") <(calls "$RUN/Nd"))"
[[ "$(ids "$RUN/Nc" all)" == "$(ids "$RUN/Nd" all)" ]] && ok "cache, no split: the same snapshots kept" || bad "cache result"
# list --reasons on the cache tier: the single 0.5 dry-run forget, the same
# calls as with RETENTION_GROUP_BY=paths
cpr "$RUN/N" "$RUN/Ne"; cache_cfg "$RUN/ne.cfg" "$RUN/Ne"; cache_cfg "$RUN/nep.cfg" "$RUN/Ne" "RETENTION_GROUP_BY=paths"
: > "$ARGV_LOG"; P "$RUN/ne.cfg" --json list --reasons > "$RUN/ne.out" 2>/dev/null; cp "$ARGV_LOG" "$RUN/argv.e"
: > "$ARGV_LOG"; P "$RUN/nep.cfg" --json list --reasons >/dev/null 2>&1
[[ "$(ARGV_LOG="$RUN/argv.e" calls "$RUN/Ne" | grep -E ' forget( |$)')" == "-r REPO forget --group-by paths --keep-last 2 --dry-run --json" ]] \
    && [[ "$(ARGV_LOG="$RUN/argv.e" calls "$RUN/Ne")" == "$(calls "$RUN/Ne")" ]] && jq -e '.archives | length > 0' "$RUN/ne.out" >/dev/null \
    && ok "cache list --reasons, no split: the one 0.5 dry-run forget, calls identical to paths" || bad "cache list argv: $(ARGV_LOG="$RUN/argv.e" calls "$RUN/Ne")"

# list --reasons without a split: the same calls and the same answer as 0.5
cpr "$RUN/N" "$RUN/Nl"; off_cfg "$RUN/nl.cfg" "$RUN/Nl"; off_cfg "$RUN/nlp.cfg" "$RUN/Nl" "RETENTION_GROUP_BY=paths"
: > "$ARGV_LOG"; P "$RUN/nl.cfg" --json list --reasons > "$RUN/nl.out" 2>/dev/null; cp "$ARGV_LOG" "$RUN/argv.g"
: > "$ARGV_LOG"; P "$RUN/nlp.cfg" --json list --reasons > "$RUN/nlp.out" 2>/dev/null
[[ "$(ARGV_LOG="$RUN/argv.g" calls "$RUN/Nl")" == "$(calls "$RUN/Nl")" ]] \
    && cmp -s <(jq -c '.archives | map(del(.age_seconds)) | sort_by(.snapshot)' "$RUN/nl.out") <(jq -c '.archives | map(del(.age_seconds)) | sort_by(.snapshot)' "$RUN/nlp.out") \
    && ok "list --reasons, no split: same calls, same plan and reasons as 0.5" || bad "list no split: $(diff <(jq -c '.archives|sort_by(.snapshot)[]|[.snapshot,.keep,.reasons]' "$RUN/nl.out") <(jq -c '.archives|sort_by(.snapshot)[]|[.snapshot,.keep,.reasons]' "$RUN/nlp.out"))"

# --- (b) a split guest is retained as one; the clean one keeps what 0.5 keeps ----------------
cpr "$RUN/S" "$RUN/Sb"; off_cfg "$RUN/sb.cfg" "$RUN/Sb"
oS="$(oracle "$RUN/S" --group-by paths --keep-daily 3)"
: > "$ARGV_LOG"; P "$RUN/sb.cfg" --json prune > "$RUN/sb.out" 2>/dev/null; rc=$?
[[ $rc == 0 ]] && ok "prune with a split guest: exit 0" || bad "split prune rc=$rc"
# hand-computed: the newest snapshot of the 3 newest days over both paths and nodes
[[ "$(names "$RUN/Sb" 101)" == "101-b6 101-b7b 101-b8" ]] && ok "split 101: keeps the 3 newest days across both paths and nodes (b6, b7b, b8)" \
    || bad "split 101 kept: $(names "$RUN/Sb" 101)"
[[ "$(ids "$RUN/Sb" 102)" == "$(sel 102 <<<"$oS")" ]] && ok "clean 102: keeps exactly what 'restic forget --group-by paths' keeps" || bad "102: $(ids "$RUN/Sb" 102) vs $(sel 102 <<<"$oS")"
[[ "$(ids "$RUN/Sb" untagged)" == "$(sel untagged <<<"$oS")" && -n "$(ids "$RUN/Sb" untagged)" ]] \
    && ok "untagged snapshots (no tags; a tag but no vmid) pruned per path exactly as in 0.5" || bad "untagged: $(ids "$RUN/Sb" untagged) vs $(sel untagged <<<"$oS")"
want="-r REPO --retry-lock 10m forget --group-by paths --keep-daily 3 --json
-r REPO --retry-lock 10m forget --group-by '' --keep-daily 3 --tag vmid=101 --json
-r REPO --retry-lock 10m prune"
[[ "$(forgets "$RUN/Sb")" == "$want" ]] && ok "split: the 0.5 forget unchanged, plus --group-by '' --tag vmid=101, one prune" || bad "split argv: $(forgets "$RUN/Sb")"
R "$RUN/Sb" check >/dev/null 2>&1 && ok "repo consistent after the two passes and one prune" || bad "check after split prune"
grep -q 'retention: guest 101 has snapshots under 2 paths, retained as one guest' "$RUN/log/pbo.log" && ok "the log says which guest was retained as one" || bad "no log line"

# the cache tier, keep-last 2
cpr "$RUN/S" "$RUN/Sc"; cache_cfg "$RUN/sc.cfg" "$RUN/Sc"
Oc="$(oracle "$RUN/S" --group-by paths --keep-last 2)"
: > "$ARGV_LOG"; P "$RUN/sc.cfg" --json prune > "$RUN/sc.out" 2>/dev/null; rc=$?
[[ $rc == 0 && "$(names "$RUN/Sc" 101)" == "101-b7b 101-b8" ]] && ok "cache: split 101 keeps its newest 2 over both paths" || bad "cache 101 (rc=$rc): $(names "$RUN/Sc" 101)"
[[ "$(ids "$RUN/Sc" 102)" == "$(sel 102 <<<"$Oc")" && "$(ids "$RUN/Sc" untagged)" == "$(sel untagged <<<"$Oc")" ]] \
    && ok "cache: 102 and the untagged keep exactly what 0.5's keep-last keeps" || bad "cache 102/untagged"
[[ "$(forgets "$RUN/Sc" | grep -c -- "--group-by '' --keep-last 2 --tag vmid=101 --json")" == 1 ]] && ok "cache: guest pass --group-by '' --keep-last 2 --tag vmid=101" || bad "cache argv: $(forgets "$RUN/Sc")"
jq -e '.cache_deleted | length == (unique | length)' "$RUN/sc.out" >/dev/null && ok "cache_deleted lists each id once" || bad "cache_deleted: $(jq -c .cache_deleted "$RUN/sc.out")"

# --- (c) per-guest keep overrides with a split guest ----------------------------------------
# C: 101 split with keep=d2 on its newest snapshot (KEEP_OVERRIDE_MIN_LAST=3 adds
# keep-last 3), 102 default, 103 clean with keep=d1, untagged u/u2.
cpr "$RUN/C" "$RUN/Ca"; cpr "$RUN/C" "$RUN/Cb"
off_cfg "$RUN/ca.cfg" "$RUN/Ca"; off_cfg "$RUN/cb.cfg" "$RUN/Cb" "RETENTION_GROUP_BY=paths"
: > "$ARGV_LOG"; P "$RUN/ca.cfg" --json prune >/dev/null 2>&1; rc1=$?; P "$RUN/cb.cfg" --json prune >/dev/null 2>&1; rc2=$?
# hand-computed: keep-last 3 → b8, b7b, b7a; keep-daily 2 → b8, b7b
[[ $rc1 == 0 && "$(names "$RUN/Ca" 101)" == "101-b7a 101-b7b 101-b8" ]] && ok "split 101 with keep=d2: its own policy and the floor, over both paths (b7a, b7b, b8)" \
    || bad "override 101 (rc=$rc1): $(names "$RUN/Ca" 101)"
[[ $rc2 == 0 && "$(ids "$RUN/Ca" 102)" == "$(ids "$RUN/Cb" 102)" && "$(ids "$RUN/Ca" 103)" == "$(ids "$RUN/Cb" 103)" ]] \
    && ok "clean 102 (default) and 103 (keep=d1) keep what 0.5 keeps" || bad "override clean: 102 $(ids "$RUN/Ca" 102)/$(ids "$RUN/Cb" 102) 103 $(ids "$RUN/Ca" 103)/$(ids "$RUN/Cb" 103)"
[[ "$(ids "$RUN/Ca" 103)" == "$(oracle "$RUN/C" --group-by paths --keep-daily 1 --keep-last 3 --tag vmid=103 | sel 103)" ]] \
    && ok "103 == the 0.5 per-keep forget run directly" || bad "103 vs oracle"
[[ "$(ids "$RUN/Ca" untagged)" == "$(ids "$RUN/C" untagged)" && "$(ids "$RUN/Cb" untagged)" == "$(ids "$RUN/C" untagged)" ]] \
    && ok "with overrides the untagged snapshots stay untouched, as in 0.5" || bad "override untagged: $(ids "$RUN/Ca" untagged) vs $(ids "$RUN/C" untagged)"
forgets "$RUN/Ca" | grep -qxF -- "-r REPO --retry-lock 10m forget --group-by '' --keep-daily 2 --keep-last 3 --tag vmid=101 --json" \
    && ok "guest pass uses the policy 101 gets in the paths pass (keep=d2 + floor)" || bad "override guest argv: $(forgets "$RUN/Ca")"

# --- (d) host-<node> with two path sets -----------------------------------------------------
cpr "$RUN/H" "$RUN/Ha"; cpr "$RUN/H" "$RUN/Hb"
off_cfg "$RUN/ha.cfg" "$RUN/Ha"; off_cfg "$RUN/hb.cfg" "$RUN/Hb" "RETENTION_GROUP_BY=paths"
P "$RUN/ha.cfg" --json prune >/dev/null 2>&1; P "$RUN/hb.cfg" --json prune >/dev/null 2>&1
[[ "$(names "$RUN/Ha" host-pve1)" == "h4 h5 h6" ]] && ok "host-pve1: its path list changed, retained as one (3 newest days h4-h6)" || bad "host guest mode: $(names "$RUN/Ha" host-pve1)"
[[ "$(names "$RUN/Hb" host-pve1)" == "h2 h3 h4 h5 h6" ]] && ok "host-pve1 with paths: each path list kept on its own (0.5)" || bad "host paths mode: $(names "$RUN/Hb" host-pve1)"
[[ "$(ids "$RUN/Ha" 102)" == "$(ids "$RUN/Hb" 102)" ]] && ok "host repo: the clean guest unchanged" || bad "host repo 102"

# --- (e) the janitor's bound forget with a split guest ----------------------------------------
cpr "$RUN/S" "$RUN/Sj"; jan_cfg "$RUN/sj.cfg" "$RUN/Sj"
JP() { PATH="${PATH#"$RUN/bin:"}" PBO_CONFIG="$1" $BIN "${@:2}"; }
: > "$ARGV_LOG"; JP "$RUN/sj.cfg" --json prune > "$RUN/sj.out" 2>/dev/null; rc=$?
[[ $rc == 0 && "$(names "$RUN/Sj" 101)" == "101-b6 101-b7b 101-b8" && "$(ids "$RUN/Sj" 102)" == "$(sel 102 <<<"$oS")" ]] \
    && ok "janitor: split 101 retained as one, 102 as in 0.5" || bad "janitor (rc=$rc): 101 $(names "$RUN/Sj" 101) 102 $(ids "$RUN/Sj" 102)"
calls "$RUN/Sj" | grep -qxF -- "-r REPO forget --group-by '' --keep-daily 3 --tag vmid=101 --dry-run --json" \
    && [[ "$(calls "$RUN/Sj" | grep -cE -- '--retry-lock 10m forget [0-9a-f]{64}')" == 2 ]] \
    && ok "janitor: both passes planned with --dry-run, then the planned ids forgotten by id" || bad "janitor argv: $(calls "$RUN/Sj")"
[[ "$(ids "$RUN/Sj" all)" == "$(ids "$RUN/Sb" all)" ]] && ok "janitor and host prune leave the same snapshots" || bad "janitor vs host"
jfile() { printf '%s/janitor-seen-%s.json' "$RUN/state" "$(printf '%s' "$1" | sha256sum | cut -c1-16)"; }
[[ -s "$(jfile "$RUN/Sj")" ]] && ok "janitor: baseline written after both passes succeeded" || bad "janitor baseline missing"
# the janitor on clean repos: the 0.5 plan (--group-by paths once), forget by id, no guest pass
cpr "$RUN/N" "$RUN/Nj"; cpr "$RUN/N" "$RUN/Nk"
jan_cfg "$RUN/nj.cfg" "$RUN/Nj"; jan_cfg "$RUN/nk.cfg" "$RUN/Nk" "RETENTION_GROUP_BY=paths"
: > "$ARGV_LOG"; JP "$RUN/nj.cfg" --json prune >/dev/null 2>&1; rc1=$?; JP "$RUN/nk.cfg" --json prune >/dev/null 2>&1
fj="$(forgets "$RUN/Nj")"
[[ $rc1 == 0 && "$(head -1 <<<"$fj")" == "-r REPO forget --group-by paths --keep-daily 3 --dry-run --json" ]] \
    && [[ "$(grep -c -- ' --dry-run' <<<"$fj")" == 1 && "$(grep -c -- "--group-by ''" <<<"$fj")" == 0 ]] \
    && [[ "$(grep -cE -- '--retry-lock 10m forget [0-9a-f]{64}' <<<"$fj")" == 1 ]] \
    && ok "janitor, no split: one 0.5 plan (--group-by paths once), forget by id, no guest pass" || bad "janitor no split argv (rc=$rc1): $fj"
[[ "$(calls_ids "$RUN/Nj")" == "$(calls_ids "$RUN/Nk")" ]] && ok "janitor, no split: calls identical to RETENTION_GROUP_BY=paths (ids compared as a set)" || bad "janitor guest vs paths: $(diff <(calls_ids "$RUN/Nj") <(calls_ids "$RUN/Nk"))"
# and with per-guest overrides: the two per-keep plans, each --group-by paths with its filter
cpr "$RUN/NO" "$RUN/NOj"; cpr "$RUN/NO" "$RUN/NOk"
jan_cfg "$RUN/noj.cfg" "$RUN/NOj"; jan_cfg "$RUN/nok.cfg" "$RUN/NOk" "RETENTION_GROUP_BY=paths"
: > "$ARGV_LOG"; JP "$RUN/noj.cfg" --json prune >/dev/null 2>&1; rc1=$?; JP "$RUN/nok.cfg" --json prune >/dev/null 2>&1
fj="$(forgets "$RUN/NOj" | grep -- ' --dry-run')"
want="-r REPO forget --group-by paths --keep-daily 3 --tag vmid=102 --dry-run --json
-r REPO forget --group-by paths --keep-daily 3 --keep-last 3 --tag vmid=103 --dry-run --json"
# (103's keep=d1 may only raise retention on a janitor: daily 3, plus the floor)
[[ $rc1 == 0 && "$fj" == "$want" && "$(forgets "$RUN/NOj" | grep -c -- "--group-by ''")" == 0 ]] \
    && ok "janitor, no split, overrides: the two 0.5 per-keep plans, no guest pass" || bad "janitor overrides argv (rc=$rc1): $(forgets "$RUN/NOj")"
[[ "$(calls "$RUN/NOj")" == "$(calls "$RUN/NOk")" ]] && ok "janitor, no split, overrides: calls identical to RETENTION_GROUP_BY=paths" || bad "janitor overrides guest vs paths: $(diff <(calls "$RUN/NOj") <(calls "$RUN/NOk"))"
# a snapshot slipped in just before the guest pass's plan: that pass forgets nothing
cpr "$RUN/S" "$RUN/Sr"; jan_cfg "$RUN/sr.cfg" "$RUN/Sr"
export RACE_REPO="$RUN/Sr" RACE_DIR="$RUN/d/b/101"
JP "$RUN/sr.cfg" --json prune >/dev/null 2>"$RUN/sr.err"; rc=$?
unset RACE_REPO RACE_DIR
[[ -e "$RUN/Sr.raced" && $rc != 0 ]] && grep -q 'snapshots appeared' "$RUN/log/pbo.log" \
    && ok "janitor: a snapshot arriving before the guest pass's plan → that pass refused, exit non-zero" || bad "janitor race rc=$rc raced=$([[ -e $RUN/Sr.raced ]] && echo y)"
[[ "$(names "$RUN/Sr" 101)" == "101-a3 101-a4 101-a5 101-b6 101-b7b 101-b8 101-race" ]] \
    && ok "janitor race: only the paths pass applied (its plan was checked), the guest pass forgot nothing" || bad "janitor race kept: $(names "$RUN/Sr" 101)"
[[ ! -e "$(jfile "$RUN/Sr")" ]] && ok "janitor race: no baseline written" || bad "baseline written after a refused pass"

# --- (f) list --reasons shows the plan prune applies -------------------------------------------
cpr "$RUN/S" "$RUN/Sf"; off_cfg "$RUN/sf.cfg" "$RUN/Sf"
P "$RUN/sf.cfg" --json list --reasons > "$RUN/sf.list" 2>/dev/null
P "$RUN/sf.cfg" --json --dry-run prune > "$RUN/sf.dry" 2>/dev/null
before="$(ids "$RUN/Sf" all)"
P "$RUN/sf.cfg" --json prune > "$RUN/sf.real" 2>/dev/null
lplan="$(jq -r '[.archives[] | select(.keep == false) | .snapshot] | sort | join(" ")' "$RUN/sf.list")"
D="$(jq -r '.offsite_deleted | sort | join(" ")' "$RUN/sf.dry")"
Pd="$(jq -r '.offsite_deleted | sort | join(" ")' "$RUN/sf.real")"
# list shows vmid-tagged snapshots only; compare on those
tagged_gone="$(comm -23 <(tr ' ' '\n' <<<"$before" | sort) <(ids "$RUN/Sf" all | tr ' ' '\n' | sort) | grep -vxF -f <(ids "$RUN/S" untagged | tr ' ' '\n') | sort | paste -sd' ')"
D_tagged="$(tr ' ' '\n' <<<"$D" | grep -vxF -f <(ids "$RUN/S" untagged | tr ' ' '\n') | paste -sd' ')"
[[ -n "$lplan" && "$lplan" == "$D_tagged" && "$lplan" == "$tagged_gone" ]] && ok "list --reasons plan == --dry-run prune plan == what prune removed" \
    || bad "plans differ: list '$lplan' dry '$D_tagged' gone '$tagged_gone'"
[[ "$D" == "$Pd" ]] && jq -e '.offsite_deleted | length == (unique | length)' "$RUN/sf.dry" >/dev/null \
    && ok "--dry-run prune lists exactly what the real prune deleted, each id once" || bad "dry '$D' real '$Pd'"
jq -e '[.archives[] | select(.vmid == "101" and .keep == false) | .reasons | length == 0] | all' "$RUN/sf.list" >/dev/null \
    && jq -e '[.archives[] | select(.vmid == "101" and .keep == true) | .reasons | length > 0] | (all and length == 3)' "$RUN/sf.list" >/dev/null \
    && ok "list --reasons: split 101's reasons come from its guest pass (old path: no stale 'daily' reason)" || bad "reasons 101: $(jq -c '[.archives[]|select(.vmid=="101")|[.ts,.keep,.reasons]]' "$RUN/sf.list")"
# the cache tier as the read repo
cpr "$RUN/S" "$RUN/Sg"; cache_cfg "$RUN/sg.cfg" "$RUN/Sg"
P "$RUN/sg.cfg" --json list --reasons > "$RUN/sg.list" 2>/dev/null
P "$RUN/sg.cfg" --json prune > "$RUN/sg.real" 2>/dev/null
lplan="$(jq -r '[.archives[] | select(.keep == false) | .snapshot] | sort | join(" ")' "$RUN/sg.list")"
Pd="$(jq -r '.cache_deleted | sort | .[]' "$RUN/sg.real" | grep -vxF -f <(ids "$RUN/S" untagged | tr ' ' '\n') | paste -sd' ')"
[[ -n "$lplan" && "$lplan" == "$Pd" ]] && ok "cache: list --reasons plan == what prune removed" || bad "cache plans: list '$lplan' prune '$Pd'"

# --- (g) RETENTION_GROUP_BY=paths is 0.5 ------------------------------------------------------
cpr "$RUN/S" "$RUN/Sp"; off_cfg "$RUN/sp.cfg" "$RUN/Sp" "RETENTION_GROUP_BY=paths"
: > "$ARGV_LOG"; P "$RUN/sp.cfg" --json prune > "$RUN/sp.out" 2>/dev/null
want="-r REPO --retry-lock 10m forget --group-by paths --keep-daily 3 --json
-r REPO --retry-lock 10m prune"
[[ "$(forgets "$RUN/Sp")" == "$want" ]] && ok "paths, split guest present: only the 0.5 forget" || bad "paths argv: $(forgets "$RUN/Sp")"
[[ "$(ids "$RUN/Sp" all)" == "$(sel all <<<"$oS")" ]] && ok "paths: keeps exactly what 'restic forget --group-by paths' keeps" || bad "paths vs oracle: $(ids "$RUN/Sp" all)"
[[ "$(names "$RUN/Sp" 101)" == "101-a3 101-a4 101-a5 101-b6 101-b7b 101-b8" ]] && ok "paths: the old path of 101 is a group of its own (never pruned past 3)" || bad "paths 101: $(names "$RUN/Sp" 101)"
cpr "$RUN/S" "$RUN/Sq"; cache_cfg "$RUN/sq.cfg" "$RUN/Sq" "RETENTION_GROUP_BY=paths"
: > "$ARGV_LOG"; P "$RUN/sq.cfg" --json prune >/dev/null 2>&1
[[ -z "$(calls "$RUN/Sq" | grep -xF -- '-r REPO snapshots --json')" && "$(ids "$RUN/Sq" all)" == "$(sel all <<<"$Oc")" ]] && ok "paths, cache: no listing, 0.5's keep-last result" || bad "paths cache: $(calls "$RUN/Sq")"
# a value that is not guest|paths fails closed: 0.5 retention, not the guest pass
cpr "$RUN/S" "$RUN/St"; off_cfg "$RUN/st.cfg" "$RUN/St" "RETENTION_GROUP_BY=path"
cpr "$RUN/S" "$RUN/Su"; cache_cfg "$RUN/su.cfg" "$RUN/Su" "RETENTION_GROUP_BY=path"
cpr "$RUN/S" "$RUN/Sp2"; off_cfg "$RUN/sp2.cfg" "$RUN/Sp2" "RETENTION_GROUP_BY=paths"
cpr "$RUN/S" "$RUN/Sq2"; cache_cfg "$RUN/sq2.cfg" "$RUN/Sq2" "RETENTION_GROUP_BY=paths"
: > "$ARGV_LOG"
P "$RUN/st.cfg" --json prune >/dev/null 2>"$RUN/st.err"; P "$RUN/su.cfg" --json prune >/dev/null 2>&1
P "$RUN/sp2.cfg" --json prune >/dev/null 2>&1; P "$RUN/sq2.cfg" --json prune >/dev/null 2>&1
[[ "$(calls "$RUN/St")" == "$(calls "$RUN/Sp2")" && "$(ids "$RUN/St" all)" == "$(sel all <<<"$oS")" ]] \
    && ok "RETENTION_GROUP_BY=path (typo), offsite: the same restic calls and result as paths" || bad "typo offsite: $(diff <(calls "$RUN/St") <(calls "$RUN/Sp2"))"
[[ "$(calls "$RUN/Su")" == "$(calls "$RUN/Sq2")" && "$(ids "$RUN/Su" all)" == "$(sel all <<<"$Oc")" ]] \
    && ok "RETENTION_GROUP_BY=path (typo), cache: the same restic calls and result as paths" || bad "typo cache: $(diff <(calls "$RUN/Su") <(calls "$RUN/Sq2"))"
grep -q "retention: RETENTION_GROUP_BY='path' is not guest|paths, retaining per path as in 0.5" "$RUN/st.err" \
    && ok "prune with a typo says it retains per path" || bad "typo prune log: $(cat "$RUN/st.err")"

# doctor: informational with guest grouping, a warning with paths
cpr "$RUN/S" "$RUN/Sd"; off_cfg "$RUN/sd.cfg" "$RUN/Sd"; off_cfg "$RUN/sdp.cfg" "$RUN/Sd" "RETENTION_GROUP_BY=paths"
res="$(P "$RUN/sd.cfg" doctor 2>&1)"
grep -q 'OK.*1 guest(s) have snapshots under more than one path (CACHE_DIR moved / host paths changed); retained as one guest each: 101 (2 paths)' <<<"$res" \
    && ok "doctor: lists the split guest with its number of paths (OK)" || bad "doctor guest: $(grep -i 'more than one path' <<<"$res")"
res="$(P "$RUN/sdp.cfg" --json doctor 2>/dev/null)"
jq -e '[.findings[] | select(.level == "warn" and (.message | test("RETENTION_GROUP_BY=paths.*never pruned: 101 \\(2 paths\\)")))] | length == 1' <<<"$res" >/dev/null \
    && ok "doctor with paths: a warning (the old paths are never pruned)" || bad "doctor paths: $(jq -c '.findings[]|select(.message|test("path"))' <<<"$res")"
cpr "$RUN/H" "$RUN/Hd"; off_cfg "$RUN/hd.cfg" "$RUN/Hd"
# (doctor exits non-zero here: guest 8001 of BACKUP_ORDER has no snapshot)
res="$(P "$RUN/hd.cfg" doctor 2>&1)"
grep -q 'OK.*retained as one guest each: host-pve1 (2 paths)' <<<"$res" && ok "doctor names host-<node> too" || bad "doctor host: $(grep 'path' <<<"$res")"
off_cfg "$RUN/nd2.cfg" "$RUN/N"
res="$(P "$RUN/nd2.cfg" doctor 2>&1)"
grep -q 'guest(s) have snapshots' <<<"$res" && bad "doctor reports a split where there is none" || { grep -q 'repo .* reachable' <<<"$res" && ok "doctor: no line when nothing is split"; } || bad "doctor did not run: $res"

# --- (h) classification: split vs shared, hostile tags, path order ------------------------------
cls_json='[
 {"short_id":"1","tags":["vmid=101"],"paths":["/a/101"]}, {"short_id":"2","tags":["vmid=101"],"paths":["/b/101"]},
 {"short_id":"3","tags":["vmid=105"],"paths":["/a/101"]},
 {"short_id":"4","tags":["vmid=106"],"paths":["/c/106"]}, {"short_id":"5","tags":["vmid=106"],"paths":["/d/106"]},
 {"short_id":"6","tags":["note=x"],"paths":["/d/106"]},
 {"short_id":"7","tags":["vmid=107"],"paths":["/x/107"]}, {"short_id":"8","tags":["vmid=107"],"paths":["/y/107"]},
 {"short_id":"9","tags":["vmid=108"],"paths":["/p","/q"]}, {"short_id":"10","tags":["vmid=108"],"paths":["/q","/p"]},
 {"short_id":"11","tags":["vmid=1;touch /tmp/x"],"paths":["/h1"]}, {"short_id":"12","tags":["vmid=1;touch /tmp/x"],"paths":["/h2"]},
 {"short_id":"13","tags":["vmid=host-pve1"],"paths":["/etc","/m"]}, {"short_id":"14","tags":["vmid=host-pve1"],"paths":["/etc","/m","/n"]}
]'
got="$(source lib/policy.sh; _split_guests "$cls_json")"
[[ "$got" == $'101\t2\tshared\n106\t2\tshared\n107\t2\tsplit\nhost-pve1\t2\tsplit' ]] \
    && ok "_split_guests: split only when no other vmid or untagged snapshot uses its paths; path order and hostile vmids ignored" || bad "_split_guests: $(printf '%q' "$got")"
# a shared guest stays at 0.5: S plus vmid 109 under a/101 makes 101 shared
cpr "$RUN/S" "$RUN/Sh"; bk "$RUN/Sh" "$(day 2 13:00:00)" n1 "vmid=109,ts=109-x" "$RUN/d/a/101"
off_cfg "$RUN/sh.cfg" "$RUN/Sh"; : > "$ARGV_LOG"
Oh="$(oracle "$RUN/Sh" --group-by paths --keep-daily 3)"
dout="$(P "$RUN/sh.cfg" doctor 2>&1)"
P "$RUN/sh.cfg" --json prune >/dev/null 2>&1
[[ "$(forgets "$RUN/Sh" | grep -c -- "--group-by ''")" == 0 && "$(ids "$RUN/Sh" all)" == "$(sel all <<<"$Oh")" ]] \
    && ok "a guest whose path is shared with another vmid is retained per path, as in 0.5" || bad "shared: $(forgets "$RUN/Sh")"
grep -q 'WARN.*1 guest(s) have snapshots under more than one path, one of them shared.*101 (2 paths)' <<<"$dout" \
    && ! grep -q 'retained as one guest each' <<<"$dout" && ok "doctor warns about the shared one (not counted as retained as one)" || bad "doctor shared: $(grep 'more than one path' <<<"$dout")"

# the key itself
[[ "$(P "$RUN/sb.cfg" config get RETENTION_GROUP_BY 2>/dev/null)" == guest ]] && ok "RETENTION_GROUP_BY defaults to guest" || bad "config get: $(P "$RUN/sb.cfg" config get RETENTION_GROUP_BY 2>&1)"
off_cfg "$RUN/bad.cfg" "$RUN/N" "RETENTION_GROUP_BY=path"
res="$(P "$RUN/bad.cfg" doctor 2>&1)"
grep -q "WARN.*RETENTION_GROUP_BY='path' is not guest|paths" <<<"$res" && ok "doctor flags a misspelt RETENTION_GROUP_BY" || bad "bad value: $(grep RETENTION <<<"$res")"
grep -q "WARN.*RETENTION_GROUP_BY='path' is not guest|paths.*: retained per path as in 0.5 (split guests are not pruned)" <<<"$res" \
    && ok "doctor says what pbo does with the misspelt value" || bad "bad value consequence: $(grep RETENTION <<<"$res")"
off_cfg "$RUN/badS.cfg" "$RUN/Sd" "RETENTION_GROUP_BY=path"
res="$(P "$RUN/badS.cfg" doctor 2>&1)"
grep -q 'WARN.*RETENTION_GROUP_BY=path retains each path on its own, so the old ones are never pruned: 101 (2 paths)' <<<"$res" \
    && ! grep -q 'retained as one guest each' <<<"$res" && ok "doctor with a misspelt value: the never-pruned warning, as with paths" || bad "doctor typo split: $(grep 'more than one path' <<<"$res")"
# append-only offsite on the host: the janitor's setting decides, not the host's
off_cfg "$RUN/aop.cfg" "$RUN/Sd" "OFFSITE_APPEND_ONLY=true" "RETENTION_GROUP_BY=paths"
off_cfg "$RUN/aog.cfg" "$RUN/Sd" "OFFSITE_APPEND_ONLY=true"
res="$(P "$RUN/aop.cfg" doctor 2>&1)"; res2="$(P "$RUN/aog.cfg" doctor 2>&1)"
for r in "$res" "$res2"; do
    grep -q "OK.*1 guest(s) have snapshots under more than one path (CACHE_DIR moved / host paths changed); offsite is append-only, so the janitor's RETENTION_GROUP_BY decides how they are retained (run doctor on the janitor): 101 (2 paths)" <<<"$r" \
        && ! grep -q 'never pruned' <<<"$r" && ! grep -q 'retained as one guest each' <<<"$r" || { bad "doctor append-only: $(grep 'more than one path' <<<"$r")"; continue; }
    ok "doctor, append-only host: no verdict from the host's RETENTION_GROUP_BY, the janitor decides"
done

rm -rf "$RUN"
printf '%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
