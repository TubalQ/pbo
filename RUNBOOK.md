# RUNBOOK — pbo

Operations manual. Offsite backup of Proxmox LXCs to an SFTP target (e.g. a
Hetzner Storage Box), deduplicated + encrypted with **restic** over native SFTP.
Run **on the host** as root. A local Proxmox Backup Server, if you have one, is
untouched; this is the **offsite arm** (the third copy in 3-2-1).

> Governing rule: an archive that has never been restored is not a backup.
> `restic check` verifies the repo; `test-restore` proves an actual `pct restore`.

## Installation (including on a new host during DR)

```bash
git clone https://github.com/ai-pvet440/pbo && cd pbo
./install.sh                      # installs tool + units (does NOT enable the timer)
pbo setup                         # wizard: engine/cache/sftp/password/mode → init
```
`install.sh` keeps a `/usr/local/sbin/lxc-offsite` compat symlink (the tool was
formerly named `lxc-offsite`).

## Configuration — one file + one secret

All operational behavior in **`/etc/pbo/config`** (KEY=VALUE):
- `ENGINE=restic` — the backup engine.
- `RESTIC_OFFSITE_REPO` — the repo, e.g. `sftp:hetzner:lxc-restic` (path is
  **relative** — a Storage Box account is chrooted). **Never rename it in
  place — that orphans every existing snapshot.**
- `RESTIC_SFTP_COMMAND` — full `ssh` command (host, `-p <port>`, `-i <key>`), so
  restic reaches the box with the right port and key.
- `RESTIC_SFTP_CONNECTIONS` — parallel SFTP streams (keep the total under the
  provider's connection limit; Hetzner caps around 10).
- `LOCAL_REPO` — `true` = cache tier (local repo, then `copy` offsite);
  `false` = offsite-only (minimal local disk). `BACKUP_MODE` — `stream`
  (one at a time, low disk, default) or `batch` (dump all, then upload).
- `BACKUP_ORDER` — which vmids, in which order (critical ones first).
- `KEEP_OFFSITE_{DAILY,WEEKLY,MONTHLY}` (+ `KEEP_LOCAL` for the cache tier) — GFS retention.
- `VZDUMP_MODE` (snapshot). Fuse CTs are automatically forced to `stop` (see gotchas).

The only secret is the **restic repo password** = your **disaster-recovery key**,
in `RESTIC_PASSWORD_FILE` (default **`/etc/pbo/restic-pass`**, mode 0600). The
config file itself holds no secret. **Export this key** (menu → Export DR key) to
a password manager **and** offline — without it the offsite data is unrecoverable.

## Daily operations

```bash
pbo status                      # lock + latest job
pbo backup <vmid>               # one CT: dump→restic backup→copy offsite
pbo --dry-run backup <vmid>     # show the plan, touch nothing
pbo list [vmid]                 # offsite inventory (restic snapshots)
pbo usage                       # repo stats: physical/logical/dedup/snapshots
pbo run-schedule [--stream|--batch]   # the whole BACKUP_ORDER → the SAME repo
pbo prune --dry-run             # show what retention would forget
pbo verify                      # restic check (repo integrity)
pbo test-restore <vmid>         # offsite→restore→boot→destroy (proof)
```

Schedule (nightly at 05:00):
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
Restore ALWAYS goes to a **new** vmid (never overwrites). `unprivileged` is read
from the archive. The new CT is left **stopped** — if it shares an IP with a live
guest, change the IP before booting. **Bind mounts are not in the archive** —
recreate them from `<archive>.conf`:
```bash
pct set <new-vmid> --mp0 /host/path,mp=/data
```

## Disaster recovery WITHOUT the tool (if the script is broken/gone)

All you need is **`restic` + the repo password + `pct`**:

```bash
export RESTIC_REPOSITORY='sftp:uXXXXX-subN@uXXXXX.your-storagebox.de:23/lxc-restic'
export RESTIC_PASSWORD_FILE=/etc/pbo/restic-pass          # the DR key
# custom port/key, exactly as RESTIC_SFTP_COMMAND in the config:
export RESTIC_SFTP_COMMAND='ssh uXXXXX-subN@uXXXXX.your-storagebox.de -p 23 -i /root/.ssh/id_rsa -s sftp'

restic snapshots                                          # what exists offsite (tagged per vmid)
restic restore <snapshot-id> --target /var/tmp/dr         # extracts the vzdump tar
pct restore <new-vmid> /var/tmp/dr/…/vzdump-lxc-<vmid>-<ts>.tar --storage <pool> --unprivileged <0|1>
```
The `unprivileged` value and any bind mounts are in the extracted `<archive>.conf`.

> **The key is a single point of failure.** restic encrypts everything; without the
> repo password you cannot even list snapshots. Store it in your password manager
> **and** offline (paper/USB) outside the house. Test DR from a clean machine at
> least once.

## Gotchas / troubleshooting

- **Fuse CT freezes during backup** — should not happen: the tool forces
  `--mode stop` for guests with `features fuse=1`. If one freezes anyway, kill the
  stuck `vzdump`/`rsync` process (state `request_wait_answer`) and the container
  resumes. `fsfreeze -u` does not help — it is the live fuse mount that hangs.
- **Slow/erroring SFTP** = rate limiting. Keep `RESTIC_SFTP_CONNECTIONS` under the
  provider's connection limit (Hetzner ~10), especially with test processes running.
- **`init` / list fails** — check `RESTIC_OFFSITE_REPO`, `RESTIC_SFTP_COMMAND`
  (port + key), and that `RESTIC_PASSWORD_FILE` exists and is readable (0600).
- **prune forgets nothing** — retention always protects the latest snapshot per
  vmid. This is intentional. `forget` (metadata) is separate from `prune` (reclaim).
- **Storage Box snapshots** — SFTP provides no append-only. A compromised host can
  delete offsite. **Turn on the provider's scheduled snapshots** and set
  `STORAGE_BOX_SNAPSHOTS_CONFIRMED=true` — it is the only ransomware protection.
- **Restore CT missing from the GUI** — in a cluster it appears under the node it
  was restored on; refresh the web UI (it does not live-push new guests).

## Where things live

| | |
|---|---|
| Program | `/usr/local/lib/pbo/` (symlink `/usr/local/sbin/pbo`; compat `/usr/local/sbin/lxc-offsite`) |
| Config | `/etc/pbo/config` |
| DR key | `/etc/pbo/restic-pass` (0600) — the restic repo password |
| Cache (if `LOCAL_REPO=true`) | `CACHE_DIR` from config (e.g. `/var/cache/pbo`) |
| Logs/jobs | `/var/log/pbo/` · `/var/lib/pbo/jobs/` |
| systemd | `pbo.service` + `pbo.timer` |
| Recipe (SSOT) | `github.com/ai-pvet440/pbo` |
