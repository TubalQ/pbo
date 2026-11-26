#!/usr/bin/perl
# tests/perl/index-compat.pl <plugin.pm> <dir> [<index.json>]: a PboPlugin.pm
# (tests/perl.sh and tests/names.sh run it with the frozen 0.6.1 copy,
# tests/perl/fixtures/PboPlugin-0.6.1.pm, and with this one) reads an index
# with the name field each entry has since 0.6.2: it loads, lists every entry
# and shows its tier notes (the field is ignored by the older plugin, not an
# error). The index stays version 1.
# Without <index.json> the index is a hand-built one written to <dir>, with
# known names and tiers. With it, the index is one pbo wrote (`pbo catalog
# refresh` in tests/names.sh), copied to <dir>: what pbo really produces must
# load too, not only what this file thinks it produces.
use strict;
use warnings;
use JSON::PP;
use Test::More;
no warnings 'once';

my ($plugin, $dir, $written) = @ARGV;
die "usage: index-compat.pl <plugin.pm> <dir> [<index.json>]\n" if !$plugin || !$dir || !-d $dir;
require $plugin;
my $P = 'PVE::Storage::Custom::PboPlugin';

sub _list {
    return eval { $P->list_volumes('pbo', { type => 'pbo', content => { backup => 1 } }, undef, ['backup']) };
}

if (defined($written)) {
    my $raw;
    {
        open(my $in, '<', $written) or die "$written: $!\n";
        local $/;
        $raw = <$in>;
        close($in);
    }
    my $idx = JSON::PP->new->utf8->decode($raw);
    # the check is only worth something when pbo wrote names into it
    my @named = grep { ref($_) eq 'HASH' && exists($_->{name}) } ($idx->{entries} // [])->@*;
    ok(@named > 0, 'the index pbo wrote has entries with a name field');
    open(my $fh, '>', "$dir/index.json") or die "$dir/index.json: $!";
    print $fh $raw;
    close($fh);
    $PVE::Storage::Custom::PboPlugin::CATALOG = "$dir/index.json";
    my $l = _list();
    ok($l, 'the plugin loads the index pbo wrote') or diag($@);
    is(scalar(($l // [])->@*), scalar(($idx->{entries} // [])->@*), 'every entry is listed');
    my @bad = grep { ($_->{notes} // '') !~ /(?:cache\+offsite|cache only|offsite only)$/ } ($l // [])->@*;
    is(scalar(@bad), 0, 'every entry shows its tier notes')
        or diag(join("\n", map { "$_->{volid}: " . ($_->{notes} // '(none)') } @bad));
    done_testing();
    exit;
}

my $A1 = 'vzdump-lxc-101-2026_01_10-05_00_01.tar';
my $A2 = 'vzdump-qemu-200-2026_01_11-05_10_00.vma';
my $index = {
    version => 1, generated => 1_700_000_000, updated => 1_700_000_000, node => 'n1',
    storage_id => 'pbo', staging_dir => "$dir/staging", spool_dir => '',
    tiers => { cache => { enabled => JSON::PP::true, ok => JSON::PP::true, count => 2 },
               offsite => { enabled => JSON::PP::true, ok => JSON::PP::true, count => 1 } },
    entries => [
        { volname => "backup/$A1", vmid => 101, type => 'lxc', ts => '2026_01_10-05_00_01', ctime => 1768021201,
          size => 1000, snapshots => { cache => 'aaaaaaaa', offsite => 'bbbbbbbb' }, keep => 'default',
          offsite_only => JSON::PP::false, name => 'web01' },
        { volname => "backup/$A2", vmid => 200, type => 'qemu', ts => '2026_01_11-05_10_00', ctime => 1768108200,
          size => 3000, snapshots => { cache => 'dddddddd', offsite => undef }, keep => 'default',
          offsite_only => JSON::PP::false, name => "caf\x{e9} 1" },
    ],
};
open(my $fh, '>', "$dir/index.json") or die "$dir/index.json: $!";
print $fh JSON::PP->new->utf8->encode($index);
close($fh);
$PVE::Storage::Custom::PboPlugin::CATALOG = "$dir/index.json";

my $l = _list();
ok($l, 'the plugin loads an index with name fields') or diag($@);
my %n = map { $_->{volid} => $_->{notes} } ($l // [])->@*;
is(scalar(keys %n), 2, 'every entry is listed');
like($n{"pbo:backup/$A1"} // '', qr/cache\+offsite/, 'the tier notes as before');
like($n{"pbo:backup/$A2"} // '', qr/cache only/, 'the tier notes as before (qemu)');
done_testing();
