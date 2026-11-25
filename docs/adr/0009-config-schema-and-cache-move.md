# ADR 0009, a config schema, a strict reader, and moving the cache directory

- **Status:** Proposed 2026-11-24. Goal: make it easy for other installations to
  choose the cache directory and other settings and to get permissions right,
  with nothing hard-coded. Target 0.6.0. Accepted when 0.6.0-rc1 has passed
  verification on a PVE host.
- **Decision (proposed):** keep `KEY=VALUE` in `/etc/pbo/config` (no YAML, no new
  dependency), but describe every key in one schema (`lib/config_schema.sh`: type,
  default, section, roles, flags), read the file with a strict parser instead of
  `source`, write it only through `pbo config set|unset` (atomic, quoted, comments
  kept, mode and owner kept, always the local file), move CACHE_DIR with a
  journalled, resumable `pbo config set CACHE_DIR <new>`, group retention per
  guest instead of per snapshot path, apply permissions from one rule table
  (`pbo doctor --fix`), and make everything that differs between installations a
  schema key (paths, names, schedules, thresholds, backend environment).

## Context

- The config is sourced as shell code (lib/common.sh `load_config`).
- The known keys are scraped with grep (lib/views.sh), which misses `LOCK_DIR` and the
  keys with inline defaults.
- `_cfg_set` (lib/menu.sh) writes values unquoted, drops comments, is not atomic, breaks a
  janitor's 0640 root:JUSER config, and can write into the cluster-shared
  `/etc/pve/pbo/config`.
- The wizard clobbers existing values on a re-run.
- CACHE_DIR feeds 19 places, among them the spool (also in storage.cfg) and staging
  (also in the catalogue's `staging_dir`, which the plugin reads).
- Retention groups by snapshot path (`forget --group-by paths`), so moving CACHE_DIR
  would leave the old snapshots in groups that are never pruned.
- Nothing checks that the CACHE_DIR parents are traversable by an unprivileged CT's
  mapped root.
- Schedules, the Storage Box alias, the mount point in a unit and several thresholds are
  hard-coded.

## Details

0.6 is built in milestones, and this ADR and the code comments name them: M1
the schema (`lib/config_schema.sh`) and the read-only `pbo config` commands, M2
the config grammar (the reader next to `source`), M3 loading (the reader
replaces `source`), M4 the writer (`pbo config set|unset`), M5 retention per
guest, M6 permissions, M7 the cache move, M8 the wizard, MP portability
(nothing that differs between installations hard-coded; part 1 without the
writer, part 2 with it). This ADR is filled in as the milestones land:
grammar, schema format, writer, the move's state machine, the retention
equivalence argument, the permission table, and the portability rules.

### Config grammar (M2)

**Why not `source`.** A sourced config is code that root runs on every pbo
command, timer and vzdump hook: a stray `$(...)`, an `export PATH=...`, a
function that replaces one of pbo's (tests/regressions.sh does exactly that on
purpose) or a typo such as `KEY=a b` (which runs `b`) all take effect silently.
The file only ever needs values. pbo 0.6 therefore reads it with a parser
(`lib/config_parse.sh`) that never runs anything, accepts a small subset of the
bash grammar, and gives every accepted line exactly the value bash would assign,
so a config that works with 0.5 reads the same and stays valid bash (a downgrade
keeps working).

**Grammar**, line by line:

- A UTF-8 BOM on line 1 and a CR at the end of a line are dropped, with a
  warning (bash keeps them: the BOM makes line 1 a command, the CR ends up in
  the value).
- Blank lines, and lines whose first non-blank character is `#`, are skipped.
- Every other line is `[blanks][export ]KEY=VALUE[blanks[# comment]]`, with KEY
  `[A-Za-z_][A-Za-z0-9_]*` and nothing but blanks and a comment after the value.
- VALUE is a run of segments up to the first unquoted blank:
  - plain characters: anything but blank `' " ` $ \ ; & | < > ( )`. A `#`
    inside a word is literal, as in bash (`K=a#b`); a `~` at the start or after
    a `:` is refused (bash expands it: "write the full path");
  - `'...'`: literal;
  - `"..."`: `\" \\ \$ \`` lose the backslash, any other pair stays two
    characters (as in bash); a backtick or `$(` inside is refused;
  - `${KEY}` or `$KEY`, unquoted or inside `"..."`: only for a schema key that
    an earlier line set (see below). Every other expansion is refused: `${HOME}`,
    `$1`, `$$`, `${X:-y}`, `${#X}`, `$(...)`, `$((...))`, a lone `$`.
- Refused, each with its line number and a hint: `KEY=a b` ("quote the value:
  KEY="a b""), `KEY= v`, `A=1 B=2`, `KEY = v`, `KEY+=v`, `KEY[i]=v`, `KEY=(...)`,
  shell operators, an unquoted backslash, a trailing backslash (line
  continuation), a quote that does not close on its line (the error spans the
  lines up to the closing quote, which are not read), `source` / `.`, function
  definitions (one error for the body), `if`/`for`/`while`/`case`,
  `declare`/`readonly`/`local`, `unset`, anything else.
- `export KEY=V`: accepted with a warning for a schema key (0.6 does not export
  config keys to child processes); accepted and recorded in `CFG_EXPORT` for
  `http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY` (M3 exports
  those to the programs pbo runs); refused for anything else, with the hint to
  put variables for restic in `RESTIC_ENV_FILE` (see "Portability"), others
  in a systemd drop-in (`Environment=`).
  An exported `PATH`, `IFS`, `BASH_ENV` or `LD_PRELOAD` would change what root
  runs. An unquoted `{` on an export line is refused: `export` is a declaration
  builtin, so bash brace-expands its argument (`export KEEP_LOCAL={1,2}` sets
  `KEEP_LOCAL=2`), which a plain assignment does not.
- A refusal message never repeats value text from the line unless the key is a
  schema key without the `secret` flag and the text holds nothing that looks
  like URL credentials: the messages reach doctor, `pbo config check`, the
  install.sh guard and the `.deb` postinst (apt's term.log).
- An unknown key is kept for the comparison and warned about (M3 never assigns
  it as a shell variable); an environment switch such as `PBO_REPO` set in the
  file is named as one. A key set twice in one file: the last wins, with a
  warning.
- In the cluster-shared `/etc/pve/pbo/config` a key flagged `exec` or
  `local-only` is not applied (`CFG_IGNORED`; doctor FAIL, an error for `pbo
  config check`): pmxcfs copies that file to every node, and such a key runs a
  program or describes one node. Ignored rather than refused (M3): one node's
  edit of the shared file must not stop pbo on every node.

**References and precedence.** A reference resolves to the value an earlier
line gave the key, in the merged order load_config sources the files: with
`PBO_CONFIG` unset the cluster-shared file, then the local `/etc/pbo/config`
(which wins); with `PBO_CONFIG` set, that file alone. A key no earlier line set
is refused ("used before it is set"; bash stops there under `set -u`), unless
pbo's environment holds it: bash expands it from the environment, so the reader
does too, with a warning (`CFG_ENV`, a snapshot of the schema keys in the
environment taken before the files are read). install.sh takes no snapshot: the
units start pbo with a clean environment, so a reference that only works from
install.sh's environment is reported. Overall precedence is unchanged: a file
value beats the environment, which beats the default, and an empty value means
the default. The owner and mode rules (refuse a group- or world-writable file,
or one owned by anyone but root or the user pbo runs as) stay, because `exec`
keys still name programs.

**Implementation.** The results are associative arrays (`CFG_VAL`, `CFG_RAW`,
`CFG_SRC` = origin:file:line, `CFG_LINE`, `CFG_EXPORT`) and the lists
`CFG_UNKNOWN`, `CFG_ERRORS`, `CFG_WARNINGS` (`file:line: message`).
`_cfg_parse_file` reads one file; `_cfg_parse_all` applies load_config's merge
and records `PBO_CONFIG_FILES`. Three fast paths (a bare value, a simple
`"..."`, a `'...'`) take almost every line and are written as globs, since bash
compiles a regex on every `[[ =~ ]]`, a glob costs far less; the rest goes
through a character scanner that also names the reason for a refusal. The two
paths give the same result on every fixture and example (`_CFG_SLOW=1` in
tests/config_parse.sh). Parsing a config takes milliseconds, a file with every
key active a few times as long. The file depends on no other library,
so install.sh can source it from the source tree.

**Shadow mode (M2, replaced in M3).** In 0.6 M2 the config was still sourced. doctor and
`pbo config check` also run the reader (before sourcing, so references see the
environment bash sees) and record the sourced value of every key it assigned
right after sourcing, before `set_defaults`. doctor warns about each key the two
read differently (a secret only as `<differs>`) and each line the reader refuses,
and says OK when they agree. No other command runs the reader, so startup costs
stay as they were. `pbo config check` is lenient: an unset variable, a syntax
error, a `${X:?}` or an `exit` (tried in a subshell first; such a file is then
not sourced and named as one bash stops on) and a broken role config (a bad
`PBO_ROLE`, a janitor with an integration or append-only, which every other
command stops on at startup) do not stop it but are reported as errors,
`--file F` reads F without sourcing it, and it exits 78 when pbo 0.6 would
refuse the config. install.sh reads the existing configs with
the reader of the version it installs before it replaces anything and warns; M3
turns that into a refusal (with `--force`) once the reader replaces `source`.
tests/all.sh runs every suite with a load_config hook that logs the reader's
verdict on each config file loaded, and checks at the end that the reader
accepts them all and agrees with bash. M3 removed the runtime comparison (see
"Loading"); the hook and the corpus check stay.

### Loading (M3)

**Decision.** `load_config` (lib/common.sh) reads the config files with the
strict reader and never sources them. Only keys of the schema become shell
variables; nothing the config says can run, export or overwrite anything else.

- **Files and merge**, as 0.5 sourced them: with `PBO_CONFIG` unset the
  cluster-shared `/etc/pve/pbo/config`, then the local `/etc/pbo/config` (which
  wins); with `PBO_CONFIG` set, that file alone (one that does not exist is an
  error, 78). Each file that exists must pass the unchanged owner and mode rules
  (`_config_file_check`: not group- or world-writable, owned by root or the user
  pbo runs as; 78 otherwise): `exec` keys still name programs root runs.
- **Precedence**, unchanged: the snapshot `CFG_ENV` of the schema keys in the
  environment is taken first (it is what a `${KEY}` no earlier line set refers
  to, and `config list`'s `source=env`); then the values the reader accepted are
  assigned (`_cfg_apply`, `printf -v`: a key the environment exported stays
  exported, with the file's value, as after `source`); then `set_defaults`
  gives every schema key that is still unset or empty its default. File beats
  environment beats default; an empty value means the default.
- **Not assigned**: unknown keys (`CFG_UNKNOWN`, a warning; doctor and `config
  check` name them, environment switches as switches), so `PATH`, `IFS`,
  `BASH_ENV` or a readonly pbo name in the file change nothing. An exported
  proxy variable (`CFG_EXPORT`) is exported to the programs pbo runs; an exported
  config key is read but not exported (a warning). An `exec` or `local-only` key
  in the shared file is ignored (`CFG_IGNORED`, doctor FAIL).
- **Errors.** A line the reader refuses stops pbo (exit 78, `EX_CONFIG`) before
  anything else runs: the first three errors on stderr, "run 'pbo config check'
  for all of them", and for a file `bash -n` accepts the hint that it is valid
  bash but no longer run as code (CHANGELOG 0.6.0 migration notes). pbo does not
  run on the rest of the file: a dropped line would silently fall back to a
  default (another repo, another retention). Lenient mode (`PBO_CFG_LENIENT`,
  set only by main() for `config check`, `config template` and `catalog
  _umount`) keeps the accepted lines and goes on, so check can report, template
  does not depend on the config, and pbo-mount.service's cleanup (a lazy
  unmount of a FUSE mount, no restic) still runs on a config pbo refuses.
- **Variables.** `PBO_CONFIG_LOCAL` is always the local file (`/etc/pbo/config`
  or `PBO_CONFIG`), whether it exists or not: the only file pbo writes. 0.5's
  `_cfg_set` (setup, menu) and `_integ_set_mode` (integrate) wrote to
  `PBO_CONFIG_LOADED`, which names the shared file when no local file exists
  yet; they write `PBO_CONFIG_LOCAL` now, through the writer since M4 (see
  "Writer").
  `PBO_CONFIG_FILES` lists the files read. `PBO_CONFIG_LOADED` (the last file
  read) and `PBO_CONFIG_SHARED_LOADED` stay for readers; a writer must not use
  them.
- **No bash at runtime.** The shadow comparison of M2 is gone. `pbo config check
  --compare-bash` is the explicit opt-in for migration debugging: it sources
  the files in a subshell with a clean environment (`env -i`, PATH and
  `CFG_ENV`, stdin and stdout closed, a timeout) after the owner and mode rules,
  and names each key bash reads differently and a file bash cannot parse or
  stops in. It runs the file, so it is never the default. tests/all.sh's corpus
  hook uses the same comparison on every config the suites load that the reader
  accepts (such a file holds nothing but assignments).
- **The janitor.** As before, root loads the config and `_role_check` re-execs
  pbo as `JANITOR_USER`, which reads the 0640 root:<group> file again (owned by
  root, so the owner rule passes for that user too). `config check|set|unset`
  run as root stay root (`PBO_SUBCOMMAND`): they concern the file itself, which
  the janitor user may read but not write. Root then writes no file in the
  janitor user's `LOG_DIR` (`LOG_FILE`, `AUDIT_FILE` and `AUDIT_JSON` cleared,
  stderr and stdout only; `ensure_dirs` creates no log file there either): a
  file there may be a symlink that user planted, and one root creates locks
  that user out of its own log. Since check no longer reads as the janitor
  user, it asks that user (`runuser -u JANITOR_USER -- test -r`) whether it can
  read each file.
- **The cluster-shared file and non-root callers.** pmxcfs gives
  `/etc/pve/pbo/config` root:www-data 0640. A non-root caller that cannot read
  it gets a note on stderr and pbo runs on the rest (the local file and the
  defaults), as 0.5 did (its `source` failed and went on); root always reads it.
- **References to keys that only have a default.** `${KEY}` to a schema key no
  earlier line set (and the environment does not hold) stays an error, rather
  than expanding to the key's default: bash stops there under `set -u` (pbo
  0.5, a downgrade), and a default is not something the file said. So the
  generated example writes every derived default literally (as 0.5 did), and
  `HOST_BACKUP_EXCLUDES`, whose 0.5 template used
  `${RESTIC_PASSWORD_FILE:-/etc/pbo/restic-pass}` (an expansion the reader
  refuses), is written out too. That a literal list no longer follows a changed
  `RESTIC_PASSWORD_FILE` is covered in the code: `pbo backup-host` always
  excludes `RESTIC_PASSWORD_FILE` and `RESTIC_REST_PASSWORD_FILE` as
  configured. tests/config_parse.sh uncomments each commented example line in
  turn (alone, and in the example) and checks the reader accepts it and agrees
  with bash.
- **set_defaults from the schema.** A loop over `CS_ORDER` replaces the 0.5
  list of `: "${KEY:=default}"` lines: a literal default is assigned as is, a
  `${REF}` is expanded from the value just assigned to the earlier key, an
  `@fn` default is computed by `_cfgdef_<KEY>` into `_CS_R` (no subshell). The
  paths pbo derives (`LOG_FILE`, `AUDIT_FILE`, the lock and holder files,
  `JOBS_DIR`) follow as code. A frozen copy of the 0.5 function
  (tests/fixtures/set_defaults_0.5.sh) is the reference tests/config.sh
  compares with, as root and as nobody, so the test never compares the schema
  with itself.
- **Cost.** Every start now needs part of the schema. An associative-array
  element costs a few microseconds to create, so the whole table (6 arrays of
  ~90 keys) costs more than reading a small config.
  A generated bash file with the filled arrays was measured and is no faster
  (bash parses the declare lines at the same cost), so there is no build step:
  the table stays the one source and `_cs_core` loads only what the loader needs
  (the key order and the raw defaults by whole-array expansions, the flags by
  key); the descriptions, types, sections and roles wait for a command that
  shows or checks them (`_cs_load`). The file check makes one `stat` instead of
  two plus an `id -u` (`$EUID`), `set_defaults` no `id -u`, and `ensure_dirs` no
  `mkdir` for directories that exist. With a small config, `pbo version` (whose
  time goes mostly to `restic version` and jq) and `load_config` alone are no
  slower than before the schema. A config with every key set costs more to
  read; tests/config.sh keeps a budget for it.

### Writer (M4)

0.5 wrote the config with `sed` (`_cfg_set`, the wizard and the menu): values
unquoted (`KEY=a b` runs `b`), comments of a replaced line dropped, a temp
file in `/tmp` renamed across filesystems (not atomic), mode forced to 0600
(a janitor's 0640 root:<user> config became unreadable for the janitor), and
when no local file existed it wrote the cluster-shared one.

**Decision.** One writer, `_cfg_write` (lib/config.sh), for `pbo config
set|unset`, `_cfg_set` (wizard, menu) and `_integ_set_mode` (`pbo integrate`).
A call is one transaction of any number of sets and unsets:

- **Lock.** `LOCK_DIR/pbo.config`, taken with `flock -n`: a second writer gets
  exit 75 at once (a config change takes a second; waiting would hide a stuck
  one). A symlink there is refused (root opens it). A dry run takes no lock.
  On a janitor run as root the lock is a read fd on the config's own
  directory (root's, not group- or world-writable, else refused): LOCK_DIR
  there belongs to the janitor user, who could swap the lock file for a
  symlink or a FIFO between any check and root's open. Only root takes this
  lock on a janitor (`config set|unset` stay root).
- **Target.** The local file (`PBO_CONFIG_LOCAL`), or with `--shared` the
  cluster-shared one; with `PBO_CONFIG` set there is no shared file and
  `--shared` is a usage error. `--shared` also needs the cluster filesystem:
  it is refused on a janitor (64: no Proxmox, the "shared" file would be a
  stray layer of that host alone) and when the shared file is not below a
  mounted pmxcfs (`/etc/pve` with `.members` or `.version`; 69: with
  pve-cluster stopped the file would land under the mount point, hidden once
  it mounts). A symlinked target is refused (the rename would replace the
  link). The lock is per node, the shared file is not: right before the
  rename the shared file is read again, and when another node changed it
  since it was read, nothing is changed (75, try again).
- **Editing**, line by line on the file as it is (the strict reader accepted it,
  so every non-comment line is one assignment): the key's last active line gets
  the new value in place, its prefix (`export`, blanks) and end-of-line comment
  kept at their column; earlier active lines of the key, which never counted, go.
  Without an active line a commented template line `#KEY=...` becomes it, in
  place, with its description; else the line goes under the schema section's
  `# --- <title> ---` header, else at the end (a proxy variable as `export`).
  Unset removes every active line of the key (an earlier one would count once
  the last is gone) and leaves comments and template lines. A new file starts
  with a header comment and `PBO_CONFIG_VERSION`.
- **Quoting.** Bare when every character is in `[A-Za-z0-9_./:,@%+=-]`, else in
  double quotes with `\ " $ \`` escaped. So nothing in a value is expanded,
  split or refused, and a `$` stays a `$` (a value given on the command line is
  the value meant, unlike the template's `${KEY}` defaults). Control characters
  other than a tab are refused: a value is one line.
- **Read back before the replace.** The candidate goes to a temp file in the
  target's directory (a dry run: in `TMPDIR`), with the old file's owner, group
  and mode (copied, never forced; pmxcfs keeps its own), or for a new local
  file what the permission table says (host 0600 root:root in a 0700
  directory, janitor 0640 root:<JANITOR_USER> in 0750). Then the files are read
  as load_config reads them, once as they are and once with the candidate in
  place of the target (`_cfg_verify`, in a subshell): the strict reader must
  accept it, every set key must read as the value given and come from the
  candidate, every unset key must no longer be set there, every other key must
  read as before, and bash, sourcing the files up to the candidate in a clean
  subshell (`_cfg_compare_bash`, the shadow comparison of M2), must agree with
  the reader on every key the change gives and on every key whose bash
  reading the change alters. Any such difference refuses the change (78) and
  names the first key. A difference the files had before (a CRLF line, which
  load_config only warns about, in the target or the shared file) is left as
  it is and named in a warning: it must not block every write, `pbo integrate`
  and the wizard included. An extended ACL of the old file (a reader the admin
  added) is copied to the new one (`getfacl`/`setfacl`, so the group bits are
  the mask again); one that cannot be copied refuses the change rather than
  dropping it. Only then: `fsync` of the temp file, `rename`, `fsync` of the
  directory. The file is valid bash after every write, so pbo 0.5 still reads it.
  A temp file left by a killed writer is removed by pbo's exit trap.
- **Results** for the caller: per key the value in the file before and after,
  the effective value before and after (the same subshell computes them, so a
  key that follows another, `RESTIC_CACHE_REPO` under `CACHE_DIR`, shows up
  too), a later file that overrides a set key, and the masked diff.

**`pbo config set KEY VALUE... [--shared] [--yes] [--force]`, `pbo config
unset KEY... [--shared] [--yes]`.** Flags are read where a key may stand
(`--` ends them), so a value may start with `--`. Before anything is locked:
each value is checked against the schema type (78 with `_cs_validate`'s
reason; a `path` or `dir` must be absolute); a key flagged `managed=<cmd>` is
refused with the command that changes it (64: `PBO_INTEGRATION` → `pbo
integrate enable|disable`, `PBO_ROLE` → install.sh); a key the schema does not
know is refused unless `--force` (64), an environment switch and names bash or
the loader would act on after a downgrade (`PATH`, `IFS`, `BASH_ENV`, `LD_*`,
readonly names) even with it; a key the role does not use (the roles column) is
refused (78), so a janitor takes no host-only key; `--shared` refuses `secret`,
`exec` and `local-only` keys (78), and `CACHE_DIR` and the keys that follow it
(78, set and unset alike): the move-cache check sees only this node's cache,
and pmxcfs copies the shared file to every node, where no check runs. Unset
needs none of the other checks but the managed one: removing a typo or a
secret is always allowed. `KEY=VALUE` typed as one argument where a key
belongs is refused (64) naming the key only: what follows the `=` may be a
secret, so it reaches neither the message (which is logged and notified) nor
the audit record (`KEY=<secret>` there). A global
`--dry-run` (also after the command) runs everything but the replace and the
hooks' changes and prints the unified diff, with the values of secret and
unknown keys shown as `<hidden>`. `--json`: `{action, file, shared, changed,
written, created, changes: [{key, action, secret, before, after, file_before,
file_after, note, overridden_by}], effective: [...], hooks: [...], diff}`,
secrets as `<set>`/`<unset>`. `audit_log` records the change (`KEY=<secret>`
for a secret or unknown key) and the command record in audit.jsonl gets the
arguments with those values masked (`AUDIT_ARGS`). `config` left
`AUDIT_READONLY`: set and unset are recorded `read_only: false`, show, list,
get, template and check stay read-only.

**Keys that follow.** A key flagged `follows=<BASE>` is not pinned at the
value it derives: `config set RESTIC_CACHE_REPO <CACHE_DIR>/repo` (or the
wizard's `_cfg_set`) removes the line instead, and when BASE changes, a line
the file has at the default derived from the old BASE is removed in the same
transaction, so the key moves along. Both only when no other config file and
not the environment sets the key: removing the line would hand the key to
that value, not to the derived default. Then the set is written (it pins the
override), and a line at the old default is rewritten to the new one.

**on_change hooks** (schema flag), for each key whose effective value
changes, each hook once:

- `confirm-repo` (`RESTIC_OFFSITE_REPO`, `RESTIC_CACHE_REPO`), for the keys
  given only, before the lock: pbo will use another repo and moves no data;
  needs `--yes` or a yes on a terminal (64 otherwise).
- `move-cache` (`CACHE_DIR`), under the lock before the replace: M4 handles an
  empty cache. The old directory must not exist or hold only directories (no
  repo config, nothing in spool or staging, no dump: any file counts, a
  directory pbo cannot read counts), the new one must not be a system
  directory, a symlink or a non-empty directory (`lost+found` and the
  snapshot directories `.zfs` and `.snapshot` of a ZFS dataset or an NFS
  export are allowed; in the old cache those two are not counted as data
  either), and with the Proxmox integration on the spool must not follow
  (storage.cfg names it for the whole cluster). Then the directory is created
  0755 and the permission table's CACHE_DIR rules are applied to it (the ACL
  entries for unprivileged CTs, then the mode; the parents are checked), and
  the config is written. `_cfg_hook_move_cache` is the one place that decides:
  since M7 a cache with data, an empty cache whose spool follows while the
  integration is on, and any change while a move is unfinished go to the
  cache move (lib/cachemove.sh, "Cache move" below); M4 refused the first two
  with 69. The same directory written another way (a trailing slash) is no
  move.
- `restart-mount` (`PVE_CATALOG_MOUNT`, `PVE_CATALOG_MOUNT_DIR`), after the
  write: pbo-mount.service is restarted only when it is active and no restore
  reads through it.

`PBO_INTEGRATION` has no hook: it is managed, written only by `pbo integrate`,
which converges PVE's side itself, and `config set` refuses it.

A failing after-write hook leaves the written config and exits 69. On a
janitor `config set|unset` run as root stay root (`_role_check`, M3): root
writes the 0640 root:<user> file the janitor user only reads.

### Retention per guest (M5)

pbo backs up the directory `$CACHE_DIR/<vmid>` (a host backup: its path list) and
retains with `restic forget --group-by paths`, so a path group has stood for a
guest. A CACHE_DIR move gives a guest a second path, and a host backup's path list
changes as files come and go; each path set then becomes a group of its own, and
an old one keeps its last snapshots for ever.

**Decision.** Classify every vmid tag (a guest, or `host-<node>`) from the snapshot
list pbo already reads per repo (`lib/policy.sh` `_split_guests`): a vmid whose
snapshots lie under more than one sorted path set, each used by that vmid alone,
is *split*. Retention runs the 0.5 forget calls unchanged (the *paths pass*: one
call, or one per keep policy with `--tag vmid=` filters), then one *guest pass*
per split vmid: `forget --group-by '' --tag vmid=<id>` with the policy that vmid
gets in the paths pass. The host is not in either key (cluster nodes share a
repo; a migrated guest keeps one history). One runner (`_forget_policy_runs`)
serves the cache tier (keep-last), offsite (GFS, keep= tags,
`KEEP_OVERRIDE_MIN_LAST`), the janitor's bound forget and `list --reasons`.
`RETENTION_GROUP_BY=paths` skips the guest pass (0.5; removed in 0.7), and so
does any value other than `guest`: the key exists to opt out of the guest pass's
deletions, so an unknown value fails closed.

**Equivalence.** Write keep(P, X) for the snapshots restic's policy P keeps of a
set X. For every bucket rule restic has (last, hourly ... yearly, within, tags) a
snapshot is kept when it is the newest of its bucket and fewer than N buckets
are newer; taking snapshots away cannot make either false, so for Y ⊆ X:
keep(P, Y) ⊇ keep(P, X) ∩ Y. Snapshots that are not kept never move a bucket, so
removing them leaves keep() of the rest unchanged.

pbo's map from a vmid to its path sets is injective (the path holds the vmid, and
a host backup's paths are its own), which `_split_guests` checks per repo. So the
path groups refine the guest groups: every path group lies inside one guest. By
the subset property each path group keeps at least what the guest's own group
keeps of it, so the paths pass only forgets snapshots the guest pass forgets too,
and the guest pass, run after it on what is left, keeps exactly keep(P, guest).
A dry run (both passes planned on the same list) therefore shows the union of
the removals, which is the guest pass's removal set: the plan shown is the plan
pruned. When no vmid is split every guest is a single path group, the guest pass
is empty and the restic calls are those of 0.5. Clean guests and snapshots
without a vmid tag are in the paths pass only, exactly as in 0.5 (restic has no
negative tag filter, so taking split guests out of an unfiltered call would have
taken the untagged snapshots out with them).

A vmid whose path set is also used by another vmid or by an untagged snapshot
breaks the injectivity; pbo never writes that, so such a vmid is not split: it
stays retained per path as in 0.5 and doctor warns about it.

**Consequences.** For a split guest the next prune forgets snapshots 0.5 kept;
doctor names the split guests (a warning with `RETENTION_GROUP_BY=paths`, whose
old groups are never pruned), and `pbo --dry-run prune` / `list --reasons` show
the plan first. Each split guest costs one extra forget per prune (offsite: one
more round-trip) until its old snapshots are gone. The cache tier makes
no extra call: its paths pass has no tag filter, so the keep and remove lists of
its forget JSON hold every snapshot the repo had, and the split guests are found
in that set. When the forget gives no usable JSON (it failed), the guest pass
does not run; the paths pass never forgets more than it would. On a host whose
offsite is append-only the janitor owns that repo's retention, so doctor there
does not judge split guests by the host's `RETENTION_GROUP_BY`.

### Permissions (M6)

pbo's directories and files were made with the right modes in a dozen places
(ensure_dirs, the catalogue writer, `integrate enable`, install.sh, the
wizard), checked in three (doctor: the DR key, CACHE_DIR, a world-writable
LOCK_DIR) and repaired in one (`_cache_dir_protect`). Nothing checked the
directories above CACHE_DIR, which an unprivileged CT's mapped root must pass
for vzdump to work, and there was no way to repair a tree in one step.

**Decision.** One rule table (`lib/perms.sh` `_perm_rules <role>`, a line per
rule: `NAME|KIND|OWNER|GROUP|MODE|ACL|CLASS|WHY`) and one engine
(`_perm_apply --check|--fix [--fix-parents] [--only NAME[:KIND]]`). NAME is
where the path comes from: a config key, `KEY/<sub>`, `KEY/..` (its directory),
`config`/`config/..` (the local config file pbo loaded), `config-shared`.
Nothing in the table is a path; a rule whose path does not exist is skipped
(M6 creates nothing). Doctor runs `--check`; `pbo doctor --fix` runs `--fix`
first, then the full report; every backup runs the CACHE_DIR rule
(`_cache_dir_protect` is a thin wrapper); install.sh runs `pbo doctor --fix
--perms-only`; the cache move (M7) applies it to the new paths; the wizard (M8)
will call it too.

| Rule (host) | Kind | Owner | Mode | Class | Why |
|---|---|---|---|---|---|
| `CACHE_DIR` | dir | root | at most 0750, ACL `u:<ct root>:--x` | fix | plaintext dumps; an unprivileged CT's vzdump runs tar as its mapped root |
| `CACHE_DIR` | parents | | traversable by each CT root | ask | the same tar must pass every directory above |
| `RESTIC_CACHE_REPO` | dir (top only) | | at most 0770 | fix | other users must not read the cache repo |
| `PVE_SPOOL_DIR`, `PVE_SPOOL_DIR/dump` | dir | root | 0755 | fix | PVE jobs write there, CT roots pass it |
| `PVE_STAGING_DIR` | dir / files | root | 0700 / 0600 | fix | staged archives are plaintext |
| `LOCK_DIR` | dir | root | 0700 | fix | a writer could hold pbo's locks |
| `LOG_DIR`; `LOG_FILE`, `AUDIT_FILE`, `AUDIT_JSON` | dir; file | root | 0755; 0600 | fix | repo paths, guest names, errors |
| `STATE_DIR`; `STATE_DIR/runs` | dir | root | 0755; 0750 | fix | the plugin reads the catalogue below it; job logs |
| `PBO_CATALOG/..`; `PBO_CATALOG` | dir; file | root | 0755; 0644 | fix | the PVE storage plugin reads it |
| `RESTIC_CACHE_DIR` | dir | root | 0700 | fix | restic's metadata cache |
| `config/..`; `config` | dir; file | root | 0700; 0600 | fix | DR key and credentials live there; sourced as code |
| `config-shared` | keys | | no secret or exec key | check | pmxcfs copies it to every node (its modes are pmxcfs's) |
| `RESTIC_PASSWORD_FILE` | file | root (reported) | 0600 or 0400 | fix | the DR key |
| `RESTIC_REST_PASSWORD_FILE` | file | root (reported) | 0600 or 0400 | fix | the rest-server password |
| `NTFY_CREDS_FILE` | file | root (reported) | at most 0640 | fix | ntfy credentials; other tools may share the file through its group |
| `PVE_CATALOG_MOUNT_DIR/..` | dir | root | at most 0700 | check | the mount uses allow_other |
| `METRICS_FILE/..` (METRICS_ENABLED) | dir | root | | check | pbo refuses to write the textfile elsewhere |

On a janitor: `CACHE_DIR` (at most 0750), `LOG_DIR` (0755) and its logs
(0600), `STATE_DIR` (0755), `LOCK_DIR` (0700) and `RESTIC_CACHE_DIR` (0700)
belong to JANITOR_USER; `config/..` 0750 and `config` 0640 are root:<the group
named JANITOR_USER, as install.sh and pbo-janitor.service's `Group=` use>. Not
the user's primary group: `adduser --system` makes that nogroup, which other
daemons share, and the unit's supplementary groups leave it out. If no group
of that name exists, the group is reported and not changed. The DR key belongs
to JANITOR_USER, 0400 or 0600 (a fix sets 0400); the ntfy file belongs to
JANITOR_USER, at most 0640. No PVE or metrics rules. LOCK_DIR's default
depends on the uid (`/run/pbo` as root, `STATE_DIR/lock` otherwise): the fix
pass of a janitor started as root takes the janitor's `STATE_DIR/lock` when
LOCK_DIR is root's default, so `/run/pbo` is never given to JANITOR_USER.

**The config's directory.** `config/..` is changed only when it is pbo's own
directory: `/etc/pbo` (the internal key `PBO_PERMS_CONFIG_DIR`, a test hook,
names another one). A config anywhere else (`PBO_CONFIG=/usr/local/etc/pbo.conf`,
`/etc/default/pbo`) lives next to other software's files, so its directory is
checked only, against "at most 0755, owned by root": root sources the config
as code, and whoever can write the directory can replace it. A config on
pmxcfs (`/etc/pve`, test hook `PBO_PVE_CFS_DIR`), also an explicit
`PBO_CONFIG` there, gets no mode rule at all (pmxcfs has fixed modes) and only
the `config-shared` key check.

**Mode specs.** `0700` exact; `0600/0400` any of them (a fix sets the first);
`<0750` no bit outside the mask (a fix clears the others, so a stricter mode
stays). CACHE_DIR keeps the 0.5 meaning of "closed": no bit for others.

**Classes.** fix: `doctor --fix` changes it. ask: only with `--fix-parents`,
because the directories above CACHE_DIR are not pbo's (often `/root`, `/srv`, a
dataset's mount point); the only change ever made there is a traverse-only
entry `u:<uid>:--x` for the uid that is blocked. check: reported only (the
mount's parent is the host's; a root-owned metrics directory is a choice of
where to point METRICS_FILE).

**Safety.**
- A symlink where a directory or file is expected is refused and reported: a
  fix would change the target, which can be anything. Inside the staging
  directory the symlinks into the mount are expected and left alone.
- Every change goes through `_perm_fdop`: a small perl program (perl-base is
  in every Debian and PVE) opens the path with `O_NOFOLLOW|O_NONBLOCK`, checks
  the type and (for a file) that it has one link, checks that
  `/proc/self/fd/N` still names the expected path, and then changes that file
  descriptor (`fchmod`, `fchown`, `setfacl` on `/proc/self/fd/N`). A rename or
  symlink slipped in between check and change is refused instead of changing
  some other file. That matters on a janitor, where root fixes files in
  directories JANITOR_USER can write.
- A shared directory is never checked or changed: the system's own (`/`,
  `/etc`, `/var/lock`, `/tmp`, ...; an explicit list in `lib/perms.sh`) and any
  sticky one. A world-writable one is named (`LOCK_DIR=/var/lock` keeps its 0.5
  warning). This keeps `PBO_CONFIG=/etc/pbo.conf` from making `/etc` 0700 and
  `CACHE_DIR=/tmp` from closing `/tmp`.
- Never recursive: the cache repo's top directory only (restic manages the
  rest), the staging directory's own files only.
- CACHE_DIR keeps `_cache_dir_protect`'s order: the ACL entries first, the mode
  only after them, and never closed while an entry is missing or setfacl is
  not installed (closed without the entry, an unprivileged
  CT's vzdump fails). An entry counts only when it is in effect: a `chmod 700`
  of the directory sets the ACL mask to `---` (getfacl shows
  `#effective:---`), and the CT is locked out as if there were no entry; the
  fix's `setfacl -m` recomputes the mask. A dry run models that mask (0705
  becomes 0715, then 0710), so its plan is the mode the fix sets. On a
  filesystem without POSIX ACLs (setfacl: "Operation not supported"; the check
  pass probes ZFS `acltype` read-only) CACHE_DIR stays open and doctor names
  the filesystem and `zfs set acltype=posixacl`, not the acl package.
- The DR key is checked for being readable before anything else (`-r`
  follows a symlink): missing, unreadable or a dangling symlink is `FAIL DR key
  ... missing or unreadable`, as in 0.5. A symlinked key is never changed
  through the link, but a target others can read is named. `doctor
  --perms-only` (install.sh, before `pbo setup` made the key) reports a key
  that does not exist at all as a warning.
- Owners are only checked as root and on a janitor; a host pbo run as a plain
  user is a test or dev setup. The DR key's and the other secrets' owner on a
  host is reported, not changed.

**Parents.** For each unprivileged CT's mapped root (from its `lxc.idmap`,
else 100000: `_ct_root_uid`) and each directory above the real CACHE_DIR,
root enters the directory and `setpriv --reuid U --regid U --clear-groups --
test -x .` asks the kernel whether U may pass it (ACLs included). Each
directory is judged on its own, so one pass names every directory that blocks.
Without root or setpriv the check is skipped with a line saying so. A blocked
parent is a WARN, not a FAIL: the backup of that CT fails, but doctor cannot
know whether the CT is meant to be backed up by pbo, and the test checkouts
of most suites sit below a 0700 home. The internal key `PBO_PERMS_PARENTS_TOP`
(a test hook) starts the walk below a directory.

**Janitor started as root.** pbo re-execs as JANITOR_USER before it writes
anything (ADR 0004), but only root can give a file to JANITOR_USER or back to
root. So `_role_check` runs the fix pass as root right before the re-exec and
passes its result on (`PBO_PERMS_FIX_REPORT`, with `PBO_PERMS_FIXED=1` so the
re-exec'd doctor does not run it again); the doctor running as JANITOR_USER
audit-logs the changes ("as root, before dropping to <user>") and reports
them. Root writes nothing to the janitor's log files.

**Output.** Findings are `level\trule\tpath\tmessage` (ok, warn, fail), changes
`name\tpath\twhat\tfrom\tto\tapplied`. Doctor prints the DR key line first, the
CACHE_DIR lines, every warning and failure, and one line for the other paths
that pass; with `--fix` the changes (`FIXED`, or `WOULD FIX` in a dry run) and
`changes: [...]` in its JSON. `doctor --fix` marks its audit.jsonl command
record `read_only: false` (`AUDIT_RW_OVERRIDE`); with `--dry-run` it stays
true.

### Cache move (M7)

CACHE_DIR is where the cache repo, the dumps of a running backup, the PVE spool
and the staging directory live; storage.cfg names the spool for the whole
cluster, the catalogue names staging, a process that read the config before a
change still has the old paths, and a restic process with the old path in
hand would create a new, empty repo there and back up into it. 0.6 M4 changed
CACHE_DIR only while the cache was empty.

**Decision.** `pbo config set CACHE_DIR <new>` moves the data, as a journalled
state machine in `lib/cachemove.sh`, entered from the writer's move-cache hook
(`_cfg_hook_move_cache` → `_cm_hook`) under the config lock, after the new
file has been checked and before it replaces the old one. The config write
itself is the writer's rename, so CACHE_DIR and the keys that follow it change
in one transaction, and the move adds nothing to how the file is written.

**Preflight**, read-only, every failure at once, before anything is locked or
written (`--dry-run` stops after it and prints it with the steps). 78 when the
input is wrong: not absolute, not canonical (`//`, `.`, `..`), a symlink or a
path through one (`readlink -m` differs), a system directory, a file, a
non-empty directory (`lost+found`, `.zfs`, `.snapshot` excepted), nested with
the old directory either way, the old CACHE_DIR a symlink, a key that follows
whose data moves while its value cannot (set by the environment or another
file) or would move elsewhere (set in the same command). 69 when the system
refuses: a filesystem in a refusal list (tmpfs, ramfs, proc, ...) or FUSE; a
network filesystem unless `--force` (then a warning); the lists hold the names
`stat -f -c %T` prints (`nfs` for v3 and v4, `v9fs` for 9p); an existing
directory above the target, or an existing empty target, not owned by root
(or the user pbo runs as) or group- or world-writable; a filesystem mounted
below the old directory (`/proc/self/mountinfo`: a child dataset for the repo,
an fstab mount for the spool), since a rename would move only its mount stub,
which mounts at the old path again on the next boot, and a copy would neither
count it (`du -x`) nor remove it (`rm --one-file-system`); for a copy, less free space than `CACHEMOVE_SPACE_FACTOR`
(default 1.1) times `du` of the cache; for each unprivileged CT's mapped root
(`_ct_root_uid`), each existing directory above the target, tested as that uid
with `setpriv` (root only; otherwise a warning says it was not checked), and a
probe on the target filesystem: a file gets an ACL entry (`setfacl`; "not
supported" names `zfs set acltype=posixacl`), a directory closed to others
with the uid's entry must let it pass. A blocking directory gives the exact
`setfacl -m u:<uid>:x <dir>` line, or with `--fix-parents` becomes a planned
change. With the integration on, the pbo storage must exist with type pbo and
`nodes` equal to this node alone: disabling it and changing its path would
otherwise change it on every node; a spool or staging that stays must stay
on the new cache's filesystem. Nothing may run: the global, schedule,
integrate and vmid locks free, the cache lock free unless the mount holds
it, no restore through the mount, no vzdump (its lock file, its processes),
no archive in the spool, no deferred stop-mode record, no process with a file
open below the old directory (in its own spelling or its resolved one: `/proc`
names the resolved path when an ancestor is a symlink). The probes are the
only writes, one file and one directory next to the target, removed at once,
and only for a target that passed the path checks and in a directory only
root can write (another user could swap a probe for a symlink before root's
`setfacl`); otherwise a warning says the CTs' access was not checked yet.

**Rename or copy.** A rename needs the same filesystem and the same mount:
two bind mounts of one filesystem, or a btrfs subvolume mounted twice, share
`st_dev` (and `stat %m`), yet `rename(2)` between them gives `EXDEV`. The mount
comes from mountinfo (`findmnt -T`); any difference means a copy, with its
space check and its verification. The rename itself never falls back to a
copy (`mv --no-copy`, or perl's `rename` where coreutils lacks it): GNU `mv`
would otherwise copy and delete unchecked. A rollback that finds both the old
and the new directory holding entries removes neither and fails (`--abort`
after the operator chose).

**Keys that follow** (schema flag `follows=CACHE_DIR`: `RESTIC_CACHE_REPO`,
`PVE_SPOOL_DIR`, `PVE_STAGING_DIR`). A value at the old derived default goes
from the file (the writer's `_cfg_follows`), so it derives again; a value
below the old directory under a name of its own is rewritten to the same
place below the new one in the same transaction (`_cm_follow_ops`); a value
elsewhere stays, and the plan names it (its data is not moved). The new
effective values come from the writer's read-back (`CFGW_EA`).

**Steps and journal.** `STATE_DIR/cache-move.json` (STATE_DIR does not move),
written atomically (temp file, fsync, rename) after each step and before a
step's change where an interruption would otherwise lose a fact
(`disabled_by_move`, `created_new`, `created_parents`, `data_started`). It
records the old and new directory, the method, every key's old and new value
and how it follows, the storage (id, path, new path, disabled before), whether
the mount ran, the flags, the steps done, the state and the last error.
States: `running`, `config-written`, `rollback-failed` (not final); `done`,
`rolled-back`, `aborted` (final). Steps:

| # | Step | What | Undone by the rollback |
|---|---|---|---|
| 1 | lock | pbo.global, pbo.schedule, pbo.integrate, pbo.catalog (waits for a refresh), pbo.cache exclusive unless the mount holds it | released |
| 2 | mount-stop | `systemctl stop pbo-mount.service` if it ran, then pbo.cache exclusive (waits up to 30 s for its restic) | started again |
| 3 | storage-disable | `pvesm set <id> --disable 1` (integration on, storage enabled) | `pvesm set <id> --delete disable` |
| 4 | staging-clear | staged archives removed (copies and links into the mount, made again on demand) | (nothing to undo) |
| 5 | target-create | missing parents 0755, the target 0755 then the CACHE_DIR rule (ACL entries, then at most 0750); `--fix-parents`: the parents rule with fix | target and created parents removed |
| 6 | data | same filesystem and mount: `rename(2)` of `<old>` onto `<new>` (an empty target is replaced); else `cp -a` of each entry, a tree comparison (type, mode, owner, group, size, link target; a directory's size is not compared), `restic check` of the copied cache repo (`--read-data` with `--verify-data`) | renamed back; a copy removed |
| 7 | config | the writer's rename: CACHE_DIR and the follow ops | (only forward from here) |
| 8 | storage-update | `pvesm set <id> --path <new spool>` when the storage named the old one; enabled again if the move disabled it | |
| 9 | catalog-refresh | `pbo catalog refresh` (the new `staging_dir`); a failure is a warning, the timer retries | |
| 10 | perms | the cache, cache repo, spool and staging rules fixed on the new paths, then checked with the parents | |
| 11 | old-remove | a copy's old directory removed when every entry is one pbo makes (vmid dirs, `host-*`, restore and fetch scratch, `repo`, `spool`, `staging`, the filesystem's own); else kept and named; `--keep-old` keeps it | |

Then the journal says `done`, the cache lock is released, and the mount starts
again if it ran (its `catalog _mount` takes the cache lock shared, so not
before). A failure in steps 1 to 6, or of the config write, rolls back at once,
in reverse, from what the journal recorded; the old tree is then as it was,
but for the staged archives step 4 removed, which are made again on demand
(tests/cachemove.sh compares it byte for byte, with modes, owners, mtimes and
ACLs, after a failure injected after each step, for a rename and a copy). The
rollback, too, writes its final state before it lets another pbo in: the
journal says `rolled-back` (or `aborted`) before the cache lock is released and
the mount is started (systemctl returns at once, and the mount's `catalog
_mount` stops at a journal that is not final); a mount that does not start is
a warning. A rollback that fails leaves `rollback-failed` and starts no mount;
`--abort` tries again. After the
config write a failure leaves `config-written` with the error and exits 69;
`--resume` runs the steps not done. A process killed between the rename and
the journal entry is recognised by the loaded CACHE_DIR already being the
journal's new one.

**Resume and abort.** `config set CACHE_DIR <new> --resume` with the journal's
`<new>`: after the config write it takes the locks again and runs the steps
left (no config write); before it, it goes through the writer again: the
hook checks that the keys would follow as planned, runs only the "nothing
runs" checks and repeats the steps idempotently (a copy starts over in the
target, a rename already done is recognised). `--abort` rolls back an
unfinished move that has not written the config; after the write it is
refused (64): the data is already where the config says. Without either flag
a change of CACHE_DIR while a move is unfinished exits 75.

**The cache lock** (`LOCK_DIR/pbo.cache`, `acquire_cache_lock` in
lib/lock.sh): shared and never waited for, by backup, ingest, fetch, restore,
test-restore, backup-host, the batch run, `catalog materialize` and `catalog
_mount` (held for as long as restic mount runs, which inherits the fd); a move
holds it exclusive, so they exit 75. Prune and verify are kept out by the
global and schedule locks the move holds. After the lock, `_cm_block` exits 75
while the journal is not final (with the command that finishes it); `restic
init` and the vzdump hook's backup-start do the same, and doctor FAILs.

**Old processes.** A process that queued for a lock (`backup --queue` on the
global lock, run-schedule, prune and verify on the schedule lock) compares,
once it has the lock and again when it takes the cache lock, its config files
and the journal with the moment it read the config (`PBO_START_US`, taken
without a fork in load_config, and the local file's device and inode, taken by
the stat load_config runs anyway). The inode is what catches the writer: it
renames a new file over the config, and that file was written before the move
ran, so its mtime can be older than the process (and some filesystems keep
whole seconds); an edit in place gives a newer mtime; a local file that
appeared counts too, and so does a CACHE_DIR that a finished move left; this
process's own writes move the marks. When they changed, it releases its locks
and execs itself with the same arguments and pid (`_lock_reexec_if_changed`,
at most three times in a row, then 75). Only the top-level process does: a
subshell (test-restore `--scheduled` runs each guest in one) that exec'd would
start a second run inside the first, so that guest fails (75) and the next
run reads the new config. `_restic_ensure` never creates an empty repo
(returns 4, `_restic_init_die` exits 75) while a move is unfinished, at or
below a place a finished move recorded as its old directory (or the old cache
repo, when it followed the cache; one pinned outside it stayed where it was and
may be created again) unless that is below the latest move's new one, or at a
local path the config on disk no longer names (read again for that check).
`ensure_dirs` does not create a CACHE_DIR a finished move left. A later
change of CACHE_DIR on an empty cache (M4's path) is recorded in the journal
once the config is written, as the latest move (method `empty`): setting it
back to a place an earlier move left makes that place usable again, and the
place it leaves becomes one the cache left.

**Consequences.** A move with data needs `--yes` (or a yes on a terminal);
an empty cache keeps M4's behaviour and writes no journal. A copy needs the
space of the cache twice until the old copy goes. A janitor's cache is moved
only when it is empty (its user owns the directory; the move refuses with 78
and says how). Retention after a move groups each guest's old and new paths
(M5). The journal of the last move stays (doctor names it) and carries the
earlier ones' old directories.
### Portability (MP, part 1)

**Principle.** Everything that can differ between hosts is a schema key with a
default, or is derived at run time: paths, names, times, limits, the backend
and uids. What is genuinely fixed (pmxcfs at `/etc/pve`, `/proc`, the two
install layouts, the shared system directories pbo refuses to touch) is listed
with its reason. Part 1 is everything that needs no config writer; the timer
schedules (systemd drop-ins written by `config set`) and per-node storage ids
in a cluster came with the writer in part 2 (below).

**The lint.** `tests/hardcode.sh` scans what runs on a host (`pbo`, `lib/`
without the schema, `install.sh`, `systemd/`, `pve-plugin/`) for absolute
paths, host names and IP addresses, and clock times outside comments. A
literal fallback of a config key (`${KEY:-...}`) counts as the schema's value:
tests/config.sh proves each equals the key's default. Everything else must
match an entry of `tests/hardcode.allow` (an extended regex over
`<file>:<value>` and its reason); an entry that matches nothing fails the lint
too, so the list is what the code really holds. Fixed on the way:
preflight read `/etc/pve/storage.cfg` instead of `PVE_STORAGE_CFG`,
`_local_node` read `/etc/pve/.members` instead of the pmxcfs directory
(`PBO_PVE_CFS_DIR`), and install.sh named the default log, state and cache
directories instead of taking them from the schema.

**RESTIC_ENV_FILE.** S3, B2, Azure, GCS and rclone take their credentials
from environment variables, which the strict reader does not export (an
exported `PATH` or `LD_PRELOAD` changes what root runs). They live in
`RESTIC_ENV_FILE` (default `/etc/pbo/restic.env`; local-only: the
cluster-shared config cannot point every node at a file in pmxcfs, which
passes the mode check and could carry variables that make restic or a backend
SDK run a program):

- The config grammar (`_cfg_parse_file` with origin `envfile`): any variable
  name, `export` allowed, a `${NAME}` only to a name set earlier in the same
  file (never pbo's environment), no message ever repeats a value.
- Names that change what runs, that pbo sets for restic itself, or that are
  pbo's own are refused with their line: `PATH`, `IFS`, `ENV`, `BASH_ENV`,
  `LD_*`, `GCONV_PATH`, `BASH_FUNC_*` and the like; `RESTIC_REPOSITORY*`,
  `RESTIC_PASSWORD*`, `RESTIC_FROM_*`, `RESTIC_CACHE_DIR`,
  `RESTIC_REST_USERNAME`/`PASSWORD` (from the config); `RESTIC_HOST`, which
  since restic 0.17 filters every snapshot command by host, while pbo passes
  the node as `--host` on backup only and expects listings and retention to
  see all hosts; every config key (`RESTIC_BIN`, `RESTIC_SFTP_COMMAND`,
  `RESTIC_REST_PASSWORD_FILE`, `RESTIC_CACERT`, ...: they belong in the
  config, where the exec and local-only rules apply) and pbo's internal names
  (`RESTIC_OPTS`, `PBO_*`, `CFG_*`, `RENV_*`, `_*`, `EX_*`).
- File rules, those of the config tightened for a file that holds nothing but
  secrets: a regular file (no symlink), owned by root or the user pbo runs as
  (on a janitor also JANITOR_USER: root reads the file before it drops to
  that user), not writable by group or others, not readable by others. A
  missing file is fine. The permission table fixes it to 0600 (janitor: the
  user's, 0400).
- Scope: load_config checks the file once and keeps only its key names
  (`RENV_KEYS`); the values are read again in the subshell of each restic
  call and set on restic's command alone (`env -- KEY=VALUE ... restic`,
  `_restic_pf`), never as variables of that shell: the program, its options
  and the rest-server password file are taken from the config before the file
  is read, so even a name the list missed cannot change what pbo runs or
  reads. pbo's shell, the programs it runs
  (vzdump, pct, systemctl, curl) and the hooks never see them. Every restic
  call that opens a repo goes through `_restic_pf` (rotate-key's own password
  files too); `restic version` and `--help` go through `_restic_bin`, without
  the environment; tests/portability.sh checks that nothing else runs
  `RESTIC_BIN`. The rest-server login is now exported in that subshell too
  (rotate-key exported it into pbo's shell).
- A file pbo refuses stops every command with 78, like a refused config line,
  except those that diagnose it: `config` (check lists the file's errors by
  line), `doctor` (FAIL per finding), `version` and `help`, and `catalog
  _umount` (below). There a restic call is refused with the reason instead of
  being run without the credentials. install.sh's upgrade guard checks the
  file with the same code and refuses the install while pbo would refuse it.

**pbo-mount.service.** Its `ExecStopPost` unmounted the fixed `/run/pbo/mnt`,
while `PVE_CATALOG_MOUNT_DIR` is a key: with another mount point a dead FUSE
mount stayed behind. `pbo catalog _umount` reads the config and lazily
unmounts what is mounted at that directory only when it is a FUSE mount
(findmnt; the kernel's mount table without it): nothing mounted is fine,
another filesystem there is left alone. It runs no restic, so it loads the
config leniently (as `config check` does) and is exempt from the
RESTIC_ENV_FILE stop: when restic died because of a refused config line or
env file, the dead mount still goes, and the next start does not fail on it.
The units keep the install.sh path (`/usr/local/lib/pbo`) and
`packaging/build-deb.sh` rewrites them; a test installs both layouts
(install.sh's own functions into a tree, the .deb for real when `dpkg-deb` is
there) and checks that every program a unit runs exists there, runs, and is
called with a command pbo has (and, for `catalog`, a subcommand it has).

**RESTIC_MIN.** The default, 0.14.0, is the oldest restic with everything
pbo always uses: `copy --from-repo`, `init --copy-chunker-params --from-repo`
and `RESTIC_FROM_PASSWORD_FILE` (0.14.0 renamed `--repo2`), the
`sftp.connections` option (0.14.0), and repository format 2, which 0.14
writes by default and older releases cannot read. The rest is older (`--no-lock`
for `cat`, `dump`, `forget --json` with reasons, `--group-by ''`, `mount
--allow-other`, percentages for `--read-data-subset`) or optional: `--retry-lock`
(0.16.0) is used only when `restic --help` lists it, the snapshot summary
(0.17.0) only when present. A forget reason names its snapshot by `short_id`
only since 0.17.0; `list --reasons` finds it by time and tree in the group's
keep list on older releases. One feature raises the floor where it is used:
the rest-server login goes to restic in its environment, never on its command
line, which restic reads since 0.16.1 (`RESTIC_REST_USERNAME` set: 0.16.1).
pbo uses no `rewrite`, no `--skip-if-unchanged`, no JSON field newer than
these. Doctor FAILs below the minimum; install.sh refuses before any pbo file
is copied (`--force` installs anyway) and names what to install, downloading
nothing. Both read the cluster-shared config and the local one, so a
rest-server login or a raised `RESTIC_MIN` in the shared file counts. The .deb depends on restic (>= 0.14.0) instead of (>= 0.16), so
distributions that ship 0.14 can install it; CI still runs one pinned
release, so the range below it is supported by this analysis, not by a test
run (README, "Compatibility").

**Thresholds.** The fixed values an operator could reasonably need to change
became advanced keys with the old value as default: `PREFLIGHT_POOL_FREE_PCT`
(150: a ZFS pool's free space against what the guest's volumes use),
`BATCH_FIT_PCT` (85: how much of CACHE_DIR's free space batch mode may plan
for), `INGEST_PENDING_MIN` (10 min), `PVE_SPOOL_MAX_AGE` (24 h),
`PVE_JOB_WINDOW_MIN` (60 min) and `CATALOG_STAGE_WAIT` (10 s). The waits,
TTLs and lock timeouts were keys already. Arithmetic reads them through
`_cfg_int_r`, which falls back to the default for a value that is not a whole
number (doctor names it), so a typo never breaks a backup. Protocol constants
stay: exit codes, the catalogue and JSON versions, pbo's own polling steps,
the PVE versions the integration needs.

**Dependencies.** `setfacl`/`getfacl` (the CACHE_DIR entry for unprivileged
CTs) come from `acl`, which minimal Debian installs lack; `setpriv` (the
parents check) and `findmnt` (the mount cleanup) from `util-linux`. The .deb
depends on both, install.sh installs them, doctor names the exact package
when one is missing.

**Time.** vzdump names an archive after the node's local time, and pbo's own
names and `ts=` tags do the same (`date +%Y_%m_%d-%H_%M_%S`); the ts is only
ever compared as text. Instants are instants: the catalogue's ctime is the
snapshot's restic time (with its offset), the timers' next run is parsed with
the zone systemctl printed it in. Retention is restic's: it buckets each
snapshot by the local day of the offset it recorded, which is the node's zone
when the snapshot was taken, and pbo passes that plan through. The storage
plugin's fallback ctime reads the name as local time. tests/portability.sh
runs these paths under UTC, +05:30 and -03:00; for retention it takes the
snapshots in each zone and checks that zone's own plan, which differs
between the three. A PVE job's next run is compared with pbo's
timer times as minutes of the local day, which is what both are.

**A CT's mapped root.** `_ct_root_uid` takes the CT's own `lxc.idmap: u 0`
line in its main section, else 100000. pve-container never reads
`/etc/subuid`: a CT without an idmap always runs its root as 100000, so pbo
read root's range there (0.5) and put the CACHE_DIR ACL on another uid when
an admin had changed that range. It no longer reads the file. Tested with
idmaps (split ranges, g lines, a snapshot section); never the real files.

**`pbo doctor --report`.** An environment report for a bug report, text or
JSON: pbo's version and layout (deb, install.sh or source), the PVE package
versions, restic, kernel, perl, bash, systemd and OS release, the UTC offset,
single node or cluster (node count and quorum, from pmxcfs' member list), the
filesystem type of CACHE_DIR and whether it has POSIX ACLs (read-only: ZFS
acltype, mount options), the backend type of each repo (sftp, rest, s3, b2,
azure, gs, swift, rclone, local, other), append-only, the integration mode,
whether RESTIC_ENV_FILE exists and how many variables it sets, and which
optional tools exist. It never prints a node or host name, URL, user, path or
value: every field is a version, a count, a type or a yes/no, and a value that
is not version-shaped is shown as "other". tests/portability.sh plants
secrets, URLs, users, hosts, a port and paths in the config and checks that
none appears.

### Portability (MP, part 2): timer schedules, per-node storage ids

**Timer schedules.** The times were fixed in `systemd/*.timer` (and repeated in
install.sh's messages and doctor's job-window check), so another schedule meant
editing a unit file that the next reinstall or package upgrade put back.

- **Keys.** `SCHEDULE_BACKUP`, `SCHEDULE_PRUNE`, `SCHEDULE_VERIFY`,
  `SCHEDULE_TEST_RESTORE`, `SCHEDULE_CATALOG` (host) and `SCHEDULE_JANITOR`
  (janitor: the roles column, so `config set` refuses the other role's keys),
  and `SCHEDULE_*_DELAY` for the `RandomizedDelaySec=` of each timer that has
  one (not pbo.timer: its start should be predictable). All advanced, so a new
  config follows the defaults. A default is the value in the unit file, which
  keeps it: the unit works without pbo's config, and tests/schedule_config.sh
  checks that every unit has its keys and that the two agree. The mapping
  timer -> keys is one table in `lib/timers.sh`.
- **Types.** `calendar` (OnCalendar=) and `timespan` (RandomizedDelaySec=).
  A value becomes a line of a unit file, so before systemd judges the syntax
  it must be plain text there: letters, digits, blanks and `* : , . / ~ - + _`
  only (a `%` is a specifier, `\` continues the line, `=` and `[` start a
  setting or a section, a newline a new line; the writer refuses control
  characters anyway). Then `systemd-analyze calendar|timespan` (offline, changes
  nothing) decides; without it (a CI container) a narrow check accepts only
  the common forms (weekdays, `[year-]month-day`, `hour:minute[:second]`, a
  time zone; numbers with units), every number in its range (hour 0-23, minute
  and second 0-59, month 1-12, day 1-31, year 1970-2199, a repetition only from
  a number), and a time zone only when it is UTC or a file in the zoneinfo
  database, so what it lets through systemd takes too. Anything else is refused
  rather than guessed: the drop-in clears the unit's calendar first, and a value
  systemd then ignores leaves the timer with no trigger. A default is valid by
  construction and not checked again (doctor validates every key on each run).
- **Drop-ins, not unit edits.** A timer whose keys differ from their defaults
  gets `<PBO_SYSTEMD_DIR>/<timer>.d/schedule.conf` (`PBO_SYSTEMD_DIR`, an
  internal key, is `/etc/systemd/system`; the .deb's units in
  `/usr/lib/systemd/system` read drop-ins there too): `[Timer]`, `OnCalendar=`
  (empty: OnCalendar= is a list, the unit's entry must go) and the value,
  `RandomizedDelaySec=` only when its key differs. A timer at its defaults has
  no drop-in; an old one is removed, and the `.d` directory when that leaves it
  empty (an admin's `override.conf` stays; `schedule.conf` sorts after it, so
  the config wins). The file is written atomically (temp file in the directory,
  0644, rename), never through a symlink, and never for a value pbo refuses
  (that timer keeps what it has; the run exits 78).
- **Who applies them.** The `apply-schedule` on_change hook of `config
  set|unset`, after the write, for the timers whose keys changed, from the
  values just written (the shell still holds the old ones); `pbo timers apply`
  for every timer of the role, which install.sh runs after installing the units
  and the .deb's postinst after an upgrade, so a reinstall keeps a custom
  schedule; `pbo doctor --fix`. After a change: `systemctl daemon-reload` once.
  A plain restart is not enough: every pbo timer has `Persistent=true`, and
  systemd computes a calendar timer's next elapse from its last trigger (the
  stamp file), so a new time earlier than the last run would have elapsed
  already and the job would start at once (a full backup at midday, a prune
  with its exclusive lock, a test restore booting a guest). So a schedule
  change resets the timer's persistent state: each changed timer that
  `is-enabled` is stopped before its drop-in is written (a stopped timer is not
  re-armed by the reload), `systemctl clean --what=state` removes its stamp
  after the reload (systemd 247 or later; when it fails the report says the
  timer may start at once), and it is started again when it was running. Its
  next run is then the first elapse of the new calendar from now; a run missed
  under the old schedule is not caught up, which is the lesser surprise. A
  disabled timer stays disabled, an enabled one that was not running stays
  stopped (pbo never enables or starts a timer of its own accord). Without
  systemctl the step is skipped with a note; a failing stop, reload or start is
  a failed after-write hook (69, the config stays written). A dry run says what
  it would write and calls nothing. On a janitor `config set|unset` and `timers
  apply` stay root (the drop-ins are root's, in the systemd directory), and
  `doctor --fix` started as root applies them before it drops to JANITOR_USER
  and hands the result on, as the permission pass does
  (`PBO_SCHED_FIX_REPORT`); the doctor running as JANITOR_USER audit-logs those
  changes ("... (as root, before dropping to <user>)"), root writes nothing into
  that user's LOG_DIR.
- **The cluster-shared file.** A schedule there reaches every node's config,
  but the hook runs only on the node that wrote it. The others are not changed
  behind their back: their doctor warns that the drop-in does not match, and
  `pbo timers apply` (or `doctor --fix`) there applies it.
- **Doctor.** A drop-in that differs from what the config wants (drift), one
  the config no longer wants (stale), a schedule pbo refuses, unit files
  systemd has not reloaded (`NeedDaemonReload`, also after a drop-in was
  removed), and a calendar in systemd (`TimersCalendar`) that is not the
  config's are warnings: the timer runs, on another schedule than the config
  says. The last one catches an `override.conf` from `systemctl edit` that sets
  `OnCalendar=` (the way to change a time before 0.6) and a reload that did not
  happen; both sides are compared in systemd's normalized form
  (`systemd-analyze calendar`), and not at all without it. The PVE job window
  (`PVE_JOB_WINDOW_MIN`) compares a job's next run, as a minute of the local
  day, with the minutes at which the backup, prune and verify timers run (the
  calendar systemd runs when it says, else the configured one): plain
  `HH:MM[:SS]` (lists too) is read directly, anything else
  (wildcards, repetitions, a time zone) is expanded with `systemd-analyze
  calendar --iterations`, which prints local times; a schedule whose times
  cannot be worked out, or that pbo refuses, is left out rather than guessed.
- **`pbo timers`** shows the calendar systemd runs (falling back to the
  configured one), the source of the configured one (default, config, shared,
  env, as `config list` says it), and notes a drop-in that does not match and a
  calendar in systemd that is not the config's.

**Per-node storage ids.** `pbo integrate enable` created `pbo` with `--nodes
<this node>` and this node's spool as `path`. storage.cfg is one file for the
cluster: a second node enabling the integration found `pbo` there, of type pbo,
and converged its path to its own spool, which broke the first node's.

- **Decision.** `PVE_STORAGE_ID`'s default is derived (`_cfgdef_PVE_STORAGE_ID`,
  bash alone, no fork, since set_defaults runs on every start): `pbo` when
  pmxcfs' member list names at most one node (a node outside a cluster lists
  itself as a cluster of one) or cannot be read, so every single-node
  installation is unchanged; else `pbo-<node>`. An entry pbo already made for
  this node keeps its id: `pbo-<node>` if storage.cfg has it, else the first
  entry of type pbo whose `nodes` names this node or that has no `nodes` (it
  serves every node). So a cluster that enabled the integration before 0.6, or
  a node that joined a cluster after enabling it, is not renamed by the
  upgrade. A `PVE_STORAGE_ID` in the local config or the environment always
  wins. It is a per-node value (`local-only`): a `PVE_STORAGE_ID` in the
  cluster-shared file is ignored (doctor FAIL), set it per node; otherwise one
  node's id would be every node's, and the remedy doctor names (a local unset)
  could not undo it.
- **Pinned on enable.** A derived per-node id is written to the local config in
  the same transaction as `PBO_INTEGRATION` (step 8, last). From then on the id
  does not depend on what pmxcfs shows (a start while /etc/pve is not mounted,
  a node that leaves the cluster), and `config list` shows it as configured.
  `pbo` is never pinned (a single node's config stays as it was).
- **Another node's storage.** enable refuses (69, nothing changed) an existing
  pbo entry whose `nodes` leave this node out: converging it would repoint a
  storage another node uses. An entry this node shares with others (in a
  cluster: no `nodes`, or a list that names another node too) may be used as
  it is, but enable refuses when step 4 would change its path: to this node's
  spool (it repoints the others) or, with `--catalog-only`, away (their jobs
  lose their backup target). The refusal's hint offers `config unset
  PVE_STORAGE_ID` only when that changes the id; while a shared entry serves
  this node the derived default keeps its id, so the hint says to set
  `pbo-<node>`. disable refuses (78, before any change) an entry whose `nodes`
  leave this node out: a config copied from another node names that node's
  pinned id, its jobs are not counted here, and `pvesm remove` would delete it
  for the cluster. A shared entry is not removed by disable either: this node
  is taken off its `nodes` (`pvesm set --nodes <the others>`, from the entry or
  pmxcfs' node list), so only the last node removes it, and this node's
  default id becomes `pbo-<node>`. Doctor FAILs a storage whose `nodes` leave
  this node out (PVE runs no job of this node on it). In a cluster where `pbo`
  serves more than this node, doctor warns and names the move, node by node:
  disable or retarget this node's jobs, `integrate disable`, set
  `PVE_STORAGE_ID pbo-<node>`, `integrate enable`, recreate the jobs per node by
  hand. An entry made before 0.6 with `nodes <this node>` is already this
  node's own storage: no warning. pbo never edits jobs.cfg (ADR 0007), so it
  does not move them itself.
- **Ownership.** A job owns guests here only when its storage serves this node
  (no `nodes`, or `nodes` names it): a job for every node on another node's
  storage fails on this node, so counting it would leave this node's guests to
  nobody (fail open, as everywhere in ownership).
- **One id everywhere.** The catalogue (`storage_id`), `integrate
  status|enable|disable`, doctor and the job checks take the id from
  `_pve_storage_id` (the configured or derived value); the vzdump hook and the
  plugin never named it (they match the type `pbo` and PVE's storeid).

**Tests.** `tests/schedule_config.sh` (the keys against the units, drop-ins
written and removed, reload, and stop / `clean --what=state` / start in that
order for a running enabled timer only, refused values with and without
systemd-analyze, dry run, `timers [apply]`, doctor's warnings and `--fix`, the
calendar systemd runs against the config through the systemctl mock,
install.sh over fresh units, the janitor's keys and its root pass through a
fake runuser, the job window)
and the cluster part of `tests/integrate.sh` (a mocked member list of one and
three nodes: the derived id, an entry kept, an explicit id, another node's
storage refused, enable/status/disable with `pbo-<node>`, ownership, the
move warning). Both run a copy of pbo that stops (99) when a path it resolved
(the config files, the directories, the PVE paths, the systemd directory) lies
outside the suite's run directory, before any command runs and before any
config or drop-in write (`tests/fixtures/run_dir_guard.sh`), and every suite
points `PBO_SYSTEMD_DIR` into the checkout, so no test can read or change a
host's units.
