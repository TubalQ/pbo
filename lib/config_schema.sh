# shellcheck shell=bash
# lib/config_schema.sh: the config schema, one row per key (ADR 0009).
#
# The single list of the keys pbo reads from /etc/pbo/config: their type,
# default, section, the roles that use them and how pbo treats them. `pbo config`
# (lib/config.sh), doctor's config check (_config_check in lib/common.sh) and the
# generated etc/config.example (`pbo config template`) all read it from here, so
# a new key is added once. set_defaults in lib/common.sh applies the defaults
# from this table at runtime (0.6 M3); tests/config.sh proves they are the ones
# the 0.5 set_defaults gave (a frozen copy in tests/fixtures/).
#
# Row format (the description is the last field and may contain |):
#   KEY|TYPE|DEFAULT|SECTION|ROLES|FLAGS|DESCRIPTION
# TYPE:
#   bool               true | false
#   int:MIN:MAX        a whole number; MIN or MAX may be empty (unbounded)
#   enum:a,b,c         one of the values; a leading empty entry (enum:,a,b) allows empty
#   duration           a restic/Go duration: 90s, 10m, 1h30m
#   path, dir          a file or directory path
#   string, list       free text; list is space-separated
#   vmids              vmids separated by commas or spaces (stray separators allowed),
#                      read by splitting on both (BACKUP_ORDER)
#   vmids-csv          vmids separated by commas; spaces around a comma are allowed,
#                      a space between two vmids is not: the code strips spaces and
#                      splits on commas only (VZDUMP_STOP_VMIDS)
#   url                scheme://...
#   command            a program, or a shell command line
# DEFAULT: a literal, ${KEY} references to keys EARLIER in the table (expanded
#   with the current value of that key), or @fn: the function _cfgdef_<KEY>
#   computes it into _CS_R (with --template: what the example shows). No
#   subshell: set_defaults runs on every pbo start.
#   An empty value in the config means the default, as with set_defaults' :=.
# ROLES: comma-separated, host and/or janitor (PBO_ROLE).
# FLAGS (comma-separated):
#   secret             the value is never printed (`pbo config` says set/unset)
#   exec               the value runs, or names, a program
#   local-only         ignored in the cluster-shared /etc/pve/pbo/config (doctor FAIL)
#   internal           a test hook: not in the example, not in `config list`
#   advanced           commented out in the generated example
#   managed=<cmd>      changed through `pbo <cmd>`, not by editing the key
#   follows=<KEY>      lives below <KEY> by default and moves with it
#   samefs=<KEY>       must be on the same filesystem as <KEY>
#   on_change=<hook>   what changing it implies (move-cache, restart-mount,
#                      confirm-repo)
#   deprecated=<KEY>   replaced by <KEY>; still honoured, not in the example
#   template=<value>   the value the example writes instead of the default (the
#                      example is installed as the first /etc/pbo/config)
#   template_janitor=<value>
#                      `config template --role janitor` writes KEY=<value> as an
#                      active line, even for an advanced key (what a janitor must set)
#
# Sections must be contiguous: the example prints them in table order.

# The table: one single-quoted string, so it holds no apostrophe. Not a
# heredoc: bash reads a small heredoc from a pipe byte by byte (slow), a
# string costs nothing. Kept in a function so sourcing this file costs nothing
# until a command needs the schema (_cs_load).
_cs_table() {
    _CS_TABLE='
PBO_CONFIG_VERSION|int:1:|@fn|schema|host,janitor||config schema this file is written for (pbo warns if it is newer than it knows)
CACHE_DIR|dir|/var/cache/pbo|paths|host,janitor|on_change=move-cache|vzdump dumps, the local restic repo, the PVE spool and staging
LOG_DIR|dir|/var/log/pbo|paths|host,janitor||pbo.log, audit.log and audit.jsonl
STATE_DIR|dir|/var/lib/pbo|paths|host,janitor||jobs, lock holders, restore-test evidence, metrics
LOCK_DIR|dir|@fn|paths|host,janitor|advanced|default /run/pbo as root (STATE_DIR/lock otherwise); never a world-writable dir
VZDUMP_MODE|enum:snapshot,suspend,stop|snapshot|vzdump|host||vzdump --mode for every guest not forced to stop
VZDUMP_STOP_VMIDS|vmids-csv||vzdump|host||these vmids are also backed up with --mode stop (comma-separated)
BACKUP_ORDER|vmids|auto|schedule|host||auto | a comma-separated vmid list (critical first)
BACKUP_MODE|enum:stream,batch|stream|schedule|host||stream (one-by-one, low disk) | batch (dump all→upload)
GLOBAL_LOCK_TIMEOUT|int:0:|7200|schedule|host,janitor||seconds a scheduled run waits in the queue
SCHEDULE_LOCK_TIMEOUT|int:0:|${GLOBAL_LOCK_TIMEOUT}|schedule|host,janitor|advanced|seconds the prune timer waits for a running run-schedule (and vice versa)
PRUNE_OWNER|string||schedule|host||cluster: the node that prunes; empty = any node
KEEP_LOCAL|int:1:|2|retention|host||local cache repo: snapshots kept per guest
RESTIC_KEEP_LAST|int:1:|${KEEP_LOCAL}|retention|host|advanced|local cache repo: keep-last per guest (follows KEEP_LOCAL)
KEEP_OFFSITE_DAILY|int:0:|7|retention|host,janitor||offsite: daily snapshots kept per guest
KEEP_OFFSITE_WEEKLY|int:0:|4|retention|host,janitor||offsite: weekly snapshots kept per guest
KEEP_OFFSITE_MONTHLY|int:0:|6|retention|host,janitor||offsite: monthly snapshots kept per guest
KEEP_OFFSITE_YEARLY|int:0:|0|retention|host,janitor||0 = no yearly bucket
KEEP_OVERRIDE_MIN_LAST|int:0:|3|retention|host,janitor|advanced|a per-guest keep tag never keeps fewer than this many snapshots
FUTURE_SKEW|int:0:|3600|retention|host,janitor|advanced|janitor: snapshots dated further ahead than this (s) block prune
RETENTION_GROUP_BY|enum:guest,paths|guest|retention|host,janitor|advanced|guest | paths (paths = 0.5 behaviour, kept for one release, removed in 0.7)
NTFY_URL|url||notifications|host,janitor|secret|ntfy server (base URL); empty = no ntfy
NTFY_TOPIC|string||notifications|host,janitor|secret|on a public ntfy server the topic is the password: keep this file 0600
NTFY_TOKEN|string||notifications|host,janitor|secret,advanced|access token (sent to curl on stdin, never on its command line)
NTFY_CREDS_FILE|path|/etc/ntfy.creds|notifications|host,janitor|advanced|alternative: NTFY_URL / NTFY_TOKEN / NTFY_TOPIC_WARN in that file
NTFY_ON_SUCCESS|bool|false|notifications|host,janitor|deprecated=NOTIFY_LEVEL|true still means NOTIFY_LEVEL=all when NOTIFY_LEVEL is empty
NOTIFY_LEVEL|enum:,fail,warn,all||notifications|host,janitor|template=fail|fail: failures only | warn: + warnings | all: + every successful run
NOTIFY_PVE|enum:auto,true,false|auto|notifications|host,janitor||Proxmox notifications: auto | true | false
METRICS_ENABLED|bool|true|metrics|host,janitor|advanced|write the Prometheus textfile
METRICS_FILE|path|${STATE_DIR}/pbo.prom|metrics|host,janitor|advanced|node_exporter textfile; its directory must be owned by root
AUDIT_JSON|path|${LOG_DIR}/audit.jsonl|metrics|host,janitor|advanced|one JSON line per command (who/what/exit) plus restore events
DOCTOR_MAX_AGE|int:1:|172800|health|host,janitor||48h, `pbo doctor` flags a guest whose newest snapshot is older (a problem on a janitor)
STORAGE_BOX_SNAPSHOTS_CONFIRMED|bool|false|health|host|advanced|true once the provider keeps snapshots of the box (ransomware backstop)
VERIFY_ROTATE|int:0:|12|integrity|host,janitor|advanced|verify --scheduled reads 1/N of the data per run (0 = structure only)
VERIFY_MAX_AGE|int:1:|3456000|integrity|host,janitor|advanced|doctor warns when the last verify is older (40 days)
VERIFY_READ_DATA|enum:0,1|0|integrity|host,janitor|advanced|1 = every verify reads all data (restic check --read-data, expensive over SFTP)
VERIFY_SUBSET|string||integrity|host,janitor|advanced|a manual verify reads this sample (restic --read-data-subset, e.g. 5%)
JOB_KEEP|int:0:|200|jobs|host|advanced|finished jobs kept in STATE_DIR/jobs
JOB_MAX_ACTIVE|int:1:|20|jobs|host|advanced|active jobs in all
JOB_MAX_PER_USER|int:1:|5|jobs|host|advanced|active jobs per user
JOB_RUNNER|enum:auto,systemd,direct|auto|jobs|host|advanced|auto (systemd-run when available) | systemd | direct
RESTIC_BIN|command|restic|restic|host,janitor|exec,advanced|the restic binary (tests point it at a scratch binary)
LOCAL_REPO|bool|true|restic|host,janitor|advanced,template_janitor=false|true = cached (local repo + copy), false = offsite only
OFFSITE_ENABLED|bool|true|restic|host,janitor|advanced,template_janitor=true|false = local repo only (no offsite copy)
RESTIC_CACHE_REPO|dir|${CACHE_DIR}/repo|restic|host|advanced,follows=CACHE_DIR,on_change=confirm-repo|local restic repo (cache tier)
RESTIC_OFFSITE_REPO|string||restic|host,janitor|advanced,on_change=confirm-repo,template_janitor=/srv/restic/<host>/pbo|sftp:<host>:<path> (native sftp), rest:https://..., or a local directory
RESTIC_SFTP_COMMAND|command||restic|host|secret,exec,local-only,advanced|full ssh command for native sftp (port, key, pinned host key); empty = the restic default
RESTIC_SFTP_CONNECTIONS|int:1:|8|restic|host|advanced|parallel sftp connections (faster restore; Storage Box ~10 max)
RESTIC_RETRY_LOCK|duration|10m|restic|host,janitor|advanced|backup/copy/prune wait this long on a locked repo (restic >= 0.16)
RESTIC_PASSWORD_FILE|path|/etc/pbo/restic-pass|restic|host,janitor|advanced,template_janitor=/etc/pbo/restic-pass|repo password (DR key), 0600
RESTIC_CACHE_DIR|dir|${STATE_DIR}/restic-cache|restic|host,janitor|advanced|the restic metadata cache
PBO_KNOWN_HOSTS|path|/etc/pbo/known_hosts|restic|host|advanced|where `pbo setup` pins the host key of the SFTP server
OFFSITE_APPEND_ONLY|bool|false|appendonly|host|advanced|host never forgets/prunes/removes keys offsite (the janitor does)
RESTIC_REST_USERNAME|string||appendonly|host|advanced|basic auth user (= first path segment with --private-repos)
RESTIC_REST_PASSWORD_FILE|path||appendonly|host|advanced|the HTTP password of that user, 0600
RESTIC_CACERT|path||appendonly|host|advanced|the self-signed cert of the server, pinned (restic --cacert)
PBO_ROLE|enum:host,janitor|host|appendonly|host,janitor|advanced,managed=install,template_janitor=janitor|host | janitor (install.sh --janitor; see etc/config.janitor.example)
JANITOR_USER|string|restic|appendonly|janitor||janitor: the user rest-server runs as; root re-execs pbo as this user
TR_PER_RUN|int:1:|1|testrestore|host|advanced|guests per scheduled run
TR_MAX_AGE|int:1:|1814400|testrestore|host|advanced|doctor warns when the last test is older (21 days)
TR_REPORT_DAYS|int:1:|90|testrestore|host|advanced|report / coverage window in days
TR_HISTORY|path|${STATE_DIR}/restore-tests.jsonl|testrestore|host|advanced|evidence history (not rotated)
TR_WAIT_TRIES|int:1:|30|testrestore|host|advanced|how often to check that the copy answers
TR_WAIT_SLEEP|int:0:|2|testrestore|host|advanced|seconds between those checks
TR_STORAGE|string||testrestore|host|advanced|storage for the throwaway copy; empty = the first one that can hold the guest
PBO_INTEGRATION|enum:standalone,both,integrated|standalone|integration|host|advanced,managed=integrate|standalone | both | integrated
PVE_STORAGE_ID|string|pbo|integration|host|advanced|the pbo storage in PVE
PVE_SPOOL_DIR|dir|${CACHE_DIR}/spool|integration|host|advanced,follows=CACHE_DIR,samefs=CACHE_DIR|PVE jobs write here (same filesystem as CACHE_DIR)
PVE_STAGING_DIR|dir|${CACHE_DIR}/staging|integration|host|advanced,follows=CACHE_DIR|archives staged for a restore from the PVE GUI
PVE_STAGING_TTL|int:0:|21600|integration|host|advanced|seconds a staged archive is kept (6 h)
PVE_STAGING_LINK_TTL|int:0:|900|integration|host|advanced|seconds a staged symlink into the mount is kept while nothing reads through it (15 min)
PVE_CATALOG_MOUNT|bool|true|integration|host|advanced,on_change=restart-mount|true: stage cache archives through pbo-mount.service (restic mount), false: restic dump
CATALOG_MOUNT_BG_WAIT|int:0:|10|integration|host|advanced|seconds a GUI request waits for an archive to show in the mount before staging it in the background
PVE_CATALOG_MOUNT_DIR|dir|/run/pbo/mnt|integration|host|advanced,on_change=restart-mount|the mount point pbo-mount.service uses; a plain path below a root-only directory (allow_other)
CATALOG_MOUNT_WAIT|int:0:|30|integration|host|advanced|seconds a task/CLI restore waits for an archive to show in the mount before restic dump
CATALOG_LOCK_TIMEOUT|int:0:|600|integration|host|advanced|seconds a catalogue refresh waits for another one
CATALOG_MOUNT_BUSY_WAIT|int:0:|900|integration|host|advanced|prune/verify wait this long (s) while a restore reads through the mount, then exit 75
CATALOG_MAX_AGE|int:1:|7200|integration|host|advanced|doctor warns when the catalogue is older (2 h)
VZDUMP_CONF|path|/etc/vzdump.conf|integration|host|advanced|its storage: line is the default for jobs without one
PVE_STORAGE_CFG|path|/etc/pve/storage.cfg|integration|host|advanced|read when `pvesh get /storage` fails
VZDUMP_LOCK|path|/var/run/vzdump.lock|integration|host|advanced|the vzdump node lock: `ingest --pending` waits for no running vzdump
PBO_PVE_PLUGIN_PATH|path|/usr/share/perl5/PVE/Storage/Custom/PboPlugin.pm|integration|host|advanced|where `pbo integrate` and doctor look for the plugin
PBO_VZDUMP_HOOK|command||integration|host|exec,advanced|the `script:` pbo puts in vzdump.conf; empty: the vzdump-hook next to pbo
PBO_CATALOG|path|/var/lib/pbo/catalog/index.json|integration|host|internal|fixed path the storage plugin reads; override only in tests
PBO_PVE_PLUGIN_CHECK|command||integration|host|exec,internal|empty: perl -MPVE::Storage load test of the plugin; else this shell command (tests)
HOST_BACKUP_PATHS|list|/etc/pve /etc/network/interfaces /etc/network/interfaces.d /etc/hosts /etc/hostname /etc/resolv.conf /etc/fstab /etc/vzdump.conf /etc/pbo /etc/systemd/system /etc/cron.d /etc/apt/sources.list /etc/apt/sources.list.d|hostbackup|host|advanced|what `pbo backup-host` saves
HOST_BACKUP_EXCLUDES|list|@fn|hostbackup|host|advanced|never backed up: the DR key, the rest password, private keys (RESTIC_PASSWORD_FILE and RESTIC_REST_PASSWORD_FILE are excluded in any case)
PBO_PVE_LXC_DIR|dir|/etc/pve/lxc|internal|host|internal|test hook: where CT configs are read
PBO_PVE_QEMU_DIR|dir|/etc/pve/qemu-server|internal|host|internal|test hook: where VM configs are read
PBO_SUBUID_FILE|path|/etc/subuid|internal|host|internal|test hook: the subordinate uid ranges (where an unprivileged CT root maps to)
PBO_PERMS_PARENTS_TOP|dir||internal|host|internal|test hook: the CACHE_DIR parents check (doctor) skips the directories above this one (the test checkout sits below a 0700 home)
PBO_PERMS_CONFIG_DIR|dir|/etc/pbo|internal|host,janitor|internal|test hook: the config directory pbo owns, which doctor --fix sets to the mode of the rule table; a config in any other directory has that directory checked only (other software keeps files there)
PBO_PVE_CFS_DIR|dir|/etc/pve|internal|host|internal|test hook: where pmxcfs is mounted; a config below it keeps the pmxcfs modes and is only checked for secret and exec keys
PBO_PVE_STORAGE_CFG|path|/etc/pve/storage.cfg|internal|host|internal|test hook: the storage.cfg lib/vzdump-hook reads (from its environment)
PBO_PVE_TEMPLATE_DIR|dir|/etc/pve/notification-templates/default|internal|host,janitor|internal|test hook: Proxmox notification templates (read from the environment at start)
'
}

# Environment switches pbo reads that are not config keys (README, test hooks).
# pbo 0.5 sourced the config, so one set there was honoured; pbo 0.6 reads only
# schema keys from it and ignores these (the reader and doctor name them as
# switches, not as typos). tests/config.sh uses this list for its own allowlists.
CS_ENV_SWITCHES='PBO_REPO PBO_NO_NOTIFY PBO_ASCII_LOG TMPDIR PBO_JANITOR_ALLOW_ROOT PBO_INTEGRATE_ALLOW_NONROOT PBO_INGEST_NO_REFRESH PBO_SELF_BIN PBO_HOOK_BIN PBO_PERL_BIN PBO_RUNUSER_BIN PBO_TEST_CONFIG_LOG'

# _cs_env_switch NAME: NAME is one of those switches.
_cs_env_switch() { [[ " $CS_ENV_SWITCHES " == *" $1 "* ]]; }

# --- derived defaults (@fn) ----------------------------------------------------
# Each sets _CS_R to the default from the current values of earlier keys; with
# --template to what the generated example shows instead (the example must not
# depend on who generated it). Results in _CS_R, not on stdout: set_defaults
# calls them on every start, and a $(...) costs a fork each.

# Locks in a directory only pbo can write: /var/lock is world-writable, and a
# local user could pre-create or hold a lock file (fs.protected_regular).
# EUID is what `id -u` prints, without the fork.
_cfgdef_LOCK_DIR() {
    if [[ "${1:-}" == --template || "$EUID" == 0 ]]; then _CS_R=/run/pbo
    else _cs_value_r STATE_DIR; _CS_R+=/lock; fi
}

_cfgdef_PBO_CONFIG_VERSION() { _CS_R="${PBO_CONFIG_SCHEMA:-1}"; }

# Never into the repo they protect, and no private keys: the DR key, the rest
# password, the 0.4 pbo-web TLS key (if left), PVE's private dir (root CA key,
# authkey, tokens), node TLS keys, SSH keys.
_cfgdef_HOST_BACKUP_EXCLUDES() {
    local tail='/etc/pbo/rest-pass /etc/pbo/web-tls /etc/pbo/*.old-* /etc/pve/priv /etc/pve/nodes/*/*.key /etc/pve/local/*.key /etc/pve/*.key /root/.ssh **/.ssh **/id_rsa **/id_ed25519 **/id_ecdsa **/*.key'
    if [[ "${1:-}" == --template ]]; then
        # The example writes the default literally, like every derived key
        # (_cs_template_value): a commented line must be a valid config line on
        # its own once uncommented, and the strict reader refuses a reference to
        # a key no earlier line sets (RESTIC_PASSWORD_FILE is commented out in
        # the example) and every :- default. The password files a host actually
        # uses are excluded by backup-host whatever this list says
        # (lib/host.sh), so a literal list cannot let the DR key into the repo
        # after RESTIC_PASSWORD_FILE is changed.
        _CS_R="$(_cs_template_value RESTIC_PASSWORD_FILE) /etc/pbo/rest-pass $tail"; return 0
    fi
    _cs_value_r RESTIC_PASSWORD_FILE
    _CS_R+=" ${RESTIC_REST_PASSWORD_FILE:-/etc/pbo/rest-pass} $tail"
}

# --- prose for the generated example ---------------------------------------------
# The explanation that used to sit in the hand-written etc/config.example, so it
# survives generation. Plain text; the generator adds the "# ".
_cfg_template_header() {
    if [[ "${1:-host}" == janitor ]]; then
        cat <<'EOF'
pbo janitor config (/etc/pbo/config on the storage host). See ADR 0004.
Generated from lib/config_schema.sh (`pbo config template --role janitor`).
Owned by root, readable by the janitor user only (chown root:<JANITOR_USER>;
chmod 0640). Set RESTIC_OFFSITE_REPO to the repo directory on this host.
EOF
        return 0
    fi
    cat <<'EOF'
/etc/pbo/config, KEY=VALUE. chmod 600, root:root.
This is the example/template, copied by install.sh. It contains no secrets
(the restic repo password lives in RESTIC_PASSWORD_FILE, 0600).
Generated from lib/config_schema.sh by `pbo config template`; `pbo config list`
shows the effective values. A line starting with # shows the default (or an
example): remove the # to set it.

The easiest way to fill this in is the interactive wizard, which does the whole
job in one pass (SSH key, host-key pinning, connection test, repo, DR key,
retention, guest set, and enabling the timers):
  pbo setup
EOF
}

_cfg_section_title() {
    case "$1" in
        schema)        printf '' ;;
        paths)         printf 'paths' ;;
        vzdump)        printf 'vzdump' ;;
        schedule)      printf 'schedule' ;;
        retention)     printf 'retention (applied by the pbo-prune.timer, or `pbo prune`)' ;;
        notifications) printf 'notifications' ;;
        metrics)       printf 'metrics and audit' ;;
        health)        printf 'health check' ;;
        integrity)     printf 'integrity (pbo-verify.timer)' ;;
        jobs)          printf 'jobs (pbo job start)' ;;
        restic)        printf 'restic repo' ;;
        appendonly)    printf 'append-only offsite (restic rest-server --append-only), see ADR 0004' ;;
        testrestore)   printf 'scheduled restore tests (pbo-test-restore.timer, `pbo restore-report`)' ;;
        integration)   printf 'Proxmox integration' ;;
        hostbackup)    printf 'host backup (`pbo backup-host`, manual only, tagged type=host)' ;;
        internal)      printf 'test hooks' ;;
        *)             printf '%s' "$1" ;;
    esac
}

_cfg_section_intro() {
    case "$1" in
        vzdump) cat <<'EOF'
Fuse containers (features fuse=1) are forced to --mode stop automatically.
Add extra vmids here to force stop mode for them too (comma-separated).
EOF
            ;;
        schedule) cat <<'EOF'
auto  = back up every guest ON THIS NODE (LXC + VM), auto-discovering new ones.
or a comma-separated vmid list for explicit order/exclusions (critical first).
In a cluster: put the SAME config on every node, each node backs up only its
own guests into the shared repo (an explicit list is filtered to local guests).
PRUNE_OWNER, cluster only: restrict `prune` to one node (prune needs an exclusive
repo lock). Empty = any node may prune (restic's lock keeps concurrent attempts safe).
EOF
            ;;
        retention) cat <<'EOF'
Per guest, set Proxmox tags instead: pbo-keep-daily-N / -weekly-N / -monthly-N / -yearly-N,
pbo-skip (not scheduled), pbo-stop (vzdump --mode stop). See README "Per-guest policy".
EOF
            ;;
        notifications) cat <<'EOF'
NOTIFY_PVE is Proxmox's own notification system (Datacenter → Notifications): auto =
use it when no ntfy is configured, true = in addition to ntfy, false = never. Events
carry the fields type=pbo and hostname=<node> for matchers. `pbo notify-test` sends a test.
EOF
            ;;
        metrics) cat <<'EOF'
Prometheus textfile, rewritten after run-schedule, verify, prune, test-restore and a
manual backup. Its directory must be owned by root. Put it in node_exporter's
--collector.textfile.directory to have it scraped, e.g.
  METRICS_FILE=/var/lib/prometheus/node-exporter/pbo.prom
EOF
            ;;
        restic) cat <<'EOF'
Onboarding: run `pbo setup` (or set the keys below by hand + create the
password file 0600 + run `pbo init` once before the first backup).
Native sftp uses a RELATIVE path on a Storage Box (it is chrooted), e.g.
  RESTIC_OFFSITE_REPO=sftp:storagebox:pbo
The Storage Box needs port/key in the ssh command (the repo URL's host label is
just a name). `pbo setup` pins the host key into /etc/pbo/known_hosts and uses
StrictHostKeyChecking=yes; accept-new is the trust-on-first-use fallback:
  RESTIC_SFTP_COMMAND="ssh uXXXXX-subN@uXXXXX-subN.your-storagebox.de -p 23 -i /root/.ssh/id_ed25519 -o UserKnownHostsFile=/etc/pbo/known_hosts -o StrictHostKeyChecking=yes -s sftp"
EOF
            ;;
        appendonly) cat <<'EOF'
The host can add snapshots but never delete them; retention runs on a separate
janitor (install.sh --janitor). `pbo doctor` proves the server refuses deletes.
With --private-repos the repo path is /<user>/<repo>, e.g.
  RESTIC_OFFSITE_REPO=rest:https://janitor.example:8000/pve1/pbo
  RESTIC_REST_USERNAME=pve1
  RESTIC_REST_PASSWORD_FILE=/etc/pbo/rest-pass
  RESTIC_CACERT=/etc/pbo/janitor-ca.pem
  OFFSITE_APPEND_ONLY=true
EOF
            ;;
        testrestore) cat <<'EOF'
Each run restores the next guest (latest test failed first, then never tested, then
the oldest test) to a throwaway vmid (9000-9099, isolated), boots it, waits for it to
answer, destroys it, and records the result in STATE_DIR/restore-tests.jsonl +
restore-report.{json,txt}. Restores and tests read the offsite repo when it is
enabled; PBO_REPO=cache (environment) reads the local one instead.
EOF
            ;;
        integration) cat <<'EOF'
ADR 0006/0007. standalone (the default) is pbo as before: pbo.timer backs up every
guest and pbo makes no extra pvesh calls. both: a guest that an enabled PVE backup
job to a `pbo` storage selects is left to that job, pbo.timer backs up the rest.
integrated: PVE jobs back up every guest; a guest no job selects is a doctor FAIL.
When the jobs cannot be read, pbo.timer backs up every guest (fail open).
Switch with `pbo integrate`, not by hand. A janitor is always standalone.
EOF
            ;;
        hostbackup) cat <<'EOF'
Space-separated. Missing paths are skipped silently (not an error).
SSH keys and the DR key are excluded by default: secrets never go in the repo
they protect, and the host must keep its own offline copy of its keys.
EOF
            ;;
    esac
}

# --- loader and helpers ------------------------------------------------------------
# Two steps, because every pbo start needs part of the table (load_config: which
# keys exist, their flags and defaults) and an associative-array element costs
# a few microseconds to create: 6 per row add up to more than a whole small
# config takes to read. A generated bash file with the
# filled arrays is no faster (bash parses the declare lines at the same cost),
# so the table stays the only source and is split as late as possible.
#
# _cs_core: CS_ORDER (keys in table order), CS_FLAGS (by key; every key has an
# entry, so it also answers "is this a key") and _CS_DEFV (the raw defaults,
# indexed like CS_ORDER). Column splits run as whole-array expansions (C
# speed); the only per-row statement is the CS_FLAGS element. Idempotent.
_cs_core() {
    [[ "${_CS_CORE:-0}" == 1 ]] && return 0
    declare -gA CS_FLAGS=()
    declare -ga CS_ORDER=() _CS_ROWS=() _CS_DEFV=()
    _cs_table
    # No globbing while splitting; rows hold no blank line and no comment.
    local - i IFS=$'\n' r=()
    set -f
    # shellcheck disable=SC2206  # splitting is the point (IFS=newline, glob off)
    _CS_ROWS=($_CS_TABLE)
    unset _CS_TABLE
    CS_ORDER=("${_CS_ROWS[@]%%|*}")
    r=("${_CS_ROWS[@]#*|}"); r=("${r[@]#*|}")    # from DEFAULT on
    _CS_DEFV=("${r[@]%%|*}")
    r=("${r[@]#*|}"); r=("${r[@]#*|}"); r=("${r[@]#*|}")   # from FLAGS on
    r=("${r[@]%%|*}")
    for i in "${!CS_ORDER[@]}"; do CS_FLAGS[${CS_ORDER[i]}]="${r[i]}"; done
    _CS_CORE=1
}

# _cs_load: the whole table: CS_TYPE CS_DEFAULT CS_SECTION CS_ROLES CS_FLAGS
# CS_DESC (by key) and CS_ORDER (table order). Idempotent: the table is read
# once per process (`pbo version` and the other commands that only load the
# config never get here).
_cs_load() {
    [[ "${_CS_LOADED:-0}" == 1 ]] && return 0
    _cs_core
    declare -gA CS_TYPE=() CS_DEFAULT=() CS_SECTION=() CS_ROLES=() CS_DESC=()
    # Split with word splitting (C speed; read or a regex per row costs far
    # more). No globbing while splitting; IFS=| keeps empty fields and joins
    # the description again (it may hold |).
    local - row f=() IFS='|'
    set -f
    for row in "${_CS_ROWS[@]}"; do
        # shellcheck disable=SC2206  # IFS=| splitting, glob off
        f=($row)
        CS_TYPE[${f[0]}]="${f[1]}"; CS_DEFAULT[${f[0]}]="${f[2]}"; CS_SECTION[${f[0]}]="${f[3]}"
        CS_ROLES[${f[0]}]="${f[4]}"; CS_DESC[${f[0]}]="${f[*]:6}"
    done
    _CS_LOADED=1
}

# _cs_has KEY: KEY is in the schema (the core load is enough).
_cs_has() { _cs_core; [[ -n "${CS_FLAGS[$1]+x}" ]]; }

# _cs_flag KEY FLAG: KEY has FLAG; a flag with a value (managed=integrate) prints it.
_cs_flag() {
    _cs_has "$1" || return 1
    local f IFS=,
    for f in ${CS_FLAGS[$1]}; do
        if [[ "$f" == "$2" ]]; then return 0; fi
        if [[ "$f" == "$2="* ]]; then printf '%s' "${f#*=}"; return 0; fi
    done
    return 1
}

# _cs_has_role KEY ROLE
_cs_has_role() { _cs_has "$1" && _cs_load && [[ ",${CS_ROLES[$1]}," == *",$2,"* ]]; }

# _cs_value_r KEY: the effective value of KEY into _CS_R: its current shell
# value, or its default when that is empty (what pbo reads through its :- fallbacks).
# A global result instead of $(...): no fork per key, and safe to recurse.
_cs_value_r() {
    _CS_R="${!1-}"
    [[ -n "$_CS_R" ]] || _cs_default_r "$1"
}

# _cs_default_r KEY: the default of KEY into _CS_R. ${REF} is replaced by the
# effective value of REF (an earlier key); nothing is eval'ed.
_cs_default_r() {
    [[ "${_CS_LOADED:-0}" == 1 ]] || _cs_load
    local spec="${CS_DEFAULT[$1]-}" out='' ref
    if [[ "$spec" == @fn ]]; then "_cfgdef_$1"; return 0; fi
    while [[ "$spec" == *'${'*'}'* ]]; do
        out+="${spec%%\$\{*}"; spec="${spec#*\$\{}"
        ref="${spec%%\}*}"; spec="${spec#*\}}"
        _CS_R=''; [[ "$ref" != "$1" && -n "${CS_TYPE[$ref]+x}" ]] && _cs_value_r "$ref"
        out+="$_CS_R"
    done
    _CS_R="$out$spec"
}

# _cs_default KEY: print the default of KEY (derived ones expanded).
_cs_default() { _cs_default_r "$1"; printf '%s' "$_CS_R"; }

# _cs_template_value KEY [ROLE]: what the generated example for ROLE (default
# host) writes for KEY: the template_<ROLE>= or template= flag, else the default
# with every ${REF} replaced by REF's own template value. Literal, as in 0.5, not
# ${REF}: a commented line must stand on its own once uncommented. The strict
# reader refuses a ${REF} to a key no earlier line sets (as bash under set -u
# stops on it: pbo 0.5, a downgrade), and the example comments most keys out (a
# minimal config, or the cluster-shared file, read before the local one that may
# set REF).
_cs_template_value() {
    local k="$1" role="${2:-host}" t spec out='' ref
    _cs_load
    if [[ "$role" != host ]] && t="$(_cs_flag "$k" "template_$role")"; then printf '%s' "$t"; return 0; fi
    if t="$(_cs_flag "$k" template)"; then printf '%s' "$t"; return 0; fi
    spec="${CS_DEFAULT[$k]}"
    if [[ "$spec" == @fn ]]; then "_cfgdef_$k" --template; printf '%s' "$_CS_R"; return 0; fi
    while [[ "$spec" == *'${'*'}'* ]]; do
        out+="${spec%%\$\{*}"; spec="${spec#*\$\{}"
        ref="${spec%%\}*}"; spec="${spec#*\}}"
        [[ "$ref" != "$k" ]] && _cs_has "$ref" && out+="$(_cs_template_value "$ref" "$role")"
    done
    printf '%s' "$out$spec"
}

# _cs_enum_values KEY: the allowed values of an enum key, joined with |
# (the empty value left out).
_cs_enum_values() {
    local l="${CS_TYPE[$1]#enum:}" v out=''
    local IFS=,
    for v in $l; do [[ -n "$v" ]] && out+="${out:+|}$v"; done
    printf '%s' "$out"
}

# _cs_validate KEY VALUE: type check. Returns 0, or prints why VALUE does not fit
# and returns 1. Empty is always valid: pbo reads it as the default.
_cs_validate() {
    local k="$1" v="$2" t v_shown
    _cs_has "$k" || { printf "%s is not a known config key" "$k"; return 1; }
    [[ -n "$v" ]] || return 0
    _cs_load
    if [[ "$v" == *$'\n'* ]]; then printf "%s spans more than one line" "$k"; return 1; fi
    t="${CS_TYPE[$k]}"
    # a secret's value never appears in the message
    if _cs_flag "$k" secret >/dev/null; then v_shown='***'; else v_shown="$v"; fi
    case "$t" in
        bool)
            [[ "$v" == true || "$v" == false ]] || { printf "%s='%s' is not true|false" "$k" "$v_shown"; return 1; } ;;
        int:*)
            local lim="${t#int:}" min max
            min="${lim%%:*}"; max="${lim#*:}"; [[ "$lim" == *:* ]] || max=''
            [[ "$v" =~ ^[0-9]+$ ]] || { printf "%s='%s' is not a whole number" "$k" "$v_shown"; return 1; }
            # 10# : a leading zero is decimal, not octal
            if [[ -n "$min" ]] && (( 10#$v < min )); then printf "%s=%s is below the minimum %s" "$k" "$v_shown" "$min"; return 1; fi
            if [[ -n "$max" ]] && (( 10#$v > max )); then printf "%s=%s is above the maximum %s" "$k" "$v_shown" "$max"; return 1; fi ;;
        enum:*)
            [[ ",${t#enum:}," == *",$v,"* ]] || { printf "%s='%s' is not %s" "$k" "$v_shown" "$(_cs_enum_values "$k")"; return 1; } ;;
        duration)
            [[ "$v" =~ ^([0-9]+(\.[0-9]+)?(ns|us|ms|s|m|h))+$ || "$v" == 0 ]] \
                || { printf "%s='%s' is not a duration (e.g. 90s, 10m, 1h30m)" "$k" "$v_shown"; return 1; } ;;
        vmids)
            # split on commas and whitespace; stray separators are harmless
            _cs_default_r "$k"
            [[ "$v" == "$_CS_R" || "$v" =~ ^[,[:space:]]*[0-9]+([,[:space:]]+[0-9]+)*[,[:space:]]*$ ]] \
                || { printf "%s='%s' is not a list of vmids" "$k" "$v_shown"; return 1; } ;;
        vmids-csv)
            # _in_csv strips spaces and splits on commas only: "101 102" would be
            # read as vmid 101102, so a space between two vmids is refused
            [[ "$v" =~ ^[\ ,]*[0-9]+(\ *,[\ ,]*[0-9]+)*[\ ,]*$ ]] \
                || { printf "%s='%s' is not a comma-separated list of vmids" "$k" "$v_shown"; return 1; } ;;
        url)
            [[ "$v" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]+$ ]] || { printf "%s is not a URL (scheme://host...)" "$k"; return 1; } ;;
        path|dir|string|list|command) : ;;
        *) printf "%s has an unknown schema type '%s'" "$k" "$t"; return 1 ;;
    esac
    return 0
}
