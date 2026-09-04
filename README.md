# lxc-offsite

Offsite backup of Proxmox LXC containers to any SFTP target (for example a
Hetzner Storage Box), using [restic](https://restic.net/) as the backup engine.

Not everyone can run a Proxmox Backup Server. `lxc-offsite` gives you a similar
result — deduplicated, encrypted, incremental offsite backups with easy
restores — using nothing but SFTP storage and a single self-contained tool that
runs on the Proxmox host itself.

It takes a `vzdump` archive of each container, stores it inside a restic
repository, ships it offsite over native SFTP, and can fetch it back and
`pct restore` it to a brand-new VMID for disaster recovery. There is an
interactive prompt-CLI (`lxc-offsite menu`) for day-to-day use.

> The tool should be debuggable at three in the morning by someone who did not
> write it.

## Why restic

- **One repository.** Everything lands in the *same* restic repo, whether you
  back up one container at a time (`stream`) or all at once (`batch`), with or
  without a local cache tier. No fragmentation.
- **Deduplication + encryption** are handled by restic. The repo password *is*
  your disaster-recovery key — export it and store it somewhere safe.
- **Native SFTP.** No FUSE mounts, no rclone. restic talks SFTP directly, with a
  full ssh command so you control port and key (needed for Hetzner Storage Box).

## Requirements

- A Proxmox VE host (provides `pct`, `vzdump`).
- `restic`, `jq`, `zstd`, `flock`, `curl` (installed by `install.sh` if missing).
- An SFTP target with key-based access. Hetzner Storage Box works well; its repo
  path is **relative** because the account is chrooted.

## Install

```bash
git clone https://github.com/ai-pvet440/lxc-offsite
cd lxc-offsite
sudo ./install.sh          # installs to /usr/local, offers the setup wizard
```

`install.sh` never enables the timer on its own — it tells you how.

## Quick start

```bash
lxc-offsite setup          # interactive wizard: engine/cache/sftp/password/mode/ntfy → init
lxc-offsite menu           # interactive prompt-CLI: guests / backup / restore / status
```

The wizard writes `/etc/lxc-offsite/config` (0600) and creates the restic repo.
After setup, use the menu to protect guests (scan the cluster, add/remove
VMIDs), run a backup, and — importantly — **export your DR key** to a password
manager.

### Schedule nightly backups

```bash
systemctl enable --now lxc-offsite.timer    # runs run-schedule at 05:00 nightly
```

## Command-line usage

```
lxc-offsite [global flags] <command> [arguments]

Global flags:
  --json              machine-readable output on stdout
  --dry-run           show what would be done, change nothing

Commands:
  setup                       interactive setup wizard
  menu                        interactive prompt-CLI (rclone style)
  init                        create/verify the restic repo(s)
  backup <vmid>               dump→verify→upload→verify→prune (global lock)
  run-schedule [--stream|--batch]  back up everything in BACKUP_ORDER → same repo
  status                      running jobs, queue length, lock holder
  list [vmid]                 list offsite archives
  restore <vmid> <ts> --to N  fetch + pct restore to a new vmid
  verify                      restic check (repo integrity)
  prune                       clean cache and offsite per policy
  test-restore <vmid>         full restore to a throwaway vmid, boot, destroy
```

## Modes

| Setting | Meaning |
|---|---|
| `LOCAL_REPO=true`  | Cached: back up to a local restic repo, then `copy` offsite (fast local restores). |
| `LOCAL_REPO=false` | Offsite-only: back up straight to the SFTP repo (minimal local disk). |
| `BACKUP_MODE=stream` | Dump→upload one container at a time (low disk). Default. |
| `BACKUP_MODE=batch`  | Dump all to cache, then upload (if there is room). |

Whatever the combination, everything ends up in **one** repo.

## Disaster recovery

Backups are only as good as your restores. On a fresh host: install
`lxc-offsite`, paste your exported DR key (menu → Export DR key), then
`lxc-offsite menu` → Restore. It always restores to a **new** VMID and never
overwrites an existing guest. Test it with `test-restore`, which restores, boots
and then destroys a throwaway copy.

## Configuration

See `etc/config.example` for every key. The password file
(`RESTIC_PASSWORD_FILE`, mode 0600) holds the only secret; the config file holds
none.

## License

AGPL-3.0-or-later. See `LICENSE`.
