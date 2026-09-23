# Backlog

## Shipped
- **restic is the only engine.** The tar.zst + rclone engine and the frozen
  Textual/whiptail TUI were removed; there is one code path. See
  [`docs/adr/0001-restic-as-backup-engine.md`](adr/0001-restic-as-backup-engine.md).
- **Interface = `pbo menu`** (rclone-style prompt-CLI). See
  [`docs/adr/0003-tui.md`](adr/0003-tui.md).
- **VM + cluster.** QEMU VMs (`.vma`/`qmrestore`) and cluster awareness (each node
  backs up its own guests into one shared repo, Model A) are implemented in
  `lib/guest.sh` and `lib/cluster.sh`. See
  [`docs/adr/0002-vm-and-cluster-support.md`](adr/0002-vm-and-cluster-support.md).
- **Scheduled retention.** `pbo-prune.timer` prunes weekly, gated by
  `_is_prune_owner` so one node prunes in a cluster.
- **Repo-password rotation.** `pbo rotate-key` (menu → Rotate DR key): `restic key
  add` → verify → `restic key remove`, instant, no re-encryption.
- **Health check.** `pbo doctor`: repo reachable, DR key perms, timer, provider
  snapshots, and per-guest newest-snapshot age.
- **Stale-lock recovery.** `pbo unlock`, plus an auto-clear before backup/prune when
  no live pbo run holds the lock.
- **CI.** shellcheck + the test suite run on every push/PR.
- **Host backup.** `pbo backup-host` stores the host's own config + rebuild
  metadata into the same repo (`type=host`, shown as `host-<node>`); manual, not
  scheduled. SSH keys and the DR key are excluded on purpose. `restore-host`
  does a file restore to a directory (never `pct restore`).
- **Numbered restore pickers.** `pbo menu` → Restore now picks the guest and the
  snapshot from numbered lists (age/size), instead of typing a raw timestamp.

## Open
- **Hardened / append-only offsite.** Prune runs locally, so the host holds the
  delete key; the provider's scheduled snapshots are the real backstop. A restic
  REST server in append-only mode (or a restricted SFTP user) would remove that
  single point. See the Hardening section in the README.
- **Deep-verify schedule.** `verify` supports `VERIFY_SUBSET=<n%>` for an affordable
  `--read-data` sample; wire it into a periodic (monthly) timer.
