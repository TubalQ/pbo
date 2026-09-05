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

echo "==> Dependencies"
need=(); for b in restic jq zstd flock curl; do command -v "$b" >/dev/null 2>&1 || need+=("$b"); done
if [[ "${#need[@]}" -gt 0 ]]; then
    echo "    installing: ${need[*]}"
    apt-get update -qq && apt-get install -y "${need[@]}"
else
    echo "    all present (restic jq zstd flock curl)"
fi
for b in vzdump pct qm zfs; do command -v "$b" >/dev/null 2>&1 || echo "    WARNING: '$b' missing, required on a real Proxmox host."; done

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

echo "==> Config"
install -m 0644 "$SRC/etc/config.example" "$CFGDIR/config.example"
if [[ -f "$CFGDIR/config" ]]; then
    echo "    $CFGDIR/config already exists, left untouched."
else
    install -m 0600 "$SRC/etc/config.example" "$CFGDIR/config"
    echo "    created $CFGDIR/config (0600), run '$BIN setup' or EDIT it."
fi

echo "==> systemd units (installed, NOT enabled)"
install -m 0644 "$SRC/systemd/pbo.service" "$UNITDIR/pbo.service"
install -m 0644 "$SRC/systemd/pbo.timer"   "$UNITDIR/pbo.timer"
systemctl daemon-reload

cat <<EOF

Installed: pbo (Proxmox Backup Offsite).

  Setup:      $BIN setup      run the guided config wizard
  Interface:  $BIN menu       open the interactive prompt
  Schedule:   systemctl enable --now pbo.timer   (runs 05:00 nightly)

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
