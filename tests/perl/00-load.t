#!/usr/bin/perl
# tests/perl/00-load.t: PboPlugin.pm loads next to the stubbed PVE modules and
# declares what ADR 0006 says (type, api, content, options without new properties).
use strict;
use warnings;
use FindBin;
use Test::More;
no warnings 'once';

use PVE::Storage;
require "$FindBin::Bin/../../pve-plugin/PboPlugin.pm";

my $P = 'PVE::Storage::Custom::PboPlugin';

ok($P->isa('PVE::Storage::Plugin'), 'derived from PVE::Storage::Plugin');
is($P->type(), 'pbo', "type is 'pbo'");
my $api = $P->api();
ok($api >= 11 && $api <= 17, "api() $api is within 11..17");
is($api, 17, 'api() follows APIVER 17');
ok($api >= PVE::Storage::APIVER() - PVE::Storage::APIAGE(), 'api() is not older than APIVER - APIAGE');

my $pd = $P->plugindata();
is_deeply($pd->{content}, [{ backup => 1 }, { backup => 1 }], 'content: backup only, default backup');
ok(!exists($pd->{format}), 'no format in plugindata (backups only)');
ok(!$pd->{features} || !$pd->{features}->{'backup-provider'}, 'not a backup provider');
ok(!$pd->{'isolate-properties'}, 'no isolate-properties');

is_deeply($P->properties(), {}, 'no own properties (path/nodes/disable/content are the base plugin\'s)');
my $o = $P->options();
is_deeply([sort keys %$o], [qw(content disable nodes path)], 'options: path, nodes, disable, content');
ok($o->{path}->{optional} && !$o->{path}->{fixed}, 'path is optional and not fixed');
ok(!exists($o->{'prune-backups'}), 'no prune-backups option');

is($PVE::Storage::Custom::PboPlugin::CATALOG, '/var/lib/pbo/catalog/index.json', 'catalogue path');
is_deeply(\@PVE::Storage::Custom::PboPlugin::PBO_BIN, ['/usr/sbin/pbo', '/usr/local/sbin/pbo'], 'pbo binary: .deb path first, then install.sh path');
is_deeply(\%PVE::Storage::Custom::PboPlugin::TESTED,
    { 'pve-manager' => '9.2.41', 'libpve-storage-perl' => '9.1.25', 'qemu-server' => '9.2.24', 'pve-container' => '6.1.28' },
    'tested version set');

done_testing();
