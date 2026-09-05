# pbo

Offsite backup for Proxmox guests, both LXC containers and QEMU VMs, to any SFTP
target such as a Hetzner Storage Box. It uses [restic](https://restic.net/) as
the backup engine, so you get deduplicated, encrypted, incremental backups.

Not everyone can run a Proxmox Backup Server. `pbo` gives you a lot of the same
value (dedup, encryption, easy restores, an offsite copy) with nothing more than
SFTP storage and one self-contained script that runs on the Proxmox host.

It works like this. For each guest it runs `vzdump`, stores the resulting archive
inside a restic repository, and ships it offsite over native SFTP. To recover, it
pulls the archive back and restores it to a brand new VMID with `pct restore`
(containers) or `qmrestore` (VMs). Day to day you drive it from an interactive
prompt (`pbo menu`).

One rule shaped the whole thing: you should be able to debug it at three in the
morning, even if you did not write it.

> **Status: beta, under active construction.** pbo backs up and restores real
> containers and VMs today, and there is a test suite to back that up, but
> interfaces and defaults can still change between versions. Try it on something
> you can afford to lose first, pin a commit if you depend on it, and please tell
> us what breaks.

## Why restic

- **One repository.** Everything lands in the same restic repo, whether you back
  up one guest at a time or all of them at once, with or without a local cache
  tier. Nothing gets fragmented across places.
- **Dedup and encryption come for free.** restic handles both. The repo password
  is your disaster-recovery key, so export it and keep it somewhere safe.
- **Plain SFTP.** No FUSE mounts, no rclone. restic speaks SFTP directly, and you
  give it a full ssh command so you control the port and key. That is what a
  Hetzner Storage Box needs.

## Requirements

- A Proxmox VE host, which gives you `pct`, `qm`, and `vzdump`.
- `restic`, `jq`, `zstd`, `flock`, and `curl`. `install.sh` installs any that are
  missing.
- An SFTP target you can reach with a key. A Hetzner Storage Box works well. Its
  repo path is relative, because the account is chrooted to its own directory.

## Install

```bash
git clone https://github.com/TubalQ/PBO
cd PBO
sudo ./install.sh
```

`install.sh` installs to `/usr/local`, offers to run the setup wizard, and never
enables the timer on its own. It prints the command for that.

## Quick start

```bash
pbo setup     # a wizard for engine, cache, sftp, password, and mode
pbo menu      # the interactive prompt: guests, backup, restore, status
```

The wizard writes `/etc/pbo/config` (mode 0600) and creates the restic repo. Once
that is done, use the menu to choose which guests to protect, run a backup, and,
most important of all, export your DR key to a password manager.

### Schedule nightly backups

```bash
systemctl enable --now pbo.timer     # runs the schedule at 05:00 every night
```

## Cluster setup

`pbo` runs on each node, and each node backs up the guests that live on it into
the same shared repo. There is no central coordinator and no cross-node SSH. It
is the same shape as Proxmox's own backup jobs: you define the intent once, and
each node runs its own part.

On every node in the cluster:

```bash
git clone https://github.com/TubalQ/PBO && cd PBO
sudo ./install.sh
pbo setup                            # point at the same repo and password
systemctl enable --now pbo.timer
```

That really is all of it. With `BACKUP_ORDER=auto` (the default) each node finds
and backs up its own guests. If a guest moves to another node, that node picks it
up on the next run, and its history continues, because restic tags every snapshot
with the vmid. A single-node install is just this with one node, and nothing about
it changes.

A few things worth knowing:

- **Use the same DR key on every node.** Paste the exported repo password into
  `/etc/pbo/restic-pass` (mode 0600) on each node. Do not put it in `/etc/pve`,
  because pmxcfs replicates that in cleartext.
- **You can edit the config once, if you want.** Put the non-secret config in
  `/etc/pve/pbo/config` and pmxcfs replicates it to every node. Each node's local
  `/etc/pbo/config` then only needs the password file, and it overrides the shared
  file where they differ.
- **Prune from a single node.** Pruning needs an exclusive lock on the repo, so
  run it from one node, or set `PRUNE_OWNER=<nodename>`.

## Command-line usage

```
pbo [global flags] <command> [arguments]

Global flags:
  --json              machine-readable output on stdout
  --dry-run           show what would happen, change nothing

Commands:
  setup                       run the interactive setup wizard
  menu                        open the interactive prompt
  init                        create or verify the restic repo
  backup <vmid>               back up one guest (dump, store, verify)
  run-schedule [--stream|--batch]   back up this node's guests into the repo
  status                      show running jobs and who holds the lock
  list [vmid]                 list the offsite archives
  restore <vmid> <ts> --to N  restore an archive to a new vmid
  verify                      run restic's integrity check
  prune                       apply the retention policy
  test-restore <vmid>         restore to a throwaway vmid, boot it, destroy it
```

## Modes

| Setting | What it does |
|---|---|
| `LOCAL_REPO=true`  | Keep a local restic repo, then copy each snapshot offsite. Restores from the local copy are fast. |
| `LOCAL_REPO=false` | Back up straight to the SFTP repo. Uses very little local disk. |
| `BACKUP_MODE=stream` | Dump and upload one guest at a time. Low disk use. This is the default. |
| `BACKUP_MODE=batch`  | Dump everything to the cache first, then upload, if there is room. |

Whatever you pick, it all ends up in one repo.

## Disaster recovery

A backup is only as good as the restore. On a fresh host, install `pbo`, paste
your exported DR key (menu, then Export DR key), and open `pbo menu`, then
Restore. It always restores to a new VMID and never overwrites a guest that
already exists. To prove the whole path works, run `test-restore`: it restores a
throwaway copy, boots it, and destroys it again.

## Configuration

`etc/config.example` documents every setting. The only secret is the repo
password, which lives in the file named by `RESTIC_PASSWORD_FILE` (mode 0600). The
config file itself holds no secrets.

## Contributing

Pull requests are very welcome. Bug reports, fixes, better docs, and new ideas all
help, especially while the tool is still in beta. It is plain bash with a small
test suite under `tests/`, so it is easy to dig into. If you change behaviour, add
or update a test to cover it. One house-style note: keep the writing plain and
human, and no em-dashes.

## License

AGPL-3.0-or-later. See `LICENSE`.
