# ADR 0007, install modes and guest ownership

- **Status:** Accepted 2026-11-23. Built in 0.5 (pre-release 0.5.0-rc1); first released in 0.6.0.
  Amended 2026-11-24: pbo-web is gone
  ([ADR 0008](0008-remove-web-ui.md)), see the end.
- **Decision:** The Proxmox integration from [ADR 0006](0006-pve-native-storage.md)
  is optional. Each host picks one of three modes, `standalone`, `both` or
  `integrated`, in the config key `PBO_INTEGRATION`. The default is `standalone`,
  which is pbo exactly as before. In `both`, every guest has **one owner**: an
  enabled PVE backup job that targets a `pbo` storage, or else the pbo timer.
  `pbo integrate` is the only command that switches modes.
- **Builds on:** [ADR 0006](0006-pve-native-storage.md) (the `pbo` storage type, the
  spool, the hook and `pbo ingest`), [ADR 0004](0004-append-only-offsite-and-janitor.md)
  (the janitor role).

## Context

ADR 0006 makes pbo a PVE storage that Datacenter -> Backup jobs can target. Not every
host wants that. Some want pbo as it is today (its own timers, CLI and pbo-web),
some want PVE's job scheduler and GUI, and a host moving from one to the other needs
both for a while. Running both without a rule gives either double backups of the same
guest or, worse, a guest that each side thinks the other one covers.

## The three modes

| | standalone | both | integrated |
|---|---|---|---|
| Plugin and the `pbo` storage | no | yes | yes |
| Who backs up a guest | pbo.timer | the PVE job that owns it, else pbo.timer | PVE jobs only |
| pbo.timer | as today | skips guests that a PVE job owns | enabled; its guest list is empty, it runs `ingest --pending` and a catalogue refresh |
| prune, verify, test-restore | as today | as today | as today |
| pbo-catalog.timer (every 15 min) | not installed | enabled | enabled |
| A guest with no owner | cannot happen | cannot happen | doctor **FAIL** |
| Ownership cannot be computed | not applicable | fail open: pbo.timer backs up every guest, doctor WARN | the same |

- `standalone` is the default. It makes **no** extra `pvesh` calls and behaves
  byte for byte as pbo did before this ADR.
- Moving between `both` and `integrated` is a config change only. Units, storage and
  hook stay the same.
- The janitor role (`PBO_ROLE=janitor`, ADR 0004) refuses every mode except
  `standalone`. A janitor has no PVE, no jobs and never gets Perl.

## Config key: `PBO_INTEGRATION`, not "mode"

`PBO_INTEGRATION=standalone|both|integrated`, default `standalone` in `set_defaults`.
The install flag is `install.sh --integration`.

"mode" is already taken several times over in pbo:
- vzdump `--mode snapshot|stop|suspend`, and pbo's per-guest mode policy
  (`VZDUMP_STOP_VMIDS`, the `pbo-stop` tag, fuse detection);
- `BACKUP_MODE=stream|batch`;
- the cache-or-offsite-only repo modes (`LOCAL_REPO`, ADR 0001).

A key or flag called `MODE`/`--mode` would be read as one of those, and
`install.sh --mode` would look like a vzdump option. `PBO_INTEGRATION` says what it
switches. It sits next to `PBO_ROLE`, which answers a different question (host or
janitor).

## One owner per guest

**Rule.** In `both` and `integrated`, a guest on this node is **owned by PVE** when at
least one pbo job selects it. Every other guest is owned by the pbo timer. A guest is
never backed up by both, and in `both` never by neither.

**A pbo job** is an entry from `pvesh get /cluster/backup` that:
1. is **enabled**: the `enabled` field is absent or true. PVE's scheduler skips only
   jobs with `enabled` set and false (Jobs.pm:334), and the API defaults it to 1 on
   create (API2/Backup.pm:329). `/cluster/backup` returns legacy `vzdump.cron` jobs
   too (API2/Backup.pm:208-237); they are treated the same way.
2. has **no `dumpdir`**;
3. has an **effective storage of type `pbo`**. The effective storage is:
   - the job's `storage`;
   - else, from `/etc/vzdump.conf`, its `storage:` line. If vzdump.conf has a
     `dumpdir:` and no `storage:`, the job has no storage and is not a pbo job. If it
     has both, vzdump ignores the `dumpdir:` (VZDump.pm:363-366);
   - else `local`.

   This follows vzdump: defaults from vzdump.conf are merged only when the job gives
   neither `dumpdir` nor `storage` (VZDump.pm:587-598), and `get_storage_param`
   returns no storage when a dumpdir is set, otherwise `storage || 'local'`
   (VZDump.pm:73-78, applied at :637-639). The set of `pbo` storages comes from
   `pvesh get /storage` (type `pbo`);
4. has **`node` unset or equal to the local node**. A job pinned to another node
   exits silently on this one (API2/VZDump.pm:96-97).

**Selection** follows `get_included_guests` (VZDump.pm:1567-1605), in this order:
1. `pool`: the pool's direct members (API2Tools.pm:258-273). pbo reads a guest's pool
   from the `pool` field of `/cluster/resources`, which `_guest_meta_load`
   (lib/policy.sh) already fetches, so this costs no extra call. A job whose pool
   does not exist dies in PVE; pbo counts it as selecting nothing, so the timer keeps
   those guests.
2. else `vmid`: the comma-separated list;
3. else `all`: every guest minus `exclude`. `exclude` applies only to `all`.
4. else nothing.

The selection is then intersected with the guests that live on this node, the same
way vzdump keeps only `$vmids_per_node->{$nodename}` (API2/VZDump.pm:101-103,
VZDump.pm:1596).

**Results.** `_guest_owner <vmid>` gives `pve:<jobid>` or `timer`. `_timer_set` is the
backup set minus PVE-owned guests; `run-schedule` uses it. `_backup_set` keeps its
meaning, "guests that must have a fresh backup", so doctor's age check and
`test-restore` still cover PVE-owned guests. `guests --json` gains `owner` and
`owner_job`.

**Why pbo computes this itself.** PVE's `/cluster/backup-info/not-backed-up` counts
every job, enabled or not, to any storage (API2/Cluster/BackupInfo.pm:20-32). A
disabled job or a job to `local` would look like coverage. See ADR 0006, amendment 10.

**Fail open.** When ownership cannot be computed (`pvesh` fails, its output does not
parse, the storage list is unreadable), pbo treats **every** guest as timer-owned and
logs a WARN; doctor shows it. The worst case is a guest backed up twice in one night,
never a guest with no backup. This holds in `integrated` too.

## Why pbo.timer stays enabled in `integrated`

- **Leftovers.** It runs `ingest --pending`, which uploads spool archives whose
  `backup-end` ingest failed (for example an offsite outage).
- **Catalogue.** It refreshes the catalogue after the night, next to the 15-minute
  catalogue timer.
- **Fail open needs a runner.** If ownership cannot be computed, the timer is what
  backs everything up. A disabled timer would turn "fail open" into "fail silent".
- **No unit changes between modes.** `both` <-> `integrated` stays a pure config
  change, and doctor's timer checks and the JSON timer list stay the same shape in
  every non-standalone mode.

## Packages and modes

| Installed | Modes possible | Notes |
|---|---|---|
| `pbo` | `standalone` | today's pbo |
| `pbo` + `pbo-web` | `standalone` | plus the web UI (ADR 0005) |
| `pbo` + `pbo-pve-storage` | `standalone`, `both`, `integrated` | the plugin, hook and units; the mode is still `standalone` until `pbo integrate enable` |
| `pbo` + `pbo-web` + `pbo-pve-storage` | all three | |
| janitor (`pbo` only) | `standalone` | never Perl, never the plugin |

- `pbo-pve-storage` Depends on `pbo (= version)`, `libpve-storage-perl (>= 9.1.18)`
  and `pve-manager (>= 9.2.29)`, uses the `pve-api-updates` trigger, never edits
  storage.cfg or vzdump.conf in postinst, and its prerm refuses removal while the
  storage or the hook is active.
- Hosts installed with `install.sh` get the same files through
  `install.sh --integration standalone|both|integrated`, after the same version
  check, without the package (ADR 0006, amendment 11). The mode is taken from the
  flag, else the existing config value, else a prompt on a terminal, else
  `standalone`. install.sh never creates the storage.

## `pbo integrate`, the only switch

`pbo integrate status|enable <both|integrated> [--catalog-only]|disable`. install.sh,
the setup guide and the admin all go through it. Every subcommand is idempotent,
supports `--dry-run` and writes an audit event.

**enable** sets the mode **last**:
1. preflight: versions, plugin loaded, repo readable, spool and staging on the same
   filesystem as the cache; a foreign `script:` in vzdump.conf is refused;
2. catalogue refresh;
3. `pvesm add pbo pbo --content backup --nodes <node>`, plus `--path <spool>` unless
   `--catalog-only`;
4. the hook line in vzdump.conf, with a marker;
5. the catalogue timer;
6. a warning if the storage has ACL entries for anyone but root;
7. `PBO_INTEGRATION=<mode>`.

If any step fails, the mode is unchanged. Coming from `standalone`, the timer still
backs up every guest.

**disable** sets the mode **first**:
1. refuse while an enabled PVE job targets a `pbo` storage; pbo never edits
   jobs.cfg, the admin removes or disables the job;
2. `PBO_INTEGRATION=standalone`, so the timer owns every guest from here on;
3. `ingest --pending`;
4. remove only our own hook line;
5. `pvesm remove`;
6. disable the catalogue timer.

**status** shows the mode, the plugin, the storage, the hook, the jobs and the
computed owners, plus the exact storage.cfg stanza and vzdump.conf line for the
host's recipe in version control.

Ordering both ways keeps the safe side: while switching, the timer owns more, never
less.

## Consequences

- **Standalone hosts see no change** and pay nothing: no `pvesh` call for jobs or
  storages, no plugin, no new units.
- **GUI restore is not isolated.** A restore from the PVE GUI has none of pbo's
  isolation (link_down, onboot 0, host-binding stripping) and can overwrite in place
  (ADR 0006, Consequences). The `pbo` storage must be admin-only: doctor warns about
  ACL entries for anyone but root, `integrate enable` warns too, and pbo-web stays the
  isolated restore path.
- **Per-guest policy moves into PVE jobs** for PVE-owned guests: one job per vzdump
  mode, guarded by the hook; `BACKUP_MODE=batch` does not apply; `pbo-skip` on a
  PVE-owned guest is a doctor warning, because the job's selection wins.
- **A stop-mode PVE job uploads at `job-end`** (ADR 0006, amendment 14), so its
  guests are down only for their dump, as with pbo.timer. A failed upload fails the
  job, not the guest's row.
- **Batch mode holds each guest's lock** from its dump to the end of its upload. When
  fail-open ownership lets pbo.timer (batch) and a PVE job back up the same guest in
  one night, the second one fails fast on the lock instead of emptying
  `$CACHE_DIR/<vmid>` under the other, and a dump that vanished before its upload is
  a failed guest, never an empty snapshot.
- **Doctor grows an integration section** (`_doctor_integration`): FAIL for a missing
  or wrong plugin, storage or hook, a pbo job with its own `script`, compression,
  `prune-backups` or `protected`, a stop-only guest in a non-stop job, spool files
  older than 24 h, a guest with no owner in `integrated`, and a spool on another
  filesystem than the cache; WARN for the rest (storage present while `standalone`, a
  disabled pbo job, a guest in two jobs, a job time near 05:00 or the prune/verify
  window, `notification-mode none`, ACLs, spool space, untested PVE versions).
- **Two schedulers share one vzdump lock.** PVE jobs and pbo.timer both take the node's
  vzdump lock. Ingest never waits on `pbo.global`, so there is no deadlock; doctor
  warns when the schedules are close.

## Amendment 2026-11-24: no pbo-web

[ADR 0008](0008-remove-web-ui.md) removes pbo-web in 0.5. The package table above
loses its two `pbo-web` rows: `pbo` alone is standalone, `pbo` +
`pbo-pve-storage` can run all three modes. Where this ADR names pbo-web as the
isolated restore path, read `pbo restore`.
