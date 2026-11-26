# Runbook

Operations manual for `pbo`. It backs up Proxmox guests (LXC containers and QEMU
VMs) offsite to an SFTP target or any other restic repository, deduplicated and
encrypted with restic. Run it on the Proxmox host as root. If you also run a
Proxmox Backup Server, pbo leaves it alone — it's the offsite leg of a 3-2-1 setup,
not a replacement.

Two ways to trust it: `restic check` verifies the repo, and `test-restore` boots a
throwaway copy to prove an actual restore works.

## Installing, including on a fresh host during recovery

```bash
git clone https://github.com/TubalQ/PBO && cd PBO
./install.sh          # installs the tool and units, does not enable the timer
pbo setup             # cache, offsite target, DR key (an existing one is kept), mode, retention, ntfy, init, guests, timers
```

`install.sh` also leaves a `lxc-offsite` symlink, because that was the old name
of the tool.

### Running pbo setup again

`pbo setup` is safe to run again, to change one thing or to check the rest. Every
question offers the current setting and Enter keeps it; an answer that keeps a
setting writes nothing, so a run that keeps everything leaves `/etc/pbo/config` as
it was. Every change goes through `pbo config set`.

- **Cache.** The local filesystems are listed with their free space, the one with
  the most is suggested (`<mount>/pbo-cache`; the default only on a first setup,
  after that a hint: Enter keeps the current CACHE_DIR and writes nothing), and a
  warning says when the root filesystem is smaller than 1.5 times the largest guest
  (all its disks). Another directory goes through `pbo config set CACHE_DIR`
  ([Moving the cache directory](#moving-the-cache-directory)): the wizard shows the
  dry run first, offers `--fix-parents` when a CT could not pass a directory above
  it, and moves only on a yes.
- **Offsite.** A configured repo is shown (its login masked) and kept unless you
  choose "change the target"; an append-only `rest:` repo is recognised as such.
  "Change" asks for the type: an SFTP server (any host, port, user and key; the repo
  is `sftp:<user>@<host>:<path>`, and `RESTIC_SFTP_COMMAND` is written only when the
  port, the key or the pinned host key needs it), a rest-server (URL, user, a 0600
  password file, append-only or not), a local or mounted directory, or another
  restic backend (the repository string, and its credentials into `RESTIC_ENV_FILE`,
  0600; values are read without echo and never shown). A Storage Box host gets its
  defaults (port 23, the account as the user) and the question whether the box
  takes snapshots (`STORAGE_BOX_SNAPSHOTS_CONFIRMED`). Replacing a repo asks first:
  pbo moves no snapshot, the old ones stay where they are. ssh options of your own
  in `RESTIC_SFTP_COMMAND` (a `ProxyJump`, `-F`) stay when you keep the host.
- **DR key.** The targets are checked first (read only). A repo that exists there
  is never given a new key: the wizard asks for its key (a password file, an export
  with a `RESTIC_PASSWORD=` line, or typed) and writes it only once it opens the
  repo. A target that cannot be reached is asked about ("does it hold a repo
  already?", yes by default); a key that cannot be checked there can be taken
  unchecked, or dropped for a generated one when there is no repo after all. A key
  file that does not open the repo stops setup.
- **Timers.** A timer that is off is offered with yes on a first setup and with no
  on a re-run, so Enter never turns on one you left off.
- **Short input.** The end of the input stops the wizard at that question (exit 64);
  it never takes a default for an answer it did not get.
- **Numbers and schedules** are checked against the schema and asked again until
  they are valid; a schedule is written with its timer drop-in.
- **Last**, `pbo doctor --fix` applies the permission table and shows the report.

## Upgrading to 0.6

pbo 0.6 reads `/etc/pbo/config` with a strict `KEY=VALUE` reader instead of
running it as shell code, and refuses a config with shell code in it (every
command, timer and the vzdump hook then exit 78). The full list of changes, and
of what is refused and how to write it instead, is in `CHANGELOG.md`, "Upgrading
from 0.5". The order:

1. **Check the config with the new reader before you install.** From a checkout of
   the new version (it reads `/etc/pbo/config`, and in a cluster
   `/etc/pve/pbo/config`, and does not change it):

   ```bash
   git clone https://github.com/TubalQ/PBO pbo-0.6 && cd pbo-0.6
   ./pbo config check                  # every line 0.6 refuses or warns about, by file and line
   ./pbo config check --compare-bash   # also sources the file as 0.5 did (it RUNS it): keys read differently
   ```

   Fix each error by hand (a value instead of a command, quotes around a value
   with blanks, the full path instead of `~`) and run the check again until it
   reports none. Warnings do not stop pbo.
2. **restic.** pbo 0.6 needs restic 0.14.0 or newer (`RESTIC_MIN`), 0.16.1 with a
   rest-server login. `install.sh` refuses an older one before it copies a file;
   install a newer restic (and set `RESTIC_BIN` if it is not the one on `PATH`).
3. **Install.** `./install.sh` (with your usual `--integration`) reads the configs
   and `RESTIC_ENV_FILE` again and changes nothing while 0.6 would refuse them
   ("Nothing was changed"; `--force` installs anyway, and then every command stops
   until the config is fixed). With the `.deb` (`apt install ./pbo_<version>_all.deb`)
   nothing can stop the upgrade: its postinst prints what `pbo config check` finds.
4. **After the install:**

   ```bash
   pbo config check              # no errors
   pbo doctor                    # the new checks: permissions, split guests, timers, storage id, restic
   pbo --dry-run doctor --fix    # what the permission table and the timer drop-ins would change
   pbo doctor --fix              # apply it (--fix-parents when a CT cannot pass a directory above CACHE_DIR)
   ```

5. **Retention per guest.** When doctor lists a guest whose snapshots lie under
   more than one path, the next prune retains them as one guest and removes what
   0.5 kept for the old path. Look first:

   ```bash
   pbo --dry-run prune           # what retention would remove, per tier
   pbo list --reasons <vmid>     # why each snapshot of that guest is kept
   ```

   `pbo config set RETENTION_GROUP_BY paths` keeps the 0.5 grouping for 0.6 only.
6. **Schedules.** If you changed a timer's time with `systemctl edit` before 0.6, that
   `override.conf` wins as long as the key is at its default (`pbo timers` and `pbo
   doctor` say so).
   Move the time into its key ([Changing the schedule](#changing-the-schedule)), then
   remove the `OnCalendar=` lines from the override (`systemctl edit pbo.timer`). Do not
   use `systemctl revert`: it also removes the drop-in pbo writes.
7. **A cluster with the Proxmox integration** keeps its `pbo` storage; doctor names
   the move to one storage per node ([In a cluster](#in-a-cluster)). Do it when it
   suits you; nothing breaks meanwhile.

Going back to 0.5: every file pbo 0.6 writes is valid bash, so 0.5 reads the config.
The timer drop-ins stay in effect (`pbo config unset SCHEDULE_BACKUP` and the others
before the downgrade, if you want the units' times back), and 0.5 does not read
`RESTIC_ENV_FILE`.

## Configuration is one file plus one secret

Everything operational lives in `/etc/pbo/config` as `KEY=VALUE` lines. pbo reads
them, it never runs them. `pbo config list` shows every key with its value and
where it comes from; change keys with `pbo config set` and `pbo config unset`
(README, "Configuration"), which check, quote and keep the file's comments and
mode. The keys you are most likely to touch:

- `RESTIC_OFFSITE_REPO` is the repo: `sftp:<user>@<host>:<path>` (a Storage Box
  account is chrooted, so its path is relative), `rest:https://<host>:<port>/<path>`,
  a directory, or another restic backend (`s3:`, `b2:`, `azure:`, `gs:`, `swift:`,
  `rclone:`, with its credentials in `RESTIC_ENV_FILE`, below). A new value needs
  `--yes`: pbo moves no snapshot, and pointing it somewhere else orphans every
  snapshot already in the old repo.
- `RESTIC_SFTP_COMMAND` is the full ssh command restic runs for an sftp repo, with
  host, port, key and the pinned host key. Without it restic runs `ssh <user>@<host>
  -s sftp` (port 22, the default keys).
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
- `SCHEDULE_*` are the timers' times ([Changing the schedule](#changing-the-schedule)).

The restic repo password is also your disaster-recovery key. It lives in
`RESTIC_PASSWORD_FILE`, by default `/etc/pbo/restic-pass`, mode 0600. Export it
(menu, then Export DR key) to a password manager and to something offline. Without
it, the offsite data is gone for good. The config is 0600 too: it can hold an ntfy
token/topic and the SFTP command, so keep it out of version control.

### Backends with credentials in the environment

S3, B2, Azure, Google Cloud Storage, Swift and rclone read their credentials from
environment variables. They go in `RESTIC_ENV_FILE` (default `/etc/pbo/restic.env`),
one `KEY=VALUE` per line, in the config's grammar. pbo gives them to restic and to
nothing else. `pbo setup` writes the file for you when you choose "another restic
backend"; by hand:

1. Create the file, root's and 0600, before anything goes into it, and write the
   variables your backend reads: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
   (`AWS_DEFAULT_REGION` when needed) for `s3:`; `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY`
   for `b2:`; `AZURE_ACCOUNT_NAME` and `AZURE_ACCOUNT_KEY` (or `AZURE_ACCOUNT_SAS`)
   for `azure:`; `GOOGLE_PROJECT_ID`, `GOOGLE_APPLICATION_CREDENTIALS` for `gs:`; the
   `OS_*` variables for `swift:`; `RCLONE_CONFIG` for `rclone:` when its config is not
   in rclone's default place.

   ```bash
   install -m 0600 -o root -g root /dev/null /etc/pbo/restic.env
   ```

2. Check it, point the repo at the backend, create the repo and check the whole:

   ```bash
   pbo config check                                                # the file's errors by line, never a value
   pbo config set RESTIC_OFFSITE_REPO s3:s3.example.net/bucket/pbo --yes
   pbo init
   pbo doctor
   ```

pbo refuses the file, and stops every command with exit 78 except `config`, `doctor`,
`version` and `help` (which diagnose it, and refuse only a restic call), when it is a
symlink, owned by another user, writable by group or others or readable by others,
or when it sets what pbo sets for restic itself or what would change which program
runs: `PATH`, `LD_*`, `RESTIC_PASSWORD*`, `RESTIC_REPOSITORY*`, `RESTIC_FROM_*`,
`RESTIC_CACHE_DIR`, `RESTIC_HOST`, the rest-server login or any config key (those
belong in the config). `pbo config check` and `pbo doctor` name the file and its
variable names, never a value; `pbo doctor --fix` sets its mode. It is per node: the
cluster-shared config cannot name it, so each node of a cluster has its own.

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

### Changing the schedule

The times are config keys in systemd's `OnCalendar=` syntax: `SCHEDULE_BACKUP`,
`SCHEDULE_PRUNE`, `SCHEDULE_VERIFY`, `SCHEDULE_TEST_RESTORE`, `SCHEDULE_CATALOG` (and
`SCHEDULE_JANITOR` on a janitor), each with a `_DELAY` key for its
`RandomizedDelaySec=` where the timer has one (not `pbo.timer`). Do not edit the unit
files: a reinstall or a package upgrade puts the defaults back.

```bash
systemd-analyze calendar --iterations=3 "Mon..Fri *-*-* 22:30:00"   # try the expression first
pbo --dry-run config set SCHEDULE_BACKUP "Mon..Fri *-*-* 22:30:00"  # the config diff and the drop-in it would write
pbo config set SCHEDULE_BACKUP "Mon..Fri *-*-* 22:30:00"
pbo timers                                                           # SCHEDULE, SOURCE (config), NEXT
systemctl list-timers 'pbo*'
pbo config unset SCHEDULE_BACKUP                                     # back to the default, the drop-in goes
```

`config set` refuses a value systemd cannot parse (exit 78, nothing written),
writes `/etc/systemd/system/pbo.timer.d/schedule.conf` (it clears the unit's
`OnCalendar=`, then sets the new one) and reloads systemd. A schedule change resets
the timer's persistent state: an enabled timer is stopped first, its last-trigger
stamp is cleared (`systemctl clean --what=state`) and it is started again if it was
running, so its next run is computed from now. Moving a time to earlier than the
last run therefore does not start the job at once, and a run missed under the old
schedule is not caught up. A disabled timer stays disabled.

If the config was edited by hand, or in the cluster-shared file, `pbo doctor` warns
that the drop-in does not match; write it with:

```bash
pbo timers apply                                                     # every drop-in of this role, from the config
```

(`pbo doctor --fix` does the same.) The SCHEDULE column of `pbo timers` is the
calendar systemd runs: an `override.conf` from `systemctl edit` that sets
`OnCalendar=` wins over a key at its default (once the key is set, pbo's
`schedule.conf` sorts after it and replaces it), and `pbo timers` and `pbo doctor`
say so; remove
its `OnCalendar=` lines and set the key instead. `pbo doctor` also warns when a
Proxmox backup job to pbo starts within `PVE_JOB_WINDOW_MIN` minutes of the backup,
prune or verify schedule.

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
REPO='sftp:pbo@backup.example:pbo'                              # RESTIC_OFFSITE_REPO
SFTP='ssh pbo@backup.example -p 2222 -i /root/.ssh/id_ed25519 -s sftp'   # RESTIC_SFTP_COMMAND (if the config has one)
R() { restic -o sftp.command="$SFTP" -r "$REPO" --password-file /etc/pbo/restic-pass "$@"; }

R snapshots --tag vmid=<vmid>                     # what is offsite for that guest
R restore <snapshot-id> --target /var/tmp/dr      # pulls out the vzdump archive
# then, depending on the guest type:
pct restore <new-vmid> /var/tmp/dr/.../vzdump-lxc-<vmid>-<ts>.tar --storage <pool> --unprivileged <0|1>
qmrestore /var/tmp/dr/.../vzdump-qemu-<vmid>-<ts>.vma <new-vmid> --storage <pool>
```

The `unprivileged` value and any bind mounts are in the extracted `.conf`. Without
a `RESTIC_SFTP_COMMAND` in the config, drop the `-o sftp.command=...`; for another
backend, export the variables of `RESTIC_ENV_FILE` first (`set -a; .
/etc/pbo/restic.env; set +a` in that shell). This form works with SFTP targets
such as a Storage Box.

The key is a single point of failure. restic encrypts everything, so without the
password you cannot even list the snapshots. Keep it in a password manager and
offline, and test a recovery from a clean machine at least once.

## In a cluster

Install `pbo` on each node. Each node backs up its own guests into the same repo,
so you get cluster-wide dedup with no central coordinator. Points to remember:

- The same repo password goes on every node, in `/etc/pbo/restic-pass`. It never
  goes in `/etc/pve`, which pmxcfs replicates in cleartext.
- You can share the non-secret config through `/etc/pve/pbo/config` (`pbo config set
  --shared`) so you edit it once. The local file still wins where they differ. Keys
  that run a program or describe one node (`RESTIC_SFTP_COMMAND`, `RESTIC_BIN`,
  `RESTIC_ENV_FILE`, `PVE_STORAGE_ID`, ...) are ignored there: set them per node.
- Prune from one node only, or set `PRUNE_OWNER`, because prune takes an exclusive
  lock.
- Stagger the backup times per node (`pbo config set SCHEDULE_BACKUP ...` on each
  node, in its local config). A schedule set with `--shared` reaches every node's
  config, but only the node that ran it gets its timer updated: run `pbo timers
  apply` on the others (their doctor warns until then).
- With the Proxmox integration each node has its own storage, `pbo-<node>`
  (`nodes <node>`, the path of that node's spool): storage.cfg is one file for the
  whole cluster, and a storage has one path. `pbo integrate enable` on a node of a
  cluster creates it and pins `PVE_STORAGE_ID=pbo-<node>` in the local config; a
  single node keeps `pbo`; a storage pbo made for this node before keeps its id.
  Make one Proxmox backup job per node, on that node's storage (`Node: <node>`,
  `Storage: pbo-<node>`). A job for every node on one node's storage fails on the
  others, and pbo does not count it as backing up their guests.
- **Moving off the shared `pbo` storage** (a cluster that enabled the integration
  before 0.6; doctor warns "storage 'pbo' in a cluster of N nodes"). On each node
  that uses it, one node at a time:
  1. In Datacenter -> Backup, disable the jobs that write to `pbo` (or point them at
     another storage for the moment). pbo never edits jobs.cfg.
  2. Leave the integration; it ingests what is left in the spool, and while `pbo`
     still serves other nodes it takes this node off the storage's `nodes` instead
     of removing it (the last node removes it). pbo.timer backs up every guest
     meanwhile.

     ```bash
     pbo integrate disable --yes
     ```

  3. Give the node its own id and enable the integration again (`both`, or `integrated`
     if that was the mode); it adds `pbo-<node>` with this node's spool:

     ```bash
     pbo config set PVE_STORAGE_ID pbo-<node>
     pbo integrate enable both
     ```

     (Unsetting `PVE_STORAGE_ID` is enough only once `pbo` no longer serves this
     node.)
  4. Recreate the jobs by hand, one per node, with `Storage: pbo-<node>`, and
     delete the old ones. The snapshots stay where they are: the GUI lists them
     under the new storage.

  A node whose config names another node's storage is refused by `pbo integrate
  enable` (its spool path would be repointed) and by `pbo integrate disable` (it
  would remove that storage for the whole cluster), and failed by doctor.

## The Proxmox integration

Only with `PBO_INTEGRATION=both` or `integrated` (README, "Proxmox GUI").

- **Health.** `pbo integrate status` shows the mode, the versions, plugin,
  storage (`pbo`, or `pbo-<node>` in a cluster), hook, spool, catalogue, the
  Proxmox jobs to it and who owns which guest, plus the exact `storage.cfg` stanza
  and `vzdump.conf` line (keep those in your host recipe). `pbo doctor` fails on
  anything broken.
- **A Proxmox job to `pbo` failed.** Look at its task log. Archives still in the
  spool, or in the cache but not offsite, are finished by `pbo ingest --pending`
  (run-schedule does it too); doctor fails while one waits for longer than
  `PVE_SPOOL_MAX_AGE` (24 h).
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

`pbo config set CACHE_DIR <new>` moves the cache with its data; what it checks and
does, step by step, is in README, "Moving the cache directory". The procedure:

1. **Pick a time when nothing runs**: no pbo timer and no Proxmox backup job in the
   next hour (a copy to another filesystem takes as long as copying the cache).
2. **Read the plan.** It prints every check and every step and changes nothing:

   ```bash
   pbo --dry-run config set CACHE_DIR <new>
   ```

   Fix what it refuses:
   - a directory above `<new>` that an unprivileged CT's root cannot pass: run the
     `setfacl -m u:<uid>:x <dir>` lines it prints, or add `--fix-parents`;
   - a filesystem without POSIX ACLs (ZFS `acltype=off`): `zfs set acltype=posixacl
     <dataset>`, or choose another one;
   - a pbo storage that is not this node's alone (`pbo config get PVE_STORAGE_ID`
     names it): in a cluster where other nodes use it (the shared `pbo` from before
     0.6), first move this node to its own storage, "Moving off the shared `pbo`
     storage" in [In a cluster](#in-a-cluster), and then move the cache. Run `pvesm
     set <id> --nodes <node>` only when no other node uses that storage, for example
     on a single node; on a shared storage it takes the storage from every other
     node, and their jobs and GUI restores with it;
   - a filesystem mounted below the old cache (a dataset for its repo or spool):
     unmount it, or move its data into the cache's own filesystem, first;
   - a target, or a directory above it, that another user owns or can write:
     choose another place, or give it to root;
   - a network filesystem: only with `--force`, and know that ACLs and renames there
     are untested;
   - something running, an archive in the spool (`pbo ingest --pending`), not enough
     space, a path pbo will not take: as named.
3. **Move.** Add `--verify-data` to read every pack of a copied repo, `--keep-old` to
   keep the old copy. It ends with `CACHE_DIR moved: <old> -> <new>`.

   ```bash
   pbo config set CACHE_DIR <new> --yes
   ```

4. **Check.** `pbo doctor` (a line names the last move and fails while one is
   unfinished), `pvesm status` and the pbo storage in the GUI (enabled, its backups
   listed), `pbo config get CACHE_DIR`, and one `pbo backup <vmid>` of a small
   unprivileged CT: that proves the CT root can reach the new place through its ACL.
5. **If it stopped.** Before the config write pbo has already rolled back: the old
   cache, the storage and the mount are as they were, and the message says why. After
   it (the message says so, and `pbo doctor` fails), fix the cause and finish the
   move. After a crash or a killed pbo, `--resume` finishes the move from where it
   was; `--abort` undoes it as long as the config was not written yet (pbo refuses
   `--abort` after that):

   ```bash
   pbo config set CACHE_DIR <new> --resume
   pbo config set CACHE_DIR <new> --abort
   ```

   The journal is `STATE_DIR/cache-move.json`; never edit it, and never move the
   directory by hand while it says a move is unfinished.
6. **Moving back** is another move: `pbo config set CACHE_DIR <old> --yes`.

`pbo setup` runs the same move from its cache step: it shows the plan of step 2,
offers `--fix-parents` when the plan needs it, and moves on a yes. On a janitor the
cache is moved only while it is empty.

## Gotchas and troubleshooting

- **Every pbo command exits 78 after an upgrade.** The config has a line pbo 0.6
  refuses (shell code, an unquoted value with a blank, ...). `pbo config check` names
  each one with its file and line; [Upgrading to 0.6](#upgrading-to-06).
- **A fuse container freezes during backup.** It should not, because the tool
  forces `--mode stop` for any guest with `features fuse=1`. If one freezes
  anyway, kill the stuck `vzdump` or `rsync` process, the one in state
  `request_wait_answer`, and the container resumes. `fsfreeze -u` does not help,
  because it is the live fuse mount that hangs.
- **SFTP is slow or throws errors.** That is usually rate limiting. Keep
  `RESTIC_SFTP_CONNECTIONS` under the provider limit, which is around 10 on
  Hetzner, especially while test processes are also running.
- **`init` or list fails.** Check `RESTIC_OFFSITE_REPO`, check `RESTIC_SFTP_COMMAND`
  for the right port and key (or `RESTIC_ENV_FILE` for a cloud backend), and check
  that `RESTIC_PASSWORD_FILE` exists and is readable at mode 0600.
- **"repo locked" in a backup failure.** Another restic process holds an exclusive
  lock on the repo, usually a prune or `check` from another node. Write operations
  wait `RESTIC_RETRY_LOCK` (10m) before giving up. If the holder is dead, `pbo unlock`.
- **Prune removes nothing.** Retention always keeps the latest snapshot per guest.
  That is on purpose. `forget` (metadata) and `prune` (reclaiming space) are
  separate steps.
- **Exit 75 from a backup, restore or `pbo init`, and doctor fails on a cache
  move.** A cache move is unfinished: finish it (`--resume`) or undo it (`--abort`),
  [Moving the cache directory](#moving-the-cache-directory), step 5.
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
  copied out with `restic dump`, a snapshot that new is not in
  the mount yet for a while). Try again; the staging logs are in `/var/lib/pbo/jobs/stage-*`.
- **A Proxmox backup job to `pbo` failed at job-end.** Its archives are in the cache
  repo but not offsite (or still in the spool). `pbo ingest --pending` finishes them;
  `pbo doctor` fails while one waits for longer than `PVE_SPOOL_MAX_AGE`.

## Where things live

| | |
|---|---|
| Program | `/usr/local/lib/pbo/` + `/usr/local/sbin/pbo` (install.sh), or `/usr/lib/pbo/` + `/usr/sbin/pbo` (.deb) |
| Config | `/etc/pbo/config` (in a cluster also `/etc/pve/pbo/config`, the local file wins); every key in `etc/config.example` |
| DR key | `/etc/pbo/restic-pass`, mode 0600, the restic repo password |
| Backend credentials | `RESTIC_ENV_FILE`, default `/etc/pbo/restic.env`, mode 0600 (only for backends that need it) |
| Cache | `CACHE_DIR` from the config, used when `LOCAL_REPO=true`; moved with `pbo config set CACHE_DIR`, journal `/var/lib/pbo/cache-move.json` |
| Logs | `/var/log/pbo/` (`pbo.log`, `audit.log`, `audit.jsonl`, all 0600) |
| Jobs | `/var/lib/pbo/runs/<id>/` (meta, log, result); per-run command logs in `/var/lib/pbo/jobs/` |
| Restore-test evidence | `/var/lib/pbo/restore-tests.jsonl`, `restore-report.{json,txt}` |
| Locks | `/run/pbo/` (root only; `pbo.config` while the config is written, `pbo.cache` while the cache moves) |
| systemd | `pbo.timer`, `pbo-prune.timer`, `pbo-verify.timer`, `pbo-test-restore.timer` (+ `.service`); with the integration `pbo-catalog.timer`, `pbo-mount.service`; on a janitor `pbo-janitor.timer`. A schedule other than the default: `/etc/systemd/system/<timer>.d/schedule.conf` |
| Proxmox integration | plugin `/usr/share/perl5/PVE/Storage/Custom/PboPlugin.pm`, hook `.../pbo/vzdump-hook`, catalogue `/var/lib/pbo/catalog/index.json`, spool `PVE_SPOOL_DIR`, staging `PVE_STAGING_DIR`, offsite copies pending `/var/lib/pbo/ingest-copy/` |
| Source | `github.com/TubalQ/PBO` |
