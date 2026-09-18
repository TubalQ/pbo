# shellcheck shell=bash
# lib/prune.sh: retention. Dispatches to the restic engine (forget/prune). The
# cache repo is pruned keep-last, offsite is pruned GFS (daily/weekly/monthly).
# restic always keeps the latest snapshot per guest regardless of policy.
#
# Scheduled prune is gated by _is_prune_owner (lib/cluster.sh) so exactly one
# node prunes in a cluster (prune takes an exclusive repo lock).

# Extract the timestamp (YYYY_MM_DD-HH_MM_SS) from an archive name. Used by the
# restic engine to tag snapshots and by list/restore to select them.
_archive_ts() { [[ "$1" =~ ([0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}) ]] && printf '%s' "${BASH_REMATCH[1]}"; }

# do_prune, dispatch to the restic engine.
do_prune() { rdo_prune; }
