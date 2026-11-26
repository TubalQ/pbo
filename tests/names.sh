#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/names.sh: the guest's name in a snapshot (0.6.2, lib/guest.sh).
#  - the encoding: a plain name= tag for a DNS-style name, nameb64= for any
#    other (comma, blank, unicode, quotes), cleaned and capped, decoded back;
#  - every path that makes a snapshot writes the tag: pbo backup, run-schedule
#    (stream and batch), backup-host, pbo ingest (directly, through the vzdump
#    hook's backup-end, ingest --pending, a VM archive): the restic argv (a
#    wrapper records it) and the REAL snapshots in both repos;
#  - the catalogue (refresh and ingest) has a name on each entry: from the tag,
#    for a snapshot without one from the guest's current config (this node's
#    config directory, or another cluster node's in pmxcfs), else "" (no such
#    guest, another type, an undecodable tag); an index written without names
#    (0.6.1) still takes new entries, and the index refresh writes loads in the
#    0.6.1 plugin (a frozen copy, tests/perl/fixtures) and this one; `pbo list`
#    has the same name (JSON) and a NAME column (text).
# Retention with and without the tag: tests/names_retention.sh.
# pbo runs (tests/fixtures/names_env.sh) as a copy of the entry point that sources
# tests/fixtures/run_dir_guard.sh: it stops (99) before any command runs when a
# path it resolved (config, LOCK_DIR, STATE_DIR, LOG_DIR, CACHE_DIR, the PVE
# paths, the catalogue, spool and staging) lies outside run-names/, and every
# such stop fails the suite.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
command -v jq >/dev/null 2>&1 || { echo "jq not installed, skipping name tests"; exit 0; }
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping name tests"; exit 0; }

printf 'pbo: guest names in snapshots, the catalogue and list\n'
RUN="$ROOT/run-names"
# shellcheck source=tests/fixtures/names_env.sh
source tests/fixtures/names_env.sh

# --- the harness: a path outside run-names/ stops pbo -------------------------------------
cfg "$RUN/config.out" "STATE_DIR=$ROOT/run-names-outside/state"
out="$(PBO_CONFIG="$RUN/config.out" "$BIN" version 2>&1)"; rc=$?
[[ $rc == 99 && "$out" == *"run_dir_guard: STATE_DIR="* && ! -e "$ROOT/run-names-outside" ]] \
    && ok "harness: a STATE_DIR outside the run directory stops pbo (99) before it creates anything" || bad "harness: rc=$rc $out"

# --- the encoding (lib/guest.sh) ----------------------------------------------------------
# U <snippet>: bash with lib/guest.sh sourced (no pbo, no config)
U() { bash -c 'set -uo pipefail; _is_janitor() { return 1; }; _cluster_node_names() { :; }; source lib/guest.sh; '"$1" _ "${@:2}"; }
long300="$(printf 'a%.0s' $(seq 1 300))"; e200="$(printf '\xc3\xa9%.0s' $(seq 1 200))"
names_in=("web01" "a,b c" $'\xc5\xbc\xc3\xb3\xc5\x82w-\xc3\xbcn\xc3\xaf \xf0\x9f\x90\xa2' "$long300" "$e200" "x=y%2C" \
          $'tab\there\x1b[0m' $'\xe2\x80\xaeevil' "   " "-lead" 'quo"te\back' $'  pad  ' $'\x01\x02' "a.b_c-d")
names_want=("web01" "a,b c" $'\xc5\xbc\xc3\xb3\xc5\x82w-\xc3\xbcn\xc3\xaf \xf0\x9f\x90\xa2' "${long300:0:128}" "$(printf '\xc3\xa9%.0s' $(seq 1 128))" "x=y%2C" \
          "tabhere[0m" "evil" "" "-lead" 'quo"te\back' "pad" "" "a.b_c-d")
kinds_want=(name b64 b64 name b64 b64 b64 name none name b64 name none name)
for i in "${!names_in[@]}"; do
    res="$(U '_guest_name_tag "$1"; printf "%s\n%s" "$GNT_TAG" "$GNT_NAME"' "${names_in[$i]}")"
    tag="${res%%$'\n'*}"; nm="${res#*$'\n'}"
    dec="$(jq -rn --arg t "$tag" "$(U 'printf %s "$PBO_JQ_NAME"')"' {tags:[$t]} | pbo_name // ""')"
    case "$tag" in name=*) k=name ;; nameb64=*) k=b64 ;; "") k=none ;; *) k=other ;; esac
    if [[ "$k" == "${kinds_want[$i]}" && "$nm" == "${names_want[$i]}" && "$dec" == "${names_want[$i]}" && "$tag" != *[,[:space:]]* ]]; then
        ok "encoding $((i+1)): ${kinds_want[$i]} tag, cleaned and decoded back (${names_want[$i]:0:24})"
    else
        bad "encoding $((i+1)) '${names_in[$i]:0:30}': kind $k tag '${tag:0:60}' name '${nm:0:40}' decoded '${dec:0:40}'"
    fi
done
# decoding is defensive: a tag comes from whoever can write the repo
dj="$(jq -c "$(U 'printf %s "$PBO_JQ_NAME"')"' map(pbo_name)' <<<'[{"tags":["nameb64=!!!"]},{"tags":["name="]},{"tags":["name=a\u0007b"]},{"tags":[1,"name=x"]},{},{"tags":null},{"tags":["nameb64=YSxi","name=plain"]},{"tags":["name=first","name=second"]}]')"
[[ "$dj" == '[null,null,"ab","x",null,null,"plain","first"]' ]] \
    && ok "decoding: an undecodable or empty tag is no name, control characters go, name= wins over nameb64=, the first one counts" || bad "decoding: $dj"
c1="$(printf 'arch: amd64\nhostname: main-name\n[snap1]\nhostname: old-name\n' > "$RUN/tmp/c.conf"; U '_conf_guest_name lxc "$1"' "$RUN/tmp/c.conf")"
c2="$(printf 'name: vm-one\r\ncores: 2\n[pending]\nname: vm-two\n' > "$RUN/tmp/q.conf"; U '_conf_guest_name qemu "$1"' "$RUN/tmp/q.conf")"
c3="$(U '_conf_guest_name lxc "$1"' "$RUN/tmp/q.conf")"
[[ "$c1" == main-name && "$c2" == vm-one && -z "$c3" ]] \
    && ok "config: hostname: of a CT, name: of a VM, from the main section only (not a snapshot's), CR dropped" || bad "config names: '$c1' '$c2' '$c3'"

# --- pbo backup: the tag on new snapshots, in both repos ------------------------------------
ct 8001 web01 "[snap1]" "hostname: before-rename"
ct 8002 "a,b c"
ct 8003 $'\xc5\xbc\xc3\xb3\xc5\x82w-\xc3\xbcn\xc3\xaf \xf0\x9f\x90\xa2'
ct 8004 "$long300"
ct 8005 ""
G init; [[ $rc == 0 ]] || bad "init: $out"
for id in 8001 8002 8003 8004 8005; do G backup "$id"; [[ $rc == 0 ]] || bad "backup $id: rc=$rc $(tail -3 <<<"$out")"; sleep 1.05; done
[[ "$(bargv 8001)" == *"--tag name=web01 "* ]] && ok "backup: restic backup gets --tag name=web01 (the main section's hostname)" || bad "backup argv 8001: $(bargv 8001)"
[[ "$(bargv 8002)" == *"--tag nameb64=YSxiIGM= "* ]] && ok "backup: a name with a comma and a blank goes as --tag nameb64=<base64>" || bad "backup argv 8002: $(bargv 8002)"
[[ -n "$(bargv 8005)" && "$(bargv 8005)" != *"--tag name"* ]] && ok "backup: a guest without a name gets no name tag, and the backup runs" || bad "backup argv 8005: $(bargv 8005)"
for id in 8001 8002 8003 8004; do
    c="$(nametags "$W/repo-cache" "$id")"; o="$(nametags "$W/repo-offsite" "$id")"
    [[ -n "$c" && "$c" == "$o" ]] || bad "backup $id: name tag cache '$c' offsite '$o'"
done
ok "backup: the name tag is on the cache snapshot and on its offsite copy"
GJ list
lj="$out"
want3=$'\xc5\xbc\xc3\xb3\xc5\x82w-\xc3\xbcn\xc3\xaf \xf0\x9f\x90\xa2'
jq -e --arg u "$want3" --arg l "${long300:0:128}" '(.archives | map({key:.vmid, value:.name}) | from_entries) as $n
    | $n["8001"] == "web01" and $n["8002"] == "a,b c" and $n["8003"] == $u and $n["8004"] == $l and $n["8005"] == null' >/dev/null 2>&1 <<<"$lj" \
    && ok "list --json: name decoded from the tag (comma and blank, unicode, capped at 128), null without one" || bad "list names: $(jq -c '[.archives[] | {vmid, name}]' <<<"$lj" 2>&1 | head -c 600)"
jq -e '.archives | all(has("vmid") and has("archive") and has("size_bytes") and has("modtime") and has("snapshot") and has("id") and has("ts") and has("type") and has("name"))' >/dev/null 2>&1 <<<"$lj" \
    && ok "list --json: the 0.6 fields are all there, name is added" || bad "list fields: $(jq -c '.archives[0]' <<<"$lj")"
G list
[[ "$(head -1 <<<"$out")" =~ ^VMID\ +ARCHIVE\ +SIZE\ +SNAP\ +NAME$ ]] && grep -qE '^8001  vzdump-lxc-8001-.* web01$' <<<"$out" && grep -qE '^8005  .* -$' <<<"$out" \
    && ok "list: a NAME column, last (it may hold blanks), - without a name" || bad "list text: $out"

# --- run-schedule (stream and batch) and backup-host ----------------------------------------
cfg "$RUN/config" "BACKUP_ORDER=8001,8002"
n0="$(R "$W/repo-cache" snapshots --json --tag name=web01 | jq length)"
G run-schedule; rc1=$rc; sleep 1.05
G run-schedule --batch; rc2=$rc
n1="$(R "$W/repo-cache" snapshots --json --tag name=web01 | jq length)"
n2="$(R "$W/repo-offsite" snapshots --json --tag nameb64=YSxiIGM= | jq length)"
[[ $rc1 == 0 && $rc2 == 0 && "$n1" == $((n0 + 2)) && "$n2" == 3 ]] \
    && ok "run-schedule (stream, then --batch): each new snapshot has the name tag, in both repos" || bad "run-schedule: rc=$rc1/$rc2 web01 $n0 -> $n1, 8002 offsite $n2: $(tail -3 <<<"$out")"
G backup-host
hj="$(R "$W/repo-cache" snapshots --json --tag vmid=host-pve1 | jq -c '[.[].tags]')"
[[ $rc == 0 && "$hj" == *'"name=pve1"'* && "$hj" == *'"type=host"'* ]] && ok "backup-host: the host's snapshot records the node name (name=pve1)" || bad "backup-host: rc=$rc $hj $(tail -2 <<<"$out")"
cfg "$RUN/config"

# --- ingest: directly, through the hook, --pending, a VM archive -----------------------------
cfg "$RUN/config" "PBO_INTEGRATION=both"
G catalog refresh; [[ $rc == 0 ]] || bad "catalog refresh before ingest: $out"
# spool <vmid>: a fresh archive in the spool (mock vzdump), its path on stdout
spool() { local b a; b="$(ls "$W/cache/spool/dump")"; sleep 1.05; vzdump "$1" --storage pbo --compress 0 >/dev/null 2>&1
          a="$(ls "$W/cache/spool/dump")"; comm -13 <(sort <<<"$b") <(sort <<<"$a") | grep -E '\.tar$' | sed "s#^#$W/cache/spool/dump/#" | tail -1; }
a1="$(spool 8001)"; t1="$(tsof "$a1")"
GJ ingest --vmid 8001 --archive "$a1"
[[ $rc == 0 && "$(tagsof "$W/repo-cache" 8001 "$t1")" == *'"name=web01"'* && "$(tagsof "$W/repo-offsite" 8001 "$t1")" == *'"name=web01"'* ]] \
    && ok "ingest: the snapshot records the name, in the cache and offsite" || bad "ingest 8001: rc=$rc $(tagsof "$W/repo-cache" 8001 "$t1") $(tail -2 "$RUN/err")"
jq -e --arg v "backup/${a1##*/}" '.entries[] | select(.volname == $v) | .name == "web01"' "$W/catalog/index.json" >/dev/null 2>&1 \
    && ok "ingest: its catalogue entry has name web01" || bad "ingest entry: $(jq -c --arg v "backup/${a1##*/}" '.entries[] | select(.volname == $v)' "$W/catalog/index.json")"
a2="$(spool 8002)"; t2="$(tsof "$a2")"
out="$(TARGET="$a2" "$BIN" _vzdump-hook backup-end snapshot 8002 2>&1)"; rc=$?; (( rc != 99 )) || echo "hook: $out" >> "$RUN/guard-hits"
[[ $rc == 0 && "$(tagsof "$W/repo-offsite" 8002 "$t2")" == *'"nameb64=YSxiIGM="'* ]] \
    && jq -e --arg v "backup/${a2##*/}" '.entries[] | select(.volname == $v) | .name == "a,b c"' "$W/catalog/index.json" >/dev/null 2>&1 \
    && ok "the vzdump hook (backup-end → ingest): nameb64 tag, the decoded name in the catalogue" || bad "hook ingest 8002: rc=$rc $(tagsof "$W/repo-offsite" 8002 "$t2") $(tail -3 <<<"$out")"
a3="$(spool 8003)"; t3="$(tsof "$a3")"; touch -d '-30 minutes' "$a3"
G ingest --pending
[[ $rc == 0 && "$(tagsof "$W/repo-cache" 8003 "$t3")" == *nameb64=* ]] \
    && jq -e --arg v "backup/${a3##*/}" --arg u "$want3" '.entries[] | select(.volname == $v) | .name == $u' "$W/catalog/index.json" >/dev/null 2>&1 \
    && ok "ingest --pending: the leftover's snapshot has the name tag, the refreshed catalogue its unicode name" || bad "pending: rc=$rc $(tagsof "$W/repo-cache" 8003 "$t3") $(tail -3 <<<"$out")"
export MOCK_QM_VMIDS=9101; printf 'name: db-vm\ncores: 2\nscsi0: teststore:vm-9101-disk-0,size=1G\n' > "$W/pve/qemu-server/9101.conf"
qv="$W/cache/spool/dump/vzdump-qemu-9101-2026_01_15-05_00_00.vma"; head -c 20000 /dev/urandom > "$qv"
GJ ingest --vmid 9101 --archive "$qv"
[[ $rc == 0 && "$(tagsof "$W/repo-cache" 9101 2026_01_15-05_00_00)" == *'"name=db-vm"'* ]] \
    && jq -e '.entries[] | select(.vmid == 9101) | .type == "qemu" and .name == "db-vm"' "$W/catalog/index.json" >/dev/null 2>&1 \
    && ok "ingest of a VM archive: name: from the VM config, tag and catalogue" || bad "ingest 9101: rc=$rc $(tagsof "$W/repo-cache" 9101 2026_01_15-05_00_00) $(tail -2 "$RUN/err")"
a5="$(spool 8005)"
GJ ingest --vmid 8005 --archive "$a5"
[[ $rc == 0 ]] && jq -e --arg v "backup/${a5##*/}" '.entries[] | select(.volname == $v) | .name == ""' "$W/catalog/index.json" >/dev/null 2>&1 \
    && [[ "$(nametags "$W/repo-cache" 8005)" == "" ]] && ok "ingest of a guest without a name: no tag, name \"\" in the catalogue" || bad "ingest 8005: rc=$rc"
# an index written by 0.6.1 (no name fields) still takes a new entry from ingest
jq -c 'del(.entries[].name)' "$W/catalog/index.json" > "$RUN/tmp/old.json" && cp "$RUN/tmp/old.json" "$W/catalog/index.json"
a6="$(spool 8001)"
GJ ingest --vmid 8001 --archive "$a6"
[[ $rc == 0 ]] && jq -e --arg v "backup/${a6##*/}" '.version == 1 and ([.entries[] | select(.volname == $v) | .name] == ["web01"])
        and ([.entries[] | select(.volname != $v) | has("name")] | all(. == false))' "$W/catalog/index.json" >/dev/null 2>&1 \
    && ok "an index without name fields (0.6.1): ingest adds its entry with a name, the others stay as they were" || bad "old index: rc=$rc $(jq -c '[.entries[] | {volname, name}]' "$W/catalog/index.json")"
G catalog show; [[ $rc == 0 && "$out" == *"web01"* ]] && ok "catalog show: prints the name" || bad "catalog show: $out"

# --- refresh: snapshots without a name tag (taken before 0.6.2) ------------------------------
# leg <repo> <vmid> <type> <ts> [tag...]: a snapshot as 0.6.1 made it (vmid, ts, type; no name), in both repos
leg() {
    local repo="$1" v="$2" t="$3" ts="$4" ext=tar d="$W/cache/$2"; shift 4
    [[ "$t" == qemu ]] && ext=vma
    mkdir -p "$d"; head -c 3000 /dev/urandom > "$d/vzdump-$t-$v-$ts.$ext"
    local extra=(); for x in "$@"; do extra+=(--tag "$x"); done
    R "$repo" backup -q --host pve1 --tag "vmid=$v" --tag "ts=$ts" --tag "type=$t" "${extra[@]+"${extra[@]}"}" "$d" >/dev/null 2>&1 || echo "seed failed: $v $ts" >&2
    rm -f "$d/vzdump-$t-$v-$ts.$ext"
}
leg "$W/repo-cache" 8001 lxc 2026_01_10-05_00_00
leg "$W/repo-cache" 8101 lxc 2026_01_10-05_00_00                    # lives on pve2 now
printf 'arch: amd64\nhostname: remote-ct\nunprivileged: 1\n' > "$W/pve/nodes/pve2/lxc/8101.conf"
leg "$W/repo-cache" 8201 lxc 2026_01_10-05_00_00                    # gone
leg "$W/repo-cache" 8001 qemu 2026_01_11-05_00_00                   # 8001 is a CT now, this was a VM
leg "$W/repo-cache" 8002 lxc 2026_01_12-05_00_00 'nameb64=!!!'      # a tag that does not decode
G catalog refresh
I="$W/catalog/index.json"
en() { jq -r --arg v "$1" '.entries[] | select(.volname == $v) | .name' "$I"; }
[[ $rc == 0 && "$(en backup/vzdump-lxc-8001-2026_01_10-05_00_00.tar)" == web01 ]] \
    && ok "refresh: a snapshot without the tag gets the guest's current name (this node's config)" || bad "refresh fallback 8001: rc=$rc '$(en backup/vzdump-lxc-8001-2026_01_10-05_00_00.tar)' $out"
[[ "$(en backup/vzdump-lxc-8101-2026_01_10-05_00_00.tar)" == remote-ct ]] \
    && ok "refresh: a guest on another cluster node: its config in pmxcfs (nodes/pve2)" || bad "refresh fallback 8101: '$(en backup/vzdump-lxc-8101-2026_01_10-05_00_00.tar)'"
[[ "$(en backup/vzdump-lxc-8201-2026_01_10-05_00_00.tar)" == "" && "$(en backup/vzdump-qemu-8001-2026_01_11-05_00_00.vma)" == "" ]] \
    && ok "refresh: a guest that is gone, or a vmid that is now another type: name \"\"" || bad "refresh 8201/qemu 8001: '$(en backup/vzdump-lxc-8201-2026_01_10-05_00_00.tar)' '$(en backup/vzdump-qemu-8001-2026_01_11-05_00_00.vma)'"
[[ "$(en backup/vzdump-lxc-8002-2026_01_12-05_00_00.tar)" == "a,b c" ]] \
    && ok "refresh: an undecodable nameb64 tag counts as none (the current name)" || bad "refresh bad tag: '$(en backup/vzdump-lxc-8002-2026_01_12-05_00_00.tar)'"
jq -e 'all(.entries[]; (.name | type) == "string") and .version == 1' "$I" >/dev/null 2>&1 \
    && ok "refresh: every entry has a name string, the index stays version 1" || bad "refresh: name types $(jq -c '[.entries[].name | type] | unique' "$I")"
tagged_ts="$(tsof "$a1")"
# rename the guest: what the snapshots recorded stays, the untagged one follows the config
ct 8001 web01-renamed
G catalog refresh
[[ "$(en "backup/vzdump-lxc-8001-$tagged_ts.tar")" == web01 && "$(en backup/vzdump-lxc-8001-2026_01_10-05_00_00.tar)" == web01-renamed ]] \
    && ok "renamed guest: tagged snapshots keep the name they were taken under, the untagged one shows the current name" || bad "rename: '$(en "backup/vzdump-lxc-8001-$tagged_ts.tar")' '$(en backup/vzdump-lxc-8001-2026_01_10-05_00_00.tar)'"
PBO_REPO=cache GJ list
jq -e '[.archives[] | select(.ts == "2026_01_10-05_00_00") | {key:.vmid, value:.name}] | from_entries
       | .["8001"] == "web01-renamed" and .["8101"] == "remote-ct" and .["8201"] == null' >/dev/null 2>&1 <<<"$out" \
    && ok "list --json: the same fallback (current name, another node's, null)" || bad "list fallback: $(jq -c '[.archives[] | select(.ts == "2026_01_10-05_00_00") | {vmid, name}]' <<<"$out")"
# the index refresh wrote (names of every kind: tagged, fallback, unicode,
# empty) loads in the plugin of 0.6.1, the last release without the name
# field, and in this one (tests/perl/index-compat.pl)
if command -v perl >/dev/null 2>&1 && perl -MJSON::PP -e 1 2>/dev/null; then
    for p in tests/perl/fixtures/PboPlugin-0.6.1.pm pve-plugin/PboPlugin.pm; do
        d="$RUN/compat-${p##*/}"; mkdir -p "$d"
        if pout="$(perl -I tests/perl/lib tests/perl/index-compat.pl "$ROOT/$p" "$d" "$I" 2>&1)"; then
            ok "$p loads the index refresh wrote ($(grep -c '^ok ' <<<"$pout") checks)"
        else
            bad "$p and the index refresh wrote"; printf '%s\n' "$pout" | sed 's/^/    /'
        fi
    done
else
    echo "  SKIP the plugins against the index refresh wrote (no perl or JSON::PP; tests/perl.sh has the hand-built index)"
fi
cfg "$RUN/config"

if [[ -s "$RUN/guard-hits" ]]; then bad "the run-dir guard stopped pbo (a path outside $RUN): $(cat "$RUN/guard-hits")"; fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
