#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/menu.sh: unit tests for the interactive menu's new building blocks, the
# numbered pickers (_pick_index) and their formatters (_ago/_hsize), plus the jq
# pipelines menu_restore uses to turn `list --json` into a guest list and a
# per-guest snapshot list. Pure bash + jq, no restic repo and no real host.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
eq()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (got '$2', wanted '$3')"; }

command -v jq >/dev/null 2>&1 || { echo "jq not installed, skipping menu tests"; exit 0; }

# Source the menu helpers. Not a tty here → colors are empty, so labels compare cleanly.
export PBO_SELF_BIN=/bin/true
# shellcheck source=lib/menu.sh
source lib/menu.sh

printf 'pbo: menu tests\n'

# --- _pick_index: valid choice echoes the index, list goes to stderr ---
idx="$(printf '2\n' | _pick_index "Pick" 1 alpha bravo charlie 2>/tmp/pbo-pick.err)"; rc=$?
eq "_pick_index: returns the chosen index" "$idx" "2"
[[ $rc == 0 ]] && ok "_pick_index: exit 0 on a valid choice" || bad "_pick_index exit ($rc)"
grep -q '\[1\] alpha' /tmp/pbo-pick.err && grep -q '\[3\] charlie' /tmp/pbo-pick.err \
    && ok "_pick_index: numbered list rendered to stderr" || bad "_pick_index list on stderr"

# --- _pick_index: empty input falls back to the default ---
idx="$(printf '\n' | _pick_index "Pick" 1 alpha bravo 2>/dev/null)"
eq "_pick_index: empty input uses the default" "$idx" "1"

# --- _pick_index: out-of-range and non-numeric both abort (non-zero, no output) ---
out="$(printf '9\n' | _pick_index "Pick" 1 alpha bravo 2>/dev/null)"; rc=$?
[[ $rc != 0 && -z "$out" ]] && ok "_pick_index: out-of-range aborts" || bad "_pick_index oob (rc=$rc out='$out')"
out="$(printf 'x\n' | _pick_index "Pick" 1 alpha bravo 2>/dev/null)"; rc=$?
[[ $rc != 0 && -z "$out" ]] && ok "_pick_index: non-numeric aborts" || bad "_pick_index nonnum (rc=$rc out='$out')"

# --- _hsize: human-readable, with a raw-bytes fallback ---
eq "_hsize: 0 bytes" "$(_hsize 0)" "0B"
[[ "$(_hsize 1288490188)" == "1.2GB" ]] && ok "_hsize: ~1.2GB" || bad "_hsize GB (got $(_hsize 1288490188))"

# --- _ago: relative age buckets (minutes / hours / days) ---
now=1000000000
eq "_ago: minutes"        "$(_ago $((now-600))   $now)" "10m ago"
eq "_ago: hours"          "$(_ago $((now-7200))  $now)" "2h ago"
eq "_ago: days"           "$(_ago $((now-172800)) $now)" "2d ago"
eq "_ago: future clamps"  "$(_ago $((now+600))   $now)" "0m ago"

# --- the jq pipelines menu_restore feeds the pickers ---
LIST='{"archives":[
  {"vmid":"108","archive":"vzdump-lxc-108-2026_09_23-05_12_51.tar","size_bytes":1288490188,"modtime":"2026-09-23T05:12:51Z","snapshot":"aaaa"},
  {"vmid":"108","archive":"vzdump-lxc-108-2026_09_21-05_10_44.tar","size_bytes":1181116006,"modtime":"2026-09-21T05:10:44Z","snapshot":"bbbb"},
  {"vmid":"100","archive":"vzdump-lxc-100-2026_09_23-05_09_00.tar","size_bytes":104857600,"modtime":"2026-09-23T05:09:00Z","snapshot":"cccc"}
]}'

# guest grouping: one row per vmid, sorted, with count + newest modtime
guests="$(jq -r '.archives | group_by(.vmid)[]
    | [ .[0].vmid, length, ([.[].modtime]|max) ] | @tsv' <<<"$LIST")"
eq "guest pipeline: rows" "$(wc -l <<<"$guests")" "2"
eq "guest pipeline: 100 has 1 snapshot" "$(awk -F'\t' '$1=="100"{print $2}' <<<"$guests")" "1"
eq "guest pipeline: 108 has 2 snapshots" "$(awk -F'\t' '$1=="108"{print $2}' <<<"$guests")" "2"
eq "guest pipeline: 108 newest modtime" "$(awk -F'\t' '$1=="108"{print $3}' <<<"$guests")" "2026-09-23T05:12:51Z"

# snapshot list for 108, newest first: first row must be the 09-23 timestamp
snaps="$(jq -r --arg v 108 '.archives[] | select(.vmid==$v)
    | [ (.archive|capture("(?<t>[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2})").t),
        .size_bytes, .modtime, .snapshot ] | @tsv' <<<"$LIST" | sort -rk3)"
eq "snapshot pipeline: newest-first ts" "$(head -1 <<<"$snaps" | cut -f1)" "2026_09_23-05_12_51"
eq "snapshot pipeline: oldest-last ts"  "$(tail -1 <<<"$snaps" | cut -f1)" "2026_09_21-05_10_44"

# --- status summary: dedup/compression label math ---
USAGE='{"physical_bytes":26900000000,"logical_bytes":210000000000,"uncompressed_bytes":62700000000,"compression_ratio":2.323}'
sz="$(jq -r '
  (.physical_bytes // 0) as $p | (.logical_bytes // 0) as $l | (.uncompressed_bytes // 0) as $u
  | ($p/1e9*10|floor/10) as $pg | ($l/1e9*10|floor/10) as $lg
  | (if $p>0 then ($l/$p*10|floor/10) else 0 end) as $tot
  | (if $u>0 then ($l/$u*10|floor/10) else 0 end) as $dd
  | ((.compression_ratio // 0)*10|floor/10) as $cc
  | "\($pg) GB physical, \($lg) GB logical (\($tot)× total: dedup \($dd)× · compress \($cc)×)"' <<<"$USAGE")"
eq "status: dedup/compress label math" "$sz" \
   "26.9 GB physical, 210 GB logical (7.8× total: dedup 3.3× · compress 2.3×)"

# --- status detailed: per-guest grouping + newest-first snapshot rows ---
det="$(jq -r '.archives|group_by(.vmid)[]|[.[0].vmid,length]|@tsv' <<<"$LIST" | sort)"
eq "detail: guest groups" "$(wc -l <<<"$det")" "2"
first="$(jq -r --arg v 108 '.archives[]|select(.vmid==$v)|[.modtime,.size_bytes,.snapshot]|@tsv' <<<"$LIST" | sort -r | head -1 | cut -f3)"
eq "detail: 108 newest snapshot id" "$first" "aaaa"

# --- menu_help renders and covers the key actions ---
help="$(printf '\n' | menu_help 2>&1)"
helpok=1
for want in "DR key" "Host backup" "Test-restore" "Restore" "Maintenance" "Tiers"; do
    grep -qF "$want" <<<"$help" || { helpok=0; bad "menu_help missing: $want"; }
done
(( helpok )) && ok "menu_help covers the key actions"

rm -f /tmp/pbo-pick.err
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
