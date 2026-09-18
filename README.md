# pbo

This backs up Proxmox guests (LXC and QEMU) to an SFTP server using
[restic](https://restic.net/). That's it. It is not trying to be Proxmox Backup
Server, and if PBS works for you, go use PBS.

The point is an encrypted offsite copy without standing up yet another server for it.
restic already does dedup, encryption and incremental backups over plain SFTP, so pbo
is mostly glue: it runs `vzdump`, throws the archive into a restic repo, and pushes it
offsite. Restore does the reverse and feeds the archive to `pct restore` or
`qmrestore`, always into a new VMID. No daemon, no web service. Drive it from
`pbo menu`, or use the individual commands if you'd rather type.

> This is beta. It backs up and restores real machines and there's a test suite, but
> things still move around, so don't make it the only copy of anything important just
> yet.

## Screenshots

A quick look at the interface before you clone it. The main menu:

![The pbo main menu](docs/img/menu.png)

And the status screen, showing both tiers with the next scheduled run:

![Status, both tiers with the next scheduled run](docs/img/status-full.png)

## Why restic

restic already solved the hard parts, so there's no reason to reinvent them. It speaks
SFTP itself, so there's no FUSE mount and no rclone in the middle. Everything goes into
one repo no matter how many guests or nodes you have. The repo password is both the
encryption key and the recovery key, so if you lose it the data is gone for good. Keep
a copy somewhere safe.

## Requirements

Nothing exotic:

- A Proxmox host (`pct`, `qm`, `vzdump`).
- `restic`, `jq`, `zstd`, `flock`, `curl`. `install.sh` installs whatever's missing.
- An SFTP target you can log into with a key. Storage Box paths are relative because the
  account is chrooted, which is expected.

## Install

```bash
git clone https://github.com/TubalQ/PBO
cd PBO
sudo ./install.sh
```

Goes into `/usr/local` and offers to run setup. It leaves the timer off, so it won't
start a nightly job you didn't ask for.

## Quick start

```bash
pbo setup     # engine, cache, sftp, password, mode
pbo menu      # guests, backup, restore, status
```

`setup` writes `/etc/pbo/config` and creates the repo. Then pick your guests, run a
backup, and export the DR key somewhere safe. Don't skip that last step.

Nightly:

```bash
systemctl enable --now pbo.timer     # 05:00
```

## Clusters

There's no cluster mode to set up. Install it on every node and each node backs up its
own guests into the same repo, the same way Proxmox's own backup jobs work. No
coordinator, no node reaching across to another over SSH.

```bash
sudo ./install.sh
pbo setup                            # same repo, same password
systemctl enable --now pbo.timer
```

With `BACKUP_ORDER=auto` each node works out its own guests. Move a guest to another
node and that node backs it up on the next run; restic tags snapshots by vmid, so the
history isn't lost.

A few things worth getting right:

- Use the same repo password on every node, in `/etc/pbo/restic-pass`. Keep it out of
  `/etc/pve`, since pmxcfs replicates that directory in cleartext, which defeats the
  point.
- To edit the config once instead of N times, put the non-secret parts in
  `/etc/pve/pbo/config` and let pmxcfs sync it. The local file still holds the password
  and wins on conflicts.
- Prune from one node only, since it takes an exclusive lock. Set `PRUNE_OWNER` to pin
  it to a node.

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
| `LOCAL_REPO=true`  | Keep a local repo, copy each snapshot offsite. Fast local restores. |
| `LOCAL_REPO=false` | Straight to SFTP. Barely touches local disk. |
| `BACKUP_MODE=stream` | One guest at a time (default). Low disk. |
| `BACKUP_MODE=batch`  | Dump everything to cache first, then upload, if it fits. |

## Disaster recovery

The point of a backup is the restore, so: the host is dead and you have a clean machine.
Install pbo, give it the same repo password (the DR key), and restore. It always
restores to a new VMID and won't overwrite a running guest. And since a backup you've
never tested isn't really a backup, `test-restore` runs the whole loop for you: it
restores a throwaway copy, boots it, and throws it away.

## Configuration

Everything is documented in `etc/config.example`. The only secret is the repo password
(`RESTIC_PASSWORD_FILE`, 0600). The config file itself holds nothing sensitive, so it's
fine to keep in version control.

## Contributing

Patches welcome. It's plain bash with tests in `tests/`. If you change how something
behaves, please add a test that covers it.

## License

AGPL-3.0-or-later. See `LICENSE`.
