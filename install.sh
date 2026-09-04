#!/usr/bin/env bash
# install.sh — installerar lxc-offsite på en Proxmox-host. Idempotent.
# Enablar ALDRIG timern automatiskt (skriver ut hur du gör det själv).
#
# Kör som root på hosten:  ./install.sh
set -Eeuo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIBDIR=/usr/local/lib/lxc-offsite
BIN=/usr/local/sbin/lxc-offsite
CFGDIR=/etc/lxc-offsite
UNITDIR=/etc/systemd/system

die(){ printf 'install: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || die "måste köras som root."

echo "==> Beroenden"
need=(); for b in rclone jq zstd flock curl; do command -v "$b" >/dev/null 2>&1 || need+=("$b"); done
if [[ "${#need[@]}" -gt 0 ]]; then
    echo "    installerar: ${need[*]}"
    apt-get update -qq && apt-get install -y "${need[@]}"
else
    echo "    alla finns (rclone jq zstd flock curl)"
fi
for b in vzdump pct zfs; do command -v "$b" >/dev/null 2>&1 || echo "    VARNING: '$b' saknas — krävs på en riktig Proxmox-host."; done

echo "==> Programfiler → $LIBDIR"
install -d -m 0755 "$LIBDIR" "$LIBDIR/lib"
install -m 0755 "$SRC/lxc-offsite" "$LIBDIR/lxc-offsite"
install -m 0644 "$SRC"/lib/*.sh "$LIBDIR/lib/"
ln -sf "$LIBDIR/lxc-offsite" "$BIN"
echo "    $BIN → $LIBDIR/lxc-offsite"

echo "==> Kataloger"
install -d -m 0755 /var/log/lxc-offsite /var/lib/lxc-offsite /var/lib/lxc-offsite/jobs
install -d -m 0700 "$CFGDIR"

echo "==> Config"
install -m 0644 "$SRC/etc/config.example" "$CFGDIR/config.example"
if [[ -f "$CFGDIR/config" ]]; then
    echo "    $CFGDIR/config finns redan — rörs inte."
else
    install -m 0600 "$SRC/etc/config.example" "$CFGDIR/config"
    echo "    skapade $CFGDIR/config (0600) — REDIGERA den."
fi
[[ -f "$CFGDIR/rclone.conf" ]] && echo "    $CFGDIR/rclone.conf finns." \
    || echo "    OBS: $CFGDIR/rclone.conf saknas — lägg dit din rclone-nyckel (0600)."

echo "==> Web console (FastAPI)"
apt-get install -y -qq python3-venv >/dev/null 2>&1 || echo "    (kunde ej apt-installera python3-venv — antar att venv finns)"
install -d -m 0755 /opt/lxc-offsite/api /opt/lxc-offsite/web
install -m 0644 "$SRC"/api/app.py "$SRC"/api/requirements.txt /opt/lxc-offsite/api/
install -m 0644 "$SRC"/web/index.html /opt/lxc-offsite/web/index.html
[[ -d /opt/lxc-offsite/api/venv ]] || python3 -m venv /opt/lxc-offsite/api/venv
/opt/lxc-offsite/api/venv/bin/pip install -q --upgrade pip >/dev/null 2>&1 || true
/opt/lxc-offsite/api/venv/bin/pip install -q -r /opt/lxc-offsite/api/requirements.txt
echo "    console → /opt/lxc-offsite/{api,web}"

echo "==> TUI (Textual — primärt gränssnitt)"
install -d -m 0755 /opt/lxc-offsite/tui
install -m 0644 "$SRC"/tui/lxco_tui.py "$SRC"/tui/lxco.tcss "$SRC"/tui/requirements.txt /opt/lxc-offsite/tui/
[[ -d /opt/lxc-offsite/tui/venv ]] || python3 -m venv /opt/lxc-offsite/tui/venv
/opt/lxc-offsite/tui/venv/bin/pip install -q --upgrade pip >/dev/null 2>&1 || true
/opt/lxc-offsite/tui/venv/bin/pip install -q -r /opt/lxc-offsite/tui/requirements.txt
echo "    TUI → 'lxc-offsite tui'  (whiptail-fallback: 'tui --simple')"

echo "==> systemd-units (installeras, enablas EJ)"
install -m 0644 "$SRC/systemd/lxc-offsite.service" "$UNITDIR/lxc-offsite.service"
install -m 0644 "$SRC/systemd/lxc-offsite.timer"   "$UNITDIR/lxc-offsite.timer"
install -m 0644 "$SRC/systemd/lxc-offsite-api.service" "$UNITDIR/lxc-offsite-api.service"
systemctl daemon-reload

cat <<EOF

Installed: lxc-offsite (PBO · Proxmox Backup Offsite).

  Setup:      $BIN setup     — guided config (engine/cache/sftp/password/mode/ntfy → init)
  Interface:  $BIN menu      — interactive prompt-CLI (guests/backup/restore/status)
  Schedule:   systemctl enable --now lxc-offsite.timer   (runs 05:00 nightly)

Uninstall: remove $LIBDIR, $BIN, units in $UNITDIR. Config/creds in $CFGDIR are kept.
EOF

# --- interactive first-run setup (only on a real terminal) ---
if [[ -t 0 && -t 1 ]]; then
    printf '\n'
    read -r -p "Run the interactive setup wizard now? [Y/n] " _ans
    if [[ -z "$_ans" || "$_ans" == [Yy]* ]]; then
        "$BIN" setup
    else
        echo "OK — run '$BIN setup' whenever you're ready."
    fi
else
    echo "Non-interactive install — run '$BIN setup' to configure."
fi
