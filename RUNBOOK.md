# Runbook

This is the operations manual for `pbo`. It backs up Proxmox guests (LXC
containers and QEMU VMs) offsite to an SFTP target, deduplicated and encrypted
with restic. Run it on the Proxmox host, as root. If you also run a Proxmox
Backup Server, `pbo` does not touch it. Think of `pbo` as the offsite copy, the
third leg of a 3-2-1 setup.

The one rule to keep in mind: a backup you have never restored is not really a
backup. `restic check` verifies the repo, and `test-restore` proves an actual
restore by booting a throwaway copy.

## Installing, including on a fresh host during recovery

```bash
git clone https://github.com/TubalQ/PBO && cd PBO
./install.sh          # installs the tool and units, does not enable the timer
pbo setup             # engine, cache, sftp, password, mode, then init
```

`install.sh` also leaves a `lxc-offsite` symlink, because that was the old name
of the tool.

## Configuration is one file plus one secret

Everything operational lives in `/etc/pbo/config` as `KEY=VALUE` lines:

- `ENGINE=restic` picks the backup engine.
- `RESTIC_OFFSITE_REPO` is the repo, for example `sftp:hetzner:lxc-restic`. The
  path is relative, because a Storage Box account is chrooted. Never rename it in
  place, or you orphan every snapshot already in it.
- `RESTIC_SFTP_COMMAND` is the full ssh command, with host, port, and key, so
  restic reaches the box correctly.
- `RESTIC_SFTP_CONNECTIONS` sets the number of parallel SFTP streams. Keep the
  total under the provider limit, which is around 10 on Hetzner.
- `LOCAL_REPO` chooses a cache tier (`true`) or offsite only (`false`).
  `BACKUP_MODE` is `stream` (one at a time, low disk, the default) or `batch`.
- `BACKUP_ORDER` is `auto` (every guest on this node) or a comma-separated list
  when you want a specific order or want to exclude some guests.
- `KEEP_OFFSITE_{DAILY,WEEKLY,MONTHLY}` and `KEEP_LOCAL` set the retention.
- `VZDUMP_MODE` is usually `snapshot`. Containers that use fuse are forced to
  `stop` automatically, for the reason explained under Gotchas.

The only secret is the restic repo password, which is also your disaster-recovery
key. It lives in `RESTIC_PASSWORD_FILE`, by default `/etc/pbo/restic-pass`, mode
0600. The config file holds no secrets. Export this key (menu, then Export DR key)
to a password manager and to something offline. Without it, the offsite data is
gone for good.

## Day-to-day commands

```bash
pbo status                     # the lock and the latest job
pbo backup <vmid>              # one guest: dump, store in restic, copy offsite
pbo --dry-run backup <vmid>    # show the plan without touching anything
pbo list [vmid]                # what is offsite (restic snapshots)
pbo usage                      # repo size, dedup ratio, snapshot count
pbo run-schedule               # back up this node's guests, what the timer runs
pbo prune --dry-run            # show what retention would remove
pbo verify                     # restic check for repo integrity
pbo test-restore <vmid>        # restore a throwaway copy, boot it, destroy it
```

To run nightly at 05:00:

```bash
systemctl enable --now pbo.timer
systemctl list-timers pbo.timer
journalctl -u pbo.service -f
```

## Restore with the tool

```bash
pbo list <vmid>                                 # find the timestamp you want
pbo restore <vmid> <ts> --to <new-vmid> --storage <pool> --yes
```

A restore always goes to a new vmid and never overwrites an existing guest. The
new guest is left stopped. If it shares an IP with a guest that is still running,
change the IP before you boot it. For containers, `unprivileged` is read back from
the archive. Bind mounts are not stored in the archive, so recreate them by hand
from the saved `.conf`:

```bash
pct set <new-vmid> --mp0 /host/path,mp=/data
```

## Recovery without the tool, if the script is broken or gone

All you need is `restic`, the repo password, and `pct` or `qm`:

```bash
export RESTIC_REPOSITORY='sftp:uXXXXX-subN@uXXXXX.your-storagebox.de:23/lxc-restic'
export RESTIC_PASSWORD_FILE=/etc/pbo/restic-pass
export RESTIC_SFTP_COMMAND='ssh uXXXXX-subN@uXXXXX.your-storagebox.de -p 23 -i /root/.ssh/id_rsa -s sftp'

restic snapshots                                  # what is offsite, tagged per vmid
restic restore <snapshot-id> --target /var/tmp/dr # pulls out the vzdump archive
# then, depending on the guest type:
pct restore <new-vmid> /var/tmp/dr/.../vzdump-lxc-<vmid>-<ts>.tar --storage <pool> --unprivileged <0|1>
qmrestore /var/tmp/dr/.../vzdump-qemu-<vmid>-<ts>.vma <new-vmid> --storage <pool>
```

The `unprivileged` value and any bind mounts are in the extracted `.conf`.

The key is a single point of failure. restic encrypts everything, so without the
password you cannot even list the snapshots. Keep it in a password manager and
offline, and test a recovery from a clean machine at least once.

## In a cluster

Install `pbo` on each node. Each node backs up its own guests into the same repo,
so you get cluster-wide dedup with no central coordinator. Points to remember:

- The same repo password goes on every node, in `/etc/pbo/restic-pass`. It never
  goes in `/etc/pve`, which pmxcfs replicates in cleartext.
- You can share the non-secret config through `/etc/pve/pbo/config` so you edit it
  once. The local file still wins where they differ.
- Prune from one node only, or set `PRUNE_OWNER`, because prune takes an exclusive
  lock.

## Gotchas and troubleshooting

- **A fuse container freezes during backup.** It should not, because the tool
  forces `--mode stop` for any guest with `features fuse=1`. If one freezes
  anyway, kill the stuck `vzdump` or `rsync` process, the one in state
  `request_wait_answer`, and the container resumes. `fsfreeze -u` does not help,
  because it is the live fuse mount that hangs.
- **SFTP is slow or throws errors.** That is usually rate limiting. Keep
  `RESTIC_SFTP_CONNECTIONS` under the provider limit, which is around 10 on
  Hetzner, especially while test processes are also running.
- **`init` or list fails.** Check `RESTIC_OFFSITE_REPO`, check `RESTIC_SFTP_COMMAND`
  for the right port and key, and check that `RESTIC_PASSWORD_FILE` exists and is
  readable at mode 0600.
- **Prune removes nothing.** Retention always keeps the latest snapshot per guest.
  That is on purpose. `forget` (metadata) and `prune` (reclaiming space) are
  separate steps.
- **The provider has no append-only mode.** Plain SFTP means a compromised host
  can delete the offsite data. Turn on your provider's scheduled snapshots and set
  `STORAGE_BOX_SNAPSHOTS_CONFIRMED=true`. That is the only protection against
  ransomware.
- **A restored guest is missing from the web UI.** In a cluster it appears under
  the node you restored it on. Refresh the web UI, which does not push new guests
  to you on its own.

## Where things live

| | |
|---|---|
| Program | `/usr/local/lib/pbo/`, with `/usr/local/sbin/pbo` as the entry point |
| Config | `/etc/pbo/config` |
| DR key | `/etc/pbo/restic-pass`, mode 0600, the restic repo password |
| Cache | `CACHE_DIR` from the config, used when `LOCAL_REPO=true` |
| Logs and jobs | `/var/log/pbo/` and `/var/lib/pbo/jobs/` |
| systemd | `pbo.service` and `pbo.timer` |
| Source | `github.com/TubalQ/PBO` |
