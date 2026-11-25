#!/usr/bin/perl
# tests/perl/10-plugin.t: PboPlugin.pm against a fixture index and spool, with the
# stubbed PVE modules (tests/perl/lib). Nothing here forks: run_command is a recorder.
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use JSON::PP;
use POSIX ();
use Test::More;
no warnings 'once';

BEGIN { $ENV{TZ} = 'UTC'; POSIX::tzset(); }

use PVE::Storage;
use PVE::Tools;
use Filesys::Df;
require "$FindBin::Bin/../../pve-plugin/PboPlugin.pm";

my $P = 'PVE::Storage::Custom::PboPlugin';
my $tmp = tempdir(CLEANUP => 1);

sub spew { my ($f, $c) = @_; open(my $fh, '>', $f) or die "$f: $!"; print $fh $c; close($fh); }

my $A1 = 'vzdump-lxc-101-2026_01_10-05_00_01.tar';   # cache + offsite
my $A2 = 'vzdump-lxc-101-2026_01_11-05_00_01.tar';   # offsite only
my $A3 = 'vzdump-qemu-200-2026_01_11-05_10_00.vma';  # cache only
my $S1 = 'vzdump-lxc-102-2026_01_12-01_30_00.tar';   # spool, not ingested
my $index = {
    version => 1, generated => 1_700_000_000, updated => 1_700_000_000, node => 'n1',
    storage_id => 'pbo', staging_dir => "$tmp/staging",
    tiers => { cache => { enabled => JSON::PP::true, ok => JSON::PP::true, count => 2 },
               offsite => { enabled => JSON::PP::true, ok => JSON::PP::true, count => 2 } },
    entries => [
        { volname => "backup/$A1", vmid => 101, type => 'lxc', ts => '2026_01_10-05_00_01', ctime => 1768021201,
          size => 1000, snapshots => { cache => 'aaaaaaaa', offsite => 'bbbbbbbb' }, keep => 'default', offsite_only => JSON::PP::false },
        { volname => "backup/$A2", vmid => 101, type => 'lxc', ts => '2026_01_11-05_00_01', ctime => 1768107601,
          size => 2000, snapshots => { cache => undef, offsite => 'cccccccc' }, keep => 'd30', offsite_only => JSON::PP::true },
        { volname => "backup/$A3", vmid => 200, type => 'qemu', ts => '2026_01_11-05_10_00', ctime => 1768108200,
          size => 3000, snapshots => { cache => 'dddddddd', offsite => undef }, keep => 'default', offsite_only => JSON::PP::false },
        { volname => 'backup/../../etc/shadow.tar', vmid => 1, type => 'lxc', size => 1, snapshots => {} },
    ],
};
my $idxfile = "$tmp/catalog/index.json";
mkdir("$tmp/catalog"); mkdir("$tmp/staging"); mkdir("$tmp/spool"); mkdir("$tmp/spool/dump");
spew($idxfile, encode_json($index));
$PVE::Storage::Custom::PboPlugin::CATALOG = $idxfile;
spew("$tmp/spool/dump/$S1", 'x' x 77);
spew("$tmp/spool/dump/vzdump-lxc-101-2026_01_12-01_30_00.tar.zst", 'z');   # compressed: not pbo's
spew("$tmp/spool/dump/vzdump-lxc-102-2026_01_12-01_30_00.log", 'log');
spew("$tmp/spool/dump/vzdump-lxc-104-2026_01_12-01_40_00.dat", 'partial'); # vzdump still writing
symlink("/etc/hostname", "$tmp/spool/dump/vzdump-lxc-103-2026_01_12-01_35_00.tar");

my $cat = { type => 'pbo', content => { backup => 1 } };                   # catalogue only
my $spl = { type => 'pbo', content => { backup => 1 }, path => "$tmp/spool" }; # backup target

my @warnings;
$SIG{__WARN__} = sub { push @warnings, $_[0] };

# --- parse_volname -----------------------------------------------------------
is_deeply([$P->parse_volname("backup/$A1")], ['backup', $A1, 101, undef, undef, undef, 'tar'], 'parse_volname lxc tar');
is_deeply([$P->parse_volname("backup/$A3")], ['backup', $A3, 200, undef, undef, undef, 'vma'], 'parse_volname qemu vma');
for my $bad ("backup/$A1.zst", "backup/vzdump-openvz-101-2026_01_10-05_00_01.tar", 'backup/foo.tar',
             "images/$A1", "backup/../$A1", "backup/$A1/x", "101/vm-101-disk-0.raw", '') {
    eval { $P->parse_volname($bad) };
    like($@, qr/unable to parse pbo volume name/, "parse_volname refuses '$bad'");
}

# --- list_volumes --------------------------------------------------------------
my $l = $P->list_volumes('pbo', $cat, undef, ['backup']);
is(scalar(@$l), 3, 'catalogue only: the 3 valid index entries (the bad volname is skipped)');
my %by = map { $_->{volid} => $_ } @$l;
is_deeply($by{"pbo:backup/$A1"}, { volid => "pbo:backup/$A1", content => 'backup', format => 'tar', size => 1000,
    ctime => 1768021201, vmid => 101, subtype => 'lxc', notes => 'pbo: cache+offsite', protected => 1 }, 'entry fields (cache+offsite)');
is($by{"pbo:backup/$A2"}->{notes}, 'pbo: offsite only', 'offsite-only note');
is($by{"pbo:backup/$A3"}->{notes}, 'pbo: cache only', 'cache-only note');
is($by{"pbo:backup/$A3"}->{subtype}, 'qemu', 'qemu subtype');
is($by{"pbo:backup/$A3"}->{format}, 'vma', 'vma format');
is_deeply([sort map { $_->{volid} } $P->list_volumes('pbo', $cat, 101, ['backup'])->@*],
    ["pbo:backup/$A1", "pbo:backup/$A2"], 'vmid filter');
is_deeply($P->list_volumes('pbo', $cat, 999, ['backup']), [], 'vmid filter: no match is an empty list');
is_deeply($P->list_volumes('pbo', $cat, undef, ['images', 'rootdir']), [], 'non-backup content: empty');

$l = $P->list_volumes('pbo', $spl, undef, ['backup']);
is(scalar(@$l), 4, 'with a path: index entries plus one spool archive');
my ($sp) = grep { $_->{volid} eq "pbo:backup/$S1" } @$l;
ok($sp, 'spool archive listed');
is($sp->{notes}, 'pbo: not ingested yet', 'spool note');
is($sp->{size}, 77, 'spool size from stat');
is($sp->{ctime}, 1768181400, 'spool ctime from the archive name');
is($sp->{vmid}, 102, 'spool vmid');
ok(!grep({ $_->{volid} =~ /zst|\.log|\.dat|-103-/ } @$l), 'compressed, log, partial and symlinked spool files are not listed');
is_deeply([map { $_->{volid} } $P->list_volumes('pbo', $spl, 102, ['backup'])->@*], ["pbo:backup/$S1"], 'vmid filter covers the spool');

# --- path ----------------------------------------------------------------------
is($P->path($cat, "backup/$A1", 'pbo'), "$tmp/staging/$A1", 'path: staging path from the index');
is($P->path($cat, "backup/$A1", 'pbo'), $P->path($cat, "backup/$A1", 'pbo'), 'path is deterministic');
is_deeply([$P->path($cat, "backup/$A1", 'pbo')], ["$tmp/staging/$A1", 101, 'backup'], 'path in list context: (path, vmid, vtype)');
is($P->path($spl, "backup/$S1", 'pbo'), "$tmp/spool/dump/$S1", 'path: a spool archive is used where it is');
is($P->path($spl, "backup/vzdump-lxc-103-2026_01_12-01_35_00.tar", 'pbo'), "$tmp/staging/vzdump-lxc-103-2026_01_12-01_35_00.tar",
    'path: a symlink in the spool is not used');
is($P->filesystem_path($cat, "backup/$A1"), "$tmp/staging/$A1", 'filesystem_path = path');
eval { $P->path($cat, "backup/$A1", 'pbo', 'snap1') };
like($@, qr/snapshots are not supported/, 'path refuses a snapshot');

# --- get_subdir (base behaviour) ---------------------------------------------
eval { $P->get_subdir($cat, 'backup') };
like($@, qr/storage definition has no path/, 'get_subdir dies without a path (no job can target a catalogue-only storage)');
is($P->get_subdir($spl, 'backup'), "$tmp/spool/dump", 'get_subdir with a path: <path>/dump');

# --- status / activate_storage ------------------------------------------------
@Filesys::Df::CALLS = ();
is_deeply([$P->status('pbo', $spl)], [1000, 600, 400, 1], 'status: statvfs of the path, active');
is($Filesys::Df::CALLS[-1], "$tmp/spool", 'status stats the path');
is_deeply([$P->status('pbo', $cat)], [1000, 600, 400, 1], 'status without a path: active');
is($Filesys::Df::CALLS[-1], "$tmp/catalog", 'status without a path stats the catalogue directory');

ok($P->activate_storage('pbo', $cat), 'activate_storage without a path');
mkdir("$tmp/newspool");
ok($P->activate_storage('pbo', { %$spl, path => "$tmp/newspool" }), 'activate_storage with an existing path');
ok(-d "$tmp/newspool/dump", 'activate_storage creates <path>/dump');
eval { $P->activate_storage('pbo', { %$spl, path => "$tmp/missing" }) };
like($@, qr/directory '\Q$tmp\E\/missing' does not exist/, 'activate_storage dies on a missing path');
{
    local $PVE::Storage::Custom::PboPlugin::CATALOG = "$tmp/none.json";
    my $ok = eval { $P->activate_storage('pbo', $cat); 1 };
    ok($ok, 'activate_storage never dies over the catalogue');
    is_deeply([$P->status('pbo', $cat)], [1000, 600, 400, 1], 'status never dies over the catalogue');
}
is(scalar(@warnings), 0, 'read side printed no warnings') or diag(join('', @warnings));
is(scalar(@PVE::Tools::CALLS), 0, 'read side ran no command (parse_volname, list_volumes, path, status, activate_storage)');

# --- missing or broken index ------------------------------------------------------
{
    local $PVE::Storage::Custom::PboPlugin::CATALOG = "$tmp/none.json";
    eval { $P->list_volumes('pbo', $cat, undef, ['backup']) };
    like($@, qr/^pbo catalog missing or unreadable, run: pbo catalog refresh/, 'list_volumes dies when the index is missing');
    eval { $P->path($cat, "backup/$A1", 'pbo') };
    like($@, qr/pbo catalog missing or unreadable/, 'path dies when the index is missing');
}
for my $junk ('', 'not json', '[]', '{"version":2,"entries":[]}', '{"version":1}') {
    my $f = "$tmp/junk.json"; spew($f, $junk);
    local $PVE::Storage::Custom::PboPlugin::CATALOG = $f;
    eval { $P->list_volumes('pbo', $cat, undef, ['backup']) };
    like($@, qr/pbo catalog missing or unreadable/, "list_volumes dies on an index of '$junk'");
}
{
    my $f = "$tmp/nostaging.json"; my %i = %$index; delete $i{staging_dir}; spew($f, encode_json(\%i));
    local $PVE::Storage::Custom::PboPlugin::CATALOG = $f;
    eval { $P->path($cat, "backup/$A1", 'pbo') };
    like($@, qr/no staging_dir/, 'path dies when the index has no staging_dir');
}

# --- sizes ----------------------------------------------------------------------
is(scalar($P->volume_size_info($cat, 'pbo', "backup/$A2")), 2000, 'volume_size_info from the index');
is_deeply([$P->volume_size_info($cat, 'pbo', "backup/$A3")], [3000, 'vma', 3000, undef], 'volume_size_info list context');
is(scalar($P->volume_size_info($spl, 'pbo', "backup/$S1")), 77, 'volume_size_info of a spool archive');

# --- nothing in PVE may delete ---------------------------------------------------
eval { $P->free_image('pbo', $cat, "backup/$A1", 0, 'tar') };
like($@, qr/managed by pbo/, 'free_image dies with the pbo text');
eval { $P->prune_backups($cat, 'pbo', { 'keep-last' => 1 }, undef, undef, 0) };
like($@, qr/retention is owned by pbo/, 'prune_backups (real run) dies with the pbo text');
my $pr = $P->prune_backups($spl, 'pbo', { 'keep-last' => 1 }, undef, undef, 1);
is(scalar(@$pr), 4, 'prune dry run lists every archive');
ok(!grep({ $_->{mark} ne 'protected' } @$pr), "prune dry run marks every archive 'protected' (nothing to remove)");
is_deeply((grep { $_->{volid} eq "pbo:backup/$A1" } @$pr)[0],
    { volid => "pbo:backup/$A1", ctime => 1768021201, type => 'lxc', vmid => 101, mark => 'protected' }, 'prune entry shape');
is_deeply([sort map { $_->{volid} } $P->prune_backups($cat, 'pbo', {}, 101, undef, 1)->@*],
    ["pbo:backup/$A1", "pbo:backup/$A2"], 'prune dry run: vmid filter');
is_deeply([map { $_->{volid} } $P->prune_backups($cat, 'pbo', {}, undef, 'qemu', 1)->@*],
    ["pbo:backup/$A3"], 'prune dry run: type filter');

# --- attributes ------------------------------------------------------------------
is($P->get_volume_attribute($cat, 'pbo', "backup/$A1", 'protected'), 1, 'protected is reported as 1');
is($P->get_volume_attribute($cat, 'pbo', "backup/$A1", 'notes'), undef, 'notes are not kept');
my $r = eval { $P->update_volume_attribute($cat, 'pbo', "backup/$A1", 'notes', 'hello'); 1 };
ok($r, 'notes are accepted and dropped');
eval { $P->update_volume_attribute($cat, 'pbo', "backup/$A1", 'protected', 0) };
like($@, qr/retention is owned by pbo/, 'changing protection is refused');
eval { $P->update_volume_attribute($cat, 'pbo', "backup/$A1", 'other', 1) };
like($@, qr/not supported/, 'unknown attribute is refused');

# --- refused operations ---------------------------------------------------------------
for my $m (qw(alloc_image clone_image create_base rename_volume volume_resize volume_snapshot
              volume_snapshot_rollback volume_snapshot_delete volume_export volume_import)) {
    eval { $P->$m('pbo', $cat, "backup/$A1") };
    like($@, qr/not supported on pbo storage/, "$m dies cleanly");
}
is($P->volume_has_feature($cat, 'copy', 'pbo', "backup/$A1"), undef, 'volume_has_feature: none');
is_deeply($P->list_images('pbo', $cat), [], 'list_images: none');
is($P->check_connection('pbo', $cat), 1, 'check_connection');
ok($P->deactivate_volume('pbo', $cat, "backup/$A1"), 'deactivate_volume is a no-op');

# --- activate_volume ---------------------------------------------------------------
my $fakebin = "$tmp/pbo"; spew($fakebin, "#!/bin/sh\nexit 99\n"); chmod(0755, $fakebin);
@PVE::Storage::Custom::PboPlugin::PBO_BIN = ("$tmp/nonexistent", $fakebin);
my $dpkg = "$tmp/dpkg-status";
spew($dpkg, join("\n",
    "Package: pve-manager\nStatus: install ok installed\nVersion: 9.2.32\n",
    "Package: libpve-storage-perl\nStatus: install ok installed\nVersion: 9.1.18\n",
    "Package: qemu-server\nStatus: install ok installed\nVersion: 9.2.20\n",
    "Package: pve-container\nStatus: install ok installed\nVersion: 6.1.24\n",
    "Package: unrelated\nStatus: install ok installed\nVersion: 99\n"));
$PVE::Storage::Custom::PboPlugin::DPKG_STATUS = $dpkg;

my $stage = sub {   # a pbo that stages the archive and prints its JSON result
    my ($cmd, $p) = @_;
    my $name = $cmd->[-1];
    spew("$tmp/staging/$name", 'archive');
    $p->{outfunc}->(encode_json({ schema => 1, status => 'ok', ok => JSON::PP::true, path => "$tmp/staging/$name", method => 'dump' }));
    return 0;
};
@PVE::Tools::CALLS = (); @warnings = ();
$PVE::Tools::RUN_HOOK = $stage;
ok(eval { $P->activate_volume('pbo', $cat, "backup/$A1") }, 'activate_volume materializes') or diag($@);
is(scalar(@PVE::Tools::CALLS), 1, 'one command');
is_deeply($PVE::Tools::CALLS[0][0], [$fakebin, '--json', 'catalog', 'materialize', $A1], 'it is pbo --json catalog materialize <archive> (first existing pbo)');
ok($PVE::Tools::CALLS[0][1]->{timeout} > 0, 'with a timeout');
ok(-f $P->path($cat, "backup/$A1", 'pbo'), 'path() is a regular file afterwards');
is(scalar(@warnings), 0, 'tested versions: no drift warning') or diag(join('', @warnings));

spew($dpkg, "Package: pve-manager\nStatus: install ok installed\nVersion: 9.2.40\n\nPackage: qemu-server\nStatus: deinstall ok config-files\nVersion: 9.9.9\n");
@warnings = ();
$P->activate_volume('pbo', $cat, "backup/$A3");
is(scalar(@warnings), 1, 'one drift warning for a newer pve-manager (removed packages ignored)');
like($warnings[0] // '', qr/pve-manager 9\.2\.40 is newer .*9\.2\.32/, 'drift warning names package and versions');

@PVE::Tools::CALLS = ();
ok($P->activate_volume('pbo', $spl, "backup/$S1"), 'activate_volume of a spool archive');
is(scalar(@PVE::Tools::CALLS), 0, 'a spool archive needs no materialize');

@PVE::Tools::CALLS = ();
eval { $P->activate_volume('pbo', $cat, 'backup/vzdump-lxc-555-2026_01_01-00_00_00.tar') };
like($@, qr/not in the pbo catalog/, 'an archive missing from the index is refused');
is(scalar(@PVE::Tools::CALLS), 0, '... without running pbo');

$PVE::Tools::RUN_HOOK = sub {
    my ($cmd, $p) = @_;
    $p->{errfunc}->('[ERROR] catalog: restic dump failed');
    $p->{outfunc}->('{"schema":1,"status":"error","ok":false,"exit":69,"error":"catalog: restic dump of x from offsite failed"}');
    return 69;
};
eval { $P->activate_volume('pbo', $cat, "backup/$A2") };
like($@, qr/materialize \Q$A2\E failed: catalog: restic dump of x from offsite failed/, 'a failing materialize dies with pbo\'s error');

$PVE::Tools::RUN_HOOK = sub { $_[1]->{errfunc}->('boom'); return 1 };
eval { $P->activate_volume('pbo', $cat, "backup/$A2") };
like($@, qr/materialize \Q$A2\E failed: boom/, 'no JSON: the last stderr line');

$PVE::Tools::RUN_HOOK = sub { die "command 'pbo' failed: got timeout\n" };
eval { $P->activate_volume('pbo', $cat, "backup/$A2") };
like($@, qr/materialize \Q$A2\E failed: .*timeout/, 'a timeout dies cleanly');

$PVE::Tools::RUN_HOOK = sub {
    $_[1]->{outfunc}->(encode_json({ ok => JSON::PP::true, path => "/elsewhere/$A2" }));
    return 0;
};
eval { $P->activate_volume('pbo', $cat, "backup/$A2") };
like($@, qr/catalogue says/, 'a materialize into another staging dir is refused');

$PVE::Tools::RUN_HOOK = sub {
    $_[1]->{outfunc}->(encode_json({ ok => JSON::PP::true, path => "$tmp/staging/$A1" }));
    return 0;
};
eval { $P->activate_volume('pbo', $cat, "backup/$A2") };
like($@, qr/expected an archive named/, 'a materialize that returns another archive is refused');

$PVE::Tools::RUN_HOOK = sub {
    $_[1]->{outfunc}->(encode_json({ ok => JSON::PP::true, path => "$tmp/staging/$A2" }));
    return 0;   # claims success, writes nothing
};
unlink("$tmp/staging/$A2");
eval { $P->activate_volume('pbo', $cat, "backup/$A2") };
like($@, qr/not a regular file/, 'the staged file must exist');

$PVE::Tools::RUN_HOOK = sub {
    spew("$tmp/staging/$A2", 'archive');
    $_[1]->{outfunc}->(encode_json({ ok => JSON::PP::true, path => "$tmp/staging//$A2" }));
    return 0;
};
ok(eval { $P->activate_volume('pbo', $cat, "backup/$A2") }, 'a doubled slash in the staged path is the same path') or diag($@);

# --- a synchronous API request (Show Configuration, Restore dialog, QEMU restore) ---
unlink("$tmp/staging/$A2");
@PVE::Tools::CALLS = ();
$PVE::Tools::RUN_HOOK = $stage;
ok(eval { $P->activate_volume('pbo', $cat, "backup/$A2") }, 'no REST environment (CLI tool): materializes') or diag($@);
is_deeply($PVE::Tools::CALLS[0][0], [$fakebin, '--json', 'catalog', 'materialize', $A2], '... and waits for it (no --background)');
is($PVE::Tools::CALLS[0][1]->{timeout}, $PVE::Storage::Custom::PboPlugin::MATERIALIZE_TIMEOUT, '... with the long timeout');

{
    no warnings 'once';
    local $PVE::RESTEnvironment::TYPE = 'priv';
    local $PVE::RESTEnvironment::WORKER = 0;
    @PVE::Tools::CALLS = ();
    $P->activate_volume('pbo', $cat, "backup/$A2");
    is_deeply($PVE::Tools::CALLS[0][0], [$fakebin, '--json', 'catalog', 'materialize', '--background', $A2],
        'pvedaemon request (not a worker): materialize --background');
    ok($PVE::Tools::CALLS[0][1]->{timeout} < 30, '... with a timeout below pveproxy\'s 30 s');

    local $PVE::RESTEnvironment::TYPE = 'pub';
    @PVE::Tools::CALLS = ();
    $P->activate_volume('pbo', $cat, "backup/$A2");
    is($PVE::Tools::CALLS[0][0][4], '--background', 'pveproxy request: --background too');

    local $PVE::RESTEnvironment::TYPE = 'priv';
    local $PVE::RESTEnvironment::WORKER = 1;
    @PVE::Tools::CALLS = ();
    $P->activate_volume('pbo', $cat, "backup/$A2");
    is_deeply($PVE::Tools::CALLS[0][0], [$fakebin, '--json', 'catalog', 'materialize', $A2], 'inside a forked task (LXC restore): waits');

    local $PVE::RESTEnvironment::TYPE = 'cli';
    local $PVE::RESTEnvironment::WORKER = 0;
    @PVE::Tools::CALLS = ();
    $P->activate_volume('pbo', $cat, "backup/$A2");
    is_deeply($PVE::Tools::CALLS[0][0], [$fakebin, '--json', 'catalog', 'materialize', $A2], 'a CLI (qmrestore): waits');
}

$PVE::Storage::Custom::PboPlugin::SYNC_CONTEXT = 1;
$PVE::Tools::RUN_HOOK = sub {
    $_[1]->{outfunc}->('{"schema":1,"status":"error","ok":false,"exit":75,"error":"pbo started staging ' . $A2 . ' from the offsite repo (snapshot cccccccc) in the background; retry in a few minutes"}');
    return 75;
};
eval { $P->activate_volume('pbo', $cat, "backup/$A2") };
like($@, qr/^pbo started staging \Q$A2\E .*retry in a few minutes$/, 'not staged yet: the request fails at once with pbo\'s "retry" message');
$PVE::Tools::RUN_HOOK = sub { $_[1]->{errfunc}->('boom'); return 1 };
eval { $P->activate_volume('pbo', $cat, "backup/$A2") };
like($@, qr/materialize \Q$A2\E failed: boom/, 'another failure in a request: the usual error');
$PVE::Storage::Custom::PboPlugin::SYNC_CONTEXT = undef;

@PVE::Storage::Custom::PboPlugin::PBO_BIN = ("$tmp/nonexistent");
eval { $P->activate_volume('pbo', $cat, "backup/$A2") };
like($@, qr/pbo not found/, 'no pbo binary: clear error');

eval { $P->activate_volume('pbo', $cat, "backup/$A1", 'snap') };
like($@, qr/snapshots are not supported/, 'activate_volume refuses a snapshot');

done_testing();
