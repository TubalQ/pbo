# Changelog

Versions follow [semver](https://semver.org/). Until 1.0, a minor bump can change
behaviour; the entry says so when it does.

## 0.6.0 (unreleased)

Planned (ADR 0009): a config schema, `pbo config list|get|set|unset|check|template`,
a strict KEY=VALUE reader instead of sourcing the config, moving CACHE_DIR with
`pbo config set CACHE_DIR`, retention grouped per guest, `pbo doctor --fix`, and
nothing that differs between installations hard-coded (landed: `RESTIC_ENV_FILE`,
`RESTIC_MIN`, threshold keys, `pbo doctor --report`, the hard-coding lint, the
timer schedules as config keys and per-node storage ids in a cluster), and a
setup wizard that is safe to run again and asks for the type of offsite target.

Changes behaviour: **the config is no longer run as code.** pbo 0.5 sourced
`/etc/pbo/config` (and `/etc/pve/pbo/config`) as shell code. pbo 0.6 reads them
with a strict KEY=VALUE reader (ADR 0009, "Config grammar" and "Loading"): it
gives every accepted line exactly the value bash would, assigns only keys of the
config schema, and refuses everything else. A config with a line it refuses
stops every pbo command, timer and the vzdump hook with exit 78 (`EX_CONFIG`),
naming the first three lines; `pbo config check` lists them all. `install.sh`
checks the existing config first and changes nothing when it would be refused
(`--force` installs anyway). See the migration notes below.

Changes behaviour, in a cluster only: a node that turns the Proxmox integration
on from scratch gets a storage of its own, `pbo-<node>` (`--nodes <node>`, its own
spool path), instead of the one `pbo` storage for the whole cluster
(`PVE_STORAGE_ID`'s default is derived; enable pins it in the local config). A
single node keeps `pbo`, and an existing storage pbo made for this node keeps its
id, so no installation is renamed by the upgrade. PVE backup jobs name a storage:
create them per node (pbo never edits jobs.cfg; doctor explains a move from a
shared `pbo`).

Changes behaviour: retention is grouped per guest for a guest whose snapshots lie
under more than one path (CACHE_DIR moved, a host backup whose path list
changed). For such a guest the next prune forgets snapshots that 0.5 kept;
`RETENTION_GROUP_BY=paths` keeps the 0.5 behaviour for one release. A repo where
no guest is split gets exactly the 0.5 restic calls, on the cache tier and
offsite alike.

Migration notes (0.5 → 0.6 config)
- Run `pbo config check` (0.6) before or right after the upgrade; `install.sh`
  runs the same reader and stops before changing anything. `pbo config check
  --compare-bash` also sources the file the way 0.5 did (in a clean subshell; it
  runs the file) and names every key the two read differently.
- A config that only has `KEY=value` lines, quoted values and `${KEY}` references
  to keys set earlier (the generated example, `pbo setup`'s output) needs no
  change. The forms that are refused, and how to write them instead:

  | Refused | Why | Write instead |
  |---|---|---|
  | `KEY=$(cmd)`, ``KEY=`cmd` `` | runs a command | the value itself (`KEY=/srv/backup`) |
  | `KEY=a b` | bash runs `b` as a command with `KEY=a` set | `KEY="a b"` |
  | `f() { ...; }`, `if`/`for`/`while`, `source file`, `. file` | code | delete them; the cluster-shared `/etc/pve/pbo/config` is read by itself |
  | `KEY+=more`, `KEY=(a b)`, `KEY[0]=a` | appends, arrays | the whole value: `KEY="a b"` |
  | `KEY=~/x`, `KEY=/a:~/x` | bash expands `~` | the full path: `KEY=/root/x` |
  | `KEY=${OTHER:-default}`, `${#X}`, `$1`, `$HOME`, `$$` | expansions other than a config key | the value: `KEY=/x`, or `KEY=${OTHER}` with `OTHER` set on an earlier line |
  | `KEY=${OTHER}` with `OTHER` not set earlier in the files | used before it is set (bash stops under `set -u`) | set `OTHER` first, or write the value |
  | `export FOO=1` (any variable but the proxy ones) | changes the environment of everything root runs | a systemd drop-in (`Environment=FOO=1`) |
  | `KEY="multi`<br>`line"`, a trailing `\` | a value must fit on one line | one line |

  Accepted with a warning (pbo runs, `config check` and doctor name it): `export
  KEY=...` of a config key (read, no longer exported to child processes), an
  unknown key (never assigned), a key set twice (the last wins), Windows line
  endings and a UTF-8 BOM (dropped; bash kept the CR in the value). `export`
  of `http_proxy`, `https_proxy`, `no_proxy` (and upper-case) is accepted and
  exported to the programs pbo runs, as before.
- Only schema keys become variables. An environment switch set in the config
  (`PBO_REPO=cache`, `PBO_NO_NOTIFY=1`, `TMPDIR=...`) was honoured by 0.5 and is
  ignored now: set it in pbo's environment (doctor names it). `PATH`, `IFS`,
  `BASH_ENV` and pbo's own names in the config change nothing.
- In the cluster-shared `/etc/pve/pbo/config` a key flagged `exec` or
  `local-only` (`RESTIC_SFTP_COMMAND`, `RESTIC_BIN`, `PBO_VZDUMP_HOOK`, ...) is
  ignored: doctor reports it as FAIL and `config check` as an error. Set it in
  `/etc/pbo/config` on each node.
- The file rules are unchanged: a group- or world-writable config, or one owned
  by anyone but root (or the janitor user), is refused (78).

Added
- A config schema (`lib/config_schema.sh`): one row per key with its type,
  default (derived ones as `${KEY}` references to earlier keys), section, roles
  (host/janitor) and flags (secret, exec, local-only, internal, advanced,
  managed, follows, samefs, on_change, deprecated, template). It covers every key
  `set_defaults` defaults, the keys that only had an inline default (`LOCK_DIR`,
  `CATALOG_*_WAIT`, `JOB_*`, `TR_HISTORY`, `TR_STORAGE`, `VERIFY_READ_DATA`,
  `VERIFY_SUBSET`, `PBO_KNOWN_HOSTS`, ...) and the test hooks. `set_defaults`
  applies its defaults (0.6 M3) to every key the config and the environment left
  unset or empty; `tests/config.sh` proves they are the ones the 0.5
  `set_defaults` gave (a frozen copy), as root and as a plain user. The keys
  that only had an inline default now have their value set too (`config list`
  shows it); `PBO_CONFIG_VERSION` in `config show`'s `file_schema` is still what
  the file declares.
- `pbo config list [--all]` (value, source (`config`, `shared` for the cluster's
  `/etc/pve/pbo/config`, `env` for a key only pbo's environment sets, or
  `default`), type for this role's keys; `--all`
  adds test hooks and the other role's keys), `pbo config get KEY` (one effective
  value; a secret prints `<set>`/`<unset>`; an unknown key exits 64) and
  `pbo config template [--role host|janitor]` (the example config generated from
  the schema; `--role janitor` sets `PBO_ROLE`, `LOCAL_REPO=false`,
  `OFFSITE_ENABLED=true`, the offsite repo and the password file, like
  `etc/config.janitor.example`). `pbo config show` keeps its format and JSON envelope; each key now
  also has `type`, `section`, `default`, `flags`, `roles`, `description`,
  `managed_by` and `known`, and the envelope names `local_file`, the file pbo
  writes (`config set|unset`: below).
- `etc/config.example` is generated by `pbo config template` (same active keys
  and values as before, so a new install gets the same first config); CI fails
  when it is stale. Commented lines show each key's default, resolved (as in 0.5)
  and quoted so that removing the `#` from any one line gives a line the strict
  reader accepts and bash reads the same, alone or in the example
  (`HOST_BACKUP_PATHS`, `HOST_BACKUP_EXCLUDES`, which is written out literally
  now: the reader refuses its old `${RESTIC_PASSWORD_FILE:-...}`).
- `pbo backup-host` always excludes `RESTIC_PASSWORD_FILE` and
  `RESTIC_REST_PASSWORD_FILE` as configured, whatever `HOST_BACKUP_EXCLUDES`
  says, so a literal exclude list cannot let the DR key into the repo after the
  password file moved.

- `RETENTION_GROUP_BY` (advanced; `guest` by default, or `paths`): `paths` is the
  0.5 behaviour, kept for one release and removed in 0.7. Any other value is
  treated as `paths` (prune logs a warning, doctor flags the value), so a typo
  never turns on the deletions the key exists to opt out of.
- Doctor names the guests whose snapshots lie under more than one path, with the
  number of paths, read from the snapshot list it already loads: OK ("retained as
  one guest each"), a warning with `RETENTION_GROUP_BY=paths` (the old paths are
  then never pruned), and a warning for a guest that shares a path with another
  vmid or with snapshots without a vmid tag (pbo never writes that; such a guest
  stays retained per path). On a host whose offsite is append-only, doctor does
  not judge the offsite's split guests by the host's setting: the janitor's
  `RETENTION_GROUP_BY` decides there.

- `pbo config check [--file F [--shared]] [--role host|janitor] [--compare-bash]`
  (ADR 0009, "Config grammar"): reads the config with pbo's strict reader
  (`lib/config_parse.sh`: KEY=VALUE lines, quotes, comments, `${KEY}` references
  to config keys set earlier, nothing run) and lists every error and warning as
  `file:line`: what the reader refuses (see the migration notes), exec/local-only
  keys in the cluster-shared file (ignored by pbo, an error here), unknown keys,
  keys set twice, test hooks, values of the wrong type, keys the role does not
  use, deprecated keys, a BOM and CR line endings. `--file F` reads F alone.
  `--compare-bash` (migration debugging) also sources the files as 0.5 did, in a
  subshell with a clean environment, and names every key bash reads differently
  and a file bash cannot parse or stops in; it runs the file, so it is never the
  default. Exit 78 when pbo refuses or ignores a line, 0 otherwise; `--json`
  gives `{status, ok, errors, warnings, ignored, files:[{file, errors, warnings,
  valid_bash}], compare_bash:{agree, keys, differences, bash_failed} | null}`. It
  reports a config every other command stops on, also a broken role config (a
  bad `PBO_ROLE`, a janitor with `PBO_INTEGRATION` other than standalone or with
  `OFFSITE_APPEND_ONLY=true`). Its messages never repeat a secret's value. On a
  janitor, `config check` run as root stays root (the janitor user may read the
  0640 config but not write it) and writes no log or audit line into the
  janitor user's `LOG_DIR`; it also asks whether `JANITOR_USER` can read each
  file (an error, exit 78, when it cannot: a 0600 root:root config stops every
  other janitor command). Every other command still drops to `JANITOR_USER`,
  which reads the config again. A role error is reported as one every command
  stops on, not as a line pbo ignores.
- Doctor reports what the reader found: a key pbo ignores in the cluster-shared
  file is a FAIL, the reader's warnings (a key set twice, CR line endings, a BOM,
  an exported config key, a reference taken from the environment) are WARNs (at
  most ten, then a count), and an environment switch set in the config is named
  as ignored.
- `install.sh` reads the existing config (and the cluster-shared one) with the
  strict reader of the version it installs before it replaces any file. When the
  reader refuses a line it lists the lines (with the migration hint when the
  file is valid bash), says "Nothing was changed" and exits; `--force` installs
  anyway, with a warning. It reads `PBO_INTEGRATION` with the same reader. The
  `.deb` postinst runs `pbo config check` and prints its findings; it never
  fails the install.
- Permission checks (ADR 0009, "Permissions (M6)"): one rule table
  (`lib/perms.sh`) of path, owner, group, mode, ACL and class (fix, ask, check)
  per role, with every path a config value. Doctor reports it: CACHE_DIR closed
  with an ACL entry per unprivileged CT (as before), the directories above
  CACHE_DIR, which each CT's mapped root must be able to pass (tested with
  `setpriv`, a WARN naming the directory, the uid and the CTs), the cache repo's
  top directory, the PVE spool (0755) and staging (0700, staged files 0600),
  LOCK_DIR (0700), the logs (0600 in a 0755 LOG_DIR), STATE_DIR (0755), its
  `runs` (0750), the catalogue (0755/0644), the restic cache (0700), the config
  directory and file (host 0700/0600 root; janitor 0750/0640 root:<the group
  named JANITOR_USER, as install.sh and pbo-janitor.service's `Group=` use>),
  the DR key (0600 or 0400), the rest-server password file (0600 or 0400), the
  ntfy credentials (no group write, no other access), the mount point's parent
  (root only) and the metrics directory (root-owned); on a janitor
  JANITOR_USER's own directories (LOCK_DIR too), logs and DR key (0400). The
  config directory is only changed when it is pbo's own (`/etc/pbo`): any
  other one (`PBO_CONFIG=/usr/local/etc/pbo.conf`) is checked only, and named
  only when group or world can write it. In a cluster, a secret or exec key in
  `/etc/pve/pbo/config` is named; a config on pmxcfs (an explicit `PBO_CONFIG`
  below `/etc/pve` too) keeps pmxcfs's modes. A symlink where a directory or
  file is expected, and a shared system or sticky directory
  (`LOCK_DIR=/var/lock`), are reported and never changed; a DR key that is a
  dangling symlink is a FAIL, one whose target others can read is named.
  CACHE_DIR's ACL entry only counts when the ACL mask lets it through (a `chmod
  700` masks it). On a filesystem without POSIX ACLs (ZFS `acltype=off`)
  doctor says so and names the fix (`zfs set acltype=posixacl`). Owners are
  checked as root and on a janitor.
- `pbo doctor --fix [--fix-parents] [--perms-only]`: applies the class fix
  rules, then shows the full report. `--dry-run` (global, or after `doctor`)
  lists the changes and makes none; each change made is audit-logged (`perms fix
  <path> mode 0755->0700`, `owner root->restic`, `acl +u:100000:--x`); `--json`
  adds `changes: [{name, path, change, from, to, applied}]`. `--fix-parents`
  also adds a traverse-only entry `u:<uid>:--x` to each directory above
  CACHE_DIR that blocks an unprivileged CT's mapped root (nothing else is ever
  changed there). `--perms-only` runs the permission section alone. On a
  janitor started as root the fix runs as root (only root can give a file to
  JANITOR_USER), then pbo re-execs as JANITOR_USER as before, which audits and
  reports the changes. Every change goes through a file descriptor opened
  without following symlinks and checked for type, hard links and path, so a
  file swapped in between check and change is refused. Nothing is created.
  Its audit.jsonl command record says `read_only: false` (a dry run: true).
  With `--perms-only` a DR key that does not exist yet (before `pbo setup`) is
  a warning, not a failure; full doctor still fails on it.
- `install.sh` runs `pbo doctor --fix --perms-only` once the files are in
  place (host and janitor) and shows the result; it never fails the install.
- `pbo config set KEY VALUE [KEY VALUE...] [--shared] [--yes] [--force]` and
  `pbo config unset KEY... [--shared] [--yes]` (ADR 0009, "Writer"): any number
  of changes in one transaction on the local config (`--shared`: the
  cluster-shared `/etc/pve/pbo/config`), under the lock `LOCK_DIR/pbo.config`
  (busy: exit 75). The value is checked against the schema type (78 with the
  reason); a managed key is refused with the command that manages it
  (`PBO_INTEGRATION`: `pbo integrate`), an unknown key unless `--force`, a key
  the role does not use (a host-only key on a janitor), and in the shared file
  a secret, exec or per-node key, and `CACHE_DIR` and the keys that follow it
  (set or unset: the cache check runs on one node only, pmxcfs copies the file
  to all). `--shared` needs a mounted cluster filesystem (refused on a janitor
  and with pve-cluster stopped), and a shared file another node changed
  meanwhile is not overwritten (75). `KEY=VALUE` typed as one argument is
  refused naming the key only (its value may be a secret: it is not logged).
  The file is edited in place: the active line
  replaced (its end-of-line comment kept), else a commented `#KEY=` template
  line, else the key goes under its section header; unset removes the active
  line and keeps comments and template lines. Values are quoted for the strict
  reader and bash alike (bare when safe, else double quotes with `\ " $ \``
  escaped). Before it replaces the old file the new one is read back with the
  strict reader and sourced by bash in a clean subshell: every key must read as
  intended (a difference the files had before, such as a CRLF line, is left
  and named in a warning). Temp file in the same directory, fsync, rename;
  owner, group, mode and an extended ACL kept (a janitor's 0640 root:<user>
  survives), a new file gets the mode of the permission table. `--dry-run` prints the diff (secret values hidden) and
  changes nothing; `--json` gives each key's value before and after (secrets
  `<set>`/`<unset>`), the keys that follow it, the file and the hooks run. The
  audit log records the change with secret values masked (also in the command's
  arguments in audit.jsonl). on_change hooks: a new `RESTIC_OFFSITE_REPO` or
  `RESTIC_CACHE_REPO` needs `--yes` (or a yes on a terminal) and says that no
  data is moved; `PVE_CATALOG_MOUNT` and `PVE_CATALOG_MOUNT_DIR` restart
  pbo-mount.service if it runs; `CACHE_DIR` on an empty cache (no file in it)
  creates the new directory with the CACHE_DIR permissions and writes the
  config; a cache with data is moved (below; `.zfs`/`.snapshot` directories do
  not count, the same path with a trailing slash is no move). A key that follows `CACHE_DIR` is
  not pinned at its derived default, and a line at the old default goes when
  `CACHE_DIR` changes, unless another config file or the environment sets the
  key (then the line is written). On a janitor `config set|unset` run as root
  stay root, and take the config lock on the config's own directory, not in
  the janitor user's LOCK_DIR.
- Moving the cache directory with its data: `pbo config set CACHE_DIR <new>
  [--yes] [--keep-old] [--fix-parents] [--verify-data] [--force]`, and
  `--resume` / `--abort` for an interrupted move (`lib/cachemove.sh`, ADR 0009,
  "Cache move"). First every check, all failures in one refusal and nothing
  changed (78 for a wrong path, 69 when the system refuses): an absolute,
  canonical path without symlinks, no system directory, empty or new, not
  nested with the old one; every directory above it owned by root and not
  group- or world-writable; not on tmpfs or FUSE, a network filesystem only
  with `--force`; on another filesystem free space of `CACHEMOVE_SPACE_FACTOR`
  (new advanced key, default 1.1) times the cache's size; the keys that follow
  CACHE_DIR (a pinned `RESTIC_CACHE_REPO`, `PVE_SPOOL_DIR`, `PVE_STAGING_DIR` at
  the old derived default is removed so it derives again, one pinned below the
  cache under another name is rewritten, one pinned elsewhere stays and is
  named); the mapped root of every unprivileged CT can pass every directory on
  the way (tested with `setpriv` as that uid), and the target filesystem takes
  POSIX ACLs (a probe file), else the exact `setfacl -m u:<uid>:x <dir>` lines
  (or `--fix-parents` adds them); with the Proxmox integration on, the pbo
  storage must belong to this node alone (storage.cfg is cluster-wide); nothing
  may run (backup, prune, verify, ingest, restore, `pbo integrate`, vzdump, an
  archive in the spool, a deferred stop-mode ingest, a file open in the cache,
  a restore through the mount); no filesystem mounted below the old cache (a
  child dataset or an fstab mount: a rename would move only its mount stub);
  an existing target owned by root and not writable by others, and the ACL
  probes run only in a directory only root can write. `--dry-run` prints the
  checks and every step.
  Then, recorded in `STATE_DIR/cache-move.json` (atomic writes): every pbo lock,
  pbo-mount.service stopped, the pbo storage disabled (`pvesm set <id> --disable
  1`), staging cleared, the target created closed to others with an ACL entry
  per CT root, the data renamed (same filesystem and the same mount; two bind
  mounts of one filesystem get a copy, and the rename never falls back to an
  unchecked copy) or copied (`cp -a`, the trees
  compared by size, count, mode and owner, `restic check` of the copied cache
  repo, with `--verify-data` `--read-data`), the config written in one
  transaction (CACHE_DIR and the keys that follow), the storage pointed at the
  new spool and enabled, the catalogue refreshed, the permission rules applied
  to the new paths and checked, the old copy removed when it holds nothing but
  pbo's own directories (`--keep-old` keeps it), the mount started again. A
  failure before the config write is rolled back at once (the old tree, but
  for staged archives, which are made again on demand, the storage and the
  mount as they were; the journal is final before the mount starts again);
  after it the move only goes forward (`--resume`). An empty cache needs no
  `--yes` and no journal: the directory is created, as before; after an earlier
  move the journal records the change, so a place a move left can be used
  again. A move with data needs `--yes` (or a yes on a terminal).
- A cache lock, `LOCK_DIR/pbo.cache`: taken shared by backup, ingest, fetch,
  restore, test-restore, backup-host, `catalog materialize` and
  pbo-mount.service; a cache move takes it exclusive, the others exit 75 while
  it does. While a move's journal is not final, backups, ingest, restores, the
  mount, the vzdump hook's backup-start and `restic init` stop with 75 and say
  how to finish it, and doctor FAILs.
- A pbo process that waited for a lock (`backup --queue`, run-schedule, prune,
  verify) and finds that its config changed meanwhile (a cache move, `config
  set`; seen by the config file's inode as well as its mtime, and by a
  CACHE_DIR a finished move left) starts itself again with the new config (same
  arguments and pid), at most three times in a row; a subshell (each guest of
  `test-restore --scheduled`) never does: that guest fails and the next run
  reads the new config. `_restic_ensure` creates no empty repo while a
  move is unfinished, at a place a finished move left (a cache repo pinned
  outside the cache stays usable), or at a path the config
  on disk no longer names; a process that read the config before a move does
  not create the old CACHE_DIR again either.

- `RESTIC_ENV_FILE` (advanced, local-only; default `/etc/pbo/restic.env`; ADR
  0009, "Portability"): `KEY=VALUE` lines in the config grammar (quotes,
  `export`, `${NAME}` to a name set earlier in the file), given to restic and
  nothing else. This is where S3, B2, Azure, GCS and rclone credentials go
  (`AWS_ACCESS_KEY_ID=...`); a `rest:`, `sftp:` or local repo needs none. A
  missing file is fine. A file that is a symlink, owned by another user,
  writable by group or others or readable by others, or that sets `PATH`,
  `LD_*`, `RESTIC_PASSWORD*`, `RESTIC_REPOSITORY*`, `RESTIC_FROM_*`,
  `RESTIC_CACHE_DIR`, `RESTIC_HOST` (pbo expects every snapshot query to see
  all hosts), the rest-server login, a config key (`RESTIC_BIN`,
  `RESTIC_REST_PASSWORD_FILE`, ...: they belong in the config) or one of pbo's
  internal names, stops every restic command (exit 78, like a config line pbo
  refuses); `pbo config check` lists its errors by line and `pbo doctor`
  reports them as FAIL. The values are read in the subshell of each restic call
  and set on restic's command alone (`env`), so they cannot change what pbo
  runs: pbo's own shell, the programs it runs and the hooks never see them, and
  doctor, `config list|show|check` and the report show the file and its key
  names, never a value. The cluster-shared config cannot name the file. The
  permission table checks it (0600 or 0400, `doctor --fix`), and `install.sh`
  refuses an upgrade while pbo would refuse the file (`--force` installs
  anyway).
- `pbo catalog _umount`: the `ExecStopPost` of pbo-mount.service. It reads
  `PVE_CATALOG_MOUNT_DIR` from the config and lazily unmounts what is mounted
  there only when it is a FUSE mount (nothing mounted is fine, another
  filesystem is left alone). It runs no restic, so it also runs on a config
  line or a RESTIC_ENV_FILE pbo refuses: the dead mount of a restic that
  failed because of them is still removed.
- `RESTIC_MIN` (advanced; default 0.14.0, the oldest restic with every feature
  pbo always uses: `copy --from-repo`, `RESTIC_FROM_PASSWORD_FILE`,
  `sftp.connections`, repository format 2; ADR 0009 has the list). A
  rest-server login (`RESTIC_REST_USERNAME`) needs 0.16.1, which reads it from
  the environment. `pbo doctor` reports the restic version and FAILs below the
  minimum; `install.sh` refuses before it copies any pbo file and names what to
  install (`--force` installs anyway); it reads the cluster-shared config and
  the local one, as pbo does. Nothing is downloaded. `pbo list --reasons` works
  on 0.14 to 0.16 too, whose forget JSON names a reason's snapshot without its
  id: pbo finds it by time and tree.
- Thresholds that differ between sites are advanced keys, with the old fixed
  values as defaults: `PREFLIGHT_POOL_FREE_PCT` (150, the free space a guest's
  ZFS pool needs against what its volumes use), `BATCH_FIT_PCT` (85, the share
  of CACHE_DIR's free space batch mode may plan for), `INGEST_PENDING_MIN` (10,
  minutes before `ingest --pending` takes a spool archive), `PVE_SPOOL_MAX_AGE`
  (86400 s, doctor's limit for a stuck spool archive or offsite copy),
  `PVE_JOB_WINDOW_MIN` (60, doctor's window around pbo's timers) and
  `CATALOG_STAGE_WAIT` (10 s, a GUI request waiting for another staging of the
  same archive). A value that is not a whole number falls back to the default
  (doctor names it).
- `pbo doctor` names missing tools with the package to install: `setfacl` and
  `getfacl` (acl), `setpriv` and `findmnt` (util-linux).
- `pbo doctor --report [--json]`: an environment report to attach to a bug
  report: pbo's version and layout (deb, install.sh, source), the PVE package
  versions, restic, kernel, perl, bash, systemd and OS release, the UTC offset,
  single node or cluster (node count, quorum), CACHE_DIR's filesystem type and
  POSIX ACL support, each repo's backend type (sftp, rest, s3, b2, azure, gs,
  swift, rclone, local), append-only, the integration mode, whether
  RESTIC_ENV_FILE exists (and its number of variables) and which optional tools
  exist. No node or host name, URL, user, path or secret.
- `tests/hardcode.sh`: a lint in CI (through tests/all.sh) that fails on an
  absolute path, host name, IP address or clock time in `pbo`, `lib/`,
  `install.sh`, `systemd/` or `pve-plugin/` that is not a schema default, a
  comment, or an entry with its reason in `tests/hardcode.allow` (an entry that
  matches nothing fails too).
- `tests/portability.sh`: RESTIC_ENV_FILE's scope and refusals, `catalog
  _umount`, every systemd unit in both install layouts (the .deb built for
  real), RESTIC_MIN in doctor and install.sh, the new threshold keys, the
  dependencies, timestamps under UTC, +05:30 and -03:00 (archive names, the
  catalogue's ctime, the timers' next run, and that the retention plan restic
  makes from the local day each snapshot recorded is passed through unchanged),
  `_ct_root_uid` with custom idmaps, and `doctor --report` with secrets, URLs,
  hosts and paths planted in the config. Every suite points RESTIC_ENV_FILE
  into the checkout, and the config corpus check fails when a config a suite
  loaded resolves a secret file to one of the machine's own.
- README: a compatibility matrix (what the suites and CI test, and what they
  do not: PVE versions, restic versions, layouts, filesystems, backends,
  clusters, time zones).
- Timer schedules as config keys (ADR 0009, "Portability, part 2"):
  `SCHEDULE_BACKUP`, `SCHEDULE_PRUNE`, `SCHEDULE_VERIFY`,
  `SCHEDULE_TEST_RESTORE`, `SCHEDULE_CATALOG` (host) and `SCHEDULE_JANITOR`
  (janitor) in systemd's `OnCalendar=` syntax, with the `RandomizedDelaySec=`
  of the timers that have one as `SCHEDULE_*_DELAY`. The defaults are the
  values in `systemd/*.timer` (unchanged: 05:00 nightly, Sunday 06:30, Wednesday
  and Saturday 10:00, every 15 minutes, 12:30 on a janitor). The new types
  `calendar` and `timespan` are checked with `systemd-analyze` when it is
  installed and, when it is not, with a narrow check that takes the common
  forms only, every number in its range and a time zone only when it is UTC or
  in the zoneinfo database (anything else is refused rather than guessed: the
  drop-in clears the unit's calendar, so a value systemd ignored would leave the
  timer with no trigger); a value with a newline, `%`, `\`, `=` or `[`
  (unit-file syntax) is always refused, with 78 and nothing written. `pbo
  config set|unset` writes the timer's drop-in
  (`/etc/systemd/system/<timer>.d/schedule.conf`: `OnCalendar=` cleared, then
  the value) and runs `systemctl daemon-reload`; a key back at its default
  removes the drop-in. The unit files are never edited. A schedule change
  resets the timer's persistent state: an enabled timer is stopped before its
  drop-in changes, its last-trigger stamp is cleared after the reload
  (`systemctl clean --what=state`, systemd 247 or later) and it is started again
  when it was running, so its next run is computed from now. A change to an
  earlier time than the last run therefore does not start the job at once, and
  a run missed under the old schedule is not caught up. A disabled timer stays
  disabled, an enabled one that was not running stays stopped.
- `pbo timers apply`: writes (or removes) every drop-in of the role from the
  config. `install.sh` runs it after installing the units and the `.deb`'s
  postinst after an upgrade, so a reinstall keeps a custom schedule; `pbo
  doctor --fix` applies them too (on a janitor started as root, before it drops
  to the janitor user). `pbo doctor` WARNs when a drop-in does not match the
  config (a hand edit, the cluster-shared file, a value refused), when systemd
  has not reloaded its unit files, and when the calendar systemd runs
  (TimersCalendar) is not the config's (another drop-in such as an
  `override.conf` from `systemctl edit` sets `OnCalendar=`). On a janitor
  started as root, the re-exec'd doctor audit-logs the drop-ins root wrote.
  `pbo timers` shows the calendar systemd runs in its SCHEDULE column, the
  source of the configured one (default, config, shared, env), and a note
  where the two differ; doctor's PVE job window compares jobs with the
  calendar systemd runs.
- Per-node storage ids in a cluster: `PVE_STORAGE_ID` defaults to `pbo` on a
  single node and to `pbo-<node>` in a cluster (pmxcfs' member list), unless
  storage.cfg already has a pbo storage for this node (`pbo-<node>`, or one
  whose `nodes` names it or that has none), which keeps its id. An explicit
  `PVE_STORAGE_ID` always wins; it is per node (`local-only`): a value in the
  cluster-shared file is ignored (doctor FAIL), set it per node. `pbo integrate
  enable` pins a derived per-node id in the local config and refuses to take
  over another node's pbo storage (its `nodes` leave this node out), or to
  change the path of an entry it shares with other nodes (no `nodes`, or a
  list with others): setting it to this node's spool would repoint them, and
  `--catalog-only` deleting it would take their backup target away. `pbo
  integrate disable` refuses another node's storage before it changes
  anything, and takes this node off a shared entry's `nodes` instead of
  removing it, so only the last node removes it. Doctor FAILs a storage whose
  `nodes` leave this node out, and in a cluster where `pbo` serves more than
  this node it WARNs with the way to move, node by node (disable, set
  `PVE_STORAGE_ID pbo-<node>`, enable, recreate the jobs per node by hand).
- `tests/schedule_config.sh` (in tests/all.sh): the schedule keys against the
  units, drop-ins written and removed, reload and the stop / clean / start
  order (running enabled timers only), refused values with and without
  systemd-analyze, dry run, `pbo timers [apply]`, doctor's drift warnings and
  `--fix`, the calendar systemd runs against the config, install.sh
  re-applying a schedule over fresh units, the janitor's keys and its root
  pass (a fake runuser), the PVE job window. `tests/integrate.sh` runs pbo with
  a mocked pmxcfs member list (no cluster block, a cluster of one, of two and
  of three) for the per-node ids, shared entries, enable/disable/status and
  ownership in a cluster. Both run a copy of pbo that stops (99) when a path it
  resolved (config, directories, PVE paths, the systemd directory) lies
  outside the suite's run directory (`tests/fixtures/run_dir_guard.sh`); every
  suite points `PBO_SYSTEMD_DIR` and pmxcfs (`PBO_PVE_CFS_DIR`,
  `PVE_STORAGE_CFG`) into the checkout.
- `tests/menu.sh` covers the setup wizard: the sftp repo and command parsed
  back (round trips, a 0.5 label, the URL form, `-l`/`-o` options), when the
  command is needed, the filesystem list and the suggestion (mocked findmnt),
  values asked again until the schema takes them, the cache step's calls
  against a fake pbo (same path, dry run then set, a no, `--fix-parents`), and
  `pbo setup` end to end with scripted answers: a first setup (sftp with a port
  and a key, the host key pinned, the DR key, retention and a schedule with its
  drop-in, timers, doctor), re-runs that keep an sftp repo with its port and
  key and an append-only `rest:` repo with the config unchanged, each type of
  target (rest-server, directory, `s3:` with `RESTIC_ENV_FILE` 0600 and no
  value in the output), and a cache with data moved on a yes and left on a no.
  The guard (`tests/fixtures/run_dir_guard.sh`) also checks the keys a suite
  names in `TEST_GUARD_KEYS` and stops before a new CACHE_DIR, a file the wizard
  writes or a key pair it generates outside the run directory.

Changed
- The config writers of `pbo setup`, the menu (`_cfg_set`) and `pbo integrate`
  (`PBO_INTEGRATION`) go through the same writer as `pbo config set`: values
  are quoted (0.5 wrote them bare, so a value with `&`, `|` or a space broke
  the file), comments, owner, group and mode are kept (0.5 forced 0600 and
  dropped a replaced line's comment), the temp file is in the config's
  directory instead of `/tmp` (an atomic rename), and a value of the wrong type
  is not written (`_cfg_set` says why). The wizard no longer pins
  `RESTIC_CACHE_REPO` at `<CACHE_DIR>/repo` (it follows CACHE_DIR).
- The audit.jsonl record of `pbo config set|unset` has `read_only: false`; the
  other `config` subcommands stay read-only records.
- Doctor's permission lines come from the rule table. The DR key line, the
  CACHE_DIR lines (open, closed, closed without a CT's ACL entry: FAIL) and the
  world-writable LOCK_DIR warning keep their meaning and wording; a fixable
  finding ends in "(pbo doctor --fix)". A group-writable CACHE_DIR is now a
  warning too (at most 0750). The other paths that pass are one line
  (`permissions: N more path(s) as the rule table wants`). `pbo doctor` refuses
  unknown arguments (exit 64; it ignored them). The CACHE_DIR closing every
  backup does (`_cache_dir_protect`) is the CACHE_DIR rule of the table: same
  order (ACL entries first, never closed without them or without setfacl), and
  it never changes a shared directory (`CACHE_DIR=/tmp`) or runs in a dry run.
- Retention per guest (ADR 0009, "Retention per guest"). `forget --group-by
  paths` made each path a guest of its own, so after a CACHE_DIR move the old
  path's snapshots would be kept for ever, and `host-<node>` snapshots were kept
  per path list. pbo now runs the 0.5 forget calls unchanged and adds, for each
  guest with more than one path, `forget --group-by '' --tag vmid=<id>` with the
  policy that guest gets (its keep= tag and `KEEP_OVERRIDE_MIN_LAST` on offsite,
  `RESTIC_KEEP_LAST` on the cache). The host stays out of the grouping, as
  before. One runner serves the cache tier, offsite, the janitor's bound forget
  (both passes planned with `--dry-run` and checked) and `pbo list --reasons`, so
  the plan shown is the plan pruned. The cache tier finds its split guests in the
  output of its own 0.5 forget (which lists every snapshot of the repo), so it
  makes no call that 0.5 did not. Snapshots without a vmid tag are
  treated exactly as in 0.5. Run `pbo --dry-run prune` (or `pbo list --reasons`)
  before the first prune after the upgrade when doctor lists a guest.
- The config is read, never sourced (0.6 M3): `load_config` keeps the merge
  (with `PBO_CONFIG` unset the cluster-shared file, then `/etc/pbo/config`,
  which wins; with `PBO_CONFIG` that file alone), the precedence (file, then
  environment, then default; an empty value is the default) and the owner/mode
  rules. `PBO_CONFIG_LOCAL` is always the local file, whether it exists or not,
  and is the only file pbo writes: `pbo setup`/the menu (`_cfg_set`) and `pbo
  integrate` (`PBO_INTEGRATION`) wrote to the cluster-shared file when no local
  one existed (fixed). `pbo version` and every other start cost no more than the
  0.5 `source`: the schema is loaded only as far as the loader needs it, and the
  forks of the old file checks are gone.
- `pbo config` shows `LOCK_DIR` and the inline-only keys with their values (they
  were reported as secrets because the old key list missed them). Secrets are the
  keys the schema flags (`NTFY_URL`, `NTFY_TOPIC`, `NTFY_TOKEN`,
  `RESTIC_SFTP_COMMAND`) plus any key the schema does not know.
- Doctor's config check reads the schema: every key's value is checked against
  its type (a warning names the key and what is wrong), deprecated keys name their
  replacement, and a key is "unknown" when neither the schema nor the list of
  environment switches (`PBO_REPO`, `PBO_NO_NOTIFY`, `TMPDIR`, ...) has it
  (before: when no upper-case word in pbo's code matched it). In a cluster the
  unknown keys of `/etc/pve/pbo/config` are named too. A space-separated
  `VZDUMP_STOP_VMIDS` is a warning: pbo splits it on commas only.
- `pbo setup` is safe to run again (ADR 0009, "Wizard"; interactive only):
  every question offers the effective config and Enter keeps it (CACHE_DIR,
  LOCAL_REPO, the offsite repo and, for an sftp one, the host, port, user, key
  and pinned host key read back from `RESTIC_SFTP_COMMAND`, retention, ntfy,
  `BACKUP_ORDER`, the schedules), and an answer that keeps a setting writes
  nothing, so a run that keeps everything leaves the config as it was. A
  configured offsite repo (an append-only `rest:` one included) is shown, its
  login masked, and kept unless the operator chooses to change the target;
  replacing it asks first (pbo moves no snapshot). 0.5 asked for an SFTP host
  on every run and rewrote the repo, the ssh command and the pinned host keys,
  and a no to ntfy emptied `NTFY_URL`.
- `pbo setup` asks for the type of offsite target instead of assuming a Storage
  Box: an SFTP server (any host, port, user and key; the repo is
  `sftp:<user>@<host>:<path>`, IPv6 as `sftp:<user>@[<v6>]:<path>`, with
  `RESTIC_SFTP_COMMAND` only when the port, the key, the pinned host key, ssh
  options of the configured command (kept while the host stays) or a host key
  ssh has not recorded yet (`accept-new`) needs it; 0.5 wrote
  `sftp:<label>:<path>` and a command every time), a rest-server (URL, user, a
  0600 password file, append-only or not; a login in a configured URL is moved
  out of it, never shown), a local or mounted directory, or another restic backend
  (the repository string; the variables that backend reads, such as
  `AWS_ACCESS_KEY_ID` for `s3:`, are named, read without echo, never printed,
  and written to `RESTIC_ENV_FILE`, 0600, only when pbo's own reader of that
  file takes them back as given). The Storage Box hints, its defaults (port 23,
  the account as the user) and the snapshot question
  (`STORAGE_BOX_SNAPSHOTS_CONFIRMED`) come only for a host below its domain.
  When the type changes, the keys of the old one go (`RESTIC_SFTP_COMMAND`; the
  rest-server login, `RESTIC_CACERT`, `OFFSITE_APPEND_ONLY`); one the
  cluster-shared file or the environment sets is written to its default in the
  local file, as is the ntfy server on "turn ntfy off". With a local cache
  repo, "none" turns offsite off.
- `pbo setup`'s cache step lists the local disk filesystems (findmnt -t; df -l
  -t without it, so a dead network mount is never sized and cannot hang it)
  with their type and free space, suggests `<mount>/pbo-cache` on the one with
  the most (the default only on a first setup when the config names no
  CACHE_DIR and the cache holds no data; otherwise a hint, and Enter keeps the
  effective CACHE_DIR without writing it), warns when the root filesystem is
  smaller than 1.5 times the largest dump of the node's guests (every disk of a
  VM), and sets the directory with `pbo config set
  CACHE_DIR`: another path shows the dry run first and runs the change (an
  empty cache: created with the permission table's rules; one with data: the
  cache move) on a yes, and offers `--fix-parents` when the plan says an
  unprivileged CT cannot pass a directory above it. 0.5 ran `mkdir -p` and
  wrote the path (and pinned `RESTIC_CACHE_REPO`).
- `pbo setup` checks numbers, choices and schedules against the schema and asks
  again until they are valid (the end of the input stops the question instead
  of asking for ever). A schedule step sets `SCHEDULE_BACKUP`,
  `SCHEDULE_PRUNE`, `SCHEDULE_VERIFY` and `SCHEDULE_TEST_RESTORE` (the writer's
  hook writes their drop-ins); the timer questions name the configured
  schedule (they named the default times), skip a timer that is enabled, and
  default to no on a re-run (Enter enabled every timer that was off).
  The last step runs `pbo doctor --fix` and shows its report.
- The wizard's and the menu's config writes (`_cfg_set`) run the writer's
  after-write hooks (apply-schedule, restart-mount) and are audit-logged as
  `pbo config set` is. A CACHE_DIR that changes is not written there: it goes
  through `pbo config set CACHE_DIR` (the cache move runs in a pbo of its own).
  The files the wizard writes itself (the DR key, a rest-server password,
  `RESTIC_ENV_FILE`, known_hosts) are written atomically: a temp file in their
  directory, then a rename; a symlink at the path is refused.
- The generated example's restic section shows an sftp repo as
  `sftp:<user>@<host>:<path>` and when `RESTIC_SFTP_COMMAND` is needed (it
  showed the Storage Box alias).
- `pbo config set CACHE_DIR` on a cache with data moves it (Added); 0.6 M4
  refused it (69). With the Proxmox integration on, an empty cache whose spool
  follows is moved the same way (the storage path changes) instead of the M4
  refusal.
- pbo-mount.service runs `pbo catalog _umount` after it stops instead of
  `umount -l /run/pbo/mnt`: with another `PVE_CATALOG_MOUNT_DIR` a dead FUSE
  mount was left behind.
- The `.deb` depends on `restic (>= 0.14.0)` (was `>= 0.16`) and on `acl`;
  `install.sh` installs `acl` and `util-linux` when `setfacl`, `getfacl`,
  `setpriv` or `findmnt` is missing.
- Every restic call that opens a repo goes through one wrapper, which exports
  RESTIC_ENV_FILE and the rest-server login in its own subshell: `rotate-key`
  exported the rest-server password into pbo's shell, and ran restic outside
  the wrapper.
- `_ct_root_uid` no longer reads `/etc/subuid`: without an `lxc.idmap: u 0`
  line pve-container always maps CT root to 100000 and ignores that file, so a
  custom root range there put the CACHE_DIR ACL (and doctor's check of its
  parents) on a uid the CT does not run as, and its vzdump failed.
- Preflight reads storage.cfg from `PVE_STORAGE_CFG`, and the node name comes
  from the pmxcfs directory pbo is configured with; `install.sh` takes the
  default log, state and cache directories from the schema. All three had the
  default path written out.
- The refusal of `export FOO=...` in the config points restic's variables to
  `RESTIC_ENV_FILE`.
- Doctor's warning about a PVE job near a pbo timer compares the job with the
  configured backup, prune and verify schedules (any calendar expression whose
  times can be worked out: plain times are read directly, wildcards and
  repetitions through `systemd-analyze calendar`), names the run closest to
  the job and the window (`runs within 60 min of pbo.timer (05:00)`; it said
  "within an hour" whatever `PVE_JOB_WINDOW_MIN` was).
- Guest ownership (`both`, `integrated`) counts only the pbo storages that
  serve this node (no `nodes`, or `nodes` names it): a cluster-wide job on
  another node's pbo storage does not back up this node's guests (vzdump finds
  the storage unavailable here), so it no longer leaves them to nobody.
- The catalogue, `pbo integrate` and doctor take the storage id from
  `PVE_STORAGE_ID` as configured (or derived), never from a literal `pbo`.

Fixed
- The check for a running vzdump (`_vzdump_running`, `ingest --pending`)
  silenced the rest of the command's error output when the vzdump lock file
  existed (a bare `exec ... 2>/dev/null`).

## 0.5.0 (unreleased)

Changes behaviour: pbo-web is gone, and the Proxmox integration is new (off by
default). A host that stays `standalone` and never ran pbo-web behaves as 0.4.1.

Removed
- **pbo-web, the web UI** (ADR 0008, supersedes ADR 0005): the Go code, the
  `pbo-web` package, `pbo-web.service`, `pbo-web-helper.service`, the egress rule,
  `etc/web.env.example`, `packaging/dev-build-web.sh`, the CI job and the web design
  files. The Proxmox GUI (with the integration) and the CLI cover it; isolated
  restores stay `pbo restore`. `install.sh` removes a pbo-web it installed
  (services, binary, the `pbo-web` user, `/etc/pbo/web.env`, `/etc/pbo/web-tls`);
  the `pbo` package `Breaks: pbo-web`, so apt removes the old package. Close TCP
  8008 in the firewall afterwards. The CLI options pbo-web used stay.


Added
- `PBO_INTEGRATION=standalone|both|integrated` (default `standalone`, unchanged
  behaviour, no extra `pvesh` calls) and guest ownership (lib/ownership.sh,
  ADR 0007): in `both`, run-schedule skips guests that an enabled PVE backup job
  to a `pbo` storage owns and logs which job; in `integrated` it backs up nothing.
  If the jobs cannot be read it backs up every guest (fail open) and warns.
  Doctor's freshness check and test-restore cover PVE-owned guests too.
- `guests --json` has `owner` (`pve|pbo|none`) and `owner_job`; `status --json`
  has `integration`. Doctor reports the mode and, with the integration on, flags
  an unowned guest in `integrated` (FAIL), `pbo-skip` on a PVE-owned guest, a
  guest in two pbo jobs and unknown ownership (WARN). A manual backup of a
  PVE-owned guest warns that it is an extra backup.
- New config keys for the integration (see etc/config.example); a janitor refuses
  any mode but `standalone`.
- `pbo catalog refresh|show|materialize <archive>|release [--all]` (lib/catalog.sh,
  ADR 0006 Phase 1). `refresh` reads both repo tiers with `--no-lock` and writes
  the index the PVE storage plugin will read (`PBO_CATALOG`) atomically, merged
  by vmid and timestamp, with the snapshot id per tier and an `offsite_only`
  flag; an unreadable tier fails the refresh and keeps the old index.
  `materialize` stages one archive in `PVE_STAGING_DIR` with `restic dump
  --no-lock` (cache first, offsite for offsite-only archives), or with
  by default as a symlink into `pbo-mount.service` (restic mount of the cache
  repo, layout verified in spike A; `PVE_CATALOG_MOUNT=false` for dump only).
  From a GUI request (`--background`) a cache archive is linked through the
  mount inline, waiting at most `CATALOG_MOUNT_BG_WAIT` (10 s), so Show
  Configuration answers on the first click. `release` removes staged
  archives older than `PVE_STAGING_TTL` and stops an idle mount. With the
  integration on, run-schedule and prune refresh the index at the end (a failure
  is a warning). prune and verify stop an active `pbo-mount.service` before they
  take exclusive repo locks. New units `pbo-catalog.service`/`.timer` (every
  15 minutes) and `pbo-mount.service`, not installed yet and left out of the
  `pbo` package.
- The Proxmox VE storage plugin `pve-plugin/PboPlugin.pm` (type `pbo`, ADR 0006):
  lists the catalogue's archives (and, when the storage has a `path`, archives a
  PVE job wrote to `<path>/dump` that are not ingested yet) as ordinary vzdump
  backups with a note per tier, and stages one for a restore or Show
  Configuration with `pbo catalog materialize`. `status`, `activate_storage`,
  `list_volumes` and `path` only read the index and stat the spool: no fork, no
  network, no FUSE. `list_volumes` dies with "run: pbo catalog refresh" on a
  missing index. Remove, real prune and protection changes are refused;
  `protected` is always 1 and notes are accepted and dropped. The options are
  `path` (optional, not fixed), `nodes`, `disable` and `content`; no
  `prune-backups`. A restore warns in the task log when pve-manager,
  libpve-storage-perl, qemu-server or pve-container is newer than the tested set.
- The index has `spool_dir` (informational; the plugin uses the storage's
  `path`).
- Third package `pbo-pve-storage_<version>_all.deb`: the plugin and the
  catalogue/mount units. Depends on `pbo (= version)`, `libpve-storage-perl
  (>= 9.1.18)` and `pve-manager (>= 9.2.29)`, activates the `pve-api-updates`
  trigger, never edits storage.cfg or vzdump.conf, and its prerm refuses removal
  while storage.cfg has a `pbo:` storage or vzdump.conf runs the pbo hook.
- `pbo ingest --vmid V --archive P` (lib/ingest.sh, ADR 0006 Phase 2): uploads an
  archive a PVE backup job wrote to the pbo spool (`PVE_SPOOL_DIR/dump`). The
  archive must lie in the spool itself, be a regular file (no symlink) and be
  named `vzdump-<lxc|qemu>-V-<ts>.<tar|vma>`. Ingest takes only the guest's lock
  (busy: exit 75 at once, never `pbo.global`), renames the archive into
  `$CACHE_DIR/V` (same filesystem, so the snapshot path is the same as for pbo's
  own backups), writes the `.conf` sidecar, backs it up to the cache and copies it
  offsite synchronously, and adds it to the catalogue. It sends no notification
  (PVE notifies about its job) and logs into the PVE task log. When nothing
  reached a repo the archive goes back to the spool; when only the offsite copy
  failed it exits 69 and the cache keeps the snapshot.
- `pbo ingest --pending`: ingests spool archives older than 10 minutes unless
  vzdump runs (`VZDUMP_LOCK`), then runs an unfiltered, idempotent `restic copy`
  cache → offsite. run-schedule runs it first when the integration is on (a
  failure is a warning).
- The vzdump hook `lib/vzdump-hook` (plain sh), shipped in `pbo-pve-storage` as
  `/usr/lib/pbo/vzdump-hook`. It exits 0 without starting pbo unless `STOREID` is
  a `pbo:` storage in storage.cfg (pbo's own `--dumpdir` runs have none), then
  runs the hidden `pbo _vzdump-hook`: `backup-start` refuses a compressed target
  and a guest pbo backs up in stop mode (fuse, `VZDUMP_STOP_VMIDS`, `pbo-stop`)
  in a snapshot or suspend job; `backup-end` runs `pbo ingest`; `log-end` removes
  the task log copy from the spool. The prerm guard checks for this path.
- Metrics: `pbo_ingest_last_*` (time, success, duration of the last ingest).
- `pbo integrate status|enable <both|integrated> [--catalog-only]|disable`
  (lib/integrate.sh), the one switch for the Proxmox integration. All three are
  idempotent, honour `--dry-run` (planned commands and the vzdump.conf diff) and
  are audited; enable/disable need root and are refused on a janitor.
  - `status [--json]`: mode, PVE versions against the minimums, plugin present
    and loadable, the storage (read from storage.cfg), the hook, the spool, the
    catalogue, the PVE jobs to pbo with their problems, guest ownership, ACLs,
    and the exact storage.cfg stanza and vzdump.conf line for a recipe.
  - `enable`: preflight first (versions, plugin, repos readable, spool and
    staging on CACHE_DIR's filesystem, no storage id of another type, no foreign
    `script:` in vzdump.conf unless `--catalog-only`), then a catalogue refresh,
    the spool (0755) and staging (0700), `pvesm add pbo <id> --content backup
    --nodes <node> [--path <spool>]` (or `pvesm set` to converge the path), the
    hook line after a marker comment in vzdump.conf (atomic, mode and owner kept;
    `--catalog-only` removes ours), `pbo-catalog.timer`, a warning for ACLs that
    give others than root@pam Datastore.* on the storage, and `PBO_INTEGRATION`
    written last.
  - `disable`: refused while an enabled PVE job writes to a pbo storage (pbo
    never edits jobs.cfg); `PBO_INTEGRATION=standalone` written first, then
    `ingest --pending` (refused while spool archives remain), our hook line(s)
    removed (vzdump.conf comes back byte for byte), the mount stopped and staging
    emptied, `pvesm remove`, the timer disabled.
- Doctor with the integration on: FAIL for PVE older than the minimum, a missing
  or unloadable plugin, a missing storage or one of another type, a missing,
  foreign or non-executable hook (backup target), a storage path that is not
  `PVE_SPOOL_DIR`, a spool on another filesystem than the cache, spool archives
  older than 24 h, and an enabled pbo job with its own `script`, compression,
  `prune-backups`, `protected`, or a stop-mode guest in a job of another mode;
  WARN for PVE newer than the tested set, an old or missing catalogue, a disabled
  pbo job, `notification-mode none`, a job within an hour of pbo.timer, prune or
  verify, ACLs for others than root, too little spool space and a disabled
  `pbo-catalog.timer`. In standalone it warns (reading storage.cfg, no pvesh) when
  a pbo storage is still configured.
- `pbo timers` lists `pbo-catalog.timer` too when the integration is on.
- `install.sh --integration standalone|both|integrated` (`--mode` is an alias;
  refused with `--janitor` unless standalone). Without the flag it keeps
  `PBO_INTEGRATION` from the existing config, asks on a terminal, and otherwise
  installs standalone. For both/integrated it checks pve-manager >= 9.2.29 and
  libpve-storage-perl >= 9.1.18 before copying any file, installs the plugin
  (load-tested, removed again when it does not load; the PVE daemons are reloaded
  only when the file changed), the hook in `/usr/local/lib/pbo/vzdump-hook` and
  the catalogue/mount units (not enabled). It never creates the storage. An
  explicit `--integration standalone` on a host whose config says both or
  integrated runs `pbo integrate disable` first and then removes the plugin
  (never while storage.cfg still has a pbo storage). install.sh is now a set of
  functions with a guarded main.
- `pbo setup` has a "Proxmox integration" step between the guests and the
  timers: it shows `pbo --dry-run integrate enable <mode>` and applies it after a
  yes (without the plugin it says how to install it and stays standalone).
- Test mocks: `dpkg-query`, `pveum`; `pvesm add|set|remove` edit
  `$MOCK_STORAGE_CFG`; `systemctl enable|disable|is-enabled`. New suites
  `tests/integrate.sh` and `tests/install.sh`.
- Tests: `tests/perl.sh` (Test::More against stubbed PVE modules, in
  `tests/all.sh` and CI) and the opt-in `tests/integration/pve-storage.sh`
  (`--load-only` loads the plugin against the installed PVE libraries without
  installing it; `--full` adds a temporary storage and only runs with
  `PBO_IT_PVE_STORAGE_FULL=1`). CI checks the third package's trigger and prerm.

Changed
- The upload half of a backup (restic backup of `$CACHE_DIR/<vmid>`, copy
  offsite, drop the loose archive) is one function, `_upload_dumpdir`, shared by
  `backup`, `run-schedule --batch` and `ingest`.
- A PVE backup job in stop mode uploads at `job-end` instead of `backup-end`
  (ADR 0006, amendment 14): vzdump restarts a stopped guest only after
  `backup-end`, so the guest stayed down until the offsite copy was done.
  `backup-end` now checks the archive and records it; a failed upload at
  `job-end` fails the job. Snapshot and suspend mode are unchanged.
- In a synchronous PVE API request (Show Configuration, the Restore dialog, a
  QEMU restore before its worker starts) the storage plugin no longer stages an
  archive inline: it runs `pbo catalog materialize --background` with a 20 s
  timeout, which returns a staged archive at once or starts a detached staging
  and fails the request with "retry in a few minutes". LXC restores (a worker)
  and the CLI still wait.
- `pbo-catalog.service` runs `pbo catalog release` before each refresh, and
  release also removes staged archives the catalogue no longer lists (pruned).
- prune, verify and `catalog release` do not stop `pbo-mount.service` while a
  process reads through it: prune and verify wait up to
  `CATALOG_MOUNT_BUSY_WAIT` seconds (900), then exit 75. In standalone they no
  longer look at the mount (no systemctl call).

Fixed
- CACHE_DIR (pbo's own dump directories and the Proxmox spool) was 0755, so a
  local user could read a plaintext vzdump archive while a backup ran. pbo now
  closes it to other users before every backup. vzdump's tar of an unprivileged
  CT runs as the CT's mapped root and has to reach its tmpdir under CACHE_DIR,
  so that uid gets an ACL entry (`u:<uid>:--x`) first; without `setfacl` (package
  acl) the directory stays open. Doctor warns while it is open and fails when it
  is closed without the entry for a local unprivileged CT.
- A staged symlink into the mount kept `pbo-mount.service`, and its lock on the
  cache repo, up for the whole `PVE_STAGING_TTL` (6 h). Mount links now go after
  `PVE_STAGING_LINK_TTL` (15 min) while nothing reads through the mount, and the
  idle mount stops. Help text of `ingest --pending` and `catalog release` updated;
  RUNBOOK has a section on running the integration.
- `tests/integration/pve-storage.sh --load-only` failed on a host where the plugin
  is installed (it loaded the checkout's copy over the registered one). It now
  checks that the installed file is the checkout's and tests that one, so it can
  run after every Proxmox upgrade as the RUNBOOK says.
- A GUI restore of an **unprivileged** container through the mount failed with
  "tar: -: Cannot open: Permission denied": Proxmox hands the archive's open fd to
  `lxc-usernsexec tar` (the CT's mapped root, e.g. uid 100000), and FUSE refuses
  every request from another uid without `allow_other`. `pbo-mount.service` now
  runs `restic mount --allow-other` (file modes still apply) and refuses a mount
  point whose parent is not root-only.
- Lines pbo writes into a Proxmox task log (the vzdump hook) are ASCII: the PVE API
  hands task logs out as latin1, so "→" showed up as "â" in the GUI.
- A stop-mode Proxmox job now keeps vzdump's `.log` in the snapshot: `log-end`
  leaves it in the spool for the job-end ingest. (Snapshot mode uploads at
  backup-end, before vzdump writes the log; it stays in the Proxmox task history.)
- Doctor warns when a stop-mode job's guests together (their newest archives)
  need more spool space than is free; until now it compared only the largest
  single archive.
- The question `integrate enable --catalog-only` asks now says what happens to
  `/etc/vzdump.conf`: untouched, or (when downgrading from a full enable) pbo's
  hook line removed. It used to list the file as if the hook were being added.
- The regression suite for the 0.4.0 audit fixes (now tests/regressions.sh) ran
  with the default LOCK_DIR, so as root it could take `/run/pbo/pbo.global` and
  leave lock files there; it now uses its own lock directory like the other
  suites.
- `ingest --pending` ran an unfiltered `restic copy` cache → offsite, which also
  re-uploaded cache snapshots that offsite retention had removed (for example
  old snapshots of a deleted guest). An ingest whose offsite
  copy fails now records `<vmid>_<ts>` under `STATE_DIR/ingest-copy`, and
  `--pending` copies exactly those (`--tag vmid=,ts=`, like the upload) and
  drops each record once copied. Doctor fails when a record is older than 24 h.
- `pbo restore` and `pbo test-restore` restored a **privileged** container as an
  unprivileged one. Proxmox leaves the `unprivileged:` line out of a privileged
  CT's config, and pbo read a missing line as "unprivileged", so the copy got
  shifted uids (files owned by 100000+) and `--restricted` (pbo-web without
  Sys.Modify) did not refuse it. A missing line now means privileged; with no
  config sidecar pbo reads the `pct.conf` vzdump puts in the archive. In place
  since the restic engine was added.
- `pbo --dry-run run-schedule` took REAL backups: each guest's `backup --queue`
  child never saw `--dry-run` (stop-mode guests were stopped). It now only logs
  and returns `would_backup` without starting anything (also with `--batch`).
- Doctor and `integrate status` flagged a PVE job with "Keep all backups" as a
  `prune-backups` problem: the API returns `prune-backups` as an object, which is
  now normalised (`keep-all=1` alone is fine).
- `run-schedule --batch` held no per-guest lock between dump and upload, and
  uploaded `$CACHE_DIR/<vmid>` without checking the archive was still there: an
  ingest of the same guest in between could leave an empty snapshot counted as
  OK. Batch now holds each guest's lock from dump to upload (a busy guest fails)
  and a vanished dump fails the guest.
- The prune, verify, restic, append-only and audit test suites ran the host's
  real `systemctl`; they use the mock now.
- A restic backup or copy that failed for another reason than a repo lock ended
  `backup` and `backup-host` with exit 1 and "stopped unexpectedly" instead of
  their own message and exit code (70, or 69 for the offsite copy): the lock
  check's empty result tripped errexit.
- The guest metadata cache split `pvesh` fields on tabs, and `read` merges empty
  tab-separated fields: a guest without a name had its tags read as its name, so a
  `pbo-skip` or `pbo-keep-*` tag on it was ignored.

Docs
- ADR 0006 accepted, with amendments (optional integration, a step-by-step bring-up,
  libpve-storage-perl >= 9.1.18, `pbo ingest --pending` instead of `pbo sync`).
- ADR 0007: install modes `standalone|both|integrated` (`PBO_INTEGRATION`) and one
  owner per guest. Nothing is built yet; `standalone` stays the default.

## 0.4.1 (2026-11-22)

The first packaged 0.4 release: CI failed for the v0.4.0 tag, so v0.4.0 has no
.deb. 0.4.1 is 0.4.0 plus the fixes below.

Fixed
- `restore` without `--storage` ended silently (exit 127, or pvesm's own exit
  code) when `pvesm` was missing or failed, e.g. without quorum. It now says that no
  storage was found and asks for `--storage`.
- Tests are hermetic: a `pvesm` mock, and the schedule tests no longer ask the
  real host's pvesh/pct. CI had been red because restore tests reached
  for a real `pvesm`. Root-only checks are skipped when the suite runs unprivileged.
- CI: the .deb job inspected both packages in one `dpkg-deb --info` call (it takes
  one archive) and failed as soon as pbo-web was packaged. Failing tests are now
  reported as annotations.

Docs
- ADR 0006 (proposed): pbo as a native Proxmox VE storage. PVE lists and restores
  pbo's snapshots from the GUI first. Datacenter -> Backup jobs come later, and a
  Backup Provider plugin only if needed.

## 0.4.0 (2026-11-22)

Changed (behaviour)
- **A restore is isolated by default** (CLI, menu and web): every NIC
  `link_down=1`, autostart off, and under the test-restore allowlist everything
  that reaches into the host is removed (bind/device mount points, `devN`,
  hookscripts, raw `lxc.mount`/`lxc.hook` lines, passthrough, unknown keys,
  `features` beyond nesting/keyctl/fuse, `lxc.cgroup2.devices.*`,
  `lxc.apparmor.profile`). It runs under a config lock, so the copy cannot be
  started halfway; if isolation fails the new copy is destroyed and the restore
  fails. Before, a CLI restore kept `onboot: 1`, the original's MAC/IP and its
  bind mounts, so it autostarted next to the original at the next reboot.
  `--keep-network` restores the copy exactly as the original (disaster recovery)
  and is refused while the original still exists in the cluster. `--isolate` is
  accepted (the default). `--restricted` (passed by the web UI for users without
  Sys.Modify) refuses privileged containers.
- `verify` fails when a repo tier cannot be opened (unreachable or wrong
  password); it used to skip it and report OK, so the rotating deep read silently
  passed over offsite. It also queues on the schedule lock and uses `--retry-lock`.
- Locks live in `/run/pbo` (root only; `STATE_DIR/lock` when not root) instead of
  the world-writable `/var/lock`; `doctor` warns about a world-writable `LOCK_DIR`.
- A per-guest retention tag never keeps fewer than `KEEP_OVERRIDE_MIN_LAST` (3)
  snapshots; `doctor` warns about guests below the default retention and about
  skipped (`pbo-skip`) guests.
- test-restore locks its throwaway vmid (free cluster-wide), no longer the source
  guest (whose nightly backup it used to block), uses its own temp directory, and
  clears `protection` before destroying the throwaway. The record says how the
  answer was proven (`respond_check`: exec, agent, or running for a VM without
  an agent). Privileged containers need Sys.Modify from the web UI.
- The janitor unit runs prune, verify and doctor even when one fails; on a
  janitor a guest with no new snapshot within `DOCTOR_MAX_AGE` is a problem and
  an alert (its host stopped sending).

Changed (breaking for `--json` consumers)
- The `--json` output is a versioned contract: every object carries
  `schema: 1`, there is exactly one object per command on stdout, and errors are
  JSON too (`status: "error"`, `exit`, `error`). Counters are numbers
  (`run-schedule` `backups_ok`/`backups_failed`/`duration_s`), `prune`
  `failed_tiers` is an array, `status` reports `locks.global` / `locks.schedule`
  as objects instead of `global_lock`/`lock_state` strings, and `doctor` lists its
  findings (`findings: [{level, message, vmid}]`).

Added
- Web UI (ADR 0005): `pbo-web`, an optional HTTPS UI on port 8008.
  Sign in with a Proxmox VE account (TFA included); permissions come from
  Proxmox. Dashboard, guests, snapshots, restore wizard, restore-test evidence,
  jobs with a live log, maintenance (verify, a prune plan, the real prune behind a
  typed confirmation, unlock, run the schedule, test notification), per-guest
  policy. Not yet: config editing, timers, DR key export, an audit-log page.
  At most 256 connections in all and 32 per source address.
  An unprivileged, systemd-sandboxed web process talks to a root helper on a Unix
  socket that re-checks every request against PVE and runs only allowlisted pbo
  commands. Separate `pbo-web` .deb (amd64); `install.sh` installs it when built.
- Jobs: `pbo job start <command> [args]` runs an action in the background
  and prints its id at once; `job list|show|log [--from N] [--follow]|cancel`.
  With systemd each job is a transient unit `pbo-job-<id>` (survives the caller,
  cancel stops its cgroup), otherwise its own session (`JOB_RUNNER=direct`).
  Each job keeps meta, log and result (exit code + the command's JSON result) in
  `STATE_DIR/runs/<id>/`; `JOB_KEEP` (200) finished jobs are kept. backup and
  prune jobs queue behind a running backup and show as `queued`. `status --json`
  lists the active jobs (`jobs_active`). Only actions can be jobs; arguments are
  passed as argv, never through a shell. Admission: one active prune / verify /
  run-schedule / test-restore at a time (per dry run), no duplicate job for the
  same command and guest, at most `JOB_MAX_ACTIVE` (20) active jobs and
  `JOB_MAX_PER_USER` (5) per user.
- Audit: `PBO_AUDIT_USER` (set by the job runner and the web UI) names who asked
  for an action; each `audit.jsonl` line also has `via`, the `client` address (web)
  and the `job` id, and the text `audit.log` names the same user.
- `pbo policy get|set <vmid>`: read and change a guest's policy (skip,
  stop mode, own retention) without editing Proxmox tags by hand. `set` rewrites
  only the `pbo-*` tags, keeps every other tag in order, validates `--keep`
  (d/w/m/y each at most once), supports `--dry-run` and is audited.
- `restore --start` boots the restored guest; see "Changed" for the
  isolation every restore now gets. The JSON result says `started`, `network`
  and `stripped`.
- `list --json` archives carry `ts` (the value `restore` takes), `type`, the full
  snapshot `id` and a real `age_seconds` (it was always 0).
- `NOTIFY_LEVEL=fail|warn|all`: failures only (default), plus warnings,
  plus every successful run, for ntfy and Proxmox notifications alike. Warnings
  are now actually sent at `warn`: a test-restore throwaway left behind, an old
  key still valid on an append-only offsite after `rotate-key`. `notify-test`
  reports the level. `NTFY_ON_SUCCESS=true` still works (means `all`); `doctor`
  suggests the new key and flags an unknown level.
- Read views for scripts and the web UI: `pbo guests` (policy, newest snapshot,
  staleness, last restore test per guest), `pbo timers`, `pbo config` (effective
  config, secrets never shown, URL credentials masked), `pbo version`.
  `config` prints values only for known keys that cannot carry a credential;
  tokens, topics, the ntfy URL, the SFTP command and any key pbo does not know
  are reported as set/unset only.
- Scheduled restore tests: `test-restore --scheduled` and the weekly
  `pbo-test-restore.timer` (Sat 10:00) rotate through the backup set (`TR_PER_RUN`):
  a guest whose latest test failed first (at most one per run), then
  never-tested guests, then the oldest-tested.
- Restore-test evidence: every test appends a record (snapshot, repo tier, stages
  with durations, result) to `STATE_DIR/restore-tests.jsonl`, and
  `restore-report.{json,txt}` is rewritten with history and per-guest coverage.
  `pbo restore-report [--days N]`, also in the maintenance menu.
- `doctor`: a guest whose latest restore test failed is a problem; warns when the
  last test is older than `TR_MAX_AGE` (21 days) and on leftover throwaway guests.
- Metrics: per-guest restore-test time, result and duration, and the last
  `test_restore` run.

Fixed (from a code audit)
- `rotate-key` could leave the cache repo opening only with a new key it never
  saved (a failed `key list` ended it silently after the cache was rotated; the
  menu then shredded the new key). Now: add and verify the new key on every repo
  first (undone on any failure), then install the new password file (the old one
  kept until its keys are gone), then remove the old keys. The menu never discards
  the new key on a failure.
- `setup` overwrote an existing DR key; it now keeps it.
- Batch mode dropped the per-guest `keep=` tag (the next prune used the defaults)
  and did not count phase-1 failures.
- `restore-host` extracts only into a new or empty directory, never into `/` or
  system paths.
- Jobs (and so every web action) ignored the cluster config `/etc/pve/pbo/config`.
- `list --json` printed nothing above ~460 snapshots (argv limit); the same limit
  is gone from `guests` and `metrics`. `list` with an unreadable repo is an error,
  not an empty list. `unlock` exits non-zero when a repo could not be unlocked; a
  failed space reclaim after prune is an error and an alert.
- `backup-host` stored private keys in the repo (`/etc/pve/priv`, node TLS keys,
  rest password, pbo-web's key); they are excluded now.
- Logs were 0644; they are 0600 (logrotate creates them 0600). URL credentials
  are masked in every log line, job log, alert and JSON string. The ntfy token is
  passed to curl on stdin, not on its command line. The metrics temp file is no
  longer predictable, and a metrics directory not owned by root is refused.
- The config is refused when owned by anyone but root (or the janitor user).
- A command that failed without a message (an errexit deep in a function) now
  logs and alerts, and in JSON mode prints the error object; an error raised
  inside `$(...)` no longer disappears into the captured output.
- `run_stream` wrote vzdump/restic progress nowhere but the per-run log; it goes
  to stderr (and so into web job logs) too. Children no longer inherit pbo's lock
  file descriptors (a qemu started by a restore kept the lock).
- `list --reasons` on a janitor no longer moves the prune baseline.
- `--json metrics` and `--json help` print one JSON object; `test-restore
  --scheduled` prints one summary object (also when there is nothing to test).
- `_cfg_set` (setup/menu) creates the config when missing (a .deb install had
  none) and escapes `&`, `|` and `\` in values.

Fixed
- A restore-test record reported `cleanup_ok: true` even when the throwaway
  could not be destroyed (jq `false // true`).
- `backup` tried to clear stale locks on the offsite repo even with
  `OFFSITE_ENABLED=false` (and hung when that repo was unreachable).
- `init --json` let restic's own message onto stdout, so the output was not JSON.
- test-restore booted its throwaway copy with the source guest's host bindings:
  as root, `pct restore` keeps bind and device mount points and raw
  `lxc.mount.entry`/`lxc.hook.*` lines, so the copy could write into a host
  directory the running original also uses. Isolation is now an allowlist:
  every config key of the throwaway must be known-safe (disks, mount points and
  unused entries only as volumes owned by the throwaway, an ISO only as cdrom; any
  config section, e.g. pending changes applied at start, refuses the boot);
  everything else is removed before boot and recorded
  as `stripped`. If anything unsafe remains, or network/autostart is still on,
  the test fails at the new `isolate` stage without booting.
- test-restore could destroy a guest it did not create: the throwaway vmid is
  picked before the (slow) fetch, and cleanup ran `destroy --purge` on that id
  even when the restore had failed. Cleanup now runs only after this run's own
  restore succeeded, and only for the restored guest type.

Changed
- The throwaway guest gets `onboot 0` and the tag `pbo-throwaway` before it boots.
- A failed restore test now runs and records its cleanup stage; a missing storage
  is recorded as a failed test instead of aborting before the record.

## 0.3.1 (2026-11-22)

Added
- Prometheus metrics as a node_exporter textfile (`METRICS_FILE`), rewritten after
  run-schedule/verify/prune/manual backup; per-guest values come from the snapshot
  summaries. `pbo metrics`.
- JSON audit log (`AUDIT_JSON`, `audit.jsonl`): every command with user, args,
  exit code, duration and a read-only flag, plus restore events. logrotate config.

Fixed (janitor, from a security review)
- The forget is bound to the checked snapshot set: the janitor asks restic for
  the plan first, refuses if it contains a snapshot that arrived after the
  checks, and then forgets exactly the planned ids.
- A malformed or unreadable baseline blocks prune and fails `doctor` instead of
  being treated as "nothing suspicious". Unparsable snapshot times count as
  suspicious.
- The baseline is written only after every forget succeeded, stamped with the
  time of the check.

## 0.3.0 (2026-11-21)

Added
- Per-guest policy from Proxmox tags: `pbo-skip`, `pbo-stop`,
  `pbo-keep-{daily,weekly,monthly,yearly}-N`. Keep overrides travel in the
  snapshot (`keep=` tag), so prune and the janitor apply them without Proxmox.
  `KEEP_OFFSITE_YEARLY`.
- Notifications through Proxmox's notification system (`NOTIFY_PVE`, default
  `auto` = when no ntfy is configured), fields `type=pbo`/`hostname`, templates in
  `/etc/pve/notification-templates/default/`. `pbo notify-test`. `doctor` warns
  when nothing would alert.
- Janitor hardening: keep tags may only raise retention there; prune is refused
  while snapshots are dated in the future (`FUTURE_SKEW`), and `doctor` fails on
  them; a new snapshot claiming a time before the janitor's last run (a backdated
  insert) blocks prune too; retention fails closed when the snapshot list can't be
  read.

## 0.2.0 (2026-11-21)

Added
- Append-only offsite: a restic rest-server in `--append-only` mode as the offsite
  repo (`OFFSITE_APPEND_ONLY`, `RESTIC_REST_USERNAME`, `RESTIC_REST_PASSWORD_FILE`,
  `RESTIC_CACERT`). `doctor` proves the server refuses deletes. ADR 0004.
- Janitor role (`PBO_ROLE=janitor`, `install.sh --janitor`, `pbo-janitor.timer`):
  retention and verify on the storage side, freshness check of every guest in the
  repo. Drops root and re-execs as `JANITOR_USER`.
- `verify --scheduled`: reads the next 1/`VERIFY_ROTATE` of the data per run, all of
  it every `VERIFY_ROTATE` runs. `pbo-verify.timer` (weekly). `doctor` reports the
  last verify and fails if it failed.
- `doctor` warns about config keys pbo doesn't know (typos) and about a config
  written for a newer pbo (`PBO_CONFIG_VERSION`).
- `.deb` package (`packaging/build-deb.sh`), built in CI.
- `SECURITY.md` with a threat model. Integration test against a real Proxmox host
  (`tests/integration/pve.sh`).

Changed
- sftp options are passed to sftp repos only, `--cacert` to rest repos only.
- A `PBO_CONFIG` that points at a missing file is an error (exit 78). It used to run
  on built-in defaults, against a different repo.

## 0.1.0 (2026-11-16)

First release: restic engine (vzdump archive stored in restic,
cache tier + offsite copy over native SFTP), LXC and QEMU, cluster-aware
(`BACKUP_ORDER=auto`, `PRUNE_OWNER`), `menu`/`setup`, `doctor`, `test-restore`,
`rotate-key`, `backup-host`/`restore-host`, scheduled prune with a schedule lock
so prune and backup never overlap.
