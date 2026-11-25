# Runbook

Operations manual for `pbo`. It backs up Proxmox guests (LXC containers and QEMU
VMs) offsite to an SFTP target, deduplicated and encrypted with restic. Run it on
the Proxmox host as root. If you also run a Proxmox Backup Server, pbo leaves it
alone — it's the offsite leg of a 3-2-1 setup, not a replacement.

Two ways to trust it: `restic check` verifies the repo, and `test-restore` boots a
throwaway copy to prove an actual restore works.

## Installing, including on a fresh host during recovery

```bash
git clone https://github.com/TubalQ/PBO && cd PBO
./install.sh          # installs the tool and units, does not enable the timer
pbo setup             # cache, sftp, DR key (an existing one is kept), mode, timers, then init
```

`install.sh` also leaves a `lxc-offsite` symlink, because that was the old name
of the tool.

## Configuration is one file plus one secret

Everything operational lives in `/etc/pbo/config` as `KEY=VALUE` lines:

- `RESTIC_OFFSITE_REPO` is the repo, for example `sftp:storagebox:pbo`. The
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
- `KEEP_OFFSITE_{DAILY,WEEKLY,MONTHLY,YEARLY}` and `KEEP_LOCAL` set the retention;
  a guest can carry its own (`pbo policy set`), never below `KEEP_OVERRIDE_MIN_LAST`.
- `VZDUMP_MODE` is usually `snapshot`. Containers that use fuse are forced to
  `stop` automatically, for the reason explained under Gotchas.

The restic repo password is also your disaster-recovery key. It lives in
`RESTIC_PASSWORD_FILE`, by default `/etc/pbo/restic-pass`, mode 0600. Export it
(menu, then Export DR key) to a password manager and to something offline. Without
it, the offsite data is gone for good. The config is 0600 too: it can hold an ntfy
token/topic and the SFTP command, so keep it out of version control.

## Day-to-day commands

```bash
pbo status                     # the lock and the latest job
pbo doctor                     # health check: repo, timer, permissions, per-guest age
pbo --dry-run doctor --fix     # what the permission fix would change (then without --dry-run)
pbo backup <vmid>              # one guest: dump, store in restic, copy offsite
pbo --dry-run backup <vmid>    # show the plan without touching anything
pbo list [vmid]                # what is offsite (restic snapshots)
pbo usage                      # repo size, dedup ratio, snapshot count
pbo run-schedule               # back up this node's guests, what the timer runs
pbo --dry-run prune            # show what retention would remove (--dry-run is a global flag)
pbo verify                     # restic check on BOTH tiers (cache + offsite)
pbo unlock                     # clear a stale repo lock after a killed run
pbo rotate-key <file>          # rotate the repo password (DR key) to a new value
pbo test-restore <vmid>        # restore a throwaway copy, boot it, destroy it
pbo backup-host                # back up THIS host's config + rebuild metadata
pbo restore-host <node> <ts> --to <dir> [--path <p>]   # extract host files
```

Host backup (`backup-host`) is manual and captures the host's own config into
the same repo (`type=host`, shown as `host-<node>`): `/etc/pve`, networking,
`/etc/pbo`, systemd units, cron and apt sources (`HOST_BACKUP_PATHS`), plus
rebuild metadata (`pveversion -v`, the manual package list, storage/network
layout). SSH keys and the DR key are excluded on purpose (`HOST_BACKUP_EXCLUDES`),
so keep your own offline copy of those. `restore-host` extracts the files to a
directory; you copy them back to live paths (e.g. `/etc/pve`) by hand.

`verify` is structure-only by default; `VERIFY_READ_DATA=1 pbo verify` reads every
pack (slow over SFTP) and `VERIFY_SUBSET=5% pbo verify` reads a cheap sample.

To run nightly backups at 05:00 and weekly retention on Sunday 06:30:

```bash
systemctl enable --now pbo.timer         # run-schedule, 05:00 daily
systemctl enable --now pbo-prune.timer   # prune --if-owner, Sunday 06:30
systemctl list-timers 'pbo*'
journalctl -u pbo.service -f
```

Retention is not applied by the backup run, only by `pbo prune` (the prune timer),
so without the prune timer the offsite repo grows until you prune by hand.

Prune and backup never run at the same time. Both timers have `Persistent=true`, so
after the host has been off past a Sunday they fire together right after boot. The
prune timer runs `prune --queue`, which waits for the backup run to finish (up to
`SCHEDULE_LOCK_TIMEOUT`). A manual `pbo prune` exits at once if a backup is running.

## Restore with the tool

```bash
pbo list <vmid>                                 # find the timestamp you want
pbo restore <vmid> <ts> --to <new-vmid> --storage <pool> --yes
```

A restore always goes to a new vmid and never overwrites an existing guest. By
default the copy is **isolated** and left stopped: every NIC `link_down=1`,
autostart off, and everything that reaches into the host removed (bind and device
mount points, `devN`, hookscripts, raw `lxc.mount`/`lxc.hook` lines, passthrough).
That is what you want while the original still runs. Add `--start` to boot it.
For containers, `unprivileged` is read back from the archive.

For disaster recovery, when the original is gone, `--keep-network` restores the
copy exactly as the original was (network, mounts, devices, autostart). pbo refuses
it while a guest with the original's vmid still exists anywhere in the cluster.

## Recovery without the tool, if the script is broken or gone

All you need is `restic`, the repo password, the SSH key for the target and `pct`
or `qm`. Take the repo and the SSH command from the config (or the DR export):
restic reads the SSH command only as the `sftp.command` option, not from an
environment variable, and the repo string is exactly `RESTIC_OFFSITE_REPO`.

```bash
REPO='sftp:storagebox:pbo'      # RESTIC_OFFSITE_REPO
SFTP='ssh uXXXXX-subN@uXXXXX-subN.your-storagebox.de -p 23 -i /root/.ssh/id_ed25519 -s sftp'   # RESTIC_SFTP_COMMAND
R() { restic -o sftp.command="$SFTP" -r "$REPO" --password-file /etc/pbo/restic-pass "$@"; }

R snapshots --tag vmid=<vmid>                     # what is offsite for that guest
R restore <snapshot-id> --target /var/tmp/dr      # pulls out the vzdump archive
# then, depending on the guest type:
pct restore <new-vmid> /var/tmp/dr/.../vzdump-lxc-<vmid>-<ts>.tar --storage <pool> --unprivileged <0|1>
qmrestore /var/tmp/dr/.../vzdump-qemu-<vmid>-<ts>.vma <new-vmid> --storage <pool>
```

The `unprivileged` value and any bind mounts are in the extracted `.conf`. (This
exact form has been tested against a Storage Box.)

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

## The Proxmox integration

Only with `PBO_INTEGRATION=both` or `integrated` (README, "Proxmox GUI").

- **Health.** `pbo integrate status` shows the mode, the versions, plugin,
  storage, hook, spool, catalogue, the Proxmox jobs to `pbo` and who owns which
  guest, plus the exact `storage.cfg` stanza and `vzdump.conf` line (keep those in
  your host recipe). `pbo doctor` fails on anything broken.
- **A Proxmox job to `pbo` failed.** Look at its task log. Archives still in the
  spool, or in the cache but not offsite, are finished by `pbo ingest --pending`
  (run-schedule does it too); doctor fails while one waits for more than 24 h.
- **After a Proxmox upgrade** (pve-manager, libpve-storage-perl, pve-container,
  qemu-server), run `tests/integration/pve-storage.sh --load-only` from a checkout
  and `pbo doctor`, which warns about versions newer than the tested set.
- **The plugin does not load** (Proxmox logs an unknown storage type `pbo`). The
  GUI loses the storage until it loads again; do not delete or re-add it in the
  GUI. Reinstall (`./install.sh --integration both`, or the `pbo-pve-storage`
  package) and `pbo integrate enable <mode>` converges storage.cfg and the hook.
- **The hook is missing.** Every vzdump on the node fails while
  `/etc/vzdump.conf` names a hook that is gone. Reinstall, or
  `pbo integrate disable --yes` to remove the line.
- **Back to standalone.** Delete or disable the Proxmox jobs that target `pbo`
  (pbo never edits jobs.cfg), then `pbo integrate disable --yes` and
  `./install.sh --integration standalone`. The pbo timer backs up every guest
  again from the next night.
- **Rebuilding the host.** Install pbo, restore `/etc/pbo` and the DR key, run
  `./install.sh --integration both`, `pbo integrate enable both`, then recreate the
  Proxmox jobs from your recipe. The snapshots are all in the repos; the catalogue
  is rebuilt from them.

## Moving the cache directory

`pbo config set CACHE_DIR <new>` moves the cache with its data (README, "Moving the
cache directory"; ADR 0009, "Cache move"). The procedure:

1. **Pick a time when nothing runs**: no pbo timer and no Proxmox backup job in the
   next hour (a copy to another filesystem takes as long as copying the cache).
2. **Read the plan.** `pbo --dry-run config set CACHE_DIR <new>` prints every check
   and every step and changes nothing. Fix what it refuses:
   - a directory above `<new>` that an unprivileged CT's root cannot pass: run the
     `setfacl -m u:<uid>:x <dir>` lines it prints, or add `--fix-parents`;
   - a filesystem without POSIX ACLs (ZFS `acltype=off`): `zfs set acltype=posixacl
     <dataset>`, or choose another one;
   - a `pbo` storage that is not this node's alone: `pvesm set pbo --nodes <node>`;
   - a filesystem mounted below the old cache (a dataset for its repo or spool):
     unmount it, or move its data into the cache's own filesystem, first;
   - a target, or a directory above it, that another user owns or can write:
     choose another place, or give it to root;
   - something running, an archive in the spool (`pbo ingest --pending`), not enough
     space, a path pbo will not take: as named.
3. **Move.** `pbo config set CACHE_DIR <new> --yes` (with `--verify-data` to read
   every pack of a copied repo, `--keep-old` to keep the old copy). It ends with
   `CACHE_DIR moved: <old> -> <new>`.
4. **Check.** `pbo doctor` (a line names the last move and fails while one is
   unfinished), `pvesm status` and the `pbo` storage in the GUI (enabled, its
   backups listed), `pbo config get CACHE_DIR`, and one `pbo backup <vmid>` of a small
   unprivileged CT: that proves the CT root can reach the new place through its ACL.
5. **If it stopped.** Before the config write pbo has already rolled back: the old
   cache, the storage and the mount are as they were, and the message says why. After
   it (the message says so, and `pbo doctor` fails), fix the cause and run
   `pbo config set CACHE_DIR <new> --resume`. After a crash or a killed pbo:
   `--resume` finishes the move from where it was; `--abort` undoes it as long as the
   config was not written yet (pbo refuses `--abort` after that). The journal is
   `STATE_DIR/cache-move.json`; never edit it, and never move the directory by hand
   while it says a move is unfinished.
6. **Moving back** is another move: `pbo config set CACHE_DIR <old> --yes`.

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
- **"repo locked" in a backup failure.** Another restic process holds an exclusive
  lock on the repo, usually a prune or `check` from another node. Write operations
  wait `RESTIC_RETRY_LOCK` (10m) before giving up. If the holder is dead, `pbo unlock`.
- **Prune removes nothing.** Retention always keeps the latest snapshot per guest.
  That is on purpose. `forget` (metadata) and `prune` (reclaiming space) are
  separate steps.
- **The provider has no append-only mode.** Plain SFTP means a compromised host
  can delete the offsite data. Either move offsite to an append-only rest-server
  with a janitor (README, "Append-only offsite"), or turn on your provider's
  scheduled snapshots and set `STORAGE_BOX_SNAPSHOTS_CONFIRMED=true`.
- **Append-only: offsite keeps growing.** The host never prunes it. Check the
  janitor: `systemctl status pbo-janitor.timer`, `runuser -u restic -- pbo doctor`.
- **Append-only: doctor says the server ACCEPTS deletes.** rest-server isn't running
  with `--append-only`, or the URL points at a different server. Fix that before
  trusting the setup.
- **Append-only: backups fail with permission errors after a janitor run.** Someone
  ran the janitor as root and left root-owned files in the repo. On the janitor:
  `chown -R restic:restic /srv/restic/<user>`. `doctor` there flags this.
- **Append-only: verifying it by hand.** From the host, `restic forget <id>` against
  the rest URL prints `403 Forbidden`, says "1 snapshots have been removed" and exits
  0, and the snapshot is still there. That's what append-only looks like.
- **Show Configuration or Restore in the Proxmox GUI says "retry in a few
  minutes".** pbo is staging the archive in the background (an offsite-only one is
  copied out with `restic dump`, a snapshot younger than about a minute is not in
  the mount yet). Try again; the staging logs are in `/var/lib/pbo/jobs/stage-*`.
- **A Proxmox backup job to `pbo` failed at job-end.** Its archives are in the cache
  repo but not offsite (or still in the spool). `pbo ingest --pending` finishes them;
  `pbo doctor` fails while one waits for more than 24 h.

## Where things live

| | |
|---|---|
| Program | `/usr/local/lib/pbo/` + `/usr/local/sbin/pbo` (install.sh), or `/usr/lib/pbo/` + `/usr/sbin/pbo` (.deb) |
| Config | `/etc/pbo/config` |
| DR key | `/etc/pbo/restic-pass`, mode 0600, the restic repo password |
| Cache | `CACHE_DIR` from the config, used when `LOCAL_REPO=true`; moved with `pbo config set CACHE_DIR`, journal `/var/lib/pbo/cache-move.json` |
| Logs | `/var/log/pbo/` (`pbo.log`, `audit.log`, `audit.jsonl`, all 0600) |
| Jobs | `/var/lib/pbo/runs/<id>/` (meta, log, result); per-run command logs in `/var/lib/pbo/jobs/` |
| Restore-test evidence | `/var/lib/pbo/restore-tests.jsonl`, `restore-report.{json,txt}` |
| Locks | `/run/pbo/` (root only; `pbo.cache` is held while the cache moves) |
| systemd | `pbo.timer`, `pbo-prune.timer`, `pbo-verify.timer`, `pbo-test-restore.timer` (+ `.service`); with the integration `pbo-catalog.timer`, `pbo-mount.service`; on a janitor `pbo-janitor.timer` |
| Proxmox integration | plugin `/usr/share/perl5/PVE/Storage/Custom/PboPlugin.pm`, hook `.../pbo/vzdump-hook`, catalogue `/var/lib/pbo/catalog/index.json`, spool `PVE_SPOOL_DIR`, staging `PVE_STAGING_DIR`, offsite copies pending `/var/lib/pbo/ingest-copy/` |
| Source | `github.com/TubalQ/PBO` |
