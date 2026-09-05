# pbo — plan

A new tool, built from scratch. It takes a local, verified `vzdump` archive file of
an LXC, ships it offsite via SFTP, and can fetch it back to a local cache for
restore. With a PBS-style interface.

`RESEARCH.md` shows why no existing project is good enough as a foundation: those
that exist lack verification, offsite retention, or both. We inherit no codebase.

**Design principle:** it must be possible to troubleshoot the tool at three in the
morning by someone who did not write it. Every decision below where simplicity
wins over efficiency is deliberate.

Target environment: Proxmox VE, cluster `mycluster`, ZFS pools `nvmepool` / `newbulk`.
Offsite: Hetzner Storage Box (SFTP, port 23) via rclone.

---

## 1. Why vzdump and not PBS

| | PBS datastore | vzdump archive |
|---|---|---|
| Artifact | chunk store, thousands of objects | **one file** per snapshot |
| Requires hardlinks | yes | no |
| Requires random access | yes | no |
| Works over SFTP | **no** | **yes** |
| Dedup between runs | yes | no |

PBS on 192.0.2.10 stays untouched as the primary local tier (fast restore, dedup).
This tool is the **offsite arm** — the third copy in 3-2-1. They do not compete.

The price of the SFTP path: no dedup between runs. Every offsite archive is full.

This is the only trade-off in the entire design worth questioning, so it deserves
to be spelled out. The alternative would be a Borg repo over port 23, which gives
dedup and compression. It was rejected for three reasons:

1. Dedup against an already zstd-compressed archive is effectively zero —
   compression destroys the chunk similarity between versions. To get any benefit
   from Borg you have to dump uncompressed, which requires considerably more local
   space and an extra compression step afterward for the cache.
2. The restore path becomes one step longer and one step more to troubleshoot.
3. Append-only, the one thing Borg would give us that rclone does not, does not
   work reliably on Storage Box. See `RESEARCH.md` section 7.

A full copy that can always be restored beats a deduplicated repo that requires
you to understand chunk formats under pressure. The cost is disk space, and disk
space on Storage Box is cheap.

---

## 2. Data flow

### Backup (local → offsite)

```
LXC (running)
  │  vzdump --mode snapshot            ZFS snapshot, ~seconds frozen
  ▼
/var/cache/pbo/<vmid>/
  vzdump-lxc-<vmid>-<ts>.tar.zst       the artifact
  vzdump-lxc-<vmid>-<ts>.tar.zst.sha256
  vzdump-lxc-<vmid>-<ts>.meta.json     vmid, hostname, storage, size, pve-version
  │
  │  1. sha256 computed locally
  │  2. tar integrity tested (zstd -t + tar -tf)
  │  3. rclone copy → offsite (crypt over sftp)
  │  4. rclone check --checksum against offsite
  ▼
offsite:lxc/<vmid>/...
```

The order is not negotiable: **verify locally before upload**, and **verify offsite
before local prune**. An archive that has never been verified is not a backup.

### Restore (offsite → cache → LXC)

```
offsite:lxc/<vmid>/
  │  rclone lsjson              list available archives
  │  rclone copy → cache        only the selected archive
  ▼
/var/cache/pbo/restore/
  │  sha256 -c                  against the sidecar file
  │  zstd -t                    structure check
  ▼
pct restore <new-vmid> <archive> --storage <pool> --unprivileged <0|1>
```

**Always restore to a new vmid** by default. Overwriting a running container from
a script is how you lose production data.

---

## 3. Components

```
/usr/local/lib/pbo/
  pbo            main script (bash, set -Eeuo pipefail)
  lib/backup.sh
  lib/restore.sh
  lib/verify.sh
  lib/notify.sh          ntfy
  api/                   FastAPI app, thin shell around the CLI
  web/                   static frontend, no build step
/etc/pbo/
  config                 KEY=VALUE, chmod 600
  rclone.conf            chmod 600, root:root
  api.env                bind address, OIDC settings, chmod 600
/var/cache/pbo/  ZFS dataset, own quota
/var/log/pbo/
  pbo.log
  audit.log              who did what via the GUI
/var/lib/pbo/
  state.json
  jobs/                  one file per asynchronous job
```

Subcommands:

| Command | Does |
|---|---|
| `backup <vmid>` | dump → verify → upload → verify → prune, one container |
| `run-schedule` | runs `backup` for each vmid in `BACKUP_ORDER`, sequentially |
| `status` | shows running jobs, queue length, and what holds the global lock |
| `list [vmid]` | lists offsite archives with size and date |
| `fetch <vmid> <ts>` | fetches an archive to cache, verifies |
| `restore <vmid> <ts> --to <new-vmid>` | fetch + `pct restore` |
| `verify <vmid>` | compares local and offsite hashes |
| `prune` | cleans up cache and offsite according to policy |
| `test-restore <vmid>` | full restore to a throwaway vmid, boot, then destroy |

---

## 4. Configuration

```ini
# /etc/pbo/config
CACHE_DIR=/var/cache/pbo
RCLONE_REMOTE=hetzner-crypt
REMOTE_PATH=lxc
VZDUMP_MODE=snapshot
VZDUMP_COMPRESS=zstd
VZDUMP_ZSTD_THREADS=4
RCLONE_TRANSFERS=4
RCLONE_CHECKERS=4          # < 8, Hetzner limit is 10 connections
RCLONE_BWLIMIT=            # e.g. "40M" at night
BACKUP_ORDER=101,102,103        # order for run-schedule, one at a time
GLOBAL_LOCK_TIMEOUT=7200        # seconds a scheduled run waits in the queue
KEEP_LOCAL=2
KEEP_OFFSITE_DAILY=7
KEEP_OFFSITE_WEEKLY=4
KEEP_OFFSITE_MONTHLY=6
NTFY_URL=https://ntfy.example/pbo
NTFY_ON_SUCCESS=false      # alert on failure, not on success
```

rclone remote, best practice for Hetzner Storage Box:

```ini
# /etc/pbo/rclone.conf
[hetzner]
type = sftp
host = uXXXXX.your-storagebox.de
user = uXXXXX
port = 23
key_file = /etc/pbo/id_ed25519
shell_type = unix
md5sum_command = md5sum
sha1sum_command = sha1sum

[hetzner-crypt]
type = crypt
remote = hetzner:pbo
filename_encryption = standard
directory_name_encryption = true
password = <rclone obscure>
password2 = <rclone obscure>
```

`md5sum_command` / `sha1sum_command` are set explicitly — Storage Box has them in
its restricted SSH environment, but rclone does not always find them via
autodetection. Without them, `rclone check --checksum` falls back to a size
comparison, which is not verification.

---

## 5. Retention

The local cache is just that — a cache: short and small.

- **Local:** the 2 most recent archives per vmid. Enough for fast rollback, keeps
  the dataset small.
- **Offsite:** 7 daily, 4 weekly, 6 monthly.

**Storage Box snapshots must be enabled and scheduled in the Hetzner console.**
This is not optional. SFTP provides no append-only, and Borg's append-only is not
reliable on Storage Box, so snapshots are the only thing that stops a compromised
Proxmox host from deleting the entire offsite copy. The tool must warn in the
dashboard if it cannot confirm that snapshots are enabled.

Because vzdump archives are not deduplicated against each other, the offsite size
is `number_retained × archive_size`. Do the math before you set the policy.

---

## 6. Pitfalls that must be handled in the code

**Bind mounts are not backed up.** `vzdump` includes mountpoints that have
`backup=1`. Bind mounts (`mp0: /host/path,mp=/data`) cannot be backed up at all
and are skipped **silently**. The tool must read `/etc/pve/lxc/<vmid>.conf`,
detect bind mounts and `backup=0` volumes, and print an explicit warning in the
log and in the meta file. A backup that silently omits your data is worse than no
backup.

**Partial uploads.** rclone uploads to a temporary name and renames on completion
— but only if `--inplace` is *not* used. Never set `--inplace`.

**The connection limit.** At most 10 concurrent connections to Storage Box.
`--checkers` and `--transfers` must sum to well under that, otherwise you get md5
errors that look like data corruption but are rate limiting.

**The crypt key is a single point of failure.** With `filename_encryption = standard`
you cannot even list the archives without the rclone configuration. Lost key = all
offsite backups lost. `password` and `password2` must exist in your password manager **and**
on paper or USB outside the house. Test a restore from a clean machine with the key
alone, at least once.

**Offsite is deletable.** SFTP provides no append-only, and Borg's append-only mode
is not an option here — it still permits `delete` and `prune`, and the server-side
variant cannot be set up on Storage Box's restricted shell. A compromised Proxmox
host with the rclone credentials can therefore delete the entire offsite directory.
The only countermeasure is Storage Box's own scheduled snapshots. Without them this
is a copy with extra steps, not ransomware protection.

**ZFS space.** `--mode snapshot` requires space in the pool. A full pool aborts the
dump. Preflight check: require free space ≥ 1.5 × the container's used size.

**Overlapping runs — global serialization.** The tool runs **one LXC at a time**,
never two in parallel. The reason is I/O: `vzdump --mode snapshot` reads heavily
from the pool while ZFS holds a snapshot open, and two concurrent dumps against
`newbulk` (raidz2) give both slower backups and noticeably worse response times for
the containers that are running.

Two locks, not one:

- **Global lock** (`/var/lock/pbo.global`) — lets through exactly one
  backup or push operation at a time, regardless of vmid.
- **Per-vmid lock** — prevents the same container from being queued twice.

Scheduled runs **queue** on the global lock with a timeout; they do not exit.
Manual runs from the CLI or GUI exit immediately with a clear message about what
is blocking and how long it has been running. The distinction matters: a scheduled
run that silently exits becomes a backup that was never taken.

Fetch and restore do **not** take the global lock — they do not write from the
pool and must be runnable during an in-progress backup.

**Clock skew.** Never sync on modtime. All comparisons use `--checksum`.

**The unprivileged flag.** `pct restore` must match the original's `unprivileged`
setting. Read it from the archive's config and set it explicitly instead of relying
on the default.

**Restore without the tool.** Document in the runbook how to fetch and unpack an
archive with only `rclone` and `pct` — if the script is broken or gone, a human
must be able to do it by hand.

**Bind mounts cannot be recreated via the GUI.** They contain arbitrary host paths
and are root-restricted, so after a restore they must be set manually with
`pct set`. Therefore save the original's `.conf` as a separate sidecar file offsite
and show it in the GUI at restore time.

**The hook script is called by every backup job.** It cannot be attached to a
single job — condition on VMID inside the script, otherwise you unintentionally
send everything offsite.

**`backup-end` does not mean success.** There is no status variable. Treat
`backup-abort` as the failure signal; never assume that `backup-end` means it went
well.

**There is no plugin API for PVE's web interface.** Do not patch pve-manager to
add a tab. A standalone app on its own port.

---

## 7. GUI

See `RESEARCH.md` for the basis behind the decisions below.

### Two interfaces, not one

The local cache is registered as a PVE directory storage. That gives you **PVE's
own backup interface for free** for everything already present locally: list, date,
size, restore button, prune settings, protected backups.

```bash
pvesm add dir pbo-cache \
  --path /var/cache/pbo \
  --content backup \
  --is_mountpoint 1 \
  --shared 0
```

Our own GUI we build only for what PVE **cannot** do: the offsite inventory, push,
fetch, verification status, and configuration. Duplicating the restore view would
be waste and would also produce two truths about what exists.

### Technology choice

A standalone web application on its own port, built with ExtJS and
`proxmox-widget-toolkit` from `/usr/share/javascript/`. The same widgets PBS uses,
so an identical look — not an imitation.

PVE's own GUI files are **never** patched. The project is licensed AGPL-3.0.

### Views

**Dashboard.** Per LXC: last successful offsite push, number of archives offsite,
total size, age of the oldest and newest, verification status. Red row if the last
push is older than `MAX_AGE_WARN`. This is the view that should answer "are my
backups OK" in three seconds.

**Offsite archives.** Grid with vmid, hostname, timestamp, size, age, verified
yes/no. Column sorting and per-vmid filter. Row actions: *Fetch to cache*,
*Verify*, *Delete*.

**Local cache.** The same grid for the cache, plus *Push to offsite* and *Delete
locally*. A link to PVE's backup view for the actual restore.

**Jobs.** Running and historical jobs with a real-time log, in the same style as
the PBS task log. Each job has status, start time, duration, and full output.

Because the tool runs one container at a time, the view must show the **queue**:
what is running now, what is waiting, and for how long. Without it, a queued backup
looks like a backup that is not happening. Manually starting a container that is
already queued must give a clear message, not silently add it again.

**Configuration.** A form against `/etc/pbo/config`: retention policy per
tier, bandwidth limit, schedule, ntfy URL, cache quota. Validation before writing,
and the configuration is versioned — every change is saved with a timestamp and
user so that a faulty retention change can be traced and rolled back.

**The hook-script path is not editable in the GUI.** It requires root@pam because
it allows execution of arbitrary code. Show it as read-only text.

### Backend

A FastAPI app that **only** calls the same CLI everything else uses, with `--json`.
No business logic in the API layer. If the GUI and the CLI can give different
answers, we have built it wrong.

Long-running operations (backup, push, fetch, restore, verify) are started as
transient systemd units via `systemd-run --unit=pbo-job-<id>` and return a
job ID immediately. The GUI polls status. **No HTTP request may wait on an rclone
upload** — that produces timeouts that look like failures but are not.

### Security

The API runs as a dedicated user, not root. Exactly the commands that need
elevated privileges are listed in a `sudoers` file with full paths and no
wildcards.

Authentication via an OIDC provider through a reverse proxy forward-auth. The API binds to
the node's LAN address and the firewall lets through only the reverse proxy VM's IP. Do
not listen on 0.0.0.0.

Destructive actions (delete, restore, prune) require the user to type the vmid by
hand as confirmation, and are logged in `audit.log` with the OIDC subject,
timestamp, and parameters.

If the GUI cannot be reached, everything must be doable from the CLI. The GUI is
convenience, never a prerequisite.

## 8. Scheduling

systemd timer, not cron — it gives journal integration and `OnFailure=` for
notification.

**One timer, not one per container.** A template timer per vmid would start
multiple jobs at once and turn the global lock into a queue you cannot see.
Instead, a single timer that starts one job which works through the containers in
the configured order, sequentially.

```ini
# /etc/systemd/system/pbo.timer
[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
```

```ini
# /etc/systemd/system/pbo.service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/pbo/pbo run-schedule
TimeoutStartSec=infinity
```

`BACKUP_ORDER` in the config specifies the order. No `RandomizedDelaySec` — we want
a predictable start time when the run is sequential anyway.

03:30 places it after PBS at 02:00 so they do not compete for I/O. If the whole
queue takes longer than the next window, the job should log a warning, not skip the
rest.

---

## 9. Acceptance criteria

The tool is not done until:

1. `backup` of a running LXC produces an archive that verifies against its sha256
   both locally and offsite.
2. An interrupted upload (kill the process midway) leaves no half archive visible
   offsite, and the next run succeeds.
3. `test-restore` boots the container and it responds, from an archive fetched from
   offsite — not from the cache.
4. A full restore succeeds on a machine with only rclone.conf and the crypt key.
5. Bind mounts generate a warning.
6. Failure sends an ntfy notification; success is silent.
7. `prune` run with `--dry-run` correctly shows what would be deleted, and `prune`
   refuses to delete the latest archive regardless of policy.
8. The cache shows up as storage in PVE's own backup interface and restore can be
   run from there.
9. The GUI shows the same numbers as `pbo list --json`. If they differ, it
   is a blocking bug.
10. A push that takes 40 minutes produces no HTTP timeout and shows a live log.
11. The API runs as non-root and cannot run anything outside the sudoers list.
12. Every destructive action via the GUI appears in `audit.log` with the OIDC
    subject.
13. Everything in the GUI can be done from the CLI with the API service stopped.
