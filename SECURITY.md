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
| Backend credentials (S3, B2, Azure, GCS, Swift, rclone) | `RESTIC_ENV_FILE`, default `/etc/pbo/restic.env` | 0600 root (0400 or 0600 the janitor user) | Whatever the provider's key allows, usually read, write and delete on the bucket. |
| ntfy token | `NTFY_TOKEN` in the config, or `NTFY_CREDS_FILE` | config 0600; the file at most 0640 | Sending notifications. Passed to curl on stdin, never on its command line. |
| Janitor copy of the repo password | janitor `/etc/pbo/restic-pass` | 0400 server user | Same as the DR key, plus delete rights on the repo files. |

### The config is data, not code

pbo 0.5 sourced `/etc/pbo/config` as shell code, as root, on every command, timer
and vzdump hook. Since 0.6 a strict reader reads it (`lib/config_parse.sh`, ADR
0009) and nothing in it runs:

- Only `KEY=VALUE` lines, single- or double-quoted values, comments and `${KEY}`
  references to a config key an earlier line set are accepted. Command
  substitution, backticks, any other expansion (`$HOME`, `${X:-y}`, `~`), an
  unquoted blank (`KEY=a b` would run `b`), operators, functions, `source`,
  control flow, arrays and `+=` are refused, with the file and line. A refused line
  stops every command with exit 78 rather than running on the rest of the file (a
  dropped line would fall back to a default: another repo, another retention).
- Only keys of the schema become variables. `PATH`, `IFS`, `BASH_ENV`, `LD_PRELOAD`
  or one of pbo's own names in the file change nothing. `export` is accepted for a
  config key (read, not exported) and for the proxy variables (`http_proxy`,
  `https_proxy`, `no_proxy`), which are exported to the programs pbo runs; any other
  `export` is refused.
- A refusal message never repeats the value of a secret key, or anything that
  looks like URL credentials: the messages reach doctor, the logs, the install
  guard and apt's terminal log.

Some keys still name programs root runs (flagged `exec` in the schema:
`RESTIC_BIN`, `RESTIC_SFTP_COMMAND`, `PBO_VZDUMP_HOOK`). So the file rules stay:
pbo refuses a config that is group- or world-writable or owned by anyone but root
(or the janitor user on a janitor), and `pbo doctor` checks that its directory is
not writable by others either. The config can hold an ntfy token and topic and the
SFTP command: keep it 0600.

**The cluster-shared file.** pmxcfs replicates `/etc/pve/pbo/config` to every node
in cleartext, with its own modes (root:www-data 0640). So keep secrets out of
`/etc/pve`, and pbo ignores there every key flagged `exec` or `local-only`
(`RESTIC_SFTP_COMMAND`, `RESTIC_BIN`, `PBO_VZDUMP_HOOK`, `RESTIC_ENV_FILE`,
`PVE_STORAGE_ID`, ...; doctor FAIL, `pbo config check` error): one node's admin
cannot make every node run a program or read its credentials from a file in
pmxcfs. Ignored rather than refused, so one node's edit cannot stop pbo on all of
them. `pbo config set --shared` refuses secret, exec and per-node keys, and
`CACHE_DIR` with the keys that follow it.

**Writes.** pbo writes the config only through `pbo config set|unset` (also for
`pbo setup`, the menu and `pbo integrate`): a lock, a temp file in the config's own
directory, the candidate read back by the strict reader and by bash before it
replaces the file, owner, group, mode and ACL kept, and the change in the audit log
with secret values masked. `KEY=VALUE` typed as one argument is refused by its key
name alone, so a secret never reaches a message or the audit record.

### RESTIC_ENV_FILE

Cloud backends take their credentials from environment variables, which the
config cannot export. They live in `RESTIC_ENV_FILE`, which pbo reads with the
same reader and hands to restic alone: the values are put into restic's own
environment in the subshell of each call (`env`), never into pbo's shell, so
vzdump, pct, curl, the hooks and every other program pbo runs never see them.
Doctor, `pbo config list|show|check` and `doctor --report` name the file and its
variable names, never a value.

pbo refuses the file, and stops every command with exit 78 except `config`,
`doctor`, `version` and `help` (which diagnose it, and refuse only a restic call),
so the timers and the vzdump hook stop too, when it is a symlink, owned by anyone but root or the user pbo runs as (on a janitor also
`JANITOR_USER`), writable by group or others, or readable by others; and when it
sets a name that changes which program runs or how the shell behaves (`PATH`,
`IFS`, `ENV`, `BASH_ENV`, `LD_*`, `GCONV_PATH`, `BASH_FUNC_*`, ...), what pbo sets
for restic itself (`RESTIC_REPOSITORY*`, `RESTIC_PASSWORD*`, `RESTIC_FROM_*`,
`RESTIC_CACHE_DIR`, the rest-server login, `RESTIC_HOST`), a config key, or one of
pbo's internal names. It is local-only: the cluster-shared config cannot name it.
`install.sh` refuses to upgrade while pbo would refuse it.

### Permissions and `pbo doctor --fix`

One rule table (`lib/perms.sh`) says who owns each of pbo's paths and with which
mode; every path in it is a config value. `pbo doctor` checks it, `pbo doctor
--fix` changes what the table marks as pbo's to change (`--dry-run` lists it
first; each change is audit-logged), `install.sh` runs `pbo doctor --fix
--perms-only`, the cache move applies it to the new paths, and every backup closes
CACHE_DIR by the same rule.

| Path (host) | Owner | Mode | Why |
|---|---|---|---|
| `CACHE_DIR` | root | at most 0750, plus `u:<ct root>:--x` per unprivileged CT | plaintext vzdump archives; an unprivileged CT's vzdump runs tar as its mapped root |
| the directories above `CACHE_DIR` | | passable by each CT's mapped root | the same tar must pass them; changed only with `--fix-parents`, and then only by a traverse-only ACL entry |
| `RESTIC_CACHE_REPO` (top directory) | | at most 0770 | other users must not read the cache repo |
| `PVE_SPOOL_DIR`, its `dump` | root | 0755 | PVE jobs write there, CT roots pass it |
| `PVE_STAGING_DIR`; staged files | root | 0700; 0600 | staged archives are plaintext |
| `LOCK_DIR` | root | 0700 | whoever can write there can hold or pre-create pbo's locks |
| `LOG_DIR`; the logs | root | 0755; 0600 | repo paths, guest names, errors, who did what |
| `STATE_DIR`; `STATE_DIR/runs` | root | 0755; 0750 | the storage plugin reads the catalogue below it; job logs |
| the catalogue and its directory | root | 0644; 0755 | the storage plugin reads it |
| `RESTIC_CACHE_DIR` | root | 0700 | restic's metadata cache (paths, tags, file names) |
| the config's directory; the config | root | 0700; 0600 | it holds the DR key and credentials; its exec keys name programs root runs |
| `RESTIC_PASSWORD_FILE`, `RESTIC_REST_PASSWORD_FILE`, `RESTIC_ENV_FILE` | root (reported) | 0600 or 0400 | the DR key, the rest-server password, backend credentials |
| `NTFY_CREDS_FILE` | root (reported) | at most 0640 | ntfy credentials; other tools may share the file through its group |
| the mount point's parent | root | at most 0700 (checked only) | the cache repo is mounted with allow_other |

On a janitor the cache, logs, state, locks, restic cache, DR key and
`RESTIC_ENV_FILE` belong to `JANITOR_USER`, and the config is 0640 root:<the group
named like that user> in a 0750 directory. The rules that keep a fix safe:

- A symlink where a directory or file is expected is reported and never changed (a
  fix would change its target), and the system's shared directories (`/`, `/etc`,
  `/tmp`, `/var/lock`, ..., and any sticky one) are never checked or changed: a
  config at `/etc/pbo.conf` cannot make `/etc` 0700.
- Every change goes through a file descriptor opened without following symlinks and
  checked for its type, its link count and its path right before the change, so a
  file swapped in between check and change is refused (on a janitor root fixes files
  in directories the janitor user can write).
- Never recursive; nothing is created. A config directory other than `/etc/pbo` (an
  explicit `PBO_CONFIG` elsewhere) is only checked, never changed: other software
  keeps files there.
- CACHE_DIR is never closed while a CT's ACL entry is missing or setfacl is absent
  (closed without it, that CT's backup fails). On a filesystem without POSIX ACLs
  doctor says so (ZFS: `zfs set acltype=posixacl`).

### Moving the cache directory

When the cache holds data, `pbo config set CACHE_DIR <new>` runs as root and moves
plaintext archives and the cache repo, so it checks the target before it writes
anything: no symlink on the
way, no system directory, every directory above it root's and not writable by
others, an existing target root's and empty, and the ACL probes it runs only in a
directory only root can write (another user could swap a probe for a symlink
before root's `setfacl`). While it runs it holds every pbo lock and the cache lock
(`LOCK_DIR/pbo.cache`) exclusive, so backups, ingest, restores, test restores and
the mount stop with exit 75 instead of writing into a half-moved tree; while its
journal says unfinished, those, `restic init` and the vzdump hook refuse to run, so
no process with the old path creates a new, empty repo there.

An empty cache (a new install, the first `pbo setup`) is not moved: pbo only
refuses a relative path, a system directory, a symlink at the target itself, a
non-directory or a non-empty directory, then creates it with the CACHE_DIR
permission rule. It does not check who owns the directories above it, so put the
cache under a path only root can write (such as `/var/cache/pbo`).

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
  server can't read. What stays root is only what concerns root's own files: `pbo
  config check|set|unset` (the root-owned config the janitor user only reads), `pbo
  timers apply` (the drop-ins in the systemd directory) and the permission and
  schedule pass of `pbo doctor --fix` before the drop to that user. None of them
  writes into the janitor user's directories, and `config set|unset` take their lock
  on the config's own directory, not in the user's LOCK_DIR.
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
