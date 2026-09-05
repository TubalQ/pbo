# RUNBOOK — pbo

Operations manual. Offsite backup of Proxmox LXCs to Hetzner Storage Box,
encrypted (rclone crypt over sftp). Run **on the host** as root. PBS on 192.0.2.10
is untouched; this is the **offsite arm** (the third copy in 3-2-1).

> Governing rule: verify locally **before** upload, verify offsite **before** prune.
> An archive that has never been verified is not a backup.

## Installation (including on a new host during DR)

```bash
git clone https://github.com/ai-pvet440/pbo && cd pbo
./install.sh                      # installs tool + units (does not enable the timer)
```
Then: edit `/etc/pbo/config`, add `/etc/pbo/rclone.conf`
(0600), create the cache dataset. See the `install.sh` output.

## Configuration — one file

All operational behavior in **`/etc/pbo/config`** (KEY=VALUE):
- `BACKUP_ORDER` — which vmids, in which order (critical ones first).
- `KEEP_LOCAL`, `KEEP_OFFSITE_{DAILY,WEEKLY,MONTHLY}` — retention.
- `VZDUMP_MODE` (snapshot). Fuse CTs are automatically forced to `stop`.
- `RCLONE_REMOTE`, `REMOTE_PATH`, `OFFSITE_ENABLED`.

Creds (the key): **`/etc/pbo/rclone.conf`** (sftp key + crypt password).
This is **the entire key** — see "Disaster recovery" below.

## Daily operations

```bash
pbo status                      # lock + latest job
pbo backup <vmid>               # one CT: dump→verify→upload→verify
pbo --dry-run backup <vmid>     # show the plan, touch nothing
pbo list [vmid]                 # offsite inventory
pbo run-schedule                # the whole BACKUP_ORDER (what the timer runs)
pbo prune --dry-run             # show what retention would delete
pbo test-restore <vmid>         # offsite→restore→boot→destroy (proof)
```

Schedule (daily at 03:30):
```bash
systemctl enable --now pbo.timer
systemctl list-timers pbo.timer
journalctl -u pbo.service -f
```

## Restore WITH the tool

```bash
pbo list <vmid>                              # find the timestamp
pbo restore <vmid> <ts> --to <new-vmid> --storage <pool> --yes
```
Restore ALWAYS goes to a new vmid. `unprivileged` is read from the archive.
**Bind mounts are not in the archive** — recreate them manually from `<archive>.conf`:
```bash
pct set <new-vmid> --mp0 /host/path,mp=/data
```

## Disaster recovery WITHOUT the tool (if the script is broken/gone)

All you need is **`rclone` + `rclone.conf` (the key) + `pct`**:

```bash
export RCLONE_CONFIG=/etc/pbo/rclone.conf
rclone lsf hetzner-crypt:lxc                          # which vmids exist offsite
rclone lsf hetzner-crypt:lxc/<vmid>                   # which archives
mkdir -p /var/tmp/dr && cd /var/tmp/dr
rclone copy hetzner-crypt:lxc/<vmid> . --include "vzdump-lxc-<vmid>-<ts>*"
sha256sum -c vzdump-lxc-<vmid>-<ts>.tar.zst.sha256    # verify
pct restore <new-vmid> vzdump-lxc-<vmid>-<ts>.tar.zst --storage <pool> --unprivileged <0|1>
```
The `unprivileged` value and any bind mounts are in `<archive>.conf`.

> **The key is a single point of failure.** With `filename_encryption=standard` you
> cannot even list the archives without `rclone.conf`. Store the crypt passwords in
> your password manager **and** offline (paper/USB) outside the house. Test DR from a clean
> machine at least once.

## Gotchas / troubleshooting

- **Fuse CT freezes during backup** — should not happen: the tool forces `--mode stop`
  for `features fuse=1` (111,112,113). If one freezes anyway: kill the stuck
  `vzdump`/`rsync` process (`request_wait_answer`), and the container resumes.
- **`md5sum` errors that look like corruption** = rate limiting. `RCLONE_TRANSFERS`
  + `RCLONE_CHECKERS` must sum to < 10 (Hetzner's connection limit).
- **`invalid`/empty on list** — check that `rclone.conf` exists and `RCLONE_CONFIG`
  points to the right place (`export RCLONE_CONFIG=/etc/pbo/config`... no: `.../rclone.conf`).
- **prune deletes nothing** — it always protects the latest per vmid and skips any
  vmid without a verified sha256. This is intentional.
- **Storage Box snapshots** — SFTP provides no append-only. A compromised host can
  delete offsite. **Turn on Hetzner's scheduled snapshots** in the console — it is
  the only ransomware protection.

## Where things live

| | |
|---|---|
| Program | `/usr/local/lib/pbo/` (symlink `/usr/local/sbin/pbo`) |
| Config | `/etc/pbo/config` |
| Creds (key) | `/etc/pbo/rclone.conf` (0600) |
| Cache | ZFS dataset at `/var/cache/pbo` (PVE storage `pbo-cache`) |
| Logs/jobs | `/var/log/pbo/` · `/var/lib/pbo/jobs/` |
| Recipe (SSOT) | `github.com/ai-pvet440/pbo` |
