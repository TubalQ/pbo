# Changelog

Versions follow [semver](https://semver.org/). Until 1.0, a minor bump can change
behaviour; the entry says so when it does.

## 0.6.0 (unreleased)

The config becomes data with a schema (ADR 0009): pbo reads `/etc/pbo/config`
with a strict `KEY=VALUE` reader instead of running it as shell code, every key
is described once in `lib/config_schema.sh`, and `pbo config
list|get|set|unset|check|template` replaces editing the file by hand. On top of
that: moving the cache directory with its data (`pbo config set CACHE_DIR`),
retention per guest, one permission table with `pbo doctor --fix`, a setup
wizard that is safe to run again and asks for the type of offsite target, and
nothing that differs between installations hard-coded (timer schedules,
backend credentials, thresholds, per-node storage ids in a cluster).

### Upgrading from 0.5

These are the migration notes pbo, `install.sh` and the `.deb` point to.

**What can stop the upgrade.**

- **The config is no longer run as code.** pbo 0.5 sourced `/etc/pbo/config`
  (and the cluster-shared `/etc/pve/pbo/config`). pbo 0.6 reads them with a
  strict reader that gives every accepted line exactly the value bash would,
  assigns only schema keys and refuses everything else. A refused line stops
  every pbo command, timer and the vzdump hook with exit 78, naming the first
  three lines; `pbo config check` lists them all.
- **`install.sh` refuses first.** Before it replaces any file it reads the
  existing configs with the reader of the version it installs and checks
  `RESTIC_ENV_FILE` (see Added). When pbo 0.6 would refuse either, it lists the
  findings, says "Nothing was changed" and exits. After installing missing
  dependency packages it checks the restic version (`RESTIC_MIN`, 0.14.0; 0.16.1
  with a rest-server login) and stops before any pbo file is installed if restic
  is older. `--force` installs anyway in both cases. The
  `.deb` cannot stop an upgrade that is already unpacked: its postinst runs `pbo
  config check` and prints what it finds.
- **Check before you upgrade**, with the new version from a checkout: `./pbo
  config check` reads the installed config the way 0.6 will (`--file F` reads one
  file). `--compare-bash` also sources the files the way 0.5 did, in a subshell
  with a clean environment (it runs the file), and names every key the two read
  differently.
- A config that only has `KEY=value` lines, quoted values and `${KEY}` references
  to keys set earlier (the generated example, what `pbo setup` writes) needs no
  change. What is refused, and how to write it instead:

  | Refused | Why | Write instead |
  |---|---|---|
  | `KEY=$(cmd)`, ``KEY=`cmd` `` | runs a command | the value itself (`KEY=/srv/backup`) |
  | `KEY=a b` | bash runs `b` as a command with `KEY=a` set | `KEY="a b"` |
  | `f() { ...; }`, `if`/`for`/`while`, `source file`, `. file` | code | delete them; the cluster-shared `/etc/pve/pbo/config` is read by itself |
  | `KEY+=more`, `KEY=(a b)`, `KEY[0]=a` | appends, arrays | the whole value: `KEY="a b"` |
  | `KEY=~/x`, `KEY=/a:~/x` | bash expands `~` | the full path: `KEY=/root/x` |
  | `KEY=${OTHER:-default}`, `${#X}`, `$1`, `$HOME`, `$$` | expansions other than a config key | the value: `KEY=/x`, or `KEY=${OTHER}` with `OTHER` set on an earlier line |
  | `KEY=${OTHER}` with `OTHER` not set earlier in the files | used before it is set (bash stops under `set -u`) | set `OTHER` first, or write the value |
  | `export FOO=1` (any variable but the proxy ones) | changes the environment of everything root runs | restic's variables: `RESTIC_ENV_FILE`; anything else: a systemd drop-in (`Environment=FOO=1`) |
  | `KEY="multi`<br>`line"`, a trailing `\` | a value must fit on one line | one line |

- Accepted with a warning (pbo runs; `config check` and doctor name it): `export
  KEY=...` of a config key (read, no longer exported to child processes), an
  unknown key (never assigned), a key set twice (the last wins), Windows line
  endings and a UTF-8 BOM (dropped; bash kept the CR in the value). `export` of
  `http_proxy`, `https_proxy`, `no_proxy` (and upper case) is accepted and
  exported to the programs pbo runs, as before.
- Only schema keys become variables. An environment switch set in the config
  (`PBO_REPO=cache`, `PBO_NO_NOTIFY=1`, `TMPDIR=...`) was honoured by 0.5 and is
  ignored now: set it in pbo's environment (doctor names it). `PATH`, `IFS`,
  `BASH_ENV` and pbo's own names in the config change nothing.
- In the cluster-shared `/etc/pve/pbo/config` a key flagged `exec` or
  `local-only` (`RESTIC_SFTP_COMMAND`, `RESTIC_BIN`, `PBO_VZDUMP_HOOK`,
  `RESTIC_ENV_FILE`, `PVE_STORAGE_ID`, ...) is ignored: doctor reports a FAIL and
  `config check` an error. Set it in `/etc/pbo/config` on each node.
- The file rules are unchanged: a group- or world-writable config, or one owned
  by anyone but root (or the janitor user), is refused (78).

**What behaves differently.**

- **Retention per guest.** `forget --group-by paths` kept each snapshot path as a
  guest of its own. A guest whose snapshots lie under more than one path (an
  earlier CACHE_DIR, a host backup whose path list changed) is now retained as
  one guest, so the next prune forgets snapshots 0.5 kept for it. A repo where no
  guest is split gets exactly the 0.5 restic calls, on the cache tier and
  offsite alike. Doctor names the split guests. `RETENTION_GROUP_BY=paths` keeps
  the 0.5 grouping for this release; it is removed in 0.7.
- **The `.deb`'s dependencies.** `restic (>= 0.14.0)` (was `>= 0.16`), so a
  distribution that ships 0.14 can install it, and the new `acl` (`setfacl`,
  `getfacl`) next to `util-linux`. `install.sh` installs `acl` and `util-linux`
  when `setfacl`, `getfacl`, `setpriv` or `findmnt` is missing.
- **`PVE_STORAGE_ID` in a cluster.** Its default is derived: `pbo` on a single
  node, `pbo-<node>` in a cluster, unless storage.cfg already has a pbo storage
  for this node, which keeps its id. So no installation is renamed by the
  upgrade; a node of a cluster that turns the integration on from scratch gets
  a storage of its own (`--nodes <node>`, its own spool), and `pbo integrate
  enable` pins the id in the local config. The key is per node: the
  cluster-shared file cannot set it. PVE backup jobs name a storage, so create
  them per node; pbo never edits jobs.cfg, and doctor explains the move from a
  shared `pbo` storage (RUNBOOK, "In a cluster").
- **Timers through drop-ins.** The schedules are config keys (`SCHEDULE_*`).
  `pbo config set` writes `/etc/systemd/system/<timer>.d/schedule.conf`; the
  unit files keep the defaults and are never edited. `install.sh` and the
  `.deb`'s postinst run `pbo timers apply`, so a reinstall keeps a custom
  schedule. An `override.conf` from `systemctl edit` that sets `OnCalendar=`
  (the way to change a time before 0.6) wins while the timer's key is at its
  default; doctor and `pbo timers` say so. Once the key is set, pbo's
  `schedule.conf` sorts after it and resets `OnCalendar=`, so the config wins.
  Move the time into the key and remove the override's `OnCalendar=` lines.
- **Config writes.** `pbo setup`, the menu and `pbo integrate` write through the
  same writer as `pbo config set`: values quoted, comments, owner and mode kept,
  always the local file. Running `pbo setup` again keeps every setting you do
  not change.
- **A CT's mapped root** comes from its `lxc.idmap` line, else 100000, and no
  longer from `/etc/subuid` (pve-container never reads that file). On a host
  with a custom root range there, the CACHE_DIR ACL entry moves to the uid the CT
  really runs as.
- `pbo doctor` refuses unknown arguments (64; it ignored them), and a
  group-writable CACHE_DIR is a warning (at most 0750).

**After the upgrade**, in this order:

1. `pbo config check`: no errors (warnings are named, pbo runs with them).
2. `pbo doctor`: the new checks (permissions, split guests, the timers'
   drop-ins, the storage id, the restic version) name what to do.
3. `pbo --dry-run doctor --fix`, then `pbo doctor --fix`: applies the
   permission table and writes the timer drop-ins (`install.sh` already ran
   the permission part; the `.deb` does not). Add `--fix-parents` when doctor
   says an unprivileged CT cannot pass a directory above CACHE_DIR.
4. When doctor lists a guest whose snapshots lie under more than one path:
   `pbo --dry-run prune` (or `pbo list --reasons <vmid>`) before the next prune
   shows what retention per guest will remove.

Added
- **The config schema** (`lib/config_schema.sh`): one row per key with its type,
  default (derived ones as `${KEY}` references to earlier keys, or computed),
  section, roles (host, janitor) and flags (secret, exec, local-only, internal,
  advanced, managed, follows, samefs, on_change, deprecated, template). It covers
  every key pbo reads, also those that only had an inline default before
  (`LOCK_DIR`, `CATALOG_*_WAIT`, `JOB_*`, `TR_HISTORY`, `TR_STORAGE`,
  `VERIFY_READ_DATA`, `VERIFY_SUBSET`, `PBO_KNOWN_HOSTS`, ...); the defaults are
  the ones 0.5 gave.
- `pbo config list [--all]` (each key of this role with its value, its source:
  `config`, `shared` for the cluster-shared file, `env`, `default`, and its type;
  `--all` adds the test hooks and the other role's keys), `pbo config get KEY`
  (one effective value; a secret prints `<set>` or `<unset>`; an unknown key
  exits 64) and `pbo config template [--role host|janitor]` (the example config
  generated from the schema). `pbo config show` keeps its format and JSON
  envelope; each key there now also has `type`, `section`, `default`, `flags`,
  `roles`, `description`, `managed_by` and `known`, and the envelope names
  `local_file`, the file pbo writes.
- `etc/config.example` is generated by `pbo config template` (the same active
  keys and values as before, so a new install gets the same first config); CI
  fails when it is stale. Each commented line shows the key's default, written
  out, so that removing the `#` from any one line gives a line the reader
  accepts and bash reads the same (`HOST_BACKUP_EXCLUDES` too, which 0.5 wrote
  with a `${...:-...}` the reader refuses).
- `pbo config check [--file F [--shared]] [--role host|janitor]
  [--compare-bash]`: reads the config with pbo's reader and lists every error
  and warning as `file:line` (lines pbo refuses, exec and local-only keys in the
  cluster-shared file, unknown keys, keys set twice, test hooks, values of the
  wrong type, keys the role does not use, deprecated keys, a BOM, CR line
  endings, a broken role config) and the errors of `RESTIC_ENV_FILE`. `--file F`
  reads F alone (`--shared`: as the cluster-shared file). `--compare-bash`
  (migration debugging, never the default: it runs the file) also sources the
  files as 0.5 did and names every key bash reads differently. Exit 78 when pbo
  refuses or ignores a line; `--json` gives `{status, ok, errors, warnings,
  ignored, files, compare_bash}`. Its messages never repeat a secret. On a
  janitor it stays root and asks whether `JANITOR_USER` can read each file.
- `pbo config set KEY VALUE [KEY VALUE...] [--shared] [--yes] [--force]` and
  `pbo config unset KEY... [--shared] [--yes]`: any number of changes in one
  transaction on the local config, under the lock `LOCK_DIR/pbo.config` (busy:
  75). Each value is checked against its type (78 with the reason). Refused: a
  key another command manages (`PBO_INTEGRATION`: `pbo integrate`), an unknown
  key unless `--force`, a key the role does not use, `KEY=VALUE` typed as one
  argument (named by its key only: the value may be a secret). The file is
  edited in place (the active line replaced with its end-of-line comment, else
  the commented template line, else under its section header), values are
  quoted for the reader and bash alike, the candidate is read back by both
  before it replaces the file (temp file in the same directory, fsync, rename),
  and owner, group, mode and an extended ACL are kept. `--dry-run` prints the
  diff (secret values hidden); `--json` gives each key's value before and after.
  The audit log records the change with secrets masked. `--shared` writes the
  cluster-shared file instead (not a secret, exec or per-node key, not
  `CACHE_DIR` and the keys that follow it; only while pmxcfs is mounted; a file
  another node changed meanwhile is not overwritten, 75). Hooks: a new
  `RESTIC_OFFSITE_REPO` or `RESTIC_CACHE_REPO` needs `--yes` (no data is moved);
  `PVE_CATALOG_MOUNT` and `PVE_CATALOG_MOUNT_DIR` restart pbo-mount.service if it
  runs; `SCHEDULE_*` write the timer drop-ins; `CACHE_DIR` creates an empty
  cache or moves one with data. A key that follows `CACHE_DIR` is never pinned
  at its derived default. On a janitor, set and unset run as root (root writes
  the 0640 config its user only reads).
- **Moving the cache directory**: `pbo config set CACHE_DIR <new> [--yes]
  [--keep-old] [--fix-parents] [--verify-data] [--force]`, and `--resume` or
  `--abort` for an interrupted move. Every check first, all failures at once and
  nothing changed (78 for a path pbo will not take, 69 when the system refuses):
  an absolute canonical path without symlinks, empty or new, no system
  directory, not nested with the old one, every directory above it root's and
  not writable by others; not tmpfs or FUSE, a network filesystem only with
  `--force`; enough free space on another filesystem (`CACHEMOVE_SPACE_FACTOR`,
  default 1.1, times the cache); every unprivileged CT's mapped root can pass
  every directory on the way and the filesystem takes POSIX ACLs (else the exact
  `setfacl` lines, or `--fix-parents`); with the integration on, a pbo storage
  of this node alone; no filesystem mounted below the old cache; nothing
  running. Then a journalled move (`STATE_DIR/cache-move.json`): every pbo lock,
  pbo-mount.service stopped, the storage disabled, staging cleared, the target
  created with the CACHE_DIR permissions, the data renamed (same filesystem and
  mount) or copied and verified (`cp -a`, the trees compared, `restic check` of
  the copied repo, `--read-data` with `--verify-data`), the config written in
  one transaction with the keys that follow, the storage pointed at the new
  spool and enabled, the catalogue refreshed, the permissions applied, the old
  copy removed when it holds only pbo's own directories (`--keep-old` keeps it),
  the mount started again. A failure before the config write rolls back at
  once; after it the move only goes forward (`--resume`). A move with data needs
  `--yes` (or a yes on a terminal); an empty cache is only created.
- A cache lock (`LOCK_DIR/pbo.cache`), shared by backup, ingest, fetch, restore,
  test-restore, backup-host, `catalog materialize` and pbo-mount.service and
  exclusive for a move: they exit 75 while a move runs. While a move is
  unfinished, backups, ingest, restores, the mount, the vzdump hook's
  backup-start and `restic init` stop with 75 and say how to finish it, doctor
  FAILs, and no empty repo is created at either place.
- A pbo process that waited for a lock (`backup --queue`, run-schedule, prune,
  verify) and finds that its config changed meanwhile (a cache move, `config
  set`) starts itself again with the new config, at most three times in a row.
- **Retention per guest** and `RETENTION_GROUP_BY` (advanced; `guest`, or
  `paths` for the 0.5 grouping, removed in 0.7; any other value is treated as
  `paths` and flagged, so a typo never turns on deletions). Doctor names the
  guests whose snapshots lie under more than one path (a warning with `paths`,
  whose old paths are never pruned) and a guest that shares a path with another
  vmid or with untagged snapshots (retained per path, as before). On a host whose
  offsite is append-only the janitor's setting decides there.
- **Permissions**: one rule table (`lib/perms.sh`) of path, owner, group, mode,
  ACL and class (fix, ask, check) per role, every path a config value. Doctor
  checks it: CACHE_DIR closed with an ACL entry per unprivileged CT (an entry
  counts only when the ACL mask lets it through), the directories above
  CACHE_DIR (passable by each CT's mapped root, tested with `setpriv`), the cache
  repo, spool and staging, LOCK_DIR, logs, STATE_DIR, the catalogue, the restic
  cache, the config directory and file, the DR key, the rest-server password,
  `RESTIC_ENV_FILE`, the ntfy credentials, the mount point's parent and the
  metrics directory; on a janitor the user's own paths. A filesystem without
  POSIX ACLs is named with its fix (`zfs set acltype=posixacl`); symlinks and
  shared system directories are reported, never changed.
- `pbo doctor --fix [--fix-parents] [--perms-only]`: applies the fix rules (and
  the timer drop-ins), then shows the full report. `--dry-run` lists the changes;
  each change made is audit-logged (`perms fix <path> mode 0755->0700`); `--json`
  adds `changes`. `--fix-parents` also adds a traverse-only entry `u:<uid>:--x`
  to each directory above CACHE_DIR that blocks a CT (nothing else is ever
  changed there). `--perms-only` runs the permission section alone. Every
  change goes through a file descriptor opened without following symlinks and
  checked for type, links and path. On a janitor started as root the fix runs as
  root before pbo drops to `JANITOR_USER`. `install.sh` runs `pbo doctor --fix
  --perms-only` once the files are in place.
- `RESTIC_ENV_FILE` (advanced, local-only; default `/etc/pbo/restic.env`):
  `KEY=VALUE` lines in the config grammar, given to restic and nothing else.
  This is where S3, B2, Azure, GCS and rclone credentials go; a `rest:`, `sftp:`
  or local repo needs none, and a missing file is fine. A file that is a
  symlink, owned by another user, writable by group or others or readable by
  others, or that sets `PATH`, `LD_*`, `RESTIC_PASSWORD*`, `RESTIC_REPOSITORY*`,
  `RESTIC_FROM_*`, `RESTIC_CACHE_DIR`, `RESTIC_HOST`, the rest-server login, a
  config key or one of pbo's internal names stops every command except config,
  doctor, version and help with 78, like a refused config line (`catalog
  _umount`, the mount unit's cleanup, runs too, since it runs no restic);
  `config check` lists its errors by line and doctor reports them. The values
  are set on restic's command alone, so pbo's shell, the programs it runs and
  the hooks never see them; doctor, `config list|show|check` and the report
  show the file and its key names, never a value. The permission table checks it
  (0600 or 0400).
- **Timer schedules as keys**: `SCHEDULE_BACKUP`, `SCHEDULE_PRUNE`,
  `SCHEDULE_VERIFY`, `SCHEDULE_TEST_RESTORE`, `SCHEDULE_CATALOG` (host) and
  `SCHEDULE_JANITOR` (janitor), in systemd's `OnCalendar=` syntax, with
  `SCHEDULE_*_DELAY` for the timers' `RandomizedDelaySec=`. The defaults are the
  units' own times (05:00 nightly, Sunday 06:30, Wednesday and Saturday 10:00,
  every 15 minutes, 12:30 on a janitor). A value is checked with
  `systemd-analyze` (without it, a narrow check that takes the common forms
  only); unit-file syntax (`%`, `\`, `=`, `[`, a newline) is always refused. A
  change writes the drop-in, reloads systemd and resets the timer's persistent
  state (an enabled timer is stopped, its stamp cleared with `systemctl clean
  --what=state`, and started again if it ran), so the next run is computed from
  now and a time moved earlier does not start the job at once; a disabled timer
  stays disabled. A key back at its default removes the drop-in.
- `pbo timers apply`: writes (or removes) every drop-in of the role from the
  config. Doctor warns when a drop-in does not match the config, when systemd
  has not reloaded, and when the calendar systemd runs is not the config's.
  `pbo timers` shows the calendar systemd runs, the source of the configured
  one (default, config, shared, env) and where the two differ.
- **Per-node storage ids** in a cluster (`PVE_STORAGE_ID`, see "Upgrading").
  `pbo integrate enable` refuses (69, nothing changed) to take over another
  node's pbo storage or to change the path of an entry it shares with other
  nodes; `pbo integrate disable` refuses another node's storage, and takes this
  node off a shared entry's `nodes` instead of removing it. Doctor FAILs a
  storage whose `nodes` leave this node out and, in a cluster where `pbo` serves
  more than this node, names the move node by node.
- `RESTIC_MIN` (advanced; default 0.14.0, the oldest restic with every feature
  pbo always uses; a rest-server login needs 0.16.1). Doctor reports the restic
  version and FAILs below the minimum; `install.sh` refuses before it copies any
  file and names what to install (`--force` installs anyway). Nothing is
  downloaded. `pbo list --reasons` works on restic 0.14 to 0.16 too.
- Thresholds that differ between sites are advanced keys with the old fixed
  values as defaults: `PREFLIGHT_POOL_FREE_PCT` (150), `BATCH_FIT_PCT` (85),
  `INGEST_PENDING_MIN` (10 min), `PVE_SPOOL_MAX_AGE` (24 h),
  `PVE_JOB_WINDOW_MIN` (60 min), `CATALOG_STAGE_WAIT` (10 s),
  `CACHEMOVE_SPACE_FACTOR` (1.1). A value that is not a whole number falls back
  to the default (doctor names it).
- `pbo [--json] doctor --report`: an environment report for a bug report (pbo's
  version and layout, PVE package versions, restic, kernel, perl, bash, systemd,
  OS release, UTC offset, single node or cluster, CACHE_DIR's filesystem type and
  ACL support, each repo's backend type, append-only, the integration mode,
  whether `RESTIC_ENV_FILE` exists, the optional tools). No node or host name,
  URL, user, path or secret.
- `pbo catalog _umount`, pbo-mount.service's `ExecStopPost`: lazily unmounts what
  is mounted at `PVE_CATALOG_MOUNT_DIR`, only when it is a FUSE mount. It runs no
  restic, so it also runs on a config pbo refuses.
- Doctor names a missing tool with its package: `setfacl`, `getfacl` (acl),
  `setpriv`, `findmnt` (util-linux).
- Tests: `tests/hardcode.sh`, a lint that fails on an absolute path, host name,
  IP address or clock time in what runs on a host that is not a schema default,
  a comment or an entry with its reason in `tests/hardcode.allow`;
  `tests/portability.sh` (RESTIC_ENV_FILE, both install layouts, RESTIC_MIN,
  time zones, custom idmaps, `doctor --report`); `tests/schedule_config.sh`;
  `tests/docs.sh` (every schema key in the example, every command and flag of
  `pbo help` and of the docs' code blocks, `./pbo` and `runuser` lines
  included, accepted by the parser; a trailing unknown flag refused with 64 by
  every command but a listed few whose parser ignores extra words, and whose
  documented flags are checked against a list; a `--dry-run` after the command
  refused as a doc bug).
  tests/docs.sh, tests/integrate.sh, tests/menu.sh and tests/schedule_config.sh
  run pbo through a copy that stops it (99) when it resolves a path outside
  their run directory (tests/fixtures/run_dir_guard.sh).

Changed
- `load_config` reads the config files with the strict reader and never sources
  them. The merge (with `PBO_CONFIG` unset the cluster-shared file, then
  `/etc/pbo/config`, which wins; with `PBO_CONFIG` that file alone), the
  precedence (file, then environment, then default; an empty value is the
  default) and the owner and mode rules stay. Only schema keys become variables;
  `set_defaults` applies the schema's defaults. Startup costs no more than the
  0.5 `source`.
- `pbo setup` is safe to run again: each question offers the effective setting
  and Enter keeps it (CACHE_DIR, LOCAL_REPO, the offsite repo and, for an sftp
  one, host, port, user, key and pinned host key read back from
  `RESTIC_SFTP_COMMAND`, retention, ntfy, `BACKUP_ORDER`, the schedules), and an
  answer that keeps a setting writes nothing. A configured offsite repo is shown
  (its login masked) and kept unless you choose to change the target; replacing
  it asks first (pbo moves no snapshot). 0.5 asked for an SFTP host on every run
  and rewrote the repo, the ssh command and the pinned host keys.
- `pbo setup` asks for the type of offsite target: an SFTP server (any host,
  port, user and key; the repo is `sftp:<user>@<host>:<path>`, with
  `RESTIC_SFTP_COMMAND` only when the port, the key, the pinned host key, kept ssh
  options or a host key ssh has not recorded yet needs it), a rest-server (URL,
  user, a 0600 password file, append-only or not; a login in a URL is moved out
  of it), a local or mounted directory, or another restic backend (the
  repository string; the variables that backend reads are named, read without
  echo and written to `RESTIC_ENV_FILE`, 0600). The Storage Box hints and its
  snapshot question (`STORAGE_BOX_SNAPSHOTS_CONFIRMED`) come only for a host
  below its domain. When the type changes, the old type's keys go.
- `pbo setup`'s cache step lists the local disk filesystems with type and free
  space, suggests `<mount>/pbo-cache` on the one with the most (the default only
  on a first setup), warns when the root filesystem is smaller than 1.5 times the
  largest guest's dump, and sets the directory with `pbo config set CACHE_DIR`
  (dry run first, then the change on a yes, `--fix-parents` offered when a CT
  could not pass a directory above it). It no longer pins `RESTIC_CACHE_REPO`.
- `pbo setup` checks numbers, choices and schedules against the schema and asks
  again until they are valid (the end of the input stops it), sets the four
  host schedules (with their drop-ins), defaults the timer questions to no on a
  re-run, and ends with `pbo doctor --fix` and its report. The files it writes
  (the DR key, a rest-server password, `RESTIC_ENV_FILE`, known_hosts) are
  written atomically, never through a symlink; an existing DR key is never
  replaced.
- The generated example shows an sftp repo as `sftp:<user>@<host>:<path>` and
  when `RESTIC_SFTP_COMMAND` is needed (it showed a provider alias).
- Doctor's config check reads the schema: every value against its type,
  deprecated keys with their replacement, and "unknown" for a key neither the
  schema nor the list of environment switches has (it was any upper-case word
  that pbo's code did not contain); in a cluster the cluster-shared file's too.
  It reports what the reader found (an ignored key in the shared file is a FAIL,
  its warnings are WARNs). A space-separated `VZDUMP_STOP_VMIDS` is a warning:
  pbo splits it on commas only.
- Doctor's permission lines come from the rule table; a fixable finding ends in
  "(pbo doctor --fix)", and the paths that pass are one line. The CACHE_DIR
  closing each backup does is the table's CACHE_DIR rule (ACL entries first,
  never closed without them, never on a shared directory or in a dry run).
- The audit.jsonl record of `pbo config set|unset` and `pbo doctor --fix` says
  `read_only: false` (a dry run: true).
- Doctor's warning about a PVE job near a pbo timer compares the job with the
  configured backup, prune and verify schedules and names the closest run and
  `PVE_JOB_WINDOW_MIN` (it said "within an hour" whatever the window).
- Guest ownership (`both`, `integrated`) counts only the pbo storages that serve
  this node: a cluster-wide job on another node's storage does not back up this
  node's guests. The catalogue, `pbo integrate` and doctor take the storage id
  from `PVE_STORAGE_ID`, never from a literal `pbo`.
- pbo-mount.service runs `pbo catalog _umount` after it stops instead of
  `umount -l` of a fixed path.
- Every restic call that opens a repo goes through one wrapper, which sets
  `RESTIC_ENV_FILE`'s variables and the rest-server login in its own subshell.
- Preflight reads storage.cfg from `PVE_STORAGE_CFG` and the node name from the
  configured pmxcfs directory; `install.sh` takes the default log, state and
  cache directories from the schema.
- `pbo help` lists the forms it was missing (`config check --file F --shared`,
  `config unset --yes`, `help` itself; `integrate enable both --catalog-only`,
  since `integrated --catalog-only` is refused) and leaves out on purpose the
  flags meant for internal callers (`backup --queue`/`--now`, `restore
  --isolate`/`--restricted`, `test-restore --restricted`).

Fixed
- `pbo list` and `pbo metrics` took any word: a misspelt `--reasons` was read
  as a vmid (an empty list, exit 0), and a misspelt `--no-write` wrote
  METRICS_FILE. Both now refuse an unknown flag with 64.
- `pbo setup`, the menu and `pbo integrate` wrote values unquoted (a value with
  a space, `&` or `|` broke the file), dropped a replaced line's comment, forced
  mode 0600 (a janitor's 0640 root:<user> config became unreadable for its
  user), renamed a temp file from `/tmp` (not atomic), and wrote the
  cluster-shared file when no local one existed.
- The wizard wrote `NTFY_URL=` on a no to ntfy and accepted any number.
- `pbo config` showed `LOCK_DIR` and the keys that only had an inline default as
  secrets (the old key list missed them).
- With another `PVE_CATALOG_MOUNT_DIR`, stopping pbo-mount.service left a dead
  FUSE mount behind.
- `rotate-key` exported the rest-server password into pbo's own shell and ran
  restic outside the wrapper.
- The CACHE_DIR ACL entry (and doctor's check of its parents) used root's range
  from `/etc/subuid`, which pve-container ignores: with a custom range there a
  CT without an `lxc.idmap` line got the entry on the wrong uid and its vzdump
  failed.
- `pbo backup-host` always excludes `RESTIC_PASSWORD_FILE` and
  `RESTIC_REST_PASSWORD_FILE` as configured, whatever `HOST_BACKUP_EXCLUDES`
  says, so a literal exclude list cannot let the DR key into the repo after the
  password file moved.
- The check for a running vzdump (`_vzdump_running`, `ingest --pending`)
  silenced the rest of the command's error output when the vzdump lock file
  existed.
- Doctor's messages about the config file and its directory said root runs the
  config as code.

Docs
- ADR 0009 (config schema, reader, writer, retention per guest, permissions,
  cache move, wizard, portability).
- README: Configuration, Moving the cache directory, Compatibility (what the
  suites and CI test, and what they do not). RUNBOOK: upgrading to 0.6, changing
  the schedule, moving the cache, re-running setup, clusters, backends with
  `RESTIC_ENV_FILE`. SECURITY: the config as data, exec keys and the shared
  file, `RESTIC_ENV_FILE`, the permission table.

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
