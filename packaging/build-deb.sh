#!/usr/bin/env bash
# packaging/build-deb.sh: build pbo_<version>_all.deb with plain dpkg-deb.
#   packaging/build-deb.sh [outdir]     (default: ./dist)
# Layout: /usr/lib/pbo (program + lib), /usr/sbin/pbo, systemd units in
# /usr/lib/systemd/system. The config is never shipped as a conffile: postinst
# creates /etc/pbo and leaves it to `pbo setup`, the way install.sh does.
set -Eeuo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$SRC/dist}"
VER="$(sed -n 's/^readonly VERSION="\(.*\)"$/\1/p' "$SRC/pbo")"
[[ -n "$VER" ]] || { echo "cannot read VERSION from pbo" >&2; exit 1; }
DEBVER="${VER//-/\~}"   # 0.2.0-dev → 0.2.0~dev sorts before 0.2.0
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

install -d "$ROOT/DEBIAN" "$ROOT/usr/lib/pbo/lib" "$ROOT/usr/sbin" \
           "$ROOT/usr/lib/systemd/system" "$ROOT/usr/share/doc/pbo/examples"
install -m 0755 "$SRC/pbo" "$ROOT/usr/lib/pbo/pbo"
install -m 0644 "$SRC"/lib/*.sh "$ROOT/usr/lib/pbo/lib/"
ln -s ../lib/pbo/pbo "$ROOT/usr/sbin/pbo"
for u in "$SRC"/systemd/*.service "$SRC"/systemd/*.timer; do
    sed 's#/usr/local/lib/pbo/#/usr/lib/pbo/#g' "$u" > "$ROOT/usr/lib/systemd/system/$(basename "$u")"
    chmod 0644 "$ROOT/usr/lib/systemd/system/$(basename "$u")"
done
install -m 0644 "$SRC"/etc/config.example "$SRC"/etc/config.janitor.example "$ROOT/usr/share/doc/pbo/examples/"
install -m 0644 "$SRC"/README.md "$SRC"/RUNBOOK.md "$SRC"/SECURITY.md "$SRC"/CHANGELOG.md "$ROOT/usr/share/doc/pbo/"
install -m 0644 "$SRC"/LICENSE "$ROOT/usr/share/doc/pbo/copyright"

cat > "$ROOT/DEBIAN/control" <<CTL
Package: pbo
Version: $DEBVER
Architecture: all
Maintainer: TubalQ <71977914+TubalQ@users.noreply.github.com>
Depends: bash (>= 5), restic (>= 0.16), jq, zstd, util-linux, curl, openssl, openssh-client
Suggests: proxmox-ve
Section: admin
Priority: optional
Homepage: https://github.com/TubalQ/PBO
Description: offsite backup of Proxmox guests with restic
 pbo runs vzdump, stores the archive in a restic repository and copies it
 offsite over SFTP or to an append-only rest-server. Restore always goes to a
 new vmid. Also runs as a janitor next to an append-only repo.
CTL
cat > "$ROOT/DEBIAN/postinst" <<'PI'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    install -d -m 0700 /etc/pbo
    install -d -m 0755 /var/log/pbo /var/lib/pbo /var/lib/pbo/jobs
    [ -e /etc/pbo/config.example ] || cp /usr/share/doc/pbo/examples/config.example /etc/pbo/config.example
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
    echo "pbo: run 'pbo setup' (PVE host) or see /usr/share/doc/pbo/examples/config.janitor.example (janitor). Timers are not enabled."
fi
PI
cat > "$ROOT/DEBIAN/postrm" <<'PR'
#!/bin/sh
set -e
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
# purge keeps /etc/pbo: it holds the DR key, and losing it loses the backups.
if [ "$1" = purge ]; then echo "pbo: /etc/pbo left in place (DR key). Remove it yourself when you're sure."; fi
PR
chmod 0755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/postrm"

mkdir -p "$OUT"
deb="$OUT/pbo_${DEBVER}_all.deb"
dpkg-deb --root-owner-group -Zxz --build "$ROOT" "$deb" >/dev/null
( cd "$OUT" && sha256sum "$(basename "$deb")" > "$(basename "$deb").sha256" )
echo "$deb"
