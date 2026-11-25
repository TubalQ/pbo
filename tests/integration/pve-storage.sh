#!/usr/bin/env bash
# tests/integration/pve-storage.sh: the pbo storage plugin against the REAL
# Proxmox VE libraries (ADR 0006). Opt-in: never run by tests/all.sh; release.sh
# runs --load-only only with PBO_IT_PVE_STORAGE=1. Run it after every PVE upgrade
# (libpve-storage-perl, pve-manager, qemu-server, pve-container).
#
#   tests/integration/pve-storage.sh --load-only
#       Read-only. In a separate perl process (taint mode, like
#       pvedaemon) it loads the installed PVE::Storage, then requires
#       pve-plugin/PboPlugin.pm from this checkout: no install, no register, no
#       storage.cfg change, no daemon touched. On a host where the plugin is
#       installed it checks that the installed file is this checkout's and tests
#       the one PVE::Storage loaded (run it after every PVE upgrade). It checks api() against the host's
#       APIVER/APIAGE, the options against the registered properties, and calls
#       parse_volname/list_volumes/path/status/get_subdir with a fake storage
#       config and a temporary index and spool. Writes only to a temp dir.
#
#   PBO_IT_PVE_STORAGE_FULL=1 tests/integration/pve-storage.sh --full
#       Only with the host admin's explicit OK: it CHANGES the host. Needs the plugin
#       installed (install.sh --integration ... or the pbo-pve-storage package)
#       and a readable catalogue. Adds a temporary storage pbo-it-<pid> (writes
#       /etc/pve/storage.cfg), lists it, extracts the configuration of the newest
#       archive (stages it through pbo catalog materialize), checks that free,
#       prune and protection are refused, and removes the storage again (trap).
#       GUI restores to new vmids stay manual.
set -uo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
PLUGIN="$SRC/pve-plugin/PboPlugin.pm"
pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
die()  { printf 'pve-storage.sh: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 64; }

mode="${1:-}"
case "$mode" in --load-only|--full) ;; -h|--help) usage ;; *) usage ;; esac
[[ -f /usr/share/perl5/PVE/Storage.pm ]] || die "no PVE::Storage here: not a Proxmox VE host"
[[ -f "$PLUGIN" ]] || die "$PLUGIN missing"

W="$(mktemp -d "${TMPDIR:-/tmp}/pbo-it-storage.XXXXXX")" || die "mktemp failed"
STORE=""
cleanup() {
    local rc=$?
    if [[ -n "$STORE" ]]; then
        # only the storage this run added, and only if it is still ours (type pbo)
        if pvesm status --storage "$STORE" >/dev/null 2>&1 \
           && grep -Eq "^pbo: ${STORE}\$" /etc/pve/storage.cfg 2>/dev/null; then
            pvesm remove "$STORE" >/dev/null 2>&1 && echo "removed temporary storage $STORE" \
                || echo "COULD NOT REMOVE temporary storage $STORE: pvesm remove $STORE" >&2
        fi
    fi
    rm -rf -- "$W"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------
load_only() {
    printf 'pbo: storage plugin against the installed PVE libraries (read-only)\n'
    dpkg-query -W -f '  ${Package} ${Version}\n' pve-manager libpve-storage-perl qemu-server pve-container 2>/dev/null || true
    local inst=/usr/share/perl5/PVE/Storage/Custom/PboPlugin.pm
    if [[ -f "$inst" ]]; then
        cmp -s -- "$inst" "$PLUGIN" && ok "the installed plugin is this checkout's ($inst)" \
            || bad "the installed plugin differs from $PLUGIN: reinstall (install.sh --integration ..., or the pbo-pve-storage package) or check out the installed version"
    fi
    mkdir -p "$W/catalog" "$W/staging" "$W/spool/dump"
    local a1=vzdump-lxc-101-2026_01_10-05_00_01.tar a2=vzdump-qemu-200-2026_01_11-05_10_00.vma s1=vzdump-lxc-102-2026_01_12-01_30_00.tar
    cat > "$W/catalog/index.json" <<EOF
{"version":1,"generated":1768107601,"updated":1768107601,"node":"it","storage_id":"pbo","staging_dir":"$W/staging","spool_dir":"$W/spool",
 "tiers":{"cache":{"enabled":true,"ok":true,"count":2},"offsite":{"enabled":true,"ok":true,"count":1}},
 "entries":[{"volname":"backup/$a1","vmid":101,"type":"lxc","ts":"2026_01_10-05_00_01","ctime":1768107601,"size":1000,
             "snapshots":{"cache":"aaaaaaaa","offsite":"bbbbbbbb"},"keep":"default","offsite_only":false},
            {"volname":"backup/$a2","vmid":200,"type":"qemu","ts":"2026_01_11-05_10_00","ctime":1768194600,"size":3000,
             "snapshots":{"cache":"cccccccc","offsite":null},"keep":"default","offsite_only":false}]}
EOF
    printf 'x' > "$W/spool/dump/$s1"
    local out rc=0
    # one line per check: "ok <text>" or "not ok <text>"
    out="$(cd "$W" && PBO_IT_W="$W" A1="$a1" A2="$a2" S1="$s1" perl -T -I "$SRC/pve-plugin" -e '
        use strict; use warnings;
        my ($W, $a1, $a2, $s1) = map { m/^(.*)$/; $1 } @ENV{qw(PBO_IT_W A1 A2 S1)};
        my @w; $SIG{__WARN__} = sub { push @w, $_[0] };
        sub check { my ($c, $t) = @_; print(($c ? "ok" : "not ok"), " $t\n"); }
        require PVE::Storage;
        check(1, "PVE::Storage loaded (APIVER " . PVE::Storage::APIVER() . ", APIAGE " . PVE::Storage::APIAGE() . ")");
        my $P = "PVE::Storage::Custom::PboPlugin";
        # on a host with the plugin installed, PVE::Storage has loaded and registered
        # it already (the shell checked it is the file of this checkout): test that one
        my $inst = PVE::Storage::Plugin->private()->{plugins}->{pbo} ? 1 : 0;
        if ($inst) {
            check(1, "type pbo registered by the installed plugin (" . ($INC{"PVE/Storage/Custom/PboPlugin.pm"} // "?") . ")");
        } else {
            eval { require "PboPlugin.pm"; 1 } or do { check(0, "require PboPlugin.pm: $@"); exit 1 };
            check(!PVE::Storage::Plugin->private()->{plugins}->{pbo}, "type pbo is not registered in this process (nothing installed)");
        }
        check($P->isa("PVE::Storage::Plugin"), "derived from the installed PVE::Storage::Plugin");
        my $api = $P->api(); my $min = PVE::Storage::APIVER() - PVE::Storage::APIAGE();
        check($api <= PVE::Storage::APIVER() && $api >= $min, "api() $api within $min.." . PVE::Storage::APIVER());
        check($api == PVE::Storage::APIVER(), "api() equals APIVER (no older-API warning on load)");
        my $props = PVE::Storage::Plugin->private()->{propertyList};
        my @missing = grep { !$props->{$_} } sort keys %{ $P->options() };
        check(!@missing, "every option is a registered base property" . (@missing ? " (missing: @missing)" : ""));
        check(!%{ $P->properties() }, "no own properties (no clash)");
        { no warnings "once"; $PVE::Storage::Custom::PboPlugin::CATALOG = "$W/catalog/index.json"; }
        my $cat = { type => "pbo", content => { backup => 1 } };
        my $spl = { type => "pbo", content => { backup => 1 }, path => "$W/spool" };
        my @pv = eval { $P->parse_volname("backup/$a1") };
        check(($pv[0] // "") eq "backup" && ($pv[2] // 0) == 101, "parse_volname");
        my $ai = eval { PVE::Storage::archive_info($a1) } // {};
        check($ai->{is_std_name} && $ai->{type} eq "lxc" && $ai->{vmid} == 101, "archive_info accepts pbo archive names");
        my $l = eval { $P->list_volumes("pbo", $cat, undef, ["backup"]) } // [];
        check(@$l == 2, "list_volumes (catalogue only): 2 entries" . ($@ ? ": $@" : ""));
        $l = eval { $P->list_volumes("pbo", $spl, undef, ["backup"]) } // [];
        check(@$l == 3 && grep({ $_->{volid} eq "pbo:backup/$s1" } @$l), "list_volumes with a path includes the spool archive");
        $l = eval { $P->list_volumes("pbo", $cat, 200, ["backup"]) } // [];
        check(@$l == 1 && $l->[0]->{subtype} eq "qemu", "list_volumes vmid filter");
        my ($sid, $vn) = eval { PVE::Storage::parse_volume_id("pbo:backup/$a1") };
        check(($vn // "") eq "backup/$a1", "PVE parse_volume_id accepts the volid");
        check((eval { $P->path($cat, "backup/$a1", "pbo") } // "") eq "$W/staging/$a1", "path: staging path from the index");
        check((eval { $P->path($spl, "backup/$s1", "pbo") } // "") eq "$W/spool/dump/$s1", "path: spool archive");
        eval { $P->get_subdir($cat, "backup") };
        check($@ =~ /storage definition has no path/, "installed get_subdir dies without a path");
        check((eval { $P->get_subdir($spl, "backup") } // "") eq "$W/spool/dump", "installed get_subdir with a path: <path>/dump");
        my @st = eval { $P->status("pbo", $spl) };
        check(($st[3] // 0) == 1 && ($st[0] // 0) > 0, "status: statvfs through the installed Filesys::Df");
        check(eval { $P->activate_storage("pbo", $spl); 1 }, "activate_storage with an existing path");
        eval { $P->free_image("pbo", $cat, "backup/$a1", 0, "tar") };
        check($@ =~ /managed by pbo/, "free_image refused");
        eval { $P->prune_backups($cat, "pbo", { "keep-last" => 1 }, undef, undef, 0) };
        check($@ =~ /retention is owned by pbo/, "prune_backups (real run) refused");
        { no warnings "once"; $PVE::Storage::Custom::PboPlugin::CATALOG = "$W/none.json"; }
        eval { $P->list_volumes("pbo", $cat, undef, ["backup"]) };
        check($@ =~ /pbo catalog missing or unreadable/, "list_volumes dies without an index");
        check(!@w, "no warnings" . (@w ? ": " . join(" | ", map { s/\n//r } @w) : ""));
    ' 2>&1)" || rc=$?
    local line
    while IFS= read -r line; do
        case "$line" in
            "ok "*)     ok "${line#ok }" ;;
            "not ok "*) bad "${line#not ok }" ;;
            *)          bad "unexpected output: $line" ;;
        esac
    done <<<"$out"
    (( rc == 0 )) || bad "perl exited $rc"
}

# ---------------------------------------------------------------------------
full() {
    [[ "${PBO_IT_PVE_STORAGE_FULL:-0}" == 1 ]] \
        || die "--full changes this host (storage.cfg): set PBO_IT_PVE_STORAGE_FULL=1 only with the host admin's OK"
    [[ "$(id -u)" == 0 ]] || die "--full must run as root"
    command -v pvesm >/dev/null 2>&1 || die "pvesm missing"
    [[ -f /usr/share/perl5/PVE/Storage/Custom/PboPlugin.pm ]] || die "the plugin is not installed (install.sh --integration both, or the pbo-pve-storage package)"
    local pbo; pbo="$(command -v pbo || true)"; [[ -n "$pbo" ]] || die "pbo not installed"
    "$pbo" catalog show >/dev/null 2>&1 || die "no readable catalogue: run 'pbo catalog refresh' first"
    printf 'pbo: storage plugin, full check on this host (temporary storage)\n'
    STORE="pbo-it-$$"
    pvesm add pbo "$STORE" --content backup --nodes "$(hostname)" >/dev/null 2>"$W/add.err" \
        && ok "pvesm add pbo $STORE" || { bad "pvesm add: $(cat "$W/add.err")"; STORE=""; return; }
    pvesm status --storage "$STORE" 2>/dev/null | awk -v s="$STORE" '$1==s && $3=="active"{f=1} END{exit !f}' \
        && ok "storage active" || bad "storage not active"
    local vol
    vol="$(pvesm list "$STORE" --content backup 2>/dev/null | awk 'NR>1 && $1 ~ /vzdump-lxc-/{v=$1} END{print v}')"
    [[ -n "$vol" ]] && ok "pvesm list shows archives (newest lxc: $vol)" || { bad "pvesm list shows no lxc archive"; return; }
    pvesm extractconfig "$vol" > "$W/conf" 2>"$W/extract.err" && grep -q '^arch:\|^rootfs:' "$W/conf" \
        && ok "extractconfig (Show Configuration) through materialize" || bad "extractconfig: $(tail -2 "$W/extract.err")"
    pvesm free "$vol" >/dev/null 2>"$W/free.err"; grep -q 'managed by pbo' "$W/free.err" && ok "pvesm free refused" || bad "pvesm free: $(cat "$W/free.err")"
    pvesm prune-backups "$STORE" --keep-last 1 --dry-run >/dev/null 2>&1 && ok "prune-backups --dry-run works" || bad "prune-backups --dry-run failed"
    pvesm prune-backups "$STORE" --keep-last 1 >/dev/null 2>"$W/prune.err"; grep -q 'retention is owned by pbo' "$W/prune.err" \
        && ok "prune-backups (real run) refused" || bad "prune-backups: $(cat "$W/prune.err")"
    pvesh set "/nodes/$(hostname)/storage/$STORE/content/$vol" --protected 0 >/dev/null 2>"$W/prot.err"
    grep -q 'retention is owned by pbo' "$W/prot.err" && ok "unprotect refused" || bad "unprotect: $(cat "$W/prot.err")"
    "$pbo" catalog release --all >/dev/null 2>&1 || true
}

case "$mode" in
    --load-only) load_only ;;
    --full)      full ;;
esac
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
