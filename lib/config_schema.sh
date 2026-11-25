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
#   decimal:MIN:MAX    a number with an optional fraction (1.1); whole-number
#                      bounds, MIN or MAX may be empty
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
#   name               a shell variable name: a letter or _, then letters, digits or _
#   version            dotted numbers: 0.14.0 (compared part by part, as sort -V does)
#   command            a program, or a shell command line
#   calendar           a systemd calendar expression (OnCalendar=, systemd.time(7)):
#                      checked with `systemd-analyze calendar`, else a conservative
#                      syntax check; never unit-file syntax (%, \, =, [, newlines)
#   timespan           a systemd time span (RandomizedDelaySec=): 15m, 1h, 90, 0
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
#                      confirm-repo, apply-schedule)
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
CACHEMOVE_SPACE_FACTOR|decimal:1:|1.1|paths|host|advanced|moving CACHE_DIR to another filesystem needs this many times the cache size free there
VZDUMP_MODE|enum:snapshot,suspend,stop|snapshot|vzdump|host||vzdump --mode for every guest not forced to stop
VZDUMP_STOP_VMIDS|vmids-csv||vzdump|host||these vmids are also backed up with --mode stop (comma-separated)
PREFLIGHT_POOL_FREE_PCT|int:0:|150|vzdump|host|advanced|preflight: the ZFS pool of a guest needs this much free space, in percent of what its backed-up volumes use
BACKUP_ORDER|vmids|auto|schedule|host||auto | a comma-separated vmid list (critical first)
BACKUP_MODE|enum:stream,batch|stream|schedule|host||stream (one-by-one, low disk) | batch (dump all→upload)
BATCH_FIT_PCT|int:1:100|85|schedule|host|advanced|batch mode runs only when the estimated dumps fit in this percentage of the free space of CACHE_DIR (else stream)
GLOBAL_LOCK_TIMEOUT|int:0:|7200|schedule|host,janitor||seconds a scheduled run waits in the queue
SCHEDULE_LOCK_TIMEOUT|int:0:|${GLOBAL_LOCK_TIMEOUT}|schedule|host,janitor|advanced|seconds the prune timer waits for a running run-schedule (and vice versa)
PRUNE_OWNER|string||schedule|host||cluster: the node that prunes; empty = any node
SCHEDULE_BACKUP|calendar|*-*-* 05:00:00|schedule|host|advanced,on_change=apply-schedule|when pbo.timer runs the nightly backup (systemd OnCalendar=)
SCHEDULE_PRUNE|calendar|Sun *-*-* 06:30:00|schedule|host|advanced,on_change=apply-schedule|when pbo-prune.timer runs retention (after a week of nightly backups)
SCHEDULE_PRUNE_DELAY|timespan|15m|schedule|host|advanced,on_change=apply-schedule|RandomizedDelaySec= of pbo-prune.timer (0 = start on time)
SCHEDULE_VERIFY|calendar|Wed *-*-* 10:00:00|schedule|host|advanced,on_change=apply-schedule|when pbo-verify.timer runs the integrity check (away from backup and prune)
SCHEDULE_VERIFY_DELAY|timespan|30m|schedule|host|advanced,on_change=apply-schedule|RandomizedDelaySec= of pbo-verify.timer
SCHEDULE_TEST_RESTORE|calendar|Sat *-*-* 10:00:00|schedule|host|advanced,on_change=apply-schedule|when pbo-test-restore.timer restores and boots one guest
SCHEDULE_TEST_RESTORE_DELAY|timespan|30m|schedule|host|advanced,on_change=apply-schedule|RandomizedDelaySec= of pbo-test-restore.timer
SCHEDULE_CATALOG|calendar|*:0/15|schedule|host|advanced,on_change=apply-schedule|when pbo-catalog.timer refreshes the catalogue (Proxmox integration)
SCHEDULE_CATALOG_DELAY|timespan|60|schedule|host|advanced,on_change=apply-schedule|RandomizedDelaySec= of pbo-catalog.timer
SCHEDULE_JANITOR|calendar|*-*-* 12:30:00|schedule|janitor|advanced,on_change=apply-schedule|janitor: when pbo-janitor.timer runs retention, verify and the freshness check
SCHEDULE_JANITOR_DELAY|timespan|15m|schedule|janitor|advanced,on_change=apply-schedule|RandomizedDelaySec= of pbo-janitor.timer
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
NTFY_CREDS_FILE|path|/etc/pbo/ntfy.creds|notifications|host,janitor|advanced|alternative: NTFY_URL / NTFY_TOKEN / NTFY_TOPIC in that file (KEY=VALUE, nothing run); the config wins
NTFY_CREDS_TOPIC_KEY|name|NTFY_TOPIC|notifications|host,janitor|advanced|the key in NTFY_CREDS_FILE that holds the topic (for a file shared with other tools)
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
RESTIC_OFFSITE_REPO|string||restic|host,janitor|advanced,on_change=confirm-repo,template_janitor=/srv/restic/<host>/pbo|sftp:<user>@<host>:<path>, rest:https://..., a local directory, or another restic backend (s3:, b2:, ...)
RESTIC_SFTP_COMMAND|command||restic|host|secret,exec,local-only,advanced|full ssh command for native sftp (port, key, pinned host key); empty = the restic default
RESTIC_SFTP_CONNECTIONS|int:1:|8|restic|host|advanced|parallel sftp connections (faster restore; Storage Box ~10 max)
RESTIC_RETRY_LOCK|duration|10m|restic|host,janitor|advanced|backup/copy/prune wait this long on a locked repo (restic >= 0.16)
RESTIC_PASSWORD_FILE|path|/etc/pbo/restic-pass|restic|host,janitor|advanced,template_janitor=/etc/pbo/restic-pass|repo password (DR key), 0600
RESTIC_ENV_FILE|path|/etc/pbo/restic.env|restic|host,janitor|local-only,advanced|KEY=VALUE lines exported to restic only (S3, B2, Azure, GCS, rclone credentials), 0600; a missing file is fine
RESTIC_MIN|version|0.14.0|restic|host,janitor|advanced|the oldest restic pbo runs with (doctor FAIL, install.sh refuses); a rest-server user (RESTIC_REST_USERNAME) needs 0.16.1
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
PVE_STORAGE_ID|string|@fn|integration|host|advanced,local-only|the pbo storage in PVE: pbo on a single node, pbo-<node> in a cluster (an entry pbo made for this node keeps its id)
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
CATALOG_STAGE_WAIT|int:0:|10|integration|host|advanced|seconds a GUI request waits while another process stages the same archive, then asks to retry
INGEST_PENDING_MIN|int:1:|10|integration|host|advanced|ingest --pending leaves spool archives younger than this many minutes alone (a PVE job may still write them)
PVE_SPOOL_MAX_AGE|int:1:|86400|integration|host|advanced|doctor FAIL: spool archives, or ingested snapshots not yet offsite, older than this (s) are stuck (24 h)
PVE_JOB_WINDOW_MIN|int:0:|60|integration|host|advanced|doctor warns about a PVE backup job to pbo that starts within this many minutes of a pbo timer
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
PBO_PERMS_PARENTS_TOP|dir||internal|host|internal|test hook: the CACHE_DIR parents check (doctor) skips the directories above this one (the test checkout sits below a 0700 home)
PBO_PERMS_CONFIG_DIR|dir|/etc/pbo|internal|host,janitor|internal|test hook: the config directory pbo owns, which doctor --fix sets to the mode of the rule table; a config in any other directory has that directory checked only (other software keeps files there)
PBO_PVE_CFS_DIR|dir|/etc/pve|internal|host|internal|test hook: where pmxcfs is mounted; a config below it keeps the pmxcfs modes and is only checked for secret and exec keys
PBO_PVE_STORAGE_CFG|path|/etc/pve/storage.cfg|internal|host|internal|test hook: the storage.cfg lib/vzdump-hook reads (from its environment)
PBO_PVE_TEMPLATE_DIR|dir|/etc/pve/notification-templates/default|internal|host,janitor|internal|test hook: Proxmox notification templates (read from the environment at start)
PBO_SYSTEMD_DIR|dir|/etc/systemd/system|internal|host,janitor|internal|test hook: where the timer drop-ins (<timer>.d/schedule.conf) are written
'
}

# Environment switches pbo reads that are not config keys (README, test hooks).
# pbo 0.5 sourced the config, so one set there was honoured; pbo 0.6 reads only
# schema keys from it and ignores these (the reader and doctor name them as
# switches, not as typos). tests/config.sh uses this list for its own allowlists.
CS_ENV_SWITCHES='PBO_REPO PBO_NO_NOTIFY PBO_ASCII_LOG TMPDIR PBO_JANITOR_ALLOW_ROOT PBO_INTEGRATE_ALLOW_NONROOT PBO_INGEST_NO_REFRESH PBO_SELF_BIN PBO_HOOK_BIN PBO_PERL_BIN PBO_RUNUSER_BIN PBO_TEST_CONFIG_LOG PBO_REEXEC_N PBO_CM_LOCK_WAIT PBO_TEST_CM_FAIL PBO_TEST_CM_KILL PBO_TEST_CM_COPY PBO_TEST_CM_FREE PBO_TEST_CM_FSTYPE PBO_TEST_CM_NEW_MOUNT PBO_TEST_CM_MOUNTINFO PBO_TEST_CM_VZDUMP_PIDS'

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

# The pbo storage's id in PVE. storage.cfg is one file for the whole cluster,
# and a storage's `path` (the spool, below each node's own CACHE_DIR) is the
# same on every node it serves: so in a cluster each node gets an entry of its
# own, `pbo-<node>` with `--nodes <node>`. A single node keeps `pbo`, as
# before (pmxcfs lists a node outside a cluster as a cluster of one). An entry
# pbo already made for this node keeps its id, so an integration enabled
# before 0.6, or before the node joined a cluster, is not renamed: the entry
# `pbo-<node>`, else the first entry of type pbo whose `nodes` names this node
# (or that has no `nodes`, so serves every node). A PVE_STORAGE_ID in the
# config always wins (set_defaults calls this only for an unset key).
# Bash alone, no jq and no fork: set_defaults runs on every pbo start. Reads
# pmxcfs' member list and storage.cfg before the keys that move them in tests
# are assigned (they follow in the table), hence the fallbacks.
_cfgdef_PVE_STORAGE_ID() {
    _CS_R=pbo
    [[ "${1:-}" == --template ]] && return 0
    local m="${PBO_PVE_CFS_DIR:-/etc/pve}/.members" txt=''
    [[ -r "$m" ]] || return 0
    { IFS= read -r -d '' txt < "$m"; } 2>/dev/null || true
    [[ "$txt" =~ \"nodes\"[[:space:]]*:[[:space:]]*([0-9]+) ]] && (( 10#${BASH_REMATCH[1]} > 1 )) || return 0
    [[ "$txt" =~ \"nodename\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9][A-Za-z0-9.-]*)\" ]] || return 0
    _cs_storage_id_for_r "${BASH_REMATCH[1]}" "${PVE_STORAGE_CFG:-/etc/pve/storage.cfg}"
}

# _cs_storage_id_for_r NODE STORAGE_CFG → _CS_R: the id NODE's pbo storage has
# in STORAGE_CFG (`pbo-NODE`, else the first pbo entry that serves NODE), else
# `pbo-NODE` for a new one. Globs, no regex per line (the storage.cfg of a
# large cluster has hundreds of lines).
_cs_storage_id_for_r() {
    local node="$1" cfg="$2" line t id='' nodes='' first='' hit=''
    _CS_R="pbo-$node"
    [[ -r "$cfg" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        case "$line" in
            [[:space:]]*)
                # a property of the entry above: only `nodes` matters
                t="${line#"${line%%[![:space:]]*}"}"
                if [[ -n "$id" && "$t" == nodes[[:space:]]* ]]; then
                    t="${t#nodes}"; nodes="${t//[[:space:]]/}"
                fi ;;
            '#'*|'') ;;
            *)  # a new entry: the one above ends
                _cs_sid_note
                if [[ "$line" == pbo:[[:space:]]* ]]; then
                    t="${line#pbo:}"; t="${t#"${t%%[![:space:]]*}"}"; id="${t%%[[:space:]]*}"
                fi ;;
        esac
    done < "$cfg"
    _cs_sid_note
    if [[ -n "$hit" ]]; then _CS_R="$hit"; elif [[ -n "$first" ]]; then _CS_R="$first"; fi
    return 0
}
# _cs_sid_note: the pbo entry _cs_storage_id_for_r just read ends (its locals:
# id, nodes, node, hit, first); note it when it is NODE's.
_cs_sid_note() {
    [[ -n "$id" ]] || return 0
    [[ "$id" == "pbo-$node" ]] && hit="$id"
    [[ -z "$first" && ( -z "$nodes" || ",$nodes," == *",$node,"* ) ]] && first="$id"
    id='' nodes=''
    return 0
}

# --- the restic version a config needs (RESTIC_MIN) --------------------------------
# Here rather than in lib/restic.sh: install.sh sources only this file and the
# reader, and refuses a restic that is too old before it installs anything.
#
# RESTIC_MIN's default, 0.14.0, is the oldest restic that has everything pbo
# always uses (ADR 0009, "Portability"): `copy --from-repo`, `init
# --copy-chunker-params --from-repo` and RESTIC_FROM_PASSWORD_FILE (0.14.0
# renamed --repo2), the sftp.connections option (0.14.0) and repository format
# 2 with compression, which restic 0.14 writes by default and older ones cannot
# read. Newer features are optional: --retry-lock (0.16.0) is used only when
# `restic --help` has it, the snapshot summary (0.17.0) only when present, and
# `list --reasons` finds a forget reason's snapshot by time and tree where it
# has no short_id (before 0.17.0).
# One feature raises the floor where the config uses it: the rest-server login
# goes to restic as RESTIC_REST_USERNAME/RESTIC_REST_PASSWORD (never on the
# command line), which restic reads since 0.16.1.

# _version_ge A B: version A >= B, dotted numbers compared part by part.
_version_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]; }

# _restic_need_version <RESTIC_MIN> <RESTIC_REST_USERNAME> → "<version>|<why>":
# the oldest restic the config runs with. An empty or malformed RESTIC_MIN is
# the default (doctor names the bad value).
_restic_need_version() {
    local min="$1" why="RESTIC_MIN"
    [[ "$min" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]] || { _cs_load; min="${CS_DEFAULT[RESTIC_MIN]}"; }
    if [[ -n "$2" ]] && ! _version_ge "$min" 0.16.1; then
        min=0.16.1; why="RESTIC_REST_USERNAME: restic reads the rest-server login from its environment since 0.16.1"
    fi
    printf '%s|%s' "$min" "$why"
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
SCHEDULE_*: when each timer runs, in systemd's OnCalendar= syntax (man systemd.time),
e.g. "Mon..Fri *-*-* 22:30:00"; the *_DELAY keys are its RandomizedDelaySec=.
`pbo config set` writes them to a drop-in (<timer>.d/schedule.conf next to the
units) and restarts the timer if it is enabled, its next run computed from now (a
time moved earlier does not start the job at once); `pbo timers` shows what is in use.
In a cluster, give the nodes different backup times: they share one repo.
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
An SFTP repo is sftp:<user>@<host>:<path> (a relative path starts in the
login's home; a Storage Box is chrooted, so its path is relative), e.g.
  RESTIC_OFFSITE_REPO=sftp:pbo@backup.example:pbo
restic runs `ssh <user>@<host> -s sftp`. Another port, a key ssh does not try
by itself or a pinned host key need the whole ssh command; `pbo setup` writes
it then, pins the host key into /etc/pbo/known_hosts and uses
StrictHostKeyChecking=yes (accept-new is the trust-on-first-use fallback):
  RESTIC_SFTP_COMMAND="ssh pbo@backup.example -p 2222 -i /root/.ssh/id_ed25519 -o UserKnownHostsFile=/etc/pbo/known_hosts -o StrictHostKeyChecking=yes -s sftp"
Other restic backends (s3:, b2:, azure:, gs:, swift:, rclone:) read their credentials
from the environment: put them in RESTIC_ENV_FILE (KEY=VALUE, chmod 600), e.g.
  AWS_ACCESS_KEY_ID=...
  AWS_SECRET_ACCESS_KEY=...
pbo exports them to restic only, never to its own shell or the hooks.
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
        decimal:*)
            local dl="${t#decimal:}" dmin dmax
            dmin="${dl%%:*}"; dmax="${dl#*:}"; [[ "$dl" == *:* ]] || dmax=''
            [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { printf "%s='%s' is not a number (e.g. 1.1)" "$k" "$v_shown"; return 1; }
            # compared on the whole part, and on the fraction at the bound itself
            local dint="${v%%.*}" dfr=0; [[ "$v" == *.* ]] && dfr="${v#*.}"
            if [[ -n "$dmin" ]] && (( 10#$dint < dmin )); then printf "%s=%s is below the minimum %s" "$k" "$v_shown" "$dmin"; return 1; fi
            if [[ -n "$dmax" ]] && { (( 10#$dint > dmax )) || (( 10#$dint == dmax && 10#$dfr > 0 )); }; then printf "%s=%s is above the maximum %s" "$k" "$v_shown" "$dmax"; return 1; fi ;;
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
        name)
            [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf "%s='%s' is not a variable name (letters, digits and _, not starting with a digit)" "$k" "$v_shown"; return 1; } ;;
        version)
            [[ "$v" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]] || { printf "%s='%s' is not a version (e.g. 0.14.0)" "$k" "$v_shown"; return 1; } ;;
        calendar)
            # the default is valid by construction (tests/schedule_config.sh):
            # doctor and config check validate every key, no fork for it
            _cs_default_r "$k"; [[ "$v" == "$_CS_R" ]] && return 0
            _cs_calendar_check "$v" \
                || { printf "%s='%s' is not a systemd calendar expression (%s; e.g. '*-*-* 05:00:00' or 'Sun 06:30', see man systemd.time)" "$k" "$v_shown" "$_CS_WHY"; return 1; } ;;
        timespan)
            _cs_default_r "$k"; [[ "$v" == "$_CS_R" ]] && return 0
            _cs_timespan_check "$v" \
                || { printf "%s='%s' is not a systemd time span (%s; e.g. 15m, 1h, 90s, 0)" "$k" "$v_shown" "$_CS_WHY"; return 1; } ;;
        path|dir|string|list|command) : ;;
        *) printf "%s has an unknown schema type '%s'" "$k" "$t"; return 1 ;;
    esac
    return 0
}

# --- systemd values: the timer schedules (SCHEDULE_*) ------------------------------
# A calendar or time span ends up as a line of a unit file (a drop-in written by
# lib/timers.sh), so before systemd judges the syntax the value must be plain
# text there: only the characters these expressions use. A % is a specifier in
# a unit file, a \ continues the line, = and [ would start a setting or a
# section, a newline a new line; none of them can get through. The rest is
# systemd's own parser (`systemd-analyze calendar|timespan`, offline, nothing is
# changed) when it is there. Without it (a CI container) a narrow check accepts
# the common forms only, with every number in its range (hour 0-23, minute and
# second 0-59, month 1-12, day 1-31, year 1970-2199) and a time zone only when
# it is UTC or a file in the zoneinfo database; anything else is refused rather
# than guessed, so a value it lets through is one systemd takes too. That
# matters because the drop-in's `OnCalendar=` line first clears the unit's own
# calendar: a value systemd then ignores leaves the timer with no trigger.
# Results: _CS_WHY on failure.

# _cs_sd_analyze: systemd-analyze can be used (PBO_TOOLS_MISSING, a test hook,
# can hide it).
_cs_sd_analyze() {
    [[ " ${PBO_TOOLS_MISSING-} " != *" systemd-analyze "* ]] && command -v systemd-analyze >/dev/null 2>&1
}

# _cs_sd_run <systemd-analyze args...>: quiet, bounded in time.
_cs_sd_run() {
    local t=(); command -v timeout >/dev/null 2>&1 && t=(timeout 10)
    "${t[@]}" systemd-analyze "$@" </dev/null >/dev/null 2>&1
}

# _cs_sd_plain VALUE CHARS: VALUE is non-empty, uses only CHARS (a bracket
# expression body) and single blanks between words.
_cs_sd_plain() {
    local v="$1"
    [[ -n "$v" ]] || { _CS_WHY='empty'; return 1; }
    # shellcheck disable=SC2254  # the character set is a pattern on purpose
    case "$v" in *[!$2]*) _CS_WHY='only letters, digits, blanks and * : , . / ~ - + _ are allowed'; return 1 ;; esac
    if [[ "$v" == ' '* || "$v" == *' ' || "$v" == *'  '* ]]; then _CS_WHY='blanks at the start or end, or two in a row'; return 1; fi
    return 0
}

# _cs_calendar_check VALUE: an OnCalendar= expression.
_cs_calendar_check() {
    local v="$1" i=0 n w ok
    _CS_WHY=''
    _cs_sd_plain "$v" 'A-Za-z0-9*:,./~+_ -' || return 1
    if _cs_sd_analyze; then
        _cs_sd_run calendar -- "$v" && return 0
        _CS_WHY='systemd-analyze calendar cannot parse it'; return 1
    fi
    case "$v" in minutely|hourly|daily|weekly|monthly|yearly|annually|quarterly|semiannually) return 0 ;; esac
    # [weekdays] [date] [time] [time zone], each part as systemd.time writes it
    local -a p=(); read -r -a p <<<"$v"
    n="${#p[@]}"
    (( n >= 1 && n <= 4 )) || { _CS_WHY='more parts than weekday, date, time and time zone'; return 1; }
    if [[ "${p[i]}" =~ ^[A-Za-z]+(\.\.[A-Za-z]+)?(,[A-Za-z]+(\.\.[A-Za-z]+)?)*$ ]]; then
        ok=1
        for w in ${p[i]//[.,]/ }; do
            case "${w,,}" in mon|tue|wed|thu|fri|sat|sun|monday|tuesday|wednesday|thursday|friday|saturday|sunday) ;; *) ok=0 ;; esac
        done
        (( ok )) || { _CS_WHY="'${p[i]}' is not a list of weekdays"; return 1; }
        i=$((i+1))
    fi
    if (( i < n )) && [[ "${p[i]}" =~ ^[0-9*][0-9*.,/~]*-[0-9*.,/~-]*$ ]]; then
        _cs_cal_date "${p[i]}" || return 1
        i=$((i+1))
    fi
    if (( i < n )) && [[ "${p[i]}" =~ ^[0-9*][0-9*.,/]*:[0-9*.,/:]*$ ]]; then
        _cs_cal_time "${p[i]}" || return 1
        i=$((i+1))
    fi
    if (( i > 0 && i == n - 1 )) && [[ "${p[i]}" =~ ^(UTC|[A-Z][A-Za-z_+-]*(/[A-Za-z0-9_+-]+)+)$ ]]; then
        # a name systemd does not know is refused by it too: only one the
        # zoneinfo database has (the regex keeps the name a plain relative path)
        if [[ "${p[i]}" != UTC && ! -f "${TZDIR:-/usr/share/zoneinfo}/${p[i]}" ]]; then
            _CS_WHY="'${p[i]}' is not a time zone in ${TZDIR:-/usr/share/zoneinfo} (systemd-analyze is not installed to judge it)"; return 1
        fi
        i=$((i+1))
    fi
    (( i == n )) || { _CS_WHY="'${p[i]}' is not a weekday, date, time or time zone part (systemd-analyze is not installed to judge it)"; return 1; }
    return 0
}

# _cs_cal_field TEXT MIN MAX NAME [frac]: one field of a calendar date or time
# without systemd-analyze: '*', or a comma list of numbers or A..B ranges (each
# may repeat: /N), every number MIN..MAX (frac: a fraction is allowed, as for
# seconds). Numbers are decimal (10#): a leading zero is not octal.
_cs_cal_field() {
    local spec="$1" lo="$2" hi="$3" name="$4" frac="${5:-}" item b x prev
    if [[ -z "$spec" || "$spec" == ,* || "$spec" == *, || "$spec" == *,,* ]]; then
        _CS_WHY="the $name is empty, or has an empty item in '$spec'"; return 1
    fi
    # read, not an unquoted expansion: '*' must not be a glob
    local -a items=()
    IFS=, read -r -a items <<<"$spec"
    for item in "${items[@]}"; do
        if [[ "$item" == */* ]]; then
            [[ "${item##*/}" =~ ^[0-9]+$ ]] && (( 10#${item##*/} > 0 )) \
                || { _CS_WHY="'$item' repeats by '${item##*/}', not a positive number (systemd-analyze is not installed to judge it)"; return 1; }
            item="${item%/*}"
            # systemd repeats from a number only ('0/15'), never from '*'
            [[ "$item" != '*' ]] || { _CS_WHY="'*/${1##*/}' repeats from '*': write a start, e.g. 0/${1##*/}"; return 1; }
        fi
        [[ "$item" == '*' ]] && continue
        if [[ "$item" == *...* || "$item" == *..*..* ]]; then
            _CS_WHY="'$item' is not a number or an A..B range for the $name (systemd-analyze is not installed to judge it)"; return 1
        fi
        prev=''
        for b in "${item%%..*}" "${item##*..}"; do
            x="$b"; [[ -n "$frac" ]] && x="${x%%.*}"
            if [[ -z "$b" || ! "$x" =~ ^[0-9]+$ || ( -z "$frac" && "$b" == *.* ) || ( "$b" == *.* && ! "$b" =~ ^[0-9]+\.[0-9]+$ ) ]]; then
                _CS_WHY="'$item' is not a number or a range for the $name (systemd-analyze is not installed to judge it)"; return 1
            fi
            (( 10#$x >= lo && 10#$x <= hi )) || { _CS_WHY="'$x' is out of range for the $name ($lo-$hi)"; return 1; }
            [[ -z "$prev" ]] || (( 10#$prev <= 10#$x )) || { _CS_WHY="the range '$item' runs backwards"; return 1; }
            prev="$x"
        done
    done
    return 0
}

# _cs_cal_date TEXT: [year-]month-day, '~' before the day counting from the
# end of the month.
_cs_cal_date() {
    local d="$1" day rest mon year='' sep=-
    [[ "$d" == *~* ]] && sep='~'
    [[ "$d" != *~*~* ]] || { _CS_WHY="'$d' has more than one '~'"; return 1; }
    day="${d##*"$sep"}"; rest="${d%"$sep"*}"
    mon="${rest##*-}"; [[ "$rest" == *-* ]] && year="${rest%-*}"
    [[ "$year" != *-* ]] || { _CS_WHY="'$d' is not [year-]month-day"; return 1; }
    if [[ -n "$year" || "$rest" == *-* ]]; then _cs_cal_field "$year" 1970 2199 year || return 1; fi
    _cs_cal_field "$mon" 1 12 month && _cs_cal_field "$day" 1 31 day
}

# _cs_cal_time TEXT: hour:minute[:second].
_cs_cal_time() {
    local -a tf=()
    IFS=: read -r -a tf <<<"$1"
    [[ "$1" != *: ]] && (( ${#tf[@]} == 2 || ${#tf[@]} == 3 )) \
        || { _CS_WHY="'$1' is not hour:minute[:second]"; return 1; }
    _cs_cal_field "${tf[0]}" 0 23 hour && _cs_cal_field "${tf[1]}" 0 59 minute \
        && { (( ${#tf[@]} == 2 )) || _cs_cal_field "${tf[2]}" 0 59 second frac; }
}

# _cs_timespan_check VALUE: a RandomizedDelaySec= time span.
_cs_timespan_check() {
    local v="$1" w
    _CS_WHY=''
    _cs_sd_plain "$v" 'A-Za-z0-9. ' || return 1
    if _cs_sd_analyze; then
        _cs_sd_run timespan -- "$v" && return 0
        _CS_WHY='systemd-analyze timespan cannot parse it'; return 1
    fi
    for w in $v; do
        [[ "$w" =~ ^[0-9]+(\.[0-9]+)?(us|usec|ms|msec|s|sec|second|seconds|m|min|minute|minutes|h|hr|hour|hours|d|day|days|w|week|weeks)?$ ]] \
            || { _CS_WHY="'$w' is not a number with a unit (us, ms, s, min, h, d, w)"; return 1; }
    done
    return 0
}
