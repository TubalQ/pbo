#!/usr/bin/env bash
# install.sh: installs pbo on a Proxmox host. Idempotent.
# NEVER enables the timer automatically (it prints how to do that yourself).
#
# Run as root on the host:  ./install.sh
set -Eeuo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIBDIR=/usr/local/lib/pbo
BIN=/usr/local/sbin/pbo
CFGDIR=/etc/pbo
UNITDIR=/etc/systemd/system

die(){ printf 'install: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || die "must be run as root."

# --janitor [--user <name>]: install on the storage host instead of a PVE node
# (ADR 0004). No vzdump/pct needed; installs the janitor units, not pbo.timer.
ROLE=host; JUSER=restic
while [[ $# -gt 0 ]]; do
    case "$1" in
        --janitor) ROLE=janitor; shift ;;
        --user)    JUSER="$2"; shift 2 ;;
        *) die "unknown flag: $1 (use --janitor [--user <name>])" ;;
    esac
done
if [[ "$ROLE" == janitor ]]; then
    id "$JUSER" >/dev/null 2>&1 || die "janitor user '$JUSER' does not exist (it should be the user rest-server runs as)"
fi

echo "==> Dependencies"
# restic jq zstd flock curl openssl: the tool + the setup wizard (openssl mints
# the DR key). ssh/sftp/ssh-keygen/ssh-keyscan come from openssh-client, which
# the wizard uses to make and pin an SSH key and to test the connection.
declare -A pkg=( [restic]=restic [jq]=jq [zstd]=zstd [flock]=util-linux [curl]=curl
                 [openssl]=openssl [ssh-keygen]=openssh-client )
need=(); for b in "${!pkg[@]}"; do command -v "$b" >/dev/null 2>&1 || need+=("${pkg[$b]}"); done
if [[ "${#need[@]}" -gt 0 ]]; then
    # unique package list
    mapfile -t need < <(printf '%s\n' "${need[@]}" | sort -u)
    echo "    installing: ${need[*]}"
    apt-get update -qq && apt-get install -y "${need[@]}"
else
    echo "    all present (restic jq zstd flock curl openssl openssh-client)"
fi
[[ "$ROLE" == janitor ]] || for b in vzdump pct qm zfs; do command -v "$b" >/dev/null 2>&1 || echo "    WARNING: '$b' missing, required on a real Proxmox host."; done

echo "==> Program files → $LIBDIR"
install -d -m 0755 "$LIBDIR" "$LIBDIR/lib"
install -m 0755 "$SRC/pbo" "$LIBDIR/pbo"
install -m 0644 "$SRC"/lib/*.sh "$LIBDIR/lib/"
ln -sf "$LIBDIR/pbo" "$BIN"
echo "    $BIN → $LIBDIR/pbo"
# Backward-compat: keep the old name working (pbo was formerly 'lxc-offsite').
ln -sf "$LIBDIR/pbo" /usr/local/sbin/lxc-offsite
echo "    /usr/local/sbin/lxc-offsite → $LIBDIR/pbo  (compat alias)"

echo "==> Directories"
install -d -m 0755 /var/log/pbo /var/lib/pbo /var/lib/pbo/jobs
install -d -m 0700 "$CFGDIR"
if [[ "$ROLE" == janitor ]]; then
    # The janitor runs as $JUSER: it needs its state/log dirs and to read the config.
    install -d -m 0755 /var/cache/pbo
    chown -R "$JUSER:$JUSER" /var/log/pbo /var/lib/pbo /var/cache/pbo
    chown "root:$JUSER" "$CFGDIR"; chmod 0750 "$CFGDIR"
fi

echo "==> Config"
EXAMPLE="$SRC/etc/config.example"; [[ "$ROLE" == janitor ]] && EXAMPLE="$SRC/etc/config.janitor.example"
install -m 0644 "$EXAMPLE" "$CFGDIR/config.example"
if [[ -f "$CFGDIR/config" ]]; then
    echo "    $CFGDIR/config already exists, left untouched."
elif [[ "$ROLE" == janitor ]]; then
    sed "s/^JANITOR_USER=.*/JANITOR_USER=$JUSER/" "$EXAMPLE" > "$CFGDIR/config"
    chown "root:$JUSER" "$CFGDIR/config"; chmod 0640 "$CFGDIR/config"
    echo "    created $CFGDIR/config (0640 root:$JUSER), EDIT it: repo path, password file."
else
    install -m 0600 "$SRC/etc/config.example" "$CFGDIR/config"
    echo "    created $CFGDIR/config (0600), run '$BIN setup' or EDIT it."
fi

if [[ "$ROLE" == janitor ]]; then
    echo "==> systemd units (installed, NOT enabled)"
    sed "s/^User=.*/User=$JUSER/; s/^Group=.*/Group=$JUSER/" "$SRC/systemd/pbo-janitor.service" > "$UNITDIR/pbo-janitor.service"
    chmod 0644 "$UNITDIR/pbo-janitor.service"
    install -m 0644 "$SRC/systemd/pbo-janitor.timer" "$UNITDIR/pbo-janitor.timer"
    systemctl daemon-reload
    cat <<EOF

Installed: pbo janitor (runs as $JUSER).

  1. Edit $CFGDIR/config: RESTIC_OFFSITE_REPO = the repo directory on this disk.
  2. Put the repo password in $CFGDIR/restic-pass, chown $JUSER, chmod 0400.
  3. Check it:   $BIN doctor        (drops to $JUSER by itself)
  4. Enable it:  systemctl enable --now pbo-janitor.timer   (daily 12:30)

Started as root, pbo re-execs itself as $JUSER (JANITOR_USER in the config), so
plain "$BIN doctor" is fine.
EOF
    exit 0
fi

echo "==> systemd units (installed, NOT enabled)"
install -m 0644 "$SRC/systemd/pbo.service"       "$UNITDIR/pbo.service"
install -m 0644 "$SRC/systemd/pbo.timer"         "$UNITDIR/pbo.timer"
install -m 0644 "$SRC/systemd/pbo-prune.service" "$UNITDIR/pbo-prune.service"
install -m 0644 "$SRC/systemd/pbo-prune.timer"   "$UNITDIR/pbo-prune.timer"
install -m 0644 "$SRC/systemd/pbo-verify.service" "$UNITDIR/pbo-verify.service"
install -m 0644 "$SRC/systemd/pbo-verify.timer"   "$UNITDIR/pbo-verify.timer"
systemctl daemon-reload

cat <<EOF

Installed: pbo (Proxmox Backup Offsite).

  Setup:      $BIN setup      guided wizard: SSH key, SFTP target, repo, DR key,
                              retention, guests, and (offered) the timers — everything.
  Interface:  $BIN menu       open the interactive prompt
  Health:     $BIN doctor     check repo, timer, key perms, per-guest age

The wizard offers to enable the schedule at the end. To do it by hand instead:
  systemctl enable --now pbo.timer         (backups, 05:00 nightly)
  systemctl enable --now pbo-prune.timer   (prune, Sun 06:30)
  systemctl enable --now pbo-verify.timer  (integrity, Wed 10:00, 1/12 of the data per run)

Uninstall: remove $LIBDIR, $BIN, units in $UNITDIR. Config/creds in $CFGDIR are kept.
EOF

# --- interactive first-run setup (only on a real terminal) ---
if [[ -t 0 && -t 1 ]]; then
    printf '\n'
    read -r -p "Run the interactive setup wizard now? [Y/n] " _ans
    if [[ -z "$_ans" || "$_ans" == [Yy]* ]]; then
        "$BIN" setup
    else
        echo "OK, run '$BIN setup' whenever you're ready."
    fi
else
    echo "Non-interactive install, run '$BIN setup' to configure."
fi
