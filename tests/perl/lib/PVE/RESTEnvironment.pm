package PVE::RESTEnvironment;
# Test stub (tests/perl): what PboPlugin.pm's _sync_request looks at.
#   $PVE::RESTEnvironment::TYPE    undef = not initialised (get dies, like the
#                                  real one), else cli|pub|priv|ha
#   $PVE::RESTEnvironment::WORKER  is_worker() (1 inside fork_worker)
use strict;
use warnings;

our $TYPE;
our $WORKER = 0;

sub get {
    die "REST environment not initialized\n" if !defined($TYPE);
    return bless { type => $TYPE }, 'PVE::RESTEnvironment';
}

sub is_worker { return $WORKER }

1;
