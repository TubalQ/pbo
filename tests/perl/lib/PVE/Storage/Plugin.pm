package PVE::Storage::Plugin;
# Test stub (tests/perl) of the base storage plugin, with the semantics
# PboPlugin.pm relies on (libpve-storage-perl 9.1.18, Storage/Plugin.pm):
#   - get_subdir dies "storage definition has no path" without a path and maps
#     backup -> <path>/dump (content-dirs honoured);
#   - get_volume_attribute returns undef, update_volume_attribute dies.
# Base methods that would touch files (free_image, prune_backups, path, status,
# list_volumes, activate_*) die with "stub: base ... reached": the plugin must
# override every one of them.
use strict;
use warnings;

my $vtype_subdirs = {
    images => 'images',
    rootdir => 'private',
    iso => 'template/iso',
    vztmpl => 'template/cache',
    backup => 'dump',
    snippets => 'snippets',
    import => 'import',
};

sub get_vtype_subdirs { return $vtype_subdirs }

sub get_subdir {
    my ($class, $scfg, $vtype) = @_;
    my $path = $scfg->{path};
    die "storage definition has no path\n" if !$path;
    die "unknown vtype '$vtype'\n" if !exists($vtype_subdirs->{$vtype});
    my $subdir = $scfg->{'content-dirs'}->{$vtype} // $vtype_subdirs->{$vtype};
    return "$path/$subdir";
}

sub plugindata { return {} }
sub properties { return {} }
sub options { return {} }

sub get_volume_attribute { return }

sub update_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute, $value) = @_;
    die "attribute '$attribute' is not supported for storage type '$scfg->{type}'\n";
}

for my $m (qw(free_image prune_backups path filesystem_path status list_volumes list_images
    activate_storage activate_volume volume_size_info parse_volname alloc_image)) {
    no strict 'refs';
    *{"PVE::Storage::Plugin::$m"} = sub { die "stub: base $m reached\n" };
}

sub check_connection { return 1 }
sub deactivate_storage { return }
sub deactivate_volume { return }

1;
