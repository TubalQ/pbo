#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/menu.sh: unit tests for the interactive menu's new building blocks, the
# numbered pickers (_pick_index) and their formatters (_ago/_hsize), plus the jq
# pipelines menu_restore uses to turn `list --json` into a guest list and a
# per-guest snapshot list. Pure bash + jq, no restic repo and no real host.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start) are the
# machine's own files: point them into the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.creds" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
    PBO_PVE_CFS_DIR="$PWD/run-none/pve" PVE_STORAGE_CFG="$PWD/run-none/pve/storage.cfg"

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
[[ "$(_hsize 1200000000)" == "1.2GB" ]] && ok "_hsize: ~1.2GB" || bad "_hsize GB (got $(_hsize 1200000000))"

# --- _ago: relative age buckets (minutes / hours / days) ---
now=1000000000
eq "_ago: minutes"        "$(_ago $((now-600))   $now)" "10m ago"
eq "_ago: hours"          "$(_ago $((now-7200))  $now)" "2h ago"
eq "_ago: days"           "$(_ago $((now-172800)) $now)" "2d ago"
eq "_ago: future clamps"  "$(_ago $((now+600))   $now)" "0m ago"

# --- the jq pipelines menu_restore feeds the pickers ---
LIST='{"archives":[
  {"vmid":"202","archive":"vzdump-lxc-202-2026_01_15-05_00_00.tar","size_bytes":1200000000,"modtime":"2026-01-15T05:00:00Z","snapshot":"aaaa"},
  {"vmid":"202","archive":"vzdump-lxc-202-2026_01_13-05_00_00.tar","size_bytes":1100000000,"modtime":"2026-01-13T05:00:00Z","snapshot":"bbbb"},
  {"vmid":"201","archive":"vzdump-lxc-201-2026_01_15-04_00_00.tar","size_bytes":100000000,"modtime":"2026-01-15T04:00:00Z","snapshot":"cccc"}
]}'

# guest grouping: one row per vmid, sorted, with count + newest modtime
guests="$(jq -r '.archives | group_by(.vmid)[]
    | [ .[0].vmid, length, ([.[].modtime]|max) ] | @tsv' <<<"$LIST")"
eq "guest pipeline: rows" "$(wc -l <<<"$guests")" "2"
eq "guest pipeline: 201 has 1 snapshot" "$(awk -F'\t' '$1=="201"{print $2}' <<<"$guests")" "1"
eq "guest pipeline: 202 has 2 snapshots" "$(awk -F'\t' '$1=="202"{print $2}' <<<"$guests")" "2"
eq "guest pipeline: 202 newest modtime" "$(awk -F'\t' '$1=="202"{print $3}' <<<"$guests")" "2026-01-15T05:00:00Z"

# snapshot list for 202, newest first: first row must be the 01-15 timestamp
snaps="$(jq -r --arg v 202 '.archives[] | select(.vmid==$v)
    | [ (.archive|capture("(?<t>[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2})").t),
        .size_bytes, .modtime, .snapshot ] | @tsv' <<<"$LIST" | sort -rk3)"
eq "snapshot pipeline: newest-first ts" "$(head -1 <<<"$snaps" | cut -f1)" "2026_01_15-05_00_00"
eq "snapshot pipeline: oldest-last ts"  "$(tail -1 <<<"$snaps" | cut -f1)" "2026_01_13-05_00_00"

# --- status summary: dedup/compression label math ---
USAGE='{"physical_bytes":10000000000,"logical_bytes":80000000000,"uncompressed_bytes":25000000000,"compression_ratio":2.5}'
sz="$(jq -r '
  (.physical_bytes // 0) as $p | (.logical_bytes // 0) as $l | (.uncompressed_bytes // 0) as $u
  | ($p/1e9*10|floor/10) as $pg | ($l/1e9*10|floor/10) as $lg
  | (if $p>0 then ($l/$p*10|floor/10) else 0 end) as $tot
  | (if $u>0 then ($l/$u*10|floor/10) else 0 end) as $dd
  | ((.compression_ratio // 0)*10|floor/10) as $cc
  | "\($pg) GB physical, \($lg) GB logical (\($tot)× total: dedup \($dd)× · compress \($cc)×)"' <<<"$USAGE")"
eq "status: dedup/compress label math" "$sz" \
   "10 GB physical, 80 GB logical (8× total: dedup 3.2× · compress 2.5×)"

# --- status detailed: per-guest grouping + newest-first snapshot rows ---
det="$(jq -r '.archives|group_by(.vmid)[]|[.[0].vmid,length]|@tsv' <<<"$LIST" | sort)"
eq "detail: guest groups" "$(wc -l <<<"$det")" "2"
first="$(jq -r --arg v 202 '.archives[]|select(.vmid==$v)|[.modtime,.size_bytes,.snapshot]|@tsv' <<<"$LIST" | sort -r | head -1 | cut -f3)"
eq "detail: 202 newest snapshot id" "$first" "aaaa"

# --- detailed view: reasons -> policy letter code (d/w/m/y/L) ---
polcode() {
    jq -r '(.reasons//[]) as $r
        | [ (if any($r[];test("daily"))   then "d" else empty end),
            (if any($r[];test("weekly"))  then "w" else empty end),
            (if any($r[];test("monthly")) then "m" else empty end),
            (if any($r[];test("yearly"))  then "y" else empty end),
            (if any($r[];test("last"))    then "L" else empty end) ] | join("")' <<<"$1"
}
eq "polcode: daily+weekly+monthly" "$(polcode '{"reasons":["daily snapshot","weekly snapshot","monthly snapshot"]}')" "dwm"
eq "polcode: oldest monthly"       "$(polcode '{"reasons":["oldest monthly snapshot"]}')" "m"
eq "polcode: keep-last"            "$(polcode '{"reasons":["last snapshot"]}')" "L"
eq "polcode: empty reasons"        "$(polcode '{"reasons":[]}')" ""

# --- _pbo_sftp_command: assembles restic's sftp.command, pins host key when asked ---
eq "sftp cmd: accept-new when no known_hosts" \
   "$(_pbo_sftp_command user host.example 23 /root/.ssh/id_ed25519)" \
   "ssh user@host.example -p 23 -i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new -s sftp"
eq "sftp cmd: pinned when known_hosts given" \
   "$(_pbo_sftp_command user host.example 23 /root/.ssh/id_ed25519 /etc/pbo/known_hosts)" \
   "ssh user@host.example -p 23 -i /root/.ssh/id_ed25519 -o UserKnownHostsFile=/etc/pbo/known_hosts -o StrictHostKeyChecking=yes -s sftp"

# --- menu_help renders and covers the key actions ---
help="$(printf '\n' | menu_help 2>&1)"
helpok=1
for want in "DR key" "Host backup" "Test-restore" "Restore" "Maintenance" "Tiers"; do
    grep -qF "$want" <<<"$help" || { helpok=0; bad "menu_help missing: $want"; }
done
(( helpok )) && ok "menu_help covers the key actions"

# --- the wizard's Proxmox integration step (a fake pbo records what it is asked) ---
W="$PWD/run/menu"; rm -rf "$W"; mkdir -p "$W"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls"\n' "$W" > "$W/fakepbo"; chmod +x "$W/fakepbo"
# I <mode> <plugin path> <answers>: run the step with lib/integrate.sh + ownership.sh loaded
I() { : > "$W/calls"; printf '%b' "$3" | PBO_SELF_BIN="$W/fakepbo" PBO_INTEGRATION="$1" PBO_PVE_PLUGIN_PATH="$2" bash -c '
        source lib/ownership.sh; source lib/integrate.sh; source lib/menu.sh; _setup_integration_step; echo "mode=$PBO_INTEGRATION"' 2>&1; }
out="$(I standalone "$W/none.pm" '2\n')"
[[ "$out" == *"plugin is not installed"* && "$out" == *"./install.sh --integration both"* && "$out" == *"apt install pbo-pve-storage"* \
   && "$out" == *"mode=standalone" && ! -s "$W/calls" ]] && ok "wizard integration: no plugin → install hint, stays standalone" || bad "wizard no plugin: $out"
: > "$W/plugin.pm"
out="$(I standalone "$W/plugin.pm" '2\ny\n')"
[[ "$(cat "$W/calls")" == $'--dry-run integrate enable both\nintegrate enable both --yes' && "$out" == *"mode=both" ]] \
    && ok "wizard integration: both → dry run shown, then enable --yes" || bad "wizard both: $(cat "$W/calls") $out"
out="$(I standalone "$W/plugin.pm" '3\nn\n')"
[[ "$(cat "$W/calls")" == '--dry-run integrate enable integrated' && "$out" == *"mode=standalone" ]] \
    && ok "wizard integration: a no after the dry run changes nothing" || bad "wizard no: $(cat "$W/calls") $out"
out="$(I standalone "$W/plugin.pm" '\n')"
[[ ! -s "$W/calls" && "$out" == *"mode=standalone" ]] && ok "wizard integration: Enter keeps standalone (the default)" || bad "wizard default: $(cat "$W/calls")"
out="$(I both "$W/plugin.pm" '1\ny\n')"
[[ "$(cat "$W/calls")" == $'--dry-run integrate disable\nintegrate disable --yes' && "$out" == *"mode=standalone" ]] \
    && ok "wizard integration: both → standalone runs integrate disable" || bad "wizard disable: $(cat "$W/calls") $out"
out="$(I both "$W/plugin.pm" '\nn\n')"
[[ "$(cat "$W/calls")" == '--dry-run integrate enable both' && "$out" == *"both (current)"* ]] \
    && ok "wizard integration: the current mode is the default (re-running it converges)" || bad "wizard current default: $(cat "$W/calls") $out"

rm -f /tmp/pbo-pick.err
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
