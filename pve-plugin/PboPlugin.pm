package PVE::Storage::Custom::PboPlugin;

# pbo storage plugin for Proxmox VE (ADR 0006, catalogue first; ADR 0007).
#
# A storage of type 'pbo' shows pbo's restic snapshots as ordinary vzdump
# archives: PVE lists them, shows their configuration and restores them through
# its normal file-archive path. It does NOT set the backup-provider feature.
#
# Read side (pvestatd, the Backups tab): status, activate_storage, list_volumes,
# parse_volname and path never fork, never touch the network and never touch a
# FUSE mount. They read the index pbo writes ($CATALOG, `pbo catalog refresh`)
# and, when the storage has a `path`, the spool directory <path>/dump that PVE
# backup jobs write to.
#
# Restore and Show Configuration: activate_volume runs
# `pbo --json catalog materialize <archive>`, which stages the archive at
# <staging_dir>/<archive> (staging_dir comes from the index); path() returns that
# file. An archive still in the spool (written by a PVE job, not ingested yet) is
# used where it is.
# Staging can take minutes to hours (restic dump of a whole archive). Inside a
# forked task (LXC restore) activate_volume waits for it. Inside a synchronous
# API request it must not: Show Configuration and the Restore dialog
# (GET .../vzdump/extractconfig) and a QEMU restore (create_vm resolves the
# archive before it forks its worker) run in one of pvedaemon's three workers,
# and pveproxy gives up after 30 s while the worker would go on copying. There
# it runs `materialize --background` with a short timeout: a staged archive is
# used at once, otherwise pbo stages it detached and the request fails with
# "retry in a few minutes". `pbo catalog release` (pbo-catalog.service, every
# 15 minutes) removes staged archives after PVE_STAGING_TTL.
#
# Nothing in PVE can delete or change a pbo backup: free_image, prune_backups
# (real run) and protection changes die; notes are accepted and dropped (a job's
# notes-template would otherwise warn in every task log); every volume reports
# protected = 1. Retention is pbo's (`pbo prune`).
#
# Installed as /usr/share/perl5/PVE/Storage/Custom/PboPlugin.pm by the
# pbo-pve-storage package or by `install.sh --integration both|integrated`.
# Tests: tests/perl/*.t (stubbed PVE modules), tests/integration/pve-storage.sh
# (the real PVE libraries).

use strict;
use warnings;

use Fcntl qw(S_ISREG);
use File::Basename qw(basename);
use JSON::PP ();
use Time::Local qw(timelocal);

use PVE::Tools qw(run_command);
use PVE::Storage::Plugin;

use base qw(PVE::Storage::Plugin);

# The index pbo writes (PBO_CATALOG); a fixed path, overridden only in tests.
our $CATALOG = '/var/lib/pbo/catalog/index.json';
# The pbo program: the .deb puts it in /usr/sbin, install.sh in /usr/local/sbin.
our @PBO_BIN = ('/usr/sbin/pbo', '/usr/local/sbin/pbo');
# How long one `pbo catalog materialize` may take (restic dump of a large archive
# from offsite is slow; the mount path is fast).
our $MATERIALIZE_TIMEOUT = 4 * 3600;
# How long it may take inside a synchronous API request (pveproxy gives up on a
# proxied request after 30 s, PVE/APIServer/AnyEvent.pm).
our $SYNC_TIMEOUT = 20;
# undef: tell a synchronous API request from the REST environment; tests set 0/1.
our $SYNC_CONTEXT;
# Where installed package versions are read from (no fork); for the drift warning.
our $DPKG_STATUS = '/var/lib/dpkg/status';
# The package versions this plugin was last verified against (load-only and full
# smoke tests). activate_volume warns in the task log when one installed is newer.
our %TESTED = (
    'pve-manager' => '9.2.32',
    'libpve-storage-perl' => '9.1.18',
    'qemu-server' => '9.2.20',
    'pve-container' => '6.1.24',
);

# pbo's archive names (lib/catalog.sh CATALOG_BASENAME_RE): uncompressed vzdump
# tar/vma with the standard timestamp, so PVE's archive_info accepts them.
my $ARCHIVE_RE = qr/vzdump-(lxc|qemu)-([0-9]+)-([0-9]{4})_([0-9]{2})_([0-9]{2})-([0-9]{2})_([0-9]{2})_([0-9]{2})\.(tar|vma)/;
my $VOLNAME_RE = qr!^backup/($ARCHIVE_RE)$!;

my $CATALOG_HINT = 'pbo catalog missing or unreadable, run: pbo catalog refresh';

# --- plugin definition -----------------------------------------------------

sub api {
    # PVE 9.1.18 has APIVER 17. Never claim more than the host offers (it would
    # refuse to load us) nor more than this plugin was written for.
    my $v = eval { PVE::Storage::APIVER() } // 17;
    return $v < 17 ? $v : 17;
}

sub type {
    return 'pbo';
}

sub plugindata {
    return {
        content => [{ backup => 1 }, { backup => 1 }],
        # no 'format': backups only, get_formats gives the default
    };
}

# No own properties: `path`, `nodes`, `disable` and `content` are the base
# plugin's (SectionConfig unified mode lets any registered property be listed in
# options). Declaring one again would clash; isolate-properties is not needed.
# `path` is optional and NOT fixed: `pvesm set <id> --path <spool>` turns a
# catalogue-only storage into a backup target, `--delete path` turns it back. No
# `prune-backups`: retention is pbo's, and vzdump's keep-all default applies.
sub options {
    return {
        path => { optional => 1 },
        nodes => { optional => 1 },
        disable => { optional => 1 },
        content => { optional => 1 },
    };
}

# --- helpers ---------------------------------------------------------------

# _untaint_path($p): an absolute path without NUL/newline or '..' components, untainted
# (pvedaemon runs under -T); undef otherwise.
sub _untaint_path {
    my ($p) = @_;
    return undef if !defined($p) || $p !~ m!^(/[^\0\n]*)$!;
    my $u = $1;
    return undef if $u =~ m!(^|/)\.\.(/|$)!;
    $u =~ s!/+$!! if length($u) > 1;
    return $u;
}

my $index_cache; # { key => "dev:ino:size:mtime", data => {...} }

# _read_index(): the parsed index, or die with the refresh hint. Cached per
# process by inode/size/mtime (pvedaemon is long-lived).
sub _read_index {
    my @st = stat($CATALOG);
    die "$CATALOG_HINT ($CATALOG: $!)\n" if !@st;
    my $key = join(':', @st[0, 1, 7, 9]);
    return $index_cache->{data} if $index_cache && $index_cache->{key} eq $key;

    my $raw;
    {
        open(my $fh, '<', $CATALOG) or die "$CATALOG_HINT ($CATALOG: $!)\n";
        local $/;
        $raw = <$fh>;
        close($fh);
    }
    my $data = eval { JSON::PP->new->utf8->decode($raw // '') };
    die "$CATALOG_HINT ($CATALOG: not valid JSON)\n" if !$data || ref($data) ne 'HASH';
    die "$CATALOG_HINT ($CATALOG: not a version 1 index)\n"
        if ($data->{version} // '') ne '1' || ref($data->{entries}) ne 'ARRAY';

    $index_cache = { key => $key, data => $data };
    return $data;
}

# _index_entry($idx, $volname): the index entry for one volume, or undef.
sub _index_entry {
    my ($idx, $volname) = @_;
    for my $e ($idx->{entries}->@*) {
        return $e if ref($e) eq 'HASH' && ($e->{volname} // '') eq $volname;
    }
    return undef;
}

# _spool_dir($scfg): <path>/dump when the storage has a path (where vzdump writes
# for this storage), undef otherwise.
sub _spool_dir {
    my ($class, $scfg) = @_;
    return undef if !$scfg->{path};
    my $dir = eval { $class->get_subdir($scfg, 'backup') };
    return _untaint_path($dir);
}

# _spool_file($scfg, $name): the archive in the spool if it is a regular file there.
sub _spool_file {
    my ($class, $scfg, $name) = @_;
    my $dir = $class->_spool_dir($scfg) // return undef;
    my $f = "$dir/$name";
    return (-f $f && !-l $f) ? $f : undef;
}

# _staging_file($name): <staging_dir>/<name>, staging_dir from the index.
sub _staging_file {
    my ($name) = @_;
    my $idx = _read_index();
    my $dir = _untaint_path($idx->{staging_dir});
    die "pbo catalog has no staging_dir, run: pbo catalog refresh\n" if !defined($dir);
    return "$dir/$name";
}

sub _notes_for {
    my ($e) = @_;
    my $snaps = ref($e->{snapshots}) eq 'HASH' ? $e->{snapshots} : {};
    my ($c, $o) = (defined($snaps->{cache}), defined($snaps->{offsite}));
    return 'pbo: offsite only' if $e->{offsite_only} || (!$c && $o);
    return 'pbo: cache+offsite' if $c && $o;
    return 'pbo: cache only';
}

sub _archive_ctime {
    my ($name) = @_;
    return undef if $name !~ m/^$ARCHIVE_RE$/;
    my $t = eval { timelocal($8, $7, $6, $5, $4 - 1, $3) };
    return $t;
}

sub _pbo_bin {
    for my $b (@PBO_BIN) {
        return $b if -f $b && -x $b;
    }
    return undef;
}

# _vercmp($a, $b): <0, 0, >0 for Debian-style versions made of digit runs
# (9.2.32, 9.1.18-1, 6.1.24~bpo1); enough to tell "newer than tested".
sub _vercmp {
    my ($x, $y) = @_;
    my @a = ($x // '') =~ m/(\d+)/g;
    my @b = ($y // '') =~ m/(\d+)/g;
    while (@a || @b) {
        my ($p, $q) = (shift(@a) // 0, shift(@b) // 0);
        return $p <=> $q if $p != $q;
    }
    return 0;
}

# _installed_versions(): { package => version } for the %TESTED packages, read
# from the dpkg status file (no fork). Empty when it cannot be read.
sub _installed_versions {
    my $res = {};
    open(my $fh, '<', $DPKG_STATUS) or return $res;
    local $/ = '';
    while (my $para = <$fh>) {
        next if $para !~ m/^Package: (\S+)$/m || !exists($TESTED{$1});
        my $pkg = $1;
        next if $para !~ m/^Status: \S+ \S+ installed$/m;
        $res->{$pkg} = $1 if $para =~ m/^Version: (\S+)$/m;
    }
    close($fh);
    return $res;
}

# _warn_version_drift(): one warning (task log) per installed package newer than
# the tested set. Only from activate_volume (a restore or Show Configuration):
# pvestatd calls activate_storage every cycle and would flood the journal.
sub _warn_version_drift {
    my $inst = _installed_versions();
    for my $pkg (sort keys %TESTED) {
        my $v = $inst->{$pkg} // next;
        warn "pbo: $pkg $v is newer than the version this plugin was tested with"
            . " ($TESTED{$pkg}); run tests/integration/pve-storage.sh after PVE upgrades\n"
            if _vercmp($v, $TESTED{$pkg}) > 0;
    }
    return;
}

# --- volumes ---------------------------------------------------------------

sub parse_volname {
    my ($class, $volname) = @_;

    if (defined($volname) && $volname =~ $VOLNAME_RE) {
        my ($name, $vmid, $fmt) = ($1, $3, $10);
        return ('backup', $name, $vmid, undef, undef, undef, $fmt);
    }
    die "unable to parse pbo volume name '" . ($volname // '') . "'\n";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;
    return $class->path($scfg, $volname, undef, $snapname);
}

# path(): the spool file if the archive is still there, else the deterministic
# staging path (the file exists only after activate_volume).
sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    die "volume snapshots are not supported on pbo storage\n" if defined($snapname);
    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    my $path = $class->_spool_file($scfg, $name) // _staging_file($name);
    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;

    my $res = [];
    return $res if !grep { $_ eq 'backup' } ($content_types // [])->@*;

    my $idx = _read_index();
    my %seen;
    for my $e ($idx->{entries}->@*) {
        next if ref($e) ne 'HASH';
        my $volname = $e->{volname} // '';
        next if $volname !~ $VOLNAME_RE;
        my ($name, $type, $evmid, $fmt) = ($1, $2, $3, $10);
        next if defined($vmid) && $evmid ne $vmid;
        $seen{$name} = 1;
        push @$res, {
            volid => "$storeid:$volname",
            content => 'backup',
            format => $fmt,
            size => int($e->{size} // 0),
            ctime => int($e->{ctime} // _archive_ctime($name) // 0),
            vmid => int($evmid),
            subtype => $type,
            notes => _notes_for($e),
            protected => 1,
        };
    }

    # archives a PVE job wrote to the spool that pbo has not ingested yet
    if (my $dir = $class->_spool_dir($scfg)) {
        if (opendir(my $dh, $dir)) {
            for my $fn (sort readdir($dh)) {
                next if $fn !~ m/^($ARCHIVE_RE)$/;
                my ($name, $type, $evmid, $fmt) = ($1, $2, $3, $10);
                next if $seen{$name};
                next if defined($vmid) && $evmid ne $vmid;
                my @st = lstat("$dir/$name");
                next if !@st || !S_ISREG($st[2]);
                push @$res, {
                    volid => "$storeid:backup/$name",
                    content => 'backup',
                    format => $fmt,
                    size => $st[7],
                    ctime => _archive_ctime($name) // $st[9],
                    vmid => int($evmid),
                    subtype => $type,
                    notes => 'pbo: not ingested yet',
                    protected => 1,
                };
            }
            closedir($dh);
        }
    }

    return $res;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    return []; # backups only
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my (undef, $name, undef, undef, undef, undef, $fmt) = $class->parse_volname($volname);
    my $size;
    if (my $f = $class->_spool_file($scfg, $name)) {
        $size = -s $f;
    } else {
        my $e = _index_entry(_read_index(), $volname)
            // die "volume '$storeid:$volname' is not in the pbo catalog (run: pbo catalog refresh)\n";
        $size = int($e->{size} // 0);
    }
    $size //= 0;
    return wantarray ? ($size, $fmt, $size, undef) : $size;
}

# --- storage ---------------------------------------------------------------

# status(): space of the spool filesystem (path set) or of the catalogue's
# directory. A statvfs only: no fork, no network, no FUSE.
sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $dir = _untaint_path($scfg->{path}) // do {
        (my $d = $CATALOG) =~ s!/[^/]*$!!;
        $d eq '' ? '/' : $d;
    };
    my $df = eval {
        require Filesys::Df;
        Filesys::Df::df($dir, 1);
    };
    if (!$df || ref($df) ne 'HASH') {
        return (0, 0, 0, 1);
    }
    my ($total, $avail, $used) = map { int($_ // 0) } $df->@{qw(blocks bavail used)};
    return ($total, $avail, $used, 1);
}

# activate_storage(): with a path, its directory must exist (vzdump writes to
# <path>/dump, created here like the base plugin does). Never reads the index,
# never dies over it and prints nothing: pvestatd calls this every cycle.
sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    if ($scfg->{path}) {
        my $path = $scfg->{path};
        die "unable to activate storage '$storeid' - directory '$path' does not exist\n"
            if !-d $path;
        if (my $dump = $class->_spool_dir($scfg)) {
            mkdir($dump, 0755) if !-d $dump;
        }
    }
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

sub check_connection {
    my ($class, $storeid, $scfg) = @_;
    return 1;
}

# _sync_request(): 1 when this runs inside a synchronous pvedaemon/pveproxy API
# request (environment type priv/pub, not a forked worker), where nothing may
# block for long. A CLI (qmrestore, pct restore) or a task worker may wait.
sub _sync_request {
    return $SYNC_CONTEXT ? 1 : 0 if defined($SYNC_CONTEXT);
    my $sync = eval {
        require PVE::RESTEnvironment;
        my $env = PVE::RESTEnvironment->get(); # dies when there is no environment
        return 0 if PVE::RESTEnvironment->is_worker();
        my $type = $env->{type} // ''; # cli|pub|priv|ha (RESTEnvironment::init)
        return ($type eq 'priv' || $type eq 'pub') ? 1 : 0;
    };
    return $sync ? 1 : 0;
}

# activate_volume(): make path() a regular file. A spool archive is already one;
# anything else is staged by `pbo catalog materialize` (in a synchronous API
# request: --background, see the header).
sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache, $hints) = @_;

    die "volume snapshots are not supported on pbo storage\n" if defined($snapname);
    my (undef, $name) = $class->parse_volname($volname);

    return 1 if $class->_spool_file($scfg, $name);

    _warn_version_drift();

    my $idx = _read_index();
    _index_entry($idx, $volname)
        // die "volume '$storeid:$volname' is not in the pbo catalog (run: pbo catalog refresh)\n";
    my $want = _staging_file($name);

    my $bin = _pbo_bin()
        // die "pbo not found (looked for " . join(', ', @PBO_BIN) . ")\n";

    my $sync = _sync_request();
    my (@out, @err);
    my $rc = eval {
        run_command(
            [$bin, '--json', 'catalog', 'materialize', ($sync ? ('--background') : ()), $name],
            timeout => $sync ? $SYNC_TIMEOUT : $MATERIALIZE_TIMEOUT,
            outfunc => sub { push @out, $_[0] if defined($_[0]) },
            errfunc => sub { push @err, $_[0] if defined($_[0]) },
            noerr => 1,
        );
    };
    if (my $err = $@) {
        chomp($err);
        die "pbo catalog materialize $name failed: $err\n";
    }

    my $res;
    for my $line (reverse @out) {
        next if $line !~ m/^\s*\{/;
        $res = eval { JSON::PP->new->decode($line) };
        last if ref($res) eq 'HASH';
        $res = undef;
    }
    if (($rc // 1) != 0 || !$res || !$res->{ok}) {
        my $why = ($res && $res->{error}) // ($err[-1] // "exit code " . ($rc // '?'));
        $why =~ s/\s+$//;
        # 75 (EX_TEMPFAIL) with --background: pbo is staging it, the caller retries
        die "$why\n" if $sync && ($rc // 0) == 75;
        die "pbo catalog materialize $name failed: $why\n";
    }

    (my $got = $res->{path} // '') =~ s!/+!/!g;
    die "pbo catalog materialize $name returned '$got', expected an archive named $name\n"
        if basename($got) ne $name;
    die "pbo staged $name at '$got' but the catalogue says '$want' (run: pbo catalog refresh)\n"
        if $got ne $want;
    die "pbo catalog materialize $name: '$want' is not a regular file\n" if !-f $want;

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    return 1; # `pbo catalog release` (pbo-catalog.service, TTL) cleans up staging
}

sub map_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $hints) = @_;
    my ($path) = $class->path($scfg, $volname, $storeid, $snapname);
    return $path;
}

sub unmap_volume {
    return 1;
}

# --- attributes and retention: owned by pbo ----------------------------------

sub get_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute) = @_;

    return 1 if $attribute eq 'protected';
    return undef; # notes are not kept
}

sub update_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute, $value) = @_;

    return undef if $attribute eq 'notes'; # accepted and dropped (job notes-template)
    die "pbo backups are always protected; retention is owned by pbo (pbo prune)\n"
        if $attribute eq 'protected';
    die "attribute '$attribute' is not supported for storage type 'pbo'\n";
}

sub get_volume_notes {
    return undef;
}

sub update_volume_notes {
    return undef;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $format) = @_;
    die "'$storeid:$volname' is managed by pbo and cannot be removed from Proxmox VE;"
        . " retention is owned by pbo (pbo prune)\n";
}

# prune_backups(): a dry run lists every archive as 'protected' (nothing in PVE
# may remove one; pbo prune decides, with its own GFS policy and keep tags). A
# real run dies.
sub prune_backups {
    my ($class, $scfg, $storeid, $keep, $vmid, $type, $dryrun, $logfunc) = @_;

    die "retention is owned by pbo: backups on '$storeid' are managed by pbo (use pbo prune)\n"
        if !$dryrun;

    my $list = [];
    for my $b ($class->list_volumes($storeid, $scfg, $vmid, ['backup'])->@*) {
        next if defined($type) && $type ne $b->{subtype};
        push @$list, {
            volid => $b->{volid},
            ctime => $b->{ctime},
            type => $b->{subtype},
            vmid => $b->{vmid},
            mark => 'protected',
        };
    }
    return $list;
}

# --- everything else a backup-only storage must refuse ----------------------

sub _refuse {
    my ($what) = @_;
    die "$what is not supported on pbo storage (backups only, managed by pbo)\n";
}

sub alloc_image { _refuse('allocating volumes') }
sub clone_image { _refuse('cloning') }
sub create_base { _refuse('creating base images') }
sub rename_volume { _refuse('renaming volumes') }
sub volume_resize { _refuse('resizing volumes') }
sub volume_snapshot { _refuse('volume snapshots') }
sub volume_snapshot_rollback { _refuse('volume snapshot rollback') }
sub volume_snapshot_delete { _refuse('volume snapshot deletion') }
sub volume_snapshot_info { _refuse('volume snapshot information') }
sub volume_export { _refuse('exporting volumes') }
sub volume_import { _refuse('importing volumes') }
sub qemu_blockdev_options { _refuse('attaching volumes to a VM') }
sub get_identity { _refuse('get_identity') }

sub volume_export_formats { return () }
sub volume_import_formats { return () }

# No features (copy, clone, snapshot, ...) on any volume: undef is the API's
# "not supported", the answer PBS gives too; callers probe and do not expect a die.
sub volume_has_feature {
    return undef;
}

1;
