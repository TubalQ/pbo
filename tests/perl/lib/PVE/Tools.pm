package PVE::Tools;
# Test stub (tests/perl): run_command records every call instead of running it.
#   @PVE::Tools::CALLS     each call as [ [cmd...], {params} ]
#   $PVE::Tools::RUN_HOOK  optional sub($cmd, \%param) -> exit code; it may call
#                          $param{outfunc}/$param{errfunc} or die like the real one
use strict;
use warnings;

use base qw(Exporter);
our @EXPORT_OK = qw(run_command);

our @CALLS;
our $RUN_HOOK;

sub run_command {
    my ($cmd, %param) = @_;
    push @CALLS, [[@$cmd], {%param}];
    return $RUN_HOOK ? $RUN_HOOK->($cmd, \%param) : 0;
}

1;
