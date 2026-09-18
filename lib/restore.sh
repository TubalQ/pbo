# shellcheck shell=bash
# lib/restore.sh: restore to a NEW vmid (never overwrite). Dispatches to the
# restic engine. Takes a per-vmid lock on the TARGET vmid, never the global lock.
#
# Hard rules (enforced in the engine, lib/restic.sh):
#   - ALWAYS restore to a new vmid; never overwrite an existing one.
#   - Read `unprivileged` from the archive's config sidecar and set it explicitly.
#   - Require --yes to actually run; without it, print the command.

# do_restore <src_vmid> <ts> <new_vmid> <storage|""> <yes:0|1>
do_restore() { rdo_restore "$1" "$2" "$3" "$4" "$5"; }
