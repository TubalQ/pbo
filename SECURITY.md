# Security

## Reporting a vulnerability

Don't open a public issue. Use GitHub's private reporting on
[TubalQ/PBO](https://github.com/TubalQ/PBO/security/advisories/new) (Security →
Report a vulnerability). Say what you found, how to reproduce it, and which version
(`pbo --version`, or the commit). Expect an answer within a week.

Supported: the latest release and `main`. Older releases get fixes only if the fix
is trivial to backport.

## Threat model

pbo runs as root on a Proxmox host, reads every guest's disks through `vzdump`, and
holds the key that decrypts all of it. That makes the host the thing to protect, and
the offsite copy the thing that has to survive when the host doesn't.

### What it holds and where

| Secret | Where | Mode | What it unlocks |
|---|---|---|---|
| Repo password (the DR key) | `RESTIC_PASSWORD_FILE`, default `/etc/pbo/restic-pass` | 0600 root | Decrypts every snapshot in the repo. Lose it and the backups are gone for good. |
| SFTP key | `/root/.ssh/…` (the key in `RESTIC_SFTP_COMMAND`) | 0600 root | Read, write **and delete** on the SFTP target. |
| rest-server HTTP password | `RESTIC_REST_PASSWORD_FILE` | 0600 root | Read and append on an append-only server. No deletes. |
| Pinned host key / server cert | `/etc/pbo/known_hosts`, `RESTIC_CACERT` | 0644 | Not secret. Stops a MITM from posing as the target. |
| ntfy token | `NTFY_TOKEN` in the config, or `NTFY_CREDS_FILE` | keep 0600 root (not checked) | Sending notifications. Passed to curl on stdin, never on its command line. |
| Janitor copy of the repo password | janitor `/etc/pbo/restic-pass` | 0400 server user | Same as the DR key, plus delete rights on the repo files. |

`/etc/pbo/config` is sourced by root, so pbo refuses it if it is group- or
world-writable or owned by anyone but root (or the janitor user on a janitor). It
can hold an ntfy token/topic and the SFTP command: keep it 0600. In a cluster, keep
secrets out of `/etc/pve`: pmxcfs replicates it to every node in cleartext.

`pbo backup-host` leaves out private key material: the DR key, the rest-server
password, an old pbo-web key (0.4), `/etc/pve/priv` (the cluster CA key, authkey, tokens), the
nodes' TLS keys, SSH keys and any `*.key` (`HOST_BACKUP_EXCLUDES`). A secret never
goes into the repo it protects. Logs (`/var/log/pbo`) are 0600 and URL credentials
are masked in log lines, job logs, alerts and JSON.

### Who can do what

| Attacker | Can | Can't | Mitigation |
|---|---|---|---|
| Network on-path | See that you back up, and how much | Read data (restic encrypts client-side); impersonate the target once the host key or cert is pinned | `setup` pins the SFTP host key; `RESTIC_CACERT` pins a rest-server cert |
| Provider / storage operator | Delete, withhold, corrupt | Read data or forge snapshots without the DR key | Encryption; `verify --scheduled` reads every pack over time and fails on corruption; a second target (not built yet) |
| Root on the PVE host, SFTP target | Read everything, **delete every offsite snapshot**, then the guests | Nothing pbo can stop | Provider snapshots (`STORAGE_BOX_SNAPSHOTS_CONFIRMED`), or move to append-only |
| Root on the PVE host, append-only target | Read everything, stop new backups, add junk snapshots | Delete or overwrite existing offsite snapshots, remove keys | rest-server `--append-only`; `doctor` proves the server refuses deletes; the janitor flags a host that stops sending |
| Root on the janitor | Delete everything it serves | Reach the PVE hosts (it has no credentials for them) | Keep it on separate hardware and location, nothing inbound but the rest-server port, no SSH, provider snapshots under it if it's rented |
| Local non-root user on the host | Nothing by default | Read secrets (0600 root); change the config (refused if writable by others) | — |
| Proxmox user with access to the `pbo` storage (integration on) | List every snapshot, read guest configs, restore any of them to a new guest that keeps the original's network and mounts (a privileged CT too, with `Sys.Modify`) | Remove, prune or unprotect snapshots (the plugin refuses), read the DR key | Keep the storage's permissions to administrators (`doctor` and `integrate enable` warn about anyone else); `pbo restore` for isolated copies |
| Someone who gets the DR key | Decrypt every snapshot they can reach | Delete through an append-only server | Store it offline (password manager + paper/USB); `pbo rotate-key` after a leak |

### Things to know

- **restic says yes when an append-only server says no.** A `forget` against a server
  that refuses deletes prints 403 per snapshot and exits 0. pbo therefore needs
  `OFFSITE_APPEND_ONLY=true` to know, and `doctor` tests that the setting matches the
  server. Without the setting, a host-side prune would look fine and do nothing.
- **Rotating the key doesn't revoke the old one everywhere by itself.** On an
  append-only target the old key stays valid until the janitor removes it, and
  `rotate-key` says so.
- **Retention runs on times the writer claims.** restic's GFS buckets go by each
  snapshot's own timestamp, which the host sets. Two consequences on a janitor, where
  the host is not trusted:
  - Future-dated snapshots could take over the buckets and push real ones out. The
    janitor refuses to prune while any snapshot is dated more than `FUTURE_SKEW`
    (1h) ahead, and `doctor` fails.
  - Backdated inserts: a snapshot slipped into a past day would make that day's
    bucket keep the fake and drop the real one. The janitor remembers which
    snapshot ids it has seen and when it last ran (on its own disk); a new id that
    claims a time before that run blocks prune and fails `doctor`. Days before the
    last janitor run are sealed that way. What stays open is the window since then:
    a compromised host can displace the snapshots of the last day or so. Retention
    by arrival time on the server (not built yet) would close that too. The first
    janitor run takes what's there as its baseline. A broken baseline blocks
    prune rather than being ignored, and the forget is bound to the snapshots
    that were checked: anything that lands mid-run stops the run and waits for
    the next one.
- **Per-guest keep tags can't lower retention on a janitor.** They come from the
  host. A janitor only lets a tag raise retention above its own `KEEP_OFFSITE_*`.
- **On the host, the policy is Proxmox tags, and tags are guest options.** Anyone
  with `VM.Config.Options` on a guest can set `pbo-skip` (no more backups) or
  `pbo-keep-daily-0` (shorter retention) in the PVE UI, without going through pbo.
  pbo limits the damage: a tag never keeps fewer than `KEEP_OVERRIDE_MIN_LAST` (3)
  snapshots, and `doctor` warns about every skipped guest and every guest below the
  default retention (and alerts with `NOTIFY_LEVEL=warn`). To close it, make the
  `pbo-*` tags registered tags that only `Sys.Modify` may set (Datacenter →
  Options → Tag Style → "registered tags" plus "user tag access: existing" or
  "none").
- **The janitor never runs as root.** Started as root, pbo re-execs as
  `JANITOR_USER`. Its state and log directories belong to that user, and root writing
  there could be redirected through a symlink; a root prune also leaves repo files the
  server can't read.
- **Restore always goes to a new vmid** and never overwrites a running guest. Every
  restore and test-restore lands in the audit log: `LOG_DIR/audit.log` (text, rotated
  weekly, 12 kept) and `LOG_DIR/audit.jsonl` (one JSON object per command with user,
  `via`, client address and job id; kept two years).
- **A janitor on the same host protects nothing.** Root on a Proxmox host is root in
  every container on it (`pct enter`, or the container's disk straight from the host's
  storage), so a janitor in an LXC on the host it guards falls with that host. It is
  fine for testing. In production it has to be a machine the host has no admin
  access to.

### The Proxmox integration

With `PBO_INTEGRATION` set to `both` or `integrated`, pbo adds a storage plugin to
the Proxmox daemons (Perl, loaded by pvedaemon, pveproxy, pvestatd and
pvescheduler) and a hook line to `/etc/vzdump.conf`. The plugin only reads the
catalogue (`/var/lib/pbo/catalog/index.json`) and calls `pbo catalog materialize`
to stage an archive; it holds no secret. Staged archives (decrypted vzdump
archives) are 0600 root in `PVE_STAGING_DIR`, removed after `PVE_STAGING_TTL` or
when the snapshot is pruned. A cache archive is served through `pbo-mount.service`,
a read-only `restic mount` of the cache repo at `/run/pbo/mnt` (root only).

A restore from the Proxmox GUI is not isolated: the copy keeps the original's
network, its bind mounts into the host and its `onboot` flag (so it starts at
the next host boot next to the original, with the original's host paths), a
privileged container stays privileged, and a restore from a guest's own Backup
tab overwrites that guest. Proxmox lets only root@pam restore a bind mount; for
anyone else the restore of such a guest fails. The mount runs with allow_other
(the user namespace of an unprivileged restore must read the archive) below the
root-only `/run/pbo`; pbo refuses a mount point anywhere else. Only give
the `pbo` storage to administrators. The hook runs as root for every vzdump on
the node but returns at once unless the job writes to a `pbo` storage; if the hook
file goes missing, every backup on the node fails, which is why `pbo integrate
disable` (and the package's prerm) remove the line first.

pbo 0.4 had a web UI (`pbo-web`, port 8008); it was removed in 0.5.0, together with
its root helper. If you ran it, close TCP 8008 in the firewall.

### Out of scope

Compromise of the Proxmox host's own boot chain or hypervisor, guests that are
already compromised when they're backed up (pbo backs up what's there), and
availability of the provider.
