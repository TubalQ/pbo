# shellcheck shell=bash
# lib/list.sh: list (offsite inventory) + fetch (pull an archive into the cache
# and verify it, without restoring). Both dispatch to the restic engine.
# Neither takes the global lock (they do not write from the storage pool).

# do_list [vmid], list snapshots as archives (restic engine).
do_list() { rdo_list "${1:-}"; }

# do_fetch <vmid> <ts>, extract+verify one snapshot into the cache (restic engine).
do_fetch() { rdo_fetch "$1" "$2"; }
