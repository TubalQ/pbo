#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/menu.sh: unit tests for the interactive menu's building blocks, the
# numbered pickers (_pick_index) and their formatters (_ago/_hsize), the jq
# pipelines menu_restore uses to turn `list --json` into a guest list and a
# per-guest snapshot list, and the setup wizard (ADR 0009, "Wizard"): its
# checks and parsers, its cache step against a fake pbo, and `pbo setup` end
# to end with scripted answers (a copy of the entry point that stops on any
# path outside run-menu/, mocks for findmnt, ssh-keyscan, sftp, systemctl,
# pvesh, a fake restic). No real repo, no real host.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start) are the
# machine's own files: point them into the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.env" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
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
mkdir -p run; PICK_ERR="$PWD/run/menu-pick.err"

# --- _pick_index: valid choice echoes the index, list goes to stderr ---
idx="$(printf '2\n' | _pick_index "Pick" 1 alpha bravo charlie 2>"$PICK_ERR")"; rc=$?
eq "_pick_index: returns the chosen index" "$idx" "2"
[[ $rc == 0 ]] && ok "_pick_index: exit 0 on a valid choice" || bad "_pick_index exit ($rc)"
grep -q '\[1\] alpha' "$PICK_ERR" && grep -q '\[3\] charlie' "$PICK_ERR" \
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
  {"vmid":"8202","archive":"vzdump-lxc-8202-2026_01_15-05_00_00.tar","size_bytes":1200000000,"modtime":"2026-01-15T05:00:00Z","snapshot":"aaaa"},
  {"vmid":"8202","archive":"vzdump-lxc-8202-2026_01_13-05_00_00.tar","size_bytes":1100000000,"modtime":"2026-01-13T05:00:00Z","snapshot":"bbbb"},
  {"vmid":"8201","archive":"vzdump-lxc-8201-2026_01_15-04_00_00.tar","size_bytes":100000000,"modtime":"2026-01-15T04:00:00Z","snapshot":"cccc"}
]}'

# guest grouping: one row per vmid, sorted, with count + newest modtime
guests="$(jq -r '.archives | group_by(.vmid)[]
    | [ .[0].vmid, length, ([.[].modtime]|max) ] | @tsv' <<<"$LIST")"
eq "guest pipeline: rows" "$(wc -l <<<"$guests")" "2"
eq "guest pipeline: 8201 has 1 snapshot" "$(awk -F'\t' '$1=="8201"{print $2}' <<<"$guests")" "1"
eq "guest pipeline: 8202 has 2 snapshots" "$(awk -F'\t' '$1=="8202"{print $2}' <<<"$guests")" "2"
eq "guest pipeline: 8202 newest modtime" "$(awk -F'\t' '$1=="8202"{print $3}' <<<"$guests")" "2026-01-15T05:00:00Z"

# snapshot list for 8202, newest first: first row must be the 01-15 timestamp
snaps="$(jq -r --arg v 8202 '.archives[] | select(.vmid==$v)
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
first="$(jq -r --arg v 8202 '.archives[]|select(.vmid==$v)|[.modtime,.size_bytes,.snapshot]|@tsv' <<<"$LIST" | sort -r | head -1 | cut -f3)"
eq "detail: 8202 newest snapshot id" "$first" "aaaa"

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
printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls"\ncase " $* " in *" --dry-run "*) exit 0 ;; esac\nexit "${FAKE_FAIL:-0}"\n' "$W" > "$W/fakepbo"; chmod +x "$W/fakepbo"
# I <mode> <plugin path> <answers>: run the step with lib/integrate.sh + ownership.sh loaded
# (ISELF: the SELF_DIR pbo runs from, for the layout of its hints; IFAIL: the
# fake pbo's exit status for a real enable/disable)
I() { : > "$W/calls"; printf '%b' "$3" | SELF_DIR="${ISELF:-$PWD}" FAKE_FAIL="${IFAIL:-0}" PBO_SELF_BIN="$W/fakepbo" PBO_INTEGRATION="$1" PBO_PVE_PLUGIN_PATH="$2" bash -c '
        source lib/ownership.sh; source lib/integrate.sh; source lib/menu.sh; _setup_integration_step; echo "rc=$? mode=$PBO_INTEGRATION"' 2>&1; }
out="$(I standalone "$W/none.pm" '2\n')"
[[ "$out" == *"plugin is not installed"* && "$out" == *"$PWD/install.sh --integration both"* && "$out" != *"apt install"* \
   && "$out" == *"rc=69 mode=standalone" && ! -s "$W/calls" ]] && ok "wizard integration: no plugin (a checkout) → this tree's install.sh, stays standalone, the step fails (69)" || bad "wizard no plugin: $out"
out="$(ISELF=/opt/x/usr/lib/pbo I standalone "$W/none.pm" '3\n')"
[[ "$out" == *"apt install pbo-pve-storage"* && "$out" != *"install.sh --integration"* && "$out" == *"rc=69 mode=standalone" ]] \
    && ok "wizard integration: no plugin on the .deb layout (/usr/lib/pbo) → apt install pbo-pve-storage only" || bad "wizard no plugin deb: $out"
out="$(ISELF=/opt/x/usr/local/lib/pbo I standalone "$W/none.pm" '2\n')"
[[ "$out" == *"install.sh --integration both from the pbo source tree"* && "$out" != *"apt install"* ]] \
    && ok "wizard integration: no plugin on the install.sh layout (/usr/local/lib/pbo) → install.sh --integration only" || bad "wizard no plugin install.sh: $out"
: > "$W/plugin.pm"
out="$(I standalone "$W/plugin.pm" '2\ny\n')"
[[ "$(cat "$W/calls")" == $'--dry-run integrate enable both\nintegrate enable both --yes' && "$out" == *"rc=0 mode=both" ]] \
    && ok "wizard integration: both → dry run shown, then enable --yes" || bad "wizard both: $(cat "$W/calls") $out"
out="$(IFAIL=69 I standalone "$W/plugin.pm" '2\ny\n')"
[[ "$out" == *"'pbo integrate enable both' did not finish, still standalone"* && "$out" == *"rc=69 mode=standalone" ]] \
    && ok "wizard integration: an enable that fails fails the step (its exit status)" || bad "wizard enable fails: $out"
out="$(IFAIL=75 I both "$W/plugin.pm" '1\ny\n')"
[[ "$out" == *"'pbo integrate disable' did not finish, still both"* && "$out" == *"rc=75 mode=both" ]] \
    && ok "wizard integration: a disable that fails fails the step" || bad "wizard disable fails: $out"
out="$(I standalone "$W/plugin.pm" '')"; rc=$?
[[ "$out" == *'The input ended at the question "Mode"'* && "$out" != *"rc="* && ! -s "$W/calls" ]] \
    && ok "wizard integration: the end of the input at the mode question stops the wizard (no default taken, nothing run)" || bad "wizard integration eof mode: $out"
out="$(I standalone "$W/plugin.pm" '2\n')"
[[ "$out" == *'The input ended at the question "Apply this'* && "$out" != *"rc="* && "$(cat "$W/calls")" == '--dry-run integrate enable both' ]] \
    && ok "wizard integration: ... and at the question after the dry run: no enable" || bad "wizard integration eof apply: $(cat "$W/calls") $out"
out="$(I standalone "$W/plugin.pm" '3\nn\n')"
[[ "$(cat "$W/calls")" == '--dry-run integrate enable integrated' && "$out" == *"rc=0 mode=standalone" ]] \
    && ok "wizard integration: a no after the dry run changes nothing" || bad "wizard no: $(cat "$W/calls") $out"
out="$(I standalone "$W/plugin.pm" '\n')"
[[ ! -s "$W/calls" && "$out" == *"rc=0 mode=standalone" ]] && ok "wizard integration: Enter keeps standalone (the default)" || bad "wizard default: $(cat "$W/calls")"
out="$(I both "$W/plugin.pm" '1\ny\n')"
[[ "$(cat "$W/calls")" == $'--dry-run integrate disable\nintegrate disable --yes' && "$out" == *"mode=standalone" ]] \
    && ok "wizard integration: both → standalone runs integrate disable" || bad "wizard disable: $(cat "$W/calls") $out"
out="$(I both "$W/plugin.pm" '\nn\n')"
[[ "$(cat "$W/calls")" == '--dry-run integrate enable both' && "$out" == *"both (current)"* ]] \
    && ok "wizard integration: the current mode is the default (re-running it converges)" || bad "wizard current default: $(cat "$W/calls") $out"

# --- the setup wizard's building blocks (lib/menu.sh, sourced above) ------------------------
# shellcheck source=lib/config_schema.sh
source lib/config_schema.sh; _cs_load
fx="$PWD/run/menu-fx"; rm -rf "$fx"; mkdir -p "$fx/bin"

# _setup_sftp_parse: the wizard's defaults from the repo and its command, and
# the command it writes reads back as the parts it was built from
_setup_sftp_parse "sftp:pbo@backup.example:pbo" "$(_pbo_sftp_command pbo backup.example 2222 /k/id_ed25519 /k/known_hosts)"
eq "sftp parse: round trip of the wizard's command (pinned)" "$_SP_USER|$_SP_HOST|$_SP_PORT|$_SP_KEY|$_SP_KH|$_SP_PATH|$_SP_LABEL" \
   "pbo|backup.example|2222|/k/id_ed25519|/k/known_hosts|pbo|"
_setup_sftp_parse "sftp:u1@h.example:/srv/r" "$(_pbo_sftp_command u1 h.example 22 /k/id_rsa)"
eq "sftp parse: round trip (accept-new, absolute path)" "$_SP_USER|$_SP_HOST|$_SP_PORT|$_SP_KEY|$_SP_KH|$_SP_PATH" "u1|h.example|22|/k/id_rsa||/srv/r"
_setup_sftp_parse "sftp:boxlabel:pbo" "ssh uXXXXX-sub1@uXXXXX-sub1.your-storagebox.de -p 23 -i /k/id -o StrictHostKeyChecking=accept-new -s sftp"
eq "sftp parse: a 0.5 repo label: the command says where to connect" "$_SP_USER|$_SP_HOST|$_SP_PORT|$_SP_LABEL|$_SP_PATH" \
   "uXXXXX-sub1|uXXXXX-sub1.your-storagebox.de|23|boxlabel|pbo"
_setup_sftp_parse "sftp://alice@srv.example:2200//data/pbo" ""
eq "sftp parse: the URL form without a command" "$_SP_USER|$_SP_HOST|$_SP_PORT|$_SP_PATH" "alice|srv.example|2200|/data/pbo"
_setup_sftp_parse "sftp:x:pbo" "ssh -l bob -oPort=2022 -o IdentityFile=/k/k1 -o UserKnownHostsFile=/k/kh srv.example -s sftp"
eq "sftp parse: options before the destination, -l and -o forms" "$_SP_USER|$_SP_HOST|$_SP_PORT|$_SP_KEY|$_SP_KH" "bob|srv.example|2022|/k/k1|/k/kh"
_setup_sftp_parse "sftp:pbo@[2001:db8::5]:pbo" "ssh pbo@2001:db8::5 -p 2222 -i /k/id -o UserKnownHostsFile=/k/kh -o StrictHostKeyChecking=yes -s sftp"
eq "sftp parse: an IPv6 repo in brackets, a bare IPv6 destination (the port in -p)" "$_SP_USER|$_SP_HOST|$_SP_PORT|$_SP_PATH|$_SP_LABEL|${_SP_EXTRA[*]}" "pbo|2001:db8::5|2222|pbo||"
_setup_sftp_parse "sftp://pbo@[2001:db8::7]:2200/srv/pbo" "ssh -p 2200 pbo@[2001:db8::7] -s sftp"
eq "sftp parse: the URL form with an IPv6 host and a [v6] destination" "$_SP_USER|$_SP_HOST|$_SP_PORT|$_SP_PATH|$_SP_LABEL" "pbo|2001:db8::7|2200|srv/pbo|"
_setup_sftp_parse "sftp:pbo@[2001:db8::5:pbo" ""
eq "sftp parse: a bracket that does not close: no host or path is guessed" "$_SP_HOST|$_SP_PATH" "|"
_setup_sftp_parse "sftp:pbo@backup.example:pbo" "ssh pbo@backup.example -p 2222 -i /k/id -o ProxyJump=bastion.example -oServerAliveInterval=30 -C -J jump.example -o UserKnownHostsFile=/k/kh -o StrictHostKeyChecking=yes -s sftp"
eq "sftp parse: the options the wizard does not ask about are kept as words (_SP_EXTRA)" "$_SP_HOST|$_SP_PORT|$_SP_KH|${_SP_EXTRA[*]}" \
   "backup.example|2222|/k/kh|-o ProxyJump=bastion.example -o ServerAliveInterval=30 -C -J jump.example"
eq "sftp cmd: kept options go in before the remote command" "$(_pbo_sftp_command pbo backup.example 2222 /k/id /k/kh "${_SP_EXTRA[@]}")" \
   "ssh pbo@backup.example -p 2222 -i /k/id -o UserKnownHostsFile=/k/kh -o StrictHostKeyChecking=yes -o ProxyJump=bastion.example -o ServerAliveInterval=30 -C -J jump.example -s sftp"
_setup_sftp_parse "sftp:box:pbo" "ssh -F /k/ssh_config box -s sftp"
eq "sftp parse: -F with a host alias: the alias is the host, -F is kept" "$_SP_HOST|$_SP_PORT|$_SP_USER|${_SP_EXTRA[*]}" "box|||-F /k/ssh_config"
_setup_sftp_parse "sftp:pbo@backup.example:pbo" "$(_pbo_sftp_command pbo backup.example 2222 /k/id_ed25519 /k/known_hosts)"
eq "sftp parse: the wizard's own command has no extra options" "${#_SP_EXTRA[@]}" 0
hostok=1
for h in backup.example 192.0.2.10 2001:db8::5 '[2001:db8::5]' ::1; do _setup_chk_host "$h" >/dev/null || { hostok=0; bad "chk_host refuses $h"; }; done
for h in 'a b' 'x;y' '-x' '[2001' ''; do ! _setup_chk_host "$h" >/dev/null || { hostok=0; bad "chk_host takes '$h'"; }; done
(( hostok )) && ok "sftp: host names, IPv4 and IPv6 addresses (bare or in brackets) are taken, other strings refused"
eq "sftp: an IPv6 address is kept without its brackets" "$(_setup_unbracket '[2001:db8::5]')|$(_setup_unbracket backup.example)" "2001:db8::5|backup.example"

# _setup_sftp_needs_cmd: a port, a key ssh does not try, a pinned host key, or
# (nothing pinned) a host whose key ssh has not recorded need it
mkdir -p "$fx/h/.ssh"
printf 'known.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOkMPvH2qbRSg0iTs8SnP+zxek/d782eT11yYblwtzqQ\n' > "$fx/h/.ssh/known_hosts"
nc() { HOME="$fx/h" _setup_sftp_needs_cmd "$@"; }   # (its default keys are $fx/h/.ssh/id_*)
if command -v ssh-keygen >/dev/null 2>&1; then
    nc 22 "$fx/h/.ssh/id_ed25519" "" known.example && bad "needs cmd: port 22 + a default key + a recorded host key needs none" \
        || ok "sftp: port 22, a key ssh tries by itself and a host key ssh recorded: no RESTIC_SFTP_COMMAND"
fi
nc 22 "$fx/h/.ssh/id_ed25519" "" new.example && ok "sftp: nothing pinned and a host key ssh never saw: RESTIC_SFTP_COMMAND (accept-new; ssh's default asks, the timers have no terminal)" \
    || bad "needs cmd: unrecorded host key"
nc 23 "$fx/h/.ssh/id_ed25519" "" known.example && ok "sftp: another port needs RESTIC_SFTP_COMMAND" || bad "needs cmd: port"
nc 22 /k/other "" known.example && ok "sftp: a key ssh does not try needs RESTIC_SFTP_COMMAND" || bad "needs cmd: key"
nc 22 "$fx/h/.ssh/id_rsa" /k/kh known.example && ok "sftp: a pinned host key file needs RESTIC_SFTP_COMMAND" || bad "needs cmd: kh"
_setup_is_storagebox uXXXXX-sub1.your-storagebox.de && ! _setup_is_storagebox backup.example \
    && ok "sftp: a Storage Box is recognised by its domain, another host is not" || bad "storagebox detection"

# _setup_fs_rows: disk filesystems only, read-write, no guest volume, one row
# per filesystem (a ZFS pool's datasets, a bind mount), the most free first
cat > "$fx/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
# mock findmnt: $MOCK_FINDMNT holds the mount table, lines as `findmnt -rn -b -o
# TARGET,FSTYPE,SIZE,AVAIL,OPTIONS,SOURCE` writes them. -t TYPES keeps those
# types; -o TARGET prints the first column only. A listing with SIZE or AVAIL
# but no -t is refused (exit 9, "UNFILTERED" in $MOCK_LOG): the real one would
# statfs every mount for it, a dead hard NFS mount too, and hang.
[ -n "${MOCK_LOG:-}" ] && echo "findmnt $*" >> "$MOCK_LOG"
types='' cols=''
while [ $# -gt 0 ]; do case "$1" in -t) types="$2"; shift 2 ;; -o) cols="$2"; shift 2 ;; *) shift ;; esac; done
case ",$cols," in *,SIZE,*|*,AVAIL,*)
    [ -n "$types" ] || { [ -n "${MOCK_LOG:-}" ] && echo "findmnt UNFILTERED" >> "$MOCK_LOG"; exit 9; } ;; esac
awk -v t=",$types," -v c="$cols" '(t == ",," || index(t, "," $2 ",")) { if (c == "TARGET") print $1; else print }' "${MOCK_FINDMNT:-/dev/null}"
EOF
chmod 755 "$fx/bin/findmnt"
mkfs_table() {   # mkfs_table BASE: the mount table of the tests, BASE standing in for the data mounts
    printf '%s\n' "/ ext4 20000000000 5000000000 rw,relatime /dev/sda1" \
        "$1/fs/big xfs 4000000000000 3000000000000 rw,relatime /dev/sdb1" \
        "$1/fs/big/bind xfs 4000000000000 3000000000000 rw,relatime /dev/sdb1[/x]" \
        "/run tmpfs 1000000 1000000 rw,nosuid tmpfs" \
        "$1/fs/ro ext4 9000000000000 9000000000000 ro,relatime /dev/sdc1" \
        "$1/fs/tank zfs 100000000000 80000000000 rw,xattr tank" \
        "$1/fs/tank/subvol-101-disk-0 zfs 8000000000 80000000000 rw,xattr tank/subvol-101-disk-0" \
        "$1/fs/tank/data zfs 200000000000 80000000000 rw,xattr tank/data" \
        "$1/fs/with\\x20blank ext4 1000000000 900000000 rw /dev/sdd1" \
        "$1/fs/nfs nfs4 9900000000000 9900000000000 rw,relatime 192.0.2.20:/export"
}
mkfs_table /b > "$fx/mounts"
rows="$(PATH="$fx/bin:$PATH" MOCK_FINDMNT="$fx/mounts" MOCK_LOG="$fx/fslog" _setup_fs_rows)"
eq "fs rows: disk filesystems, read-write, one per filesystem, the most free first" "$(cut -f1,2,4 <<<"$rows" | tr '\t\n' ' |')" \
   "/b/fs/big xfs 3000000000000|/b/fs/tank zfs 80000000000|/ ext4 5000000000|/b/fs/with blank ext4 900000000|"
eq "fs suggest: <mount>/pbo-cache on the one with the most free space" \
   "$(PATH="$fx/bin:$PATH" MOCK_FINDMNT="$fx/mounts" _setup_cache_suggest "$rows" /var/cache/pbo)" "/b/fs/big/pbo-cache"
eq "fs suggest: the current CACHE_DIR when it is on that filesystem already" \
   "$(PATH="$fx/bin:$PATH" MOCK_FINDMNT="$fx/mounts" _setup_cache_suggest "$rows" /b/fs/big/backups)" "/b/fs/big/backups"
eq "fs suggest: the schema default when the root filesystem has the most" \
   "$(PATH="$fx/bin:$PATH" MOCK_FINDMNT="$fx/mounts" _setup_cache_suggest "$(printf '/\text4\t9\t9')" "")" "/var/cache/pbo"
printf '%s\n' "/ ext4 600000000000 500000000000 rw /dev/sda1" "/var ext4 20000000000 15000000000 rw /dev/sda2" > "$fx/mounts-var"
eq "fs suggest: the root filesystem has the most, the default's /var is a smaller mount of its own: /pbo-cache" \
   "$(PATH="$fx/bin:$PATH" MOCK_FINDMNT="$fx/mounts-var" _setup_cache_suggest "$(PATH="$fx/bin:$PATH" MOCK_FINDMNT="$fx/mounts-var" _setup_fs_rows)" "")" "/pbo-cache"
# a hard NFS mount whose server is gone hangs a statfs for ever: the tools
# filter by type themselves, before they size anything
eq "fs mount of: a path on a network mount maps to that mount (a listing without sizes)" \
   "$(PATH="$fx/bin:$PATH" MOCK_FINDMNT="$fx/mounts" MOCK_LOG="$fx/fslog" _setup_mount_of /b/fs/nfs/pbo)" "/b/fs/nfs"
! grep -q UNFILTERED "$fx/fslog" && grep -q -- '-t ext2,ext3,ext4,xfs,btrfs,zfs,f2fs,jfs,reiserfs,bcachefs ' "$fx/fslog" && [[ "$rows" != *nfs* ]] \
    && ok "fs rows: findmnt lists the disk filesystem types only (-t): a network mount is never sized" || bad "fs filter: $(cat "$fx/fslog") $rows"
mkdir -p "$fx/dfbin"; ln -sf "$(command -v awk)" "$fx/dfbin/awk"
printf '%s\n' "#!$BASH" '# mock df: sizes only with -l and -t (GNU df then skips the other mounts before statfs)' \
    'l=0 t=0; for a; do case "$a" in -l) l=1 ;; -t) t=1 ;; esac; done' \
    '[[ $l == 1 && $t == 1 ]] || { echo UNFILTERED >&2; exit 9; }' \
    'echo "Filesystem Type 1-blocks Used Available Capacity Mounted"; echo "/dev/sdb1 xfs 4000 1000 3000 25% /b/fs/big"' > "$fx/dfbin/df"
chmod 755 "$fx/dfbin/df"
eq "fs raw: without findmnt, df -l with one -t per disk type" "$(PATH="$fx/dfbin" _setup_fs_raw 2>&1)" "/b/fs/big xfs 4000 3000 rw /dev/sdb1"
# the root filesystem warning: below 1.5 x the largest guest only
_setup_root_small 20000000000 16000000000 && ok "cache: a 20 GB root filesystem is too small for a 16 GB guest" || bad "root small: 20/16"
! _setup_root_small 20000000000 13000000000 && ! _setup_root_small 20000000000 0 && ! _setup_root_small 20000000000 "" && ! _setup_root_small "" 16000000000 \
    && ok "cache: no root warning at 1.5 x and above, without a guest, or without the sizes" || bad "root small: quiet cases"

# _setup_ask_key: a number or an enum value is asked again until the schema takes it
out="$(printf '%s\n' abc 0 -3 4 | { _setup_ask_key KEEP_LOCAL "keep" 2; echo "rc=$? v=$_SV"; })"
[[ "$(grep -c 'try again' <<<"$out")" == 3 && "$out" == *"rc=0 v=4"* && "$out" == *"KEEP_LOCAL='abc' is not a whole number"* && "$out" == *"KEEP_LOCAL=0 is below the minimum 1"* ]] \
    && ok "wizard: an invalid number is asked again (three refusals, then 4)" || bad "ask_key int: $out"
out="$(printf '%s\n' fast batch | { _setup_ask_key BACKUP_MODE "mode" stream; echo "rc=$? v=$_SV"; })"
[[ "$out" == *"BACKUP_MODE='fast' is not stream|batch"* && "$out" == *"rc=0 v=batch"* ]] && ok "wizard: an enum value outside the schema is asked again" || bad "ask_key enum: $out"
out="$(printf '\n' | { _setup_ask_key KEEP_LOCAL "keep" 5; echo "rc=$? v=$_SV"; })"
[[ "$out" == *"rc=0 v=5"* ]] && ok "wizard: Enter keeps the default" || bad "ask_key default: $out"
out="$(printf '' | { _setup_ask_key KEEP_LOCAL "keep" 5; echo "rc=$? v=$_SV"; })"; rc=$?
[[ $rc == 64 && "$out" == *'The input ended at the question "keep"'* && "$out" != *"v=5"* ]] \
    && ok "wizard: the end of the input is no Enter: the default is not taken, the wizard stops (64)" || bad "ask_key eof default: rc=$rc $out"
out="$(printf 'abc\n' | { _setup_ask_key KEEP_LOCAL "keep" xyz; echo "rc=$?"; })"; rc=$?
[[ $rc == 64 && "$out" == *"try again"* && "$out" == *"The input ended"* && "$out" != *"rc="* ]] \
    && ok "wizard: the end of the input on an invalid answer stops the wizard (no endless loop)" || bad "ask_key eof: rc=$rc $out"
out="$(printf '7' | { _setup_ask_key KEEP_LOCAL "keep" 5; echo "rc=$? v=$_SV"; _setup_yn "next" y; echo "WENT-ON"; })"; rc=$?
[[ "$out" == *"rc=0 v=7"* && "$out" == *'The input ended at the question "next (y/n)"'* && "$out" != *WENT-ON* ]] \
    && ok "wizard: a last answer without a newline is taken; the question after it stops" || bad "ask partial line: rc=$rc $out"
for q in '_setup_yn "q" y' '_setup_pick "q" 1 a b' '_setup_askpw "q"' '_setup_ask_keep "q" cur _setup_chk_set'; do
    out="$(printf '' | { eval "$q"; echo "went on"; })"; rc=$?
    [[ $rc == 64 && "$out" == *"The input ended"* && "$out" != *"went on"* ]] || { bad "wizard eof: $q went on (rc=$rc): $out"; continue; }
done
ok "wizard: every kind of question (yes/no, a choice, a secret, a kept secret) stops at the end of the input"

# --- the cache step's calls (a fake pbo records what it is asked) -------------------------
printf '%s\n' '#!/usr/bin/env bash' "echo \"\$*\" >> \"$fx/calls\"" \
    'case " $* " in *" --dry-run "*) [[ " $* " == *" --fix-parents "* ]] && { echo "plan: ok"; exit 0; }' \
    '    [[ -n "${FAKE_PARENTS:-}" ]] && { echo "    fail  /x does not let uid 100000 through (or add --fix-parents)"; exit 69; }; echo "plan: ok"; exit 0 ;; esac' \
    'exit 0' > "$fx/fakepbo"; chmod 755 "$fx/fakepbo"
CS() {   # CS <current> <default> <answers>: _setup_cache_dir with the fake pbo; output in $out
    : > "$fx/calls"
    out="$(printf '%b' "$3" | PBO_SELF_BIN="$fx/fakepbo" bash -c 'source lib/menu.sh; _setup_cache_dir "$1" "$2"; echo "fp=$SETUP_FIX_PARENTS"' _ "$1" "$2" 2>&1)"
}
CS "$fx/old" "$fx/old" '\n'
[[ ! -s "$fx/calls" && "$out" == *"CACHE_DIR stays $fx/old"* ]] \
    && ok "cache step: the same directory writes nothing (no pbo call: a re-run never pins a default)" || bad "cache same: $(cat "$fx/calls") $out"
CS "$fx/old" "$fx/old" "$fx/new\n\n"
eq "cache step: another directory shows the dry run, then config set on a yes" "$(paste -sd'|' "$fx/calls")" \
   "--dry-run config set CACHE_DIR $fx/new --yes|config set CACHE_DIR $fx/new --yes|--json config list --all"
CS "$fx/old" "$fx/old" "$fx/new\nn\n"
[[ "$(cat "$fx/calls")" == "--dry-run config set CACHE_DIR $fx/new --yes" && "$out" == *"CACHE_DIR stays $fx/old"* ]] \
    && ok "cache step: a no after the dry run changes nothing" || bad "cache no: $(cat "$fx/calls") $out"
out="$(: > "$fx/calls"; printf '%b' "$fx/new\ny\n\n" | FAKE_PARENTS=1 PBO_SELF_BIN="$fx/fakepbo" bash -c 'source lib/menu.sh; _setup_cache_dir "$1" "$1"; echo "fp=$SETUP_FIX_PARENTS"' _ "$fx/old" 2>&1)"
eq "cache step: a CT that cannot pass offers --fix-parents: the dry run again with it, then the move with it" "$(paste -sd'|' "$fx/calls")" \
   "--dry-run config set CACHE_DIR $fx/new --yes|--dry-run config set CACHE_DIR $fx/new --yes --fix-parents|config set CACHE_DIR $fx/new --yes --fix-parents|--json config list --all"
[[ "$out" == *"fp=1"* ]] && ok "cache step: --fix-parents is remembered for doctor --fix" || bad "cache fp: $out"
out="$(: > "$fx/calls"; printf '%b' "$fx/new\ny\nn\n" | FAKE_PARENTS=1 PBO_SELF_BIN="$fx/fakepbo" bash -c 'source lib/menu.sh; _setup_cache_dir "$1" "$1"; echo "fp=$SETUP_FIX_PARENTS"' _ "$fx/old" 2>&1)"
[[ "$(paste -sd'|' "$fx/calls")" == "--dry-run config set CACHE_DIR $fx/new --yes|--dry-run config set CACHE_DIR $fx/new --yes --fix-parents" \
   && "$out" == *"CACHE_DIR stays $fx/old"* && "$out" == *"fp=0"* ]] \
    && ok "cache step: --fix-parents agreed to for a move then declined is not handed to doctor (the kept CACHE_DIR's parents)" || bad "cache fp declined: $(cat "$fx/calls") $out"

# --- the wizard, end to end -------------------------------------------------------------------
# pbo runs as a copy of the entry point that sources tests/fixtures/run_dir_guard.sh:
# it stops (99) before any command when a path it resolved (config, directories,
# PVE paths, the systemd directory, and here PBO_KNOWN_HOSTS and
# RESTIC_REST_PASSWORD_FILE) lies outside run-menu/, and before any file the
# wizard writes there (the config, a new CACHE_DIR, the DR key, a password
# file, RESTIC_ENV_FILE, known_hosts, a key pair). ssh-keyscan, sftp, curl, qm,
# findmnt, systemctl and pvesh are mocks, restic a fake; HOME is in the run
# directory too (the default key path).
wr="$PWD/run-menu"; rm -rf "$wr"
mkdir -p "$wr"/{bin,cache,state,log,lock,sysd,units,tree,pve,lxc,qemu,tmp,none,mnt,home,keys,fs/big}
for m in systemctl pvesh pvesm pct qm vzdump dpkg-query pveum; do install -m 0755 "tests/mocks/$m" "$wr/bin/"; done
install -m 0755 "$fx/bin/findmnt" "$wr/bin/"
printf '%s\n' '#!/usr/bin/env bash' '# mock ssh-keyscan: one host key for the host (and port) asked' \
    'p=22; while [ $# -gt 1 ]; do case "$1" in -p) p="$2"; shift 2 ;; *) shift ;; esac; done' \
    'h="$1"; [ "$p" = 22 ] || h="[$1]:$p"' \
    'echo "$h ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOkMPvH2qbRSg0iTs8SnP+zxek/d782eT11yYblwtzqQ"' > "$wr/bin/ssh-keyscan"
printf '%s\n' '#!/usr/bin/env bash' '# mock sftp: the login works (MOCK_SFTP_RC)' '[ -n "${MOCK_LOG:-}" ] && echo "sftp $*" >> "$MOCK_LOG"' \
    'cat >/dev/null; exit "${MOCK_SFTP_RC:-0}"' > "$wr/bin/sftp"
printf '%s\n' '#!/usr/bin/env bash' '# mock curl: no network' '[ -n "${MOCK_LOG:-}" ] && echo "curl $*" >> "$MOCK_LOG"' 'exit 7' > "$wr/bin/curl"
# the fake restic: a repo is a directory below FAKE_RESTIC_DIR named after
# the repo string, made by init with the key it was given; `cat config` exits
# 10 without one, 12 with another key (restic >= 0.17), and 1 with restic's
# message for a repo string that contains FAKE_RESTIC_DOWN (unreachable), or
# restic 0.14-0.16's 'permission denied' for one that contains
# FAKE_RESTIC_DENY (an NFS export with root_squash). FAKE_RESTIC_INIT_RC: init
# fails with that status; FAKE_RESTIC_SNAPS: the file `snapshots` prints
# (else none)
cat > "$wr/bin/restic-fake" <<'EOF'
#!/usr/bin/env bash
for a; do case "$a" in version) echo "restic 0.18.0 compiled with go1.24 on linux/amd64"; exit 0 ;; esac; done
repo=''; for ((i = 1; i < $#; i++)); do [[ "${!i}" == -r ]] && { j=$((i + 1)); repo="${!j}"; }; done
[[ -n "${FAKE_RESTIC_DOWN:-}" && "$repo" == *"$FAKE_RESTIC_DOWN"* ]] && { echo "Fatal: unable to open repository at $repo: connection refused" >&2; exit 1; }
[[ -n "${FAKE_RESTIC_DENY:-}" && "$repo" == *"$FAKE_RESTIC_DENY"* ]] && { printf 'Fatal: unable to open config file: Stat: stat %s/config: permission denied\nIs there a repository at the following location?\n%s\n' "$repo" "$repo" >&2; exit 1; }
d="${FAKE_RESTIC_DIR:?}/$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '_')"
key="$(cat -- "${RESTIC_PASSWORD_FILE:-/dev/null}" 2>/dev/null)"
case " $* " in
    *" init "*) [[ ! -e "$d/config" ]] || { echo "Fatal: config file already exists" >&2; exit 1; }
               [[ -z "${FAKE_RESTIC_INIT_RC:-}" ]] || { echo "Fatal: create repository at $repo failed: permission denied" >&2; exit "$FAKE_RESTIC_INIT_RC"; }
               mkdir -p "$d" && printf '%s' "$key" > "$d/key" && : > "$d/config"; exit ;;
    *" cat config "*) [[ -e "$d/config" ]] || { echo "Fatal: repository does not exist: unable to open config file" >&2; exit 10; }
               [[ "$key" == "$(cat "$d/key")" ]] || { echo "Fatal: wrong password or no key found" >&2; exit 12; }
               echo '{"version":2}' ;;
    *" snapshots "*) if [[ -n "${FAKE_RESTIC_SNAPS:-}" ]]; then cat -- "$FAKE_RESTIC_SNAPS"; else echo "[]"; fi ;;
esac
exit 0
EOF
chmod 755 "$wr/bin/ssh-keyscan" "$wr/bin/sftp" "$wr/bin/curl" "$wr/bin/restic-fake"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOkMPvH2qbRSg0iTs8SnP+zxek/d782eT11yYblwtzqQ pbo@test\n' > "$wr/keys/id_ed25519.pub"
printf 'not a real key\n' > "$wr/keys/id_ed25519"; chmod 600 "$wr/keys/id_ed25519"
printf '{"nodename":"pve1","version":3,"cluster":{"name":"lab","version":1,"nodes":1,"quorate":1},"nodelist":{"pve1":{"id":1,"online":1,"ip":"192.0.2.11"}}}\n' > "$wr/pve/.members"
printf '[{"vmid":101,"name":"web","type":"lxc","node":"pve1","status":"running","maxdisk":16000000000}]\n' > "$wr/resources.json"
mkfs_table "$wr" > "$wr/mounts"
{ sed '$d' pbo; printf '%s\n' 'source "$SELF_DIR/../../tests/fixtures/run_dir_guard.sh"'; tail -n 1 pbo; } > "$wr/tree/pbo"
chmod 755 "$wr/tree/pbo"; ln -s "$PWD/lib" "$wr/tree/lib"
wbin="$wr/tree/pbo"
cfgw() {   # cfgw [--no-kh] <extra lines...>: the wizard's config, every path in $wr (CFGW_CACHE=none: no CACHE_DIR line)
    local kh=1; [[ "${1:-}" == --no-kh ]] && { kh=0; shift; }
    { [[ "${CFGW_CACHE:-}" == none ]] || printf 'CACHE_DIR=%s\n' "${CFGW_CACHE:-$wr/cache}"
      printf '%s\n' "LOG_DIR=$wr/log" "STATE_DIR=$wr/state" "LOCK_DIR=$wr/lock" \
        "RESTIC_PASSWORD_FILE=$wr/pass" "RESTIC_CACHE_DIR=$wr/rcache" "RESTIC_BIN=$wr/bin/restic-fake" \
        "RESTIC_ENV_FILE=$wr/restic.env" "NTFY_CREDS_FILE=$wr/none/ntfy.env" "NOTIFY_PVE=false" \
        "PBO_PVE_LXC_DIR=$wr/lxc" "PBO_PVE_QEMU_DIR=$wr/qemu" "PBO_PVE_CFS_DIR=$wr/pve" \
        "PVE_STORAGE_CFG=$wr/storage.cfg" "PBO_PVE_STORAGE_CFG=$wr/storage.cfg" "VZDUMP_CONF=$wr/vzdump.conf" \
        "VZDUMP_LOCK=$wr/vzdump.lock" "PBO_CATALOG=$wr/state/catalog/index.json" "PVE_CATALOG_MOUNT_DIR=$wr/mnt/restic" \
        "PBO_PERMS_PARENTS_TOP=$wr" "PBO_PERMS_CONFIG_DIR=$wr" "PBO_SYSTEMD_DIR=$wr/units"
      (( kh )) && printf 'PBO_KNOWN_HOSTS=%s\n' "$wr/known_hosts"
      printf '%s\n' "$@"; } > "$wr/config"
    chmod 600 "$wr/config"
    # a fresh start for each scenario: no journal of an earlier cache move
    rm -f "$wr/state"/cache-move*
}
# the environment of every run of the copy of pbo: every path in $wr; WQM: the
# VMs `qm` knows (their configs in $wr/qemu), WSFTP_RC: the sftp login's exit
# status, WSHARED: a cluster-shared config file, WDOWN/WDENY/WINITRC/WSNAPS:
# the fake restic's FAKE_RESTIC_* (above). CACHE_DIR's schema default is
# $wr/dcache, so that a config without a CACHE_DIR line stays in the run
# directory too.
wenv() {
    W_ENV=(PATH="$wr/bin:$PATH" HOME="$wr/home" TMPDIR="$wr/tmp" PBO_CONFIG="$wr/config"
        MOCK_LOG="$wr/calls" TEST_RUN="$wr" TEST_GUARD_KEYS="PBO_KNOWN_HOSTS RESTIC_REST_PASSWORD_FILE" MOCK_SYSTEMCTL_DIR="$wr/sysd"
        MOCK_SYSTEMCTL_ENABLED="" MOCK_PVESH_JSON="$wr/resources.json" MOCK_FINDMNT="$wr/mounts" MOCK_CONF_DIR="$wr/lxc"
        MOCK_QM_VMIDS="${WQM-}" MOCK_QM_CONF_DIR="$wr/qemu" MOCK_SFTP_RC="${WSFTP_RC:-0}"
        TEST_GUARD_SHARED="${WSHARED-}" TEST_GUARD_CACHE_DEFAULT="$wr/dcache"
        PBO_PVE_PLUGIN_PATH="$wr/none/PboPlugin.pm" PBO_PVE_TEMPLATE_DIR="$wr/none/templates"
        FAKE_RESTIC_DIR="$wr/frepos" FAKE_RESTIC_DOWN="${WDOWN-}" FAKE_RESTIC_DENY="${WDENY-}"
        FAKE_RESTIC_INIT_RC="${WINITRC-}" FAKE_RESTIC_SNAPS="${WSNAPS-}")
}
# WIZ <answer>...: pbo setup with the answers on stdin, one per line ("" is
# Enter), then Enter for every question left (the wizard stops at the end of
# the input: 64); output in $out, exit status in $rc
WIZ() { wenv; out="$({ printf '%s\n' "$@"; yes '' | head -n 200; } | env -u PBO_SELF_BIN "${W_ENV[@]}" "$wbin" setup 2>&1)"; rc=$?; }
# WIZE <answer>...: the answers and nothing after them: the input ends after the last one
WIZE() { wenv; out="$(printf '%s\n' "$@" | env -u PBO_SELF_BIN "${W_ENV[@]}" "$wbin" setup 2>&1)"; rc=$?; }
WIZ0() { wenv; out="$(yes '' | head -n 200 | env -u PBO_SELF_BIN "${W_ENV[@]}" "$wbin" "$@" setup 2>&1)"; rc=$?; }   # WIZ0 [global flags]: Enter at every question
effw() { wenv; env -u PBO_SELF_BIN "${W_ENV[@]}" "$wbin" config get "$1" </dev/null 2>&1; }   # KEY's effective value, as pbo reads every file
rdw() { env -i bash -c 'source "$1" >/dev/null 2>&1; printf %s "${!2-}"' _ "${2:-$wr/config}" "$1"; }   # KEY as bash reads the config
noguard() { [[ "$out" != *run_dir_guard* ]]; }
vmconf() { printf 'name: vm8001\n'; local d i=0; for d; do printf 'scsi%s: local-lvm:vm-8001-disk-%s,size=%sG\n' "$i" "$i" "$d"; i=$((i+1)); done; }   # vmconf SIZE_G...
KH0='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOkMPvH2qbRSg0iTs8SnP+zxek/d782eT11yYblwtzqQ'

# the harness: a config that leaves a path the wizard writes at the host's default stops pbo first
cfgw --no-kh
WIZ0
[[ $rc == 99 && "$out" == *"PBO_KNOWN_HOSTS="*"is outside $wr"* ]] \
    && ok "wizard harness: PBO_KNOWN_HOSTS at the host's default stops pbo (99) before the wizard runs" || bad "wizard guard: rc=$rc $out"

# a first setup: an SFTP server on another port with its own key. The node has
# a VM with two 8 GB disks (16 GB to dump, on a 20 GB root filesystem). The
# config is 0644 before it: only doctor --fix, the last step, makes it 0600
# (the writer keeps a file's mode)
cfgw; : > "$wr/calls"; chmod 644 "$wr/config"
WQM=8001; vmconf 8 8 > "$wr/qemu/8001.conf"
WIZ "" "$wr/fs/big/pbo-cache" "" \
    1 backup.example 2222 pbo "$wr/keys/id_ed25519" "" "" \
    "" "" \
    y abc 0 3 "" "" x 12 "" \
    "" "" "" \
    y nightly "*-*-* 03:30:00" "" "" "" \
    y n n n
noguard && ok "wizard: a first setup writes nothing outside the run directory (the guard never stopped it)" || bad "wizard guard hit: $out"
[[ "$out" == *"Local filesystems, the most free space first"* && "$out" == *"$wr/fs/big "* && "$out" == *"Suggestion: $wr/fs/big/pbo-cache"* ]] \
    && [[ "$out" != *"$wr/fs/nfs"* ]] && ! grep -q 'findmnt UNFILTERED' "$wr/calls" \
    && ok "wizard cache: the local filesystems are listed (no network mount, none sized) and the one with the most free space suggested" || bad "wizard fs list: $(grep findmnt "$wr/calls") $out"
[[ "$out" == *"WARN the root filesystem"*"smaller than 1.5 x the largest guest"* ]] \
    && ok "wizard cache: a root filesystem smaller than 1.5 x the largest guest (every disk of a VM) is warned about" || bad "wizard root warn: $out"
[[ "$(rdw CACHE_DIR)" == "$wr/fs/big/pbo-cache" && -d "$wr/fs/big/pbo-cache" && -z "$(rdw RESTIC_CACHE_REPO)" ]] && ! grep -q '^RESTIC_CACHE_REPO=' "$wr/config" \
    && [[ "$out" == *"dry run, nothing changed yet"* && "$out" == *"would be created"* ]] \
    && ok "wizard cache: a new directory is set through config set CACHE_DIR after its dry run; RESTIC_CACHE_REPO is not pinned" \
    || bad "wizard cache: CACHE_DIR=$(rdw CACHE_DIR) $(grep CACHE "$wr/config") $out"
eq "wizard sftp: repo sftp:<user>@<host>:<path>" "$(rdw RESTIC_OFFSITE_REPO)" "sftp:pbo@backup.example:pbo"
eq "wizard sftp: RESTIC_SFTP_COMMAND with the port, the key and the pinned host key" "$(rdw RESTIC_SFTP_COMMAND)" \
   "ssh pbo@backup.example -p 2222 -i $wr/keys/id_ed25519 -o UserKnownHostsFile=$wr/known_hosts -o StrictHostKeyChecking=yes -s sftp"
grep -q '^\[backup.example\]:2222 ssh-ed25519 ' "$wr/known_hosts" && [[ "$(stat -c %a "$wr/known_hosts")" == 644 ]] \
    && ok "wizard sftp: the host key is pinned in PBO_KNOWN_HOSTS" || bad "wizard known_hosts: $(cat "$wr/known_hosts" 2>&1)"
[[ "$out" != *"Does the Storage Box take automatic snapshots"* && "$out" != *"A Storage Box:"* && -z "$(rdw STORAGE_BOX_SNAPSHOTS_CONFIRMED)" ]] \
    && ok "wizard sftp: no Storage Box question for another SFTP server" || bad "wizard sb: $out"
[[ -s "$wr/pass" && "$(stat -c %a "$wr/pass")" == 600 ]] && ok "wizard: a new DR key is written 0600" || bad "wizard pass: $(stat -c %a "$wr/pass" 2>&1)"
[[ "$(rdw KEEP_LOCAL)" == 3 && "$(rdw KEEP_OFFSITE_MONTHLY)" == 12 && -z "$(rdw KEEP_OFFSITE_DAILY)" && "$(grep -c 'try again' <<<"$out")" -ge 4 ]] \
    && ok "wizard retention: invalid numbers are asked again; a kept default is not written" || bad "wizard retention: $(grep KEEP "$wr/config") $out"
[[ "$(rdw SCHEDULE_BACKUP)" == "*-*-* 03:30:00" && -z "$(rdw SCHEDULE_PRUNE)" ]] && grep -q '^OnCalendar=\*-\*-\* 03:30:00$' "$wr/units/pbo.timer.d/schedule.conf" \
    && [[ ! -e "$wr/units/pbo-prune.timer.d/schedule.conf" && "$out" == *"SCHEDULE_BACKUP='nightly' is not a systemd calendar expression"* ]] \
    && ok "wizard schedule: an invalid calendar is asked again; the new one is written with its drop-in (the writer's hook)" \
    || bad "wizard schedule: $(grep SCHEDULE "$wr/config"); $(cat "$wr/units/pbo.timer.d/schedule.conf" 2>&1) $out"
grep -qx 'systemctl enable --now pbo.timer' "$wr/calls" && ! grep -q 'enable --now pbo-prune.timer' "$wr/calls" \
    && [[ "$out" == *"Enable"*"pbo.timer"* || "$out" == *"pbo.timer enabled"* ]] \
    && ok "wizard timers: the timers asked for are enabled, the others are not" || bad "wizard timers: $(grep enable "$wr/calls")"
grep -q 'audit: config set file=.*RESTIC_OFFSITE_REPO=' "$wr/log/pbo.log" && grep -q 'RESTIC_SFTP_COMMAND=<secret>' "$wr/log/pbo.log" \
    && ok "wizard: its config changes are audit-logged (the secret masked)" || bad "wizard audit: $(grep -c audit "$wr/log/pbo.log" 2>&1)"
# what only doctor --fix does: the config 0644 -> 0600, its FIXED line, the audit record
[[ "$out" == *"Health check (pbo doctor --fix)"* ]] \
    && [[ "$(stat -c %a "$wr/config")" == 600 && "$out" == *"FIXED"*"$wr/config"* ]] && grep -q "perms fix $wr/config mode 0644->0600" "$wr/log/pbo.log" \
    && ok "wizard: the last step runs pbo doctor --fix (the config made 0600) and shows its report" \
    || bad "wizard end: rc=$rc mode=$(stat -c %a "$wr/config") $(grep 'perms fix' "$wr/log/pbo.log") $out"
# a first setup: no guest has a snapshot yet, so doctor finds problems: the
# wizard exits with doctor's status and says so instead of "Setup complete"
[[ $rc == 69 && "$out" != *"Setup complete"* && "$out" == *"not everything worked"* && "$out" == *"the health check: pbo doctor found problems (exit 69"* \
   && "$out" == *"a guest with no snapshot yet"* ]] && grep -qE 'FAIL  guest [0-9]+ has NO snapshot' <<<"$out" \
   && [[ "$(sed -n '/not everything worked/,/Fix that/p' <<<"$out" | grep -c '^    - ')" == 1 && "$out" != *"the Proxmox integration:"* ]] \
    && ok "wizard: a doctor that finds problems fails the wizard (69): the closing text names it, no 'Setup complete'" || bad "wizard doctor fail: rc=$rc $out"
[[ -s "$wr/frepos/$(printf '%s' "$wr/fs/big/pbo-cache/repo" | tr -c 'A-Za-z0-9._-' '_')/config" ]] || [[ -e "$wr/frepos/$(printf '%s' "$wr/fs/big/pbo-cache/repo" | tr -c 'A-Za-z0-9._-' '_')/config" ]] \
    && [[ "$out" == *"cache repo $wr/fs/big/pbo-cache/repo: no repo yet"* && "$out" == *"offsite repo sftp:***@backup.example:pbo: no repo yet"* ]] \
    && ok "wizard DR key: a first setup probes both targets (no repo yet), generates the key, init makes the repos" || bad "wizard probe first: $out"

# a re-run that keeps every answer changes nothing: not the config, not
# known_hosts, and no timer the first run left off is enabled
cp "$wr/config" "$wr/config.first"; cp "$wr/known_hosts" "$wr/kh.first"
: > "$wr/calls"
WIZ0
cmp -s "$wr/config" "$wr/config.first" && cmp -s "$wr/known_hosts" "$wr/kh.first" && [[ "$out" == *"Keeping the offsite repo"* ]] \
    && [[ "$out" == *"Configured: SFTP backup.example, user pbo, port 2222, key $wr/keys/id_ed25519, path pbo, host key pinned in $wr/known_hosts"* ]] \
    && [[ "$out" == *"pbo.timer is enabled"* && "$out" == *"Keeping the existing DR key"* && "$out" == *"CACHE_DIR stays $wr/fs/big/pbo-cache"* ]] && noguard \
    && ! grep -q 'systemctl enable' "$wr/calls" && [[ ! -e "$wr/sysd/pbo-prune.timer.enabled" && ! -e "$wr/sysd/pbo-test-restore.timer.enabled" ]] \
    && ok "wizard re-run: Enter everywhere keeps the sftp repo with its port and key, the config is unchanged, no timer is enabled" \
    || bad "wizard re-run: $(diff "$wr/config.first" "$wr/config"); $(grep systemctl "$wr/calls") $out"
# the root filesystem warning stays quiet where it must: 12 GB to dump on a 20
# GB root (40 GB is not below 3 x 12.9 GB), and a node without guests
vmconf 6 6 > "$wr/qemu/8001.conf"
WIZ0
[[ "$out" != *"WARN the root filesystem"* ]] && cmp -s "$wr/config" "$wr/config.first" && noguard \
    && ok "wizard cache: no root warning when the root filesystem is at least 1.5 x the largest guest" || bad "wizard root warn quiet: $out"
WQM=''
WIZ0
[[ "$out" != *"WARN the root filesystem"* ]] && noguard && ok "wizard cache: no root warning on a node without guests" || bad "wizard root warn no guest: $out"
# a VM's boot disk is not its dump: 32 GB + 2 TB on a 100 GB root filesystem
WQM=8001; vmconf 32 2048 > "$wr/qemu/8001.conf"
sed 's#^/ ext4 20000000000 #/ ext4 100000000000 #' "$wr/mounts" > "$wr/mounts.100"; cp "$wr/mounts" "$wr/mounts.20"; cp "$wr/mounts.100" "$wr/mounts"
WIZ0
[[ "$out" == *"WARN the root filesystem"*"smaller than 1.5 x the largest guest"* ]] && noguard \
    && ok "wizard cache: the largest guest counts every disk of a VM (32 GB boot + 2 TB data on a 100 GB root warns)" || bad "wizard root warn multi-disk: $out"
cp "$wr/mounts.20" "$wr/mounts"; vmconf 8 8 > "$wr/qemu/8001.conf"

# choosing 'change' and keeping every part: the command reads back as it was
WIZ "" "" 2 "" "" "" "" "" ""
cmp -s "$wr/config" "$wr/config.first" && [[ "$out" == *"[backup.example]:2222 is pinned in"* || "$out" == *"pinned [backup.example]:2222 in"* ]] \
    && [[ "$out" == *"probing sftp://pbo@backup.example:2222"* ]] && noguard \
    && ok "wizard re-run: change, then Enter on every sftp part: RESTIC_SFTP_COMMAND round-trips, nothing is written" \
    || bad "wizard change keep: $(diff "$wr/config.first" "$wr/config") $out"
# ... and the ssh options of a command the wizard did not write stay in it
cfgw "RESTIC_OFFSITE_REPO=sftp:pbo@backup.example:pbo" \
     "RESTIC_SFTP_COMMAND=\"ssh pbo@backup.example -p 2222 -i $wr/keys/id_ed25519 -o ProxyJump=bastion.example -o ServerAliveInterval=30 -o UserKnownHostsFile=$wr/known_hosts -o StrictHostKeyChecking=yes -s sftp\""
cp "$wr/kh.first" "$wr/known_hosts"; : > "$wr/calls"
WIZ "" "" 2 "" "" "" "" "" ""
c="$(rdw RESTIC_SFTP_COMMAND)"
[[ "$c" == *" -o ProxyJump=bastion.example "* && "$c" == *" -o ServerAliveInterval=30 "* && "$c" == *"-o UserKnownHostsFile=$wr/known_hosts -o StrictHostKeyChecking=yes"* ]] \
    && [[ "$c" == "ssh pbo@backup.example -p 2222 "*" -s sftp" && "$(rdw RESTIC_OFFSITE_REPO)" == "sftp:pbo@backup.example:pbo" && "$out" != *"The offsite repo changes"* ]] \
    && grep -q '^sftp .*-o ProxyJump=bastion.example' "$wr/calls" && [[ "$out" == *"also has: -o ProxyJump=bastion.example -o ServerAliveInterval=30 (kept)"* ]] && noguard \
    && ok "wizard sftp: change + Enter keeps the other ssh options of the command (ProxyJump, ServerAliveInterval), the connection test uses them" \
    || bad "wizard sftp extra: $c; $(grep '^sftp' "$wr/calls") $out"
# an IPv6 server: the repo has it in brackets, the command's destination bare
cfgw "RESTIC_OFFSITE_REPO=\"sftp:pbo@[2001:db8::5]:pbo\"" \
     "RESTIC_SFTP_COMMAND=\"ssh pbo@2001:db8::5 -p 2222 -i $wr/keys/id_ed25519 -o UserKnownHostsFile=$wr/known_hosts -o StrictHostKeyChecking=yes -s sftp\""
cp "$wr/config" "$wr/config.v6"; : > "$wr/calls"
WIZ "" "" 2 "" "" "" "" "" ""
cmp -s "$wr/config" "$wr/config.v6" && [[ "$out" == *"Configured: SFTP 2001:db8::5, user pbo, port 2222, key $wr/keys/id_ed25519, path pbo"* ]] \
    && [[ "$out" != *"is not a host name"* && "$out" != *"The offsite repo changes"* && "$out" == *"probing sftp://pbo@[2001:db8::5]:2222"* ]] \
    && grep -q '^sftp .* pbo@\[2001:db8::5\]$' "$wr/calls" && grep -q '^\[2001:db8::5\]:2222 ssh-ed25519 ' "$wr/known_hosts" && noguard \
    && ok "wizard sftp: an IPv6 repo is read, kept on change + Enter, pinned and tested ([v6]:port)" || bad "wizard sftp v6: $(diff "$wr/config.v6" "$wr/config"); $(grep '^sftp' "$wr/calls") $out"
WIZ "" "" 2 "" "[2001:db8::9]" 2222 pbo "" "" y
eq "wizard sftp: a new IPv6 server (given in brackets) is written as sftp:<user>@[<v6>]:<path>" "$(rdw RESTIC_OFFSITE_REPO)|$(rdw RESTIC_SFTP_COMMAND)" \
   "sftp:pbo@[2001:db8::9]:pbo|ssh pbo@2001:db8::9 -p 2222 -i $wr/keys/id_ed25519 -o UserKnownHostsFile=$wr/known_hosts -o StrictHostKeyChecking=yes -s sftp"
# a cache move re-reads the values from pbo's JSON, which masks a login: the
# sftp user must come back as it is, not as ***
mkdir -p "$wr/home/.ssh"; cp "$wr/keys/id_ed25519" "$wr/keys/id_ed25519.pub" "$wr/home/.ssh/"
printf 'backup.example %s\n' "$KH0" > "$wr/home/.ssh/known_hosts"
CFGW_CACHE="$wr/cache-r0" cfgw "RESTIC_OFFSITE_REPO=sftp:pbo@backup.example:pbo"
cp "$wr/kh.first" "$wr/known_hosts"
WIZ "" "$wr/cache-r1" "" 2 "" "" "" "" "" "" n
[[ "$(rdw CACHE_DIR)" == "$wr/cache-r1" && "$(rdw RESTIC_OFFSITE_REPO)" == "sftp:pbo@backup.example:pbo" && -z "$(rdw RESTIC_SFTP_COMMAND)" ]] \
    && [[ "$out" == *"Configured: SFTP backup.example, user pbo, port 22"* && "$out" != *"user ***"* && "$out" != *"is not a user name"* ]] \
    && [[ "$out" != *"The offsite repo changes"* && "$out" != *"The input ended"* ]] && noguard \
    && ok "wizard: after a cache move the sftp repo keeps its user (not the masked form), change + Enter keeps the repo" \
    || bad "wizard refresh masked: rc=$rc $(grep -E 'CACHE|OFFSITE|SFTP' "$wr/config") $out"

# a rest-server (append-only) repo is recognised and kept
cfgw "RESTIC_OFFSITE_REPO=rest:https://janitor.example:8000/pve1/pbo" "RESTIC_REST_USERNAME=pve1" \
     "RESTIC_REST_PASSWORD_FILE=$wr/rest-pass" "OFFSITE_APPEND_ONLY=true" "LOCAL_REPO=false"
printf 'restpw\n' > "$wr/rest-pass"; chmod 600 "$wr/rest-pass"
cp "$wr/config" "$wr/config.rest"
WIZ0
cmp -s "$wr/config" "$wr/config.rest" && [[ "$out" == *"Configured: rest-server https://janitor.example:8000/pve1/pbo, user pve1, append-only"* ]] \
    && [[ "$out" == *"Keeping the offsite repo"* && "$out" != *"SFTP server"* ]] && noguard \
    && ok "wizard re-run: an append-only rest: repo is shown and kept, the config is unchanged" || bad "wizard rest keep: $(diff "$wr/config.rest" "$wr/config") $out"
# replacing it asks first: a no keeps the repo and every file as they were
WIZ "" "" 2 "" "https://rest2.example:8000/pve1/pbo" n
cmp -s "$wr/config" "$wr/config.rest" && [[ "$(cat "$wr/rest-pass")" == restpw ]] \
    && [[ "$out" == *"The offsite repo changes: rest:https://janitor.example:8000/pve1/pbo -> rest:https://rest2.example:8000/pve1/pbo"* ]] \
    && [[ "$out" == *"Kept rest:https://janitor.example:8000/pve1/pbo"* ]] && noguard \
    && ok "wizard offsite: another repo is not used on a no (the config and the password file unchanged)" || bad "wizard replace no: $(diff "$wr/config.rest" "$wr/config") $out"
WIZ "" "" 2 "" "https://rest2.example:8000/pve1/pbo" y "" "" "" ""
[[ "$(rdw RESTIC_OFFSITE_REPO)" == "rest:https://rest2.example:8000/pve1/pbo" && "$(rdw RESTIC_REST_USERNAME)" == pve1 && "$(rdw OFFSITE_APPEND_ONLY)" == true ]] \
    && [[ "$out" == *"rest:https://janitor.example:8000/pve1/pbo -> rest:https://rest2.example:8000/pve1/pbo"* && "$out" == *"pbo moves no snapshot"* && "$out" != *restpw* ]] && noguard \
    && ok "wizard offsite: on a yes the new repo is written (old -> new shown, no snapshot moved, no password shown)" || bad "wizard replace yes: $(grep -E 'REST|OFFSITE' "$wr/config") $out"
# a login written into the URL (restic's user:pass@ form): never shown, Enter
# keeps the URL without it, the user and the password go to their own keys
cfgw 'RESTIC_OFFSITE_REPO=rest:https://u1:Url%40Secret-77@rest.example:8000/u1/pbo'; rm -f "$wr/rest-pass"
WIZ "" "" 2 "" "" "" "" "" "" ""
[[ "$(rdw RESTIC_OFFSITE_REPO)" == "rest:https://rest.example:8000/u1/pbo" && "$(rdw RESTIC_REST_USERNAME)" == u1 && "$(rdw RESTIC_REST_PASSWORD_FILE)" == "$wr/rest-pass" ]] \
    && [[ "$(cat "$wr/rest-pass" 2>&1)" == 'Url@Secret-77' && "$(stat -c %a "$wr/rest-pass")" == 600 ]] \
    && [[ "$out" != *Secret-77* && "$out" != *"give the URL without the login"* && "$out" != *"The offsite repo changes"* ]] && noguard \
    && ok "wizard rest-server: a login in the configured URL is never shown; Enter keeps the URL without it, the password moves to a 0600 file" \
    || bad "wizard rest url login: $(grep -E 'REST|OFFSITE' "$wr/config"); $(cat "$wr/rest-pass" 2>&1) $out"

# each type of target writes its own keys
cfgw; rm -f "$wr/rest-pass"
WIZ "" "" 2 "ftp://nope" "https://u:p@rest.example/x" "https://rest.example:8000/pve1/pbo" pve1 "" "Rest-Secret-123" "" y
[[ "$(rdw RESTIC_OFFSITE_REPO)" == "rest:https://rest.example:8000/pve1/pbo" && "$(rdw RESTIC_REST_USERNAME)" == pve1 \
   && "$(rdw RESTIC_REST_PASSWORD_FILE)" == "$wr/rest-pass" && "$(rdw OFFSITE_APPEND_ONLY)" == true ]] \
    && [[ "$(cat "$wr/rest-pass")" == Rest-Secret-123 && "$(stat -c %a "$wr/rest-pass")" == 600 && "$out" != *Rest-Secret-123* ]] \
    && [[ "$out" == *"'ftp://nope' is not an http(s) URL"* && "$out" == *"give the URL without the login"* ]] && noguard \
    && ok "wizard rest-server: URL (asked again until valid), user, a 0600 password file (never shown), append-only" \
    || bad "wizard rest: $(cat "$wr/config" | grep -E 'REST|APPEND|OFFSITE') $out"
cfgw
WIZ "" "" 3 "$wr/offsite-repo"
[[ "$(rdw RESTIC_OFFSITE_REPO)" == "$wr/offsite-repo" && "$out" == *"is on the filesystem of CACHE_DIR"* ]] && noguard \
    && ok "wizard directory: the path is the repo (a warning when it shares the cache's filesystem)" || bad "wizard dir: $(rdw RESTIC_OFFSITE_REPO) $out"
# a change of type removes the keys of the old one: sftp -> rest-server ...
cfgw "RESTIC_OFFSITE_REPO=sftp:pbo@backup.example:pbo" "RESTIC_SFTP_COMMAND=\"ssh pbo@backup.example -p 2222 -i $wr/keys/id_ed25519 -s sftp\""; rm -f "$wr/rest-pass"
WIZ "" "" 2 2 "https://rest.example:8000/pve1/pbo" y pve1 "" "Rest-Secret-9" "" n
[[ "$(rdw RESTIC_OFFSITE_REPO)" == "rest:https://rest.example:8000/pve1/pbo" && -z "$(rdw RESTIC_SFTP_COMMAND)" ]] && ! grep -q '^RESTIC_SFTP_COMMAND' "$wr/config" \
    && [[ "$out" == *"The offsite repo changes: sftp:***@backup.example:pbo -> rest:https://rest.example:8000/pve1/pbo"* ]] && noguard \
    && ok "wizard offsite: sftp -> rest-server removes RESTIC_SFTP_COMMAND" || bad "wizard sftp->rest: $(grep -E 'SFTP|OFFSITE' "$wr/config") $out"
# ... and rest-server -> a directory removes the rest-server login and append-only
cfgw "RESTIC_OFFSITE_REPO=rest:https://janitor.example:8000/pve1/pbo" "RESTIC_REST_USERNAME=pve1" \
     "RESTIC_REST_PASSWORD_FILE=$wr/rest-pass" "OFFSITE_APPEND_ONLY=true"
WIZ "" "" 2 3 "$wr/offsite-repo" y
[[ "$(rdw RESTIC_OFFSITE_REPO)" == "$wr/offsite-repo" ]] && ! grep -qE '^(RESTIC_REST_USERNAME|RESTIC_REST_PASSWORD_FILE|OFFSITE_APPEND_ONLY)=' "$wr/config" && noguard \
    && ok "wizard offsite: rest-server -> directory removes the rest-server user, password file and append-only" || bad "wizard rest->dir: $(grep -E 'REST|APPEND|OFFSITE' "$wr/config") $out"
cfgw; rm -f "$wr/restic.env"
WIZ "" "" 4 "s3:https://s3.example/bucket/pbo" "" "AKIDTESTVALUE1" 'Se$cret/"q`x\y' "" "BAD-NAME" RESTIC_PASSWORD MY_EXTRA "extra value" ""
[[ "$(rdw RESTIC_OFFSITE_REPO)" == "s3:https://s3.example/bucket/pbo" && "$(stat -c %a "$wr/restic.env" 2>&1)" == 600 ]] \
    && [[ "$(rdw AWS_ACCESS_KEY_ID "$wr/restic.env")" == AKIDTESTVALUE1 && "$(rdw AWS_SECRET_ACCESS_KEY "$wr/restic.env")" == 'Se$cret/"q`x\y' && "$(rdw MY_EXTRA "$wr/restic.env")" == "extra value" ]] \
    && ! grep -q AWS_DEFAULT_REGION "$wr/restic.env" && [[ "$out" == *"AWS_ACCESS_KEY_ID"*"required"* ]] \
    && [[ "$out" != *AKIDTESTVALUE1* && "$out" != *'Se$cret'* && "$out" != *"extra value"* ]] \
    && [[ "$out" == *"'BAD-NAME' is not a variable name"* && "$out" == *"RESTIC_PASSWORD cannot be set there"* ]] && noguard \
    && ok "wizard other backend: the repo string, its variables named, the values in RESTIC_ENV_FILE 0600, never printed" \
    || bad "wizard other: $(grep OFFSITE "$wr/config"); $(stat -c %a "$wr/restic.env" 2>&1) $out"
printf 'AWS_ACCESS_KEY_ID=old\n' > "$wr/restic.env"; chmod 600 "$wr/restic.env"
cfgw "RESTIC_OFFSITE_REPO=s3:https://s3.example/bucket/pbo"
WIZ "" "" 2 "" "" "" "" "NEWSECRET" "" ""
[[ "$(rdw AWS_ACCESS_KEY_ID "$wr/restic.env")" == old && "$(rdw AWS_SECRET_ACCESS_KEY "$wr/restic.env")" == NEWSECRET && "$out" != *NEWSECRET* ]] \
    && [[ "$out" == *"s3 backend s3:https://s3.example/bucket/pbo, credentials in $wr/restic.env (AWS_ACCESS_KEY_ID)"* ]] \
    && ok "wizard other backend: a variable the file has is kept on Enter, a new one added" || bad "wizard env keep: $out"

# a CACHE_DIR with data: the move's dry run first, the move on a yes
cfgw; mkdir -p "$wr/cache/101"; printf 'x\n' > "$wr/cache/101/vzdump-lxc-101-2026_01_15-05_00_00.tar"
cp "$wr/config" "$wr/config.cm"
WIZ "" "$wr/cache2" n
[[ "$(rdw CACHE_DIR)" == "$wr/cache" && -f "$wr/cache/101/vzdump-lxc-101-2026_01_15-05_00_00.tar" && "$out" == *"cache move plan"* && "$out" == *"CACHE_DIR stays $wr/cache"* ]] \
    && cmp -s "$wr/config" "$wr/config.cm" && ok "wizard cache: a cache with data shows the move's plan; a no changes nothing" || bad "wizard move no: $out"
WIZ "" "$wr/cache2" y
[[ "$(rdw CACHE_DIR)" == "$wr/cache2" && -f "$wr/cache2/101/vzdump-lxc-101-2026_01_15-05_00_00.tar" && ! -e "$wr/cache/101" && "$out" == *"CACHE_DIR is $wr/cache2"* ]] && noguard \
    && ok "wizard cache: on a yes the cache is moved (pbo config set CACHE_DIR)" || bad "wizard move: CACHE_DIR=$(rdw CACHE_DIR) $(ls -R "$wr/cache2" 2>&1) $out"
# a config without a CACHE_DIR line (the default, $wr/dcache here): Enter
# keeps it and writes nothing, whether the cache holds data ...
CFGW_CACHE=none cfgw "RESTIC_OFFSITE_REPO=$wr/offsite-repo"
mkdir -p "$wr/dcache/101"; printf 'x\n' > "$wr/dcache/101/vzdump-lxc-101-2026_01_15-05_00_00.tar"
cp "$wr/config" "$wr/config.nocd"
WIZ0
cmp -s "$wr/config" "$wr/config.nocd" && [[ "$out" == *"CACHE_DIR stays $wr/dcache"* ]] && noguard \
    && ok "wizard re-run: the default CACHE_DIR (no line) with data is kept on Enter and not pinned (the config byte for byte as it was)" \
    || bad "wizard cache default pinned: $(diff "$wr/config.nocd" "$wr/config") $out"
# ... or is empty on an offsite-only host: the suggestion is a hint, Enter does not move the cache there
rm -rf "$wr/dcache"
CFGW_CACHE=none cfgw "RESTIC_OFFSITE_REPO=$wr/offsite-repo" "LOCAL_REPO=false"
cp "$wr/config" "$wr/config.nocd"
WIZ0
cmp -s "$wr/config" "$wr/config.nocd" && [[ "$out" == *"Suggestion: $wr/fs/big/pbo-cache"* && "$out" == *"CACHE_DIR stays $wr/dcache"* && ! -e "$wr/fs/big/pbo-cache/.pbo-moved" ]] && noguard \
    && ok "wizard re-run: an empty default cache (offsite only) stays the default; the suggestion is only a hint" \
    || bad "wizard cache suggestion default: $(diff "$wr/config.nocd" "$wr/config") $out"
# a CACHE_DIR the cluster-shared file sets is not written into the local file on Enter
printf 'CACHE_DIR=%s\n' "$wr/cache-sh" > "$wr/shared.cfg"
CFGW_CACHE=none cfgw "RESTIC_OFFSITE_REPO=$wr/offsite-repo"
cp "$wr/config" "$wr/config.nocd"
WSHARED="$wr/shared.cfg" WIZ0
cmp -s "$wr/config" "$wr/config.nocd" && [[ "$out" == *"CACHE_DIR stays $wr/cache-sh"* ]] && noguard \
    && ok "wizard re-run: a CACHE_DIR from the cluster-shared file is kept on Enter, not pinned locally" \
    || bad "wizard cache shared: $(diff "$wr/config.nocd" "$wr/config") $out"

# a Storage Box: its defaults (port 23, the account as the user) and its snapshot question
cfgw
WIZ "" "" 1 uXXXXX-sub1.your-storagebox.de "" "" "$wr/keys/id_ed25519" "" "" y
[[ "$(rdw RESTIC_OFFSITE_REPO)" == "sftp:uXXXXX-sub1@uXXXXX-sub1.your-storagebox.de:pbo" && "$(rdw STORAGE_BOX_SNAPSHOTS_CONFIRMED)" == true ]] \
    && [[ "$(rdw RESTIC_SFTP_COMMAND)" == "ssh uXXXXX-sub1@uXXXXX-sub1.your-storagebox.de -p 23 -i $wr/keys/id_ed25519 -o UserKnownHostsFile=$wr/known_hosts -o StrictHostKeyChecking=yes -s sftp" ]] \
    && [[ "$out" == *"A Storage Box:"* && "$out" == *"ssh-copy-id -s -p 23"* ]] && noguard \
    && ok "wizard sftp: a Storage Box gets port 23, the account as the user, its hints and the snapshot question" || bad "wizard storagebox: $(grep -E 'OFFSITE|SFTP|STORAGE' "$wr/config") $out"
# port 22, a key ssh tries by itself, a host key ssh recorded, no pinning: no
# RESTIC_SFTP_COMMAND (an old one goes)
printf 'h.example %s\n' "$KH0" > "$wr/home/.ssh/known_hosts"
cfgw "RESTIC_OFFSITE_REPO=sftp:old@h.example:pbo" "RESTIC_SFTP_COMMAND=\"ssh old@h.example -p 2222 -i $wr/keys/id_ed25519 -s sftp\""
WIZ "" "" 2 "" "" 22 "" "$wr/home/.ssh/id_ed25519" "" n
[[ "$(rdw RESTIC_OFFSITE_REPO)" == "sftp:old@h.example:pbo" && -z "$(rdw RESTIC_SFTP_COMMAND)" ]] && ! grep -q '^RESTIC_SFTP_COMMAND' "$wr/config" \
    && [[ "$out" == *"No RESTIC_SFTP_COMMAND: restic runs ssh old@h.example with its defaults"* && "$out" == *"trust on first use"* ]] && noguard \
    && ok "wizard sftp: port 22, a default key and a host key ssh recorded need no RESTIC_SFTP_COMMAND (the old one is removed)" || bad "wizard sftp no cmd: $(grep SFTP "$wr/config") $out"
# the same with a host key nobody recorded (the server unreachable during
# setup): trust on first use needs accept-new, or the first timer run fails
: > "$wr/home/.ssh/known_hosts"
cfgw "RESTIC_OFFSITE_REPO=sftp:old@h.example:pbo"
WSFTP_RC=1 WIZ "" "" 2 "" "" "" "" "" "" n n
[[ "$(rdw RESTIC_SFTP_COMMAND)" == "ssh old@h.example -p 22 -i $wr/home/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new -s sftp" ]] \
    && [[ "$out" == *"Going on without a verified connection"* && "$out" == *"trusted on first use (accept-new)"* ]] && noguard \
    && ok "wizard sftp: not pinned, a host key ssh never recorded: RESTIC_SFTP_COMMAND with StrictHostKeyChecking=accept-new" || bad "wizard sftp accept-new: $(grep SFTP "$wr/config") $out"
# ntfy: a configured server is shown masked and kept, the topic never shown
cfgw "NTFY_URL=https://ntfy.example/base" "NTFY_TOPIC=very-secret-topic" "RESTIC_OFFSITE_REPO=$wr/offsite-repo"
cp "$wr/config" "$wr/config.ntfy"
WIZ0
cmp -s "$wr/config" "$wr/config.ntfy" && [[ "$out" == *"ntfy: https://ntfy.example/base, topic <set>, notify on: fail"* && "$out" != *very-secret-topic* ]] \
    && ok "wizard ntfy: a configured server is kept on Enter, its topic not shown" || bad "wizard ntfy: $(diff "$wr/config.ntfy" "$wr/config") $out"
# a global --dry-run would not reach the steps' own pbo runs: refused
WIZ0 --dry-run
[[ $rc == 64 && "$out" == *"setup has no --dry-run"* ]] && cmp -s "$wr/config" "$wr/config.ntfy" \
    && ok "wizard: pbo --dry-run setup is refused (64), nothing changed" || bad "wizard dry run: rc=$rc $out"
# 'turn ntfy off' with the server in the cluster-shared file: the local file
# gets the empty default (it wins), so ntfy is off on this node
printf '%s\n' "NTFY_URL=https://ntfy.example/base" "NTFY_TOPIC=shared-topic" > "$wr/shared.cfg"
cfgw "RESTIC_OFFSITE_REPO=$wr/offsite-repo"
WSHARED="$wr/shared.cfg" WIZ "" "" "" "" "" 3
o1="$out"
WSHARED="$wr/shared.cfg" WIZ0
[[ "$o1" == *"ntfy: https://ntfy.example/base"* && "$o1" == *"ntfy off."* && "$out" == *"ntfy stays off."* && "$out" != *"ntfy: https://"* ]] \
    && [[ "$(WSHARED="$wr/shared.cfg" effw NTFY_URL)" == "<unset>" ]] && grep -qE "^NTFY_URL=(''|\"\")?\$" "$wr/config" && noguard \
    && ok "wizard ntfy: turning off a server the cluster-shared file sets writes the empty default locally (ntfy is off)" \
    || bad "wizard ntfy shared off: $(grep NTFY "$wr/config"); $o1 $out"
# a shared OFFSITE_APPEND_ONLY=true and a switch from rest-server to sftp:
# false locally (else this host would never prune its new sftp repo)
printf 'OFFSITE_APPEND_ONLY=true\n' > "$wr/shared.cfg"
cfgw "RESTIC_OFFSITE_REPO=rest:https://janitor.example:8000/pve1/pbo" "RESTIC_REST_USERNAME=pve1" "RESTIC_REST_PASSWORD_FILE=$wr/rest-pass"
printf 'restpw\n' > "$wr/rest-pass"; chmod 600 "$wr/rest-pass"; cp "$wr/kh.first" "$wr/known_hosts"
WSHARED="$wr/shared.cfg" WIZ "" "" 2 1 backup.example 2222 pbo "$wr/keys/id_ed25519" "" y
[[ "$(rdw RESTIC_OFFSITE_REPO)" == "sftp:pbo@backup.example:pbo" && "$(WSHARED="$wr/shared.cfg" effw OFFSITE_APPEND_ONLY)" == false ]] \
    && grep -qx 'OFFSITE_APPEND_ONLY=false' "$wr/config" && ! grep -qE '^RESTIC_REST_(USERNAME|PASSWORD_FILE)=' "$wr/config" && noguard \
    && ok "wizard offsite: rest-server -> sftp turns a shared OFFSITE_APPEND_ONLY=true off on this node" \
    || bad "wizard append-only shared: $(grep -E 'APPEND|REST|OFFSITE' "$wr/config"); $(WSHARED="$wr/shared.cfg" effw OFFSITE_APPEND_ONLY) $out"

# --- the end of the input stops the wizard, in every step (0.6.1) -----------------------------
# The first setup's answers, cut short at the start of a step: pbo setup exits
# 64, says where, never "Setup complete", and nothing the steps after it
# would set is written. Each run starts fresh (no DR key, no repo, no pinned
# host key, an empty cache directory).
FIRST=("" "$wr/fs/big/pbo-cache" "" 1 backup.example 2222 pbo "$wr/keys/id_ed25519" "" "" "" ""
       y abc 0 3 "" "" x 12 "" "" "" "" y nightly "*-*-* 03:30:00" "" "" "" y n n n)
fresh() {
    CFGW_CACHE="$wr/cache-eof" cfgw; rm -rf "$wr/cache-eof" "$wr/fs/big/pbo-cache" "$wr/frepos" "$wr/units"
    mkdir -p "$wr/cache-eof" "$wr/units"; rm -f "$wr/pass" "$wr/known_hosts"; : > "$wr/calls"; rm -f "$wr/sysd"/*.enabled
}
# eofat N STEP: the first N answers only; the wizard stops in STEP
eofat() {
    fresh; WIZE "${FIRST[@]:0:$1}"
    [[ $rc == 64 && "$out" == *"setup stops in the $2 step (exit 64)"* && "$out" != *"Setup complete"* && "$out" != *"not everything worked"* ]] && noguard
}
errs=''
eofat 0 cache && [[ "$(rdw CACHE_DIR)" == "$wr/cache-eof" ]] || errs+="0: rc=$rc $(tail -3 <<<"$out"); "
eofat 2 cache && [[ "$(rdw CACHE_DIR)" == "$wr/cache-eof" && ! -e "$wr/fs/big/pbo-cache" ]] || errs+="2: rc=$rc $(tail -3 <<<"$out"); "
eofat 8 offsite && [[ -z "$(rdw RESTIC_OFFSITE_REPO)" ]] || errs+="8: rc=$rc $(rdw RESTIC_OFFSITE_REPO) $(tail -3 <<<"$out"); "
eofat 10 drkey && [[ "$(rdw RESTIC_OFFSITE_REPO)" == "sftp:pbo@backup.example:pbo" && ! -e "$wr/pass" ]] || errs+="10: rc=$rc $(tail -3 <<<"$out"); "
eofat 11 mode && [[ -s "$wr/pass" && ! -e "$wr/frepos" && -z "$(rdw BACKUP_MODE)" ]] || errs+="11: rc=$rc $(tail -3 <<<"$out"); "
eofat 21 ntfy && [[ "$(rdw KEEP_OFFSITE_MONTHLY)" == 12 && ! -e "$wr/frepos" ]] || errs+="21: rc=$rc $(tail -3 <<<"$out"); "
eofat 23 integration && [[ -d "$wr/frepos" ]] && ! grep -q 'systemctl enable' "$wr/calls" || errs+="23: rc=$rc $(tail -3 <<<"$out"); "
eofat 24 schedule && [[ -z "$(rdw SCHEDULE_BACKUP)" ]] && ! grep -q 'systemctl enable' "$wr/calls" || errs+="24: rc=$rc $(tail -3 <<<"$out"); "
eofat 29 schedule && [[ -z "$(rdw SCHEDULE_BACKUP)" ]] || errs+="29: rc=$rc $(tail -3 <<<"$out"); "
eofat 30 schedule && [[ "$(rdw SCHEDULE_BACKUP)" == "*-*-* 03:30:00" ]] && ! grep -q 'systemctl enable' "$wr/calls" || errs+="30: rc=$rc $(tail -3 <<<"$out"); "
eofat 31 schedule && grep -qx 'systemctl enable --now pbo.timer' "$wr/calls" && ! grep -q 'enable --now pbo-verify.timer' "$wr/calls" \
    && [[ "$out" != *"Health check"* ]] || errs+="31: rc=$rc $(tail -3 <<<"$out"); "
[[ -z "$errs" ]] && ok "wizard: short input in each step (cache, offsite, DR key, mode, ntfy, integration, schedule, timers) exits 64, names the step, writes nothing after it, never 'Setup complete'" \
    || bad "wizard short input: $errs"
fresh; WIZE "${FIRST[@]}"
[[ $rc == 69 && "$out" == *"not everything worked"* && "$out" != *"The input ended"* ]] && noguard \
    && ok "wizard: the whole first setup on exactly its answers runs to the end (doctor's 69: no snapshot yet)" || bad "wizard exact answers: rc=$rc $(tail -5 <<<"$out")"

# the success path: the same first setup where every guest has a fresh
# snapshot already (FAKE_RESTIC_SNAPS): doctor passes, setup exits 0 and says
# "Setup complete"
now="$(date +%s)"
jq -c --arg t "$(date -u -d "@$((now - 3600))" +%Y-%m-%dT%H:%M:%SZ)" --arg p "$wr/fs/big/pbo-cache" \
    '[.[] | {time: $t, tags: ["vmid=\(.vmid)"], paths: ["\($p)/\(.vmid)"], hostname: "pve1", id: "0\(.vmid)", short_id: "0\(.vmid)"}]' \
    <(jq -c --argjson q "${WQM:-0}" '. + (if $q > 0 then [{vmid: $q}] else [] end)' "$wr/resources.json") > "$wr/snaps.json"
fresh; WSNAPS="$wr/snaps.json" WIZE "${FIRST[@]}"
[[ $rc == 0 && "$out" == *"Setup complete"* && "$out" != *"not everything worked"* && "$out" != *"The input ended"* ]] && noguard \
   && grep -qE 'OK  guest [0-9]+ newest snapshot 1h old' <<<"$out" \
    && ok "wizard: a first setup whose guests have a snapshot already ends in 'Setup complete' (exit 0)" || bad "wizard success: rc=$rc $(tail -25 <<<"$out")"

# init fails in the wizard: setup stops there with init's own status, and
# nothing after it runs (no guest set, no schedule, no timer)
fresh; WINITRC=1 WIZ "${FIRST[@]:0:21}"
o1="$out"; r1=$rc
rc0="$(WINITRC=1; wenv; env -u PBO_SELF_BIN "${W_ENV[@]}" "$wbin" init </dev/null >/dev/null 2>&1; echo $?)"
out="$o1"
[[ $r1 != 0 && $r1 == "$rc0" && "$o1" == *"init failed (exit $r1)"* && "$o1" == *"repo init failed"* && "$o1" == *"Setup stopped in the init step"* \
   && "$o1" != *"Setup complete"* && "$o1" != *"not everything worked"* && "$o1" != *"Proxmox integration —"* ]] \
   && ! grep -q 'systemctl enable' "$wr/calls" && [[ -z "$(rdw SCHEDULE_BACKUP)" ]] && noguard \
    && ok "wizard: a failed repo init stops setup in the init step with init's status ($rc0), nothing after it runs" \
    || bad "wizard init fails: rc=$r1 init=$rc0 $(tail -8 <<<"$o1")"
rm -rf "$wr/frepos"

# a fresh install.sh host has no CACHE_DIR line (install.sh writes no config):
# on a first setup the suggestion is the default, Enter takes it
fresh; CFGW_CACHE=none cfgw; rm -rf "$wr/dcache"
WIZE "" "" ""
[[ "$(rdw CACHE_DIR)" == "$wr/fs/big/pbo-cache" && -d "$wr/fs/big/pbo-cache" && "$out" == *"CACHE_DIR is $wr/fs/big/pbo-cache"* ]] && noguard \
    && ok "wizard cache: no CACHE_DIR in the config on a first setup: the suggestion is the default (Enter, then yes, moves nothing and sets it)" \
    || bad "wizard cache suggestion fresh: $(rdw CACHE_DIR) $out"

# --- the DR key step probes the target first (0.6.1) -------------------------------------------
# A repo that exists already on a rest-server (the fake restic's repo for it
# holds the key "right-key"): the wizard never offers a new key, asks for the
# existing one and writes it only once it opens the repo.
san() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
KREPO=rest:https://rest.example:8000/pve1/off-k
krepo() {   # krepo: a config with that offsite repo only (no cache repo), the repo there, no DR key
    rm -rf "$wr/frepos"; mkdir -p "$wr/frepos/$(san "$KREPO")"
    printf 'right-key' > "$wr/frepos/$(san "$KREPO")/key"; : > "$wr/frepos/$(san "$KREPO")/config"
    CFGW_CACHE="$wr/cache-eof" cfgw "RESTIC_OFFSITE_REPO=$KREPO" "LOCAL_REPO=false"; rm -f "$wr/pass"
}
printf 'wrong-key\n' > "$wr/k-wrong"; printf '# exported\nRESTIC_OFFSITE_REPO=%s\nRESTIC_PASSWORD=right-key\n' "$KREPO" > "$wr/k-export"
# an edited export whose last line, the key, has no newline: the key alone
printf '# exported\nRESTIC_OFFSITE_REPO=%s\nRESTIC_PASSWORD=right-key' "$KREPO" > "$wr/k-export-nonl"
printf 'plain-key\n' > "$wr/k-plain"
kf="$(bash -c 'source lib/menu.sh; _setup_key_from_file "$1"; printf "|"; _setup_key_from_file "$2"; printf "|"; _setup_key_from_file "$3"' _ \
      "$wr/k-export-nonl" "$wr/k-export" "$wr/k-plain" 2>&1)"
[[ "$kf" == 'right-key|right-key|plain-key' ]] && ok "wizard DR key file: the RESTIC_PASSWORD= line of an export (with or without a final newline), else the whole file" \
    || bad "key from file: $kf"
chmod 600 "$wr/k-wrong" "$wr/k-export"
krepo
WIZE "" "" "" "$wr/k-wrong" y
[[ $rc == 64 && "$out" == *"offsite repo $KREPO: a repo is there"* && "$out" == *"A repo exists there already"* \
   && "$out" == *"That key does not open the offsite repo $KREPO: not written"* && "$out" == *"'y' is not an absolute path"* ]] \
    && [[ ! -e "$wr/pass" ]] && noguard \
    && ok "wizard DR key: a repo exists: no new key is offered (a 'y' is read as the key's file), a key that does not open it is refused and nothing is written" \
    || bad "wizard drkey wrong: rc=$rc $(ls "$wr/pass" 2>&1) $out"
krepo
WIZ "" "" "" "$wr/k-export"
[[ "$(cat "$wr/pass" 2>&1)" == right-key && "$(stat -c %a "$wr/pass")" == 600 && "$out" == *"offsite repo $KREPO: a repo is there, the key opens it"* \
   && "$out" != *"Generated:"* && "$out" != *"The input ended"* ]] && noguard \
    && ok "wizard DR key: the key from an export file that opens the repo is written (0600), never a generated one" || bad "wizard drkey export: $(cat "$wr/pass" 2>&1) $out"
krepo
WIZ "" "" "" "" "right-key"
[[ "$(cat "$wr/pass" 2>&1)" == right-key && "$out" != *right-key* ]] && noguard \
    && ok "wizard DR key: ... or typed without echo (never shown)" || bad "wizard drkey typed: $(cat "$wr/pass" 2>&1) $out"
# the target cannot be reached: asked, "a repo is there" by default
krepo
WDOWN=off-k WIZE "" "" "" "" "$wr/k-export" 1
[[ ! -e "$wr/pass" && "$out" == *"Whether a repo exists there cannot be told now"*"connection refused"* && "$out" == *"Give the DR key that repo was made with"* \
   && $rc == 64 ]] && noguard \
    && ok "wizard DR key: a target that cannot be checked: asked (yes by default), a key that cannot be checked is not written unless picked" \
    || bad "wizard drkey unknown other key: rc=$rc $(cat "$wr/pass" 2>&1) $out"
krepo
WDOWN=off-k WIZE "" "" "" "" "$wr/k-export" 2
[[ "$(cat "$wr/pass" 2>&1)" == right-key ]] && noguard \
    && ok "wizard DR key: ... and taken unchecked when that is picked" || bad "wizard drkey unknown: $(cat "$wr/pass" 2>&1) $out"
# ... and the way back: "there is no repo there" after a key was given
krepo
WDOWN=off-k WIZE "" "" "" "" "" "typed-key-1" 3 y
[[ -s "$wr/pass" && "$(cat "$wr/pass")" != typed-key-1 && "$(stat -c %a "$wr/pass")" == 600 && "$out" == *"Generated:"* && "$out" != *typed-key-1* ]] && noguard \
    && ok "wizard DR key: a target that cannot be checked, yes to 'holds a repo' by mistake: 'no repo there' goes back to generating a key (written, 0600)" \
    || bad "wizard drkey way back: $(cat "$wr/pass" 2>&1) $out"
# a directory repo restic cannot read (permission denied: NFS with
# root_squash) is no new target: asked, "a repo is there" by default
rm -rf "$wr/frepos" "$wr/nfs-repo"; mkdir -p "$wr/nfs-repo"
CFGW_CACHE="$wr/cache-eof" cfgw "RESTIC_OFFSITE_REPO=$wr/nfs-repo" "LOCAL_REPO=false"; rm -f "$wr/pass"
WDENY=nfs-repo WIZE "" "" "" ""
[[ $rc == 64 && "$out" == *"offsite repo $wr/nfs-repo: cannot tell"*"permission denied"* && "$out" == *"Whether a repo exists there cannot be told now"* \
   && "$out" == *"Give the DR key that repo was made with"* && "$out" != *"Generated:"* && ! -e "$wr/pass" ]] && noguard \
    && ok "wizard DR key: a directory repo restic may not read (permission denied) is not taken for a new one: asked, a repo there by default" \
    || bad "wizard drkey denied dir: rc=$rc $out"
rm -rf "$wr/nfs-repo"
krepo
WDOWN=off-k WIZE "" "" "" n y
[[ -s "$wr/pass" && "$(cat "$wr/pass")" != right-key && "$out" == *"Generated:"* ]] && noguard \
    && ok "wizard DR key: ... and a no there is a new target: generating stays the default" || bad "wizard drkey unknown no: $(cat "$wr/pass" 2>&1) $out"
# a DR key file that does not open the repo the target holds: setup stops, the key file stays
krepo; printf 'another-key\n' > "$wr/pass"; chmod 600 "$wr/pass"
WIZ "" "" ""
[[ $rc == 1 && "$(cat "$wr/pass")" == another-key && "$out" == *"The DR key in $wr/pass does not open the offsite repo $KREPO"* \
   && "$out" == *"Setup stopped in the drkey step"* && "$out" != *"Setup complete"* ]] && noguard \
    && ok "wizard DR key: a key file that does not open the existing repo stops setup in the DR key step (the file kept)" || bad "wizard drkey kept wrong: rc=$rc $out"
rm -f "$wr/pass"; rm -rf "$wr/frepos"

rm -f "$PICK_ERR"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
