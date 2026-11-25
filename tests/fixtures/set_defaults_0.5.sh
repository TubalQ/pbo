# shellcheck shell=bash
# tests/fixtures/set_defaults_0.5.sh: the set_defaults of pbo 0.5 / 0.6 M2,
# frozen. 0.6 M3 replaced it with the schema (lib/config_schema.sh, applied by
# set_defaults in lib/common.sh); tests/config.sh sources this copy after
# lib/common.sh and proves the schema gives the same defaults, as root and as a
# plain user. Never edit it to make that test pass: a changed default is a
# deliberate change of the schema, with its own test.

set_defaults() {
    : "${CACHE_DIR:=/var/cache/pbo}"
    : "${LOG_DIR:=/var/log/pbo}"
    : "${STATE_DIR:=/var/lib/pbo}"
    # locks in a directory only pbo can write: /var/lock is world-writable, and
    # a local user could pre-create or hold a lock file (fs.protected_regular)
    if [[ "$(id -u)" == 0 ]]; then : "${LOCK_DIR:=/run/pbo}"; else : "${LOCK_DIR:=${STATE_DIR}/lock}"; fi
    : "${VZDUMP_MODE:=snapshot}"
    : "${VZDUMP_STOP_VMIDS:=}"         # these (+ auto-detected fuse CTs) → --mode stop
    : "${BACKUP_ORDER:=auto}"          # auto = all guests on THIS node; or an explicit csv (critical-first)
    : "${PRUNE_OWNER:=}"               # cluster: restrict prune to this nodename (empty = any node may prune)
    : "${GLOBAL_LOCK_TIMEOUT:=7200}"
    : "${SCHEDULE_LOCK_TIMEOUT:=${GLOBAL_LOCK_TIMEOUT}}"   # how long a queued prune/run-schedule waits for the other
    : "${KEEP_LOCAL:=2}"
    : "${KEEP_OFFSITE_DAILY:=7}"
    : "${KEEP_OFFSITE_WEEKLY:=4}"
    : "${KEEP_OFFSITE_MONTHLY:=6}"
    : "${KEEP_OVERRIDE_MIN_LAST:=3}"   # a per-guest keep tag never keeps fewer than this many
    : "${KEEP_OFFSITE_YEARLY:=0}"      # 0 = no yearly bucket
    : "${FUTURE_SKEW:=3600}"           # seconds a snapshot may be dated ahead before it counts as "from the future"
    : "${RETENTION_GROUP_BY:=guest}"   # guest | paths (0.5 behaviour, removed in 0.7)
    : "${NTFY_URL:=}"                  # ntfy server (base URL); empty = no notifications
    : "${NTFY_TOKEN:=}"                # otherwise read from NTFY_CREDS_FILE
    : "${NTFY_TOPIC:=}"                # otherwise NTFY_TOPIC_WARN from the creds file
    : "${NTFY_CREDS_FILE:=/etc/ntfy.creds}"
    : "${NTFY_ON_SUCCESS:=false}"      # deprecated: NOTIFY_LEVEL=all
    : "${NOTIFY_LEVEL:=}"              # fail | warn | all (empty: fail, or all if NTFY_ON_SUCCESS=true)
    : "${NOTIFY_PVE:=auto}"            # Proxmox notification system: auto (when no ntfy) | true (also) | false
    : "${OFFSITE_ENABLED:=true}"       # false = local repo only, no offsite copy
    : "${PBO_ROLE:=host}"              # host = PVE node that backs up guests | janitor = storage-side box that owns offsite retention
    : "${JANITOR_USER:=restic}"         # janitor: the user rest-server runs as; root re-execs as this user
    : "${OFFSITE_APPEND_ONLY:=false}"  # true = offsite refuses deletes (rest-server --append-only); this host never prunes it
    : "${TR_WAIT_TRIES:=30}"           # test-restore: number of attempts to reach the guest
    : "${TR_WAIT_SLEEP:=2}"            # test-restore: seconds between attempts
    : "${TR_PER_RUN:=1}"               # test-restore --scheduled: guests per run
    : "${TR_MAX_AGE:=1814400}"         # 21 days, doctor warns when the last restore test is older
    : "${TR_REPORT_DAYS:=90}"          # restore-report / doctor coverage window (days)
    : "${STORAGE_BOX_SNAPSHOTS_CONFIRMED:=false}"  # confirm that Hetzner snapshots are on
    : "${DOCTOR_MAX_AGE:=172800}"      # 48h, doctor flags a guest whose newest snapshot is older
    : "${VERIFY_ROTATE:=12}"           # verify --scheduled reads 1/N of the data per run, all of it every N runs (0 = structure only)
    : "${VERIFY_MAX_AGE:=3456000}"     # 40 days, doctor warns when the last verify is older

    # --- Proxmox integration (ADR 0006/0007) ---
    : "${PBO_INTEGRATION:=standalone}"                    # standalone (pbo.timer backs up every guest) | both | integrated
    : "${PVE_STORAGE_ID:=pbo}"                            # the pbo storage that `pbo integrate` adds to PVE
    : "${PVE_SPOOL_DIR:=${CACHE_DIR}/spool}"              # where PVE jobs write archives (same filesystem as CACHE_DIR)
    : "${PVE_STAGING_DIR:=${CACHE_DIR}/staging}"          # archives materialised for a PVE restore
    : "${PVE_STAGING_TTL:=21600}"                         # seconds a staged archive is kept (6 h)
    : "${PVE_STAGING_LINK_TTL:=900}"                      # seconds a staged symlink into the mount is kept while nothing reads through it
    : "${PVE_CATALOG_MOUNT:=true}"                        # true = stage cache archives as symlinks into pbo-mount.service (restic mount); false = restic dump
    : "${PVE_CATALOG_MOUNT_DIR:=/run/pbo/mnt}"            # where pbo-mount.service mounts the cache repo
    : "${CATALOG_MOUNT_BUSY_WAIT:=900}"                   # prune/verify wait this long (s) for a restore reading through the mount, then exit 75
    : "${CATALOG_MAX_AGE:=7200}"                          # doctor warns when the catalogue is older (2 h)
    : "${VZDUMP_CONF:=/etc/vzdump.conf}"                  # vzdump defaults (storage: for jobs without one)
    : "${PVE_STORAGE_CFG:=/etc/pve/storage.cfg}"          # read when `pvesh get /storage` fails
    : "${PBO_CATALOG:=/var/lib/pbo/catalog/index.json}"   # fixed path the storage plugin reads; override only in tests
    : "${VZDUMP_LOCK:=/var/run/vzdump.lock}"              # vzdump's node lock: `ingest --pending` leaves the spool alone while it is held
    : "${PBO_PVE_PLUGIN_PATH:=/usr/share/perl5/PVE/Storage/Custom/PboPlugin.pm}"  # where `pbo integrate`/doctor look for the storage plugin
    : "${PBO_PVE_PLUGIN_CHECK:=}"                         # empty: perl -MPVE::Storage load test of the plugin; else this shell command (tests)
    : "${PBO_VZDUMP_HOOK:=}"                              # empty: the vzdump-hook next to this pbo (install.sh /usr/local/lib/pbo, package /usr/lib/pbo)

    # --- restic engine ---
    : "${BACKUP_MODE:=stream}"                            # stream (one-by-one) | batch (dump all→upload), SAME repo
    : "${RESTIC_BIN:=restic}"                             # override in tests (scratch binary)
    : "${LOCAL_REPO:=true}"                               # true=cached (local repo+copy), false=offsite-only
    : "${RESTIC_CACHE_REPO:=${CACHE_DIR}/repo}"           # local restic repo (cache tier)
    : "${RESTIC_OFFSITE_REPO:=}"                          # sftp:user@host:port/path (native) or local dir (test)
    : "${RESTIC_PASSWORD_FILE:=/etc/pbo/restic-pass}"  # repo password (DR key), 0600
    : "${RESTIC_CACHE_DIR:=${STATE_DIR}/restic-cache}"    # restic's own metadata cache
    : "${RESTIC_KEEP_LAST:=${KEEP_LOCAL}}"               # local repo: keep N latest per guest
    : "${RESTIC_SFTP_COMMAND:=}"                          # full ssh command for native sftp (port/key); empty=restic default
    : "${RESTIC_RETRY_LOCK:=10m}"                         # write ops wait this long on a busy repo lock (another node, a manual restic). Empty = fail at once
    : "${RESTIC_SFTP_CONNECTIONS:=8}"                     # parallel sftp connections (Storage Box ~10 max), speeds up restore considerably
    : "${RESTIC_REST_USERNAME:=}"                         # rest-server basic auth user (rest: repos); with --private-repos also the first path segment
    : "${RESTIC_REST_PASSWORD_FILE:=}"                    # file with that user's HTTP password, 0600
    : "${RESTIC_CACERT:=}"                                # pinned cert/CA for a self-signed rest-server (restic --cacert)

    # --- host backup (config + rebuild metadata, manual: `pbo backup-host`) ---
    # Curated, space-separated. Missing paths are skipped (not an error).
    : "${HOST_BACKUP_PATHS:=/etc/pve /etc/network/interfaces /etc/network/interfaces.d /etc/hosts /etc/hostname /etc/resolv.conf /etc/fstab /etc/vzdump.conf /etc/pbo /etc/systemd/system /etc/cron.d /etc/apt/sources.list /etc/apt/sources.list.d}"
    # SSH keys and the DR key are deliberately excluded (secrets never go in the
    # repo they protect / the host must keep its own offline key copy).
    # never into the repo they protect, and no private keys: the DR key, the rest
    # password, the 0.4 pbo-web TLS key (if left), PVE's private dir (root CA key, authkey, tokens),
    # node TLS keys, SSH keys
    : "${HOST_BACKUP_EXCLUDES:=${RESTIC_PASSWORD_FILE} ${RESTIC_REST_PASSWORD_FILE:-/etc/pbo/rest-pass} /etc/pbo/rest-pass /etc/pbo/web-tls /etc/pbo/*.old-* /etc/pve/priv /etc/pve/nodes/*/*.key /etc/pve/local/*.key /etc/pve/*.key /root/.ssh **/.ssh **/id_rsa **/id_ed25519 **/id_ecdsa **/*.key}"

    # Derived paths.
    LOG_FILE="${LOG_DIR}/pbo.log"
    AUDIT_FILE="${LOG_DIR}/audit.log"
    : "${AUDIT_JSON:=${LOG_DIR}/audit.jsonl}"        # one JSON object per line: every command + audit events
    : "${METRICS_ENABLED:=true}"
    : "${METRICS_FILE:=${STATE_DIR}/pbo.prom}"       # node_exporter textfile; point it into --collector.textfile.directory
    GLOBAL_LOCK_FILE="${LOCK_DIR}/pbo.global"
    GLOBAL_HOLDER_FILE="${STATE_DIR}/global.holder"
    SCHED_LOCK_FILE="${LOCK_DIR}/pbo.schedule"
    SCHED_HOLDER_FILE="${STATE_DIR}/schedule.holder"
    JOBS_DIR="${STATE_DIR}/jobs"
}
