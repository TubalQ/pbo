package Filesys::Df;
# Test stub (tests/perl): a fixed statvfs answer for existing directories, and a
# record of every call (the plugin must stat, never fork).
use strict;
use warnings;

our @CALLS;

sub df {
    my ($dir, $bs) = @_;
    push @CALLS, $dir;
    return undef if !-d $dir;
    return { blocks => 1000 * ($bs // 1024), bavail => 600 * ($bs // 1024), used => 400 * ($bs // 1024) };
}

1;
