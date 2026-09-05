# pbo

Offsite backup for Proxmox guests (LXC and QEMU) to any SFTP target — a Hetzner
Storage Box, say. It uses [restic](https://restic.net/) under the hood, so backups
are deduplicated, encrypted and incremental.

If you can't or won't run a full Proxmox Backup Server, this gets you most of the
way there — dedup, encryption, quick restores, an offsite copy — with just SFTP
storage and one script on the host.

For each guest it runs `vzdump`, stashes the archive in a restic repo and pushes it
offsite over plain SFTP. Restores pull the archive back and hand it to `pct restore`
(containers) or `qmrestore` (VMs), always into a fresh VMID. Day to day you drive it
from `pbo menu`.

> **Beta.** It backs up and restores real containers and VMs, and there's a test
> suite, but defaults and interfaces still move around. Try it on something you can
> afford to lose, pin a commit if you rely on it, and open an issue when it breaks.

## Why restic

Everything ends up in one repo, whether you back up a single guest or the whole
node, cached locally or not. restic does the dedup and encryption; the repo password
is your recovery key, so export it and keep it somewhere safe. No FUSE, no rclone —
restic speaks SFTP directly and you hand it a full ssh command, which is what a
chrooted Storage Box needs.

## Requirements

- A Proxmox VE host (for `pct`, `qm`, `vzdump`).
- `restic`, `jq`, `zstd`, `flock`, `curl` — `install.sh` grabs whatever's missing.
- An SFTP target you can reach with a key. Storage Box paths are relative (the
  account is chrooted to its own directory).

## Install

```bash
git clone https://github.com/TubalQ/PBO
cd PBO
sudo ./install.sh
```

Installs into `/usr/local`, offers to run the setup wizard, and leaves the timer
disabled (it prints how to enable it).

## Quick start

```bash
pbo setup     # engine, cache, sftp, password, mode
pbo menu      # guests, backup, restore, status
```

The wizard writes `/etc/pbo/config` (0600) and creates the repo. Then pick which
guests to protect, run a backup, and — do this — export your DR key to a password
manager.

Nightly schedule:

```bash
systemctl enable --now pbo.timer     # 05:00 every night
```

## Clusters

Run `pbo` on each node; each node backs up its own guests into the same shared repo.
No central coordinator, no cross-node SSH — same idea as Proxmox's own backup jobs.
Per node:

```bash
git clone https://github.com/TubalQ/PBO && cd PBO
sudo ./install.sh
pbo setup                            # same repo, same password
systemctl enable --now pbo.timer
```

With `BACKUP_ORDER=auto` (the default) each node finds its own guests. Move a guest
to another node and that node picks it up next run — restic tags every snapshot with
the vmid, so its history follows it. A single node is just this with one node.

Three things to get right:

- Use the same repo password on every node. Paste it into `/etc/pbo/restic-pass`
  (0600). Keep it out of `/etc/pve` — pmxcfs replicates that in cleartext.
- To edit config once for the whole cluster, put the non-secret bits in
  `/etc/pve/pbo/config`; pmxcfs syncs it, and each node's local config just adds the
  password (and wins where they differ).
- Prune from one node only — it needs an exclusive lock on the repo. Run it in one
  place or set `PRUNE_OWNER=<nodename>`.

## Commands

```
pbo [global flags] <command> [arguments]

Global flags:
  --json              machine-readable output
  --dry-run           show what would happen, do nothing

Commands:
  setup                       setup wizard
  menu                        interactive prompt
  init                        create or verify the repo
  backup <vmid>               back up one guest
  run-schedule [--stream|--batch]   back up this node's guests
  status                      running jobs and lock holder
  list [vmid]                 offsite archives
  restore <vmid> <ts> --to N  restore to a new vmid
  verify                      restic integrity check
  prune                       apply retention
  test-restore <vmid>         restore to a throwaway vmid, boot, destroy
```

## Modes

| Setting | Effect |
|---|---|
| `LOCAL_REPO=true`  | Keep a local repo, copy each snapshot offsite. Local restores are fast. |
| `LOCAL_REPO=false` | Straight to SFTP. Barely touches local disk. |
| `BACKUP_MODE=stream` | One guest at a time (default). Low disk. |
| `BACKUP_MODE=batch`  | Dump everything to cache first, then upload, if it fits. |

It all lands in one repo either way.

## Disaster recovery

On a fresh host: install pbo, paste your DR key (menu → Export DR key), then
menu → Restore. It only ever restores to a new VMID, never over an existing guest.
`test-restore` proves the path end to end — it restores a throwaway copy, boots it,
and destroys it.

## Configuration

`etc/config.example` documents every setting. The one secret is the repo password,
in the file named by `RESTIC_PASSWORD_FILE` (0600). The config file holds nothing
sensitive.

## Contributing

PRs welcome, especially while it's beta — bugs, fixes, docs, ideas. It's plain bash
with tests under `tests/`; if you change behaviour, cover it with a test.

## License

AGPL-3.0-or-later. See `LICENSE`.
