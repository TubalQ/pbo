#!/usr/bin/env bash
# packaging/build-deb.sh: build the .deb packages with plain dpkg-deb.
#   packaging/build-deb.sh [outdir]     (default: ./dist)
#   pbo_<version>_all.deb              standalone pbo
#   pbo-pve-storage_<version>_all.deb  the Proxmox integration (ADR 0006/0007)
# Layout: /usr/lib/pbo (program + lib), /usr/sbin/pbo, systemd units in
# /usr/lib/systemd/system. The config is never shipped as a conffile: postinst
# creates /etc/pbo and leaves the config to `pbo setup`, the way install.sh
# does (the examples are in /usr/share/doc/pbo/examples).
set -Eeuo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$SRC/dist}"
VER="$(sed -n 's/^readonly VERSION="\(.*\)"$/\1/p' "$SRC/pbo")"
[[ -n "$VER" ]] || { echo "cannot read VERSION from pbo" >&2; exit 1; }
DEBVER="${VER//-/\~}"   # 0.2.0-dev → 0.2.0~dev sorts before 0.2.0
ROOT="$(mktemp -d)"; PROOT="$(mktemp -d)"; chmod 0755 "$ROOT" "$PROOT"
trap 'rm -rf "$ROOT" "$PROOT"' EXIT
# unit files point at the install.sh paths; packages use /usr/lib/pbo and /usr/sbin
unit_rewrite() { sed 's#/usr/local/lib/pbo/#/usr/lib/pbo/#g; s#/usr/local/sbin/pbo#/usr/sbin/pbo#g' "$1"; }

install -d "$ROOT/DEBIAN" "$ROOT/usr/lib/pbo/lib" "$ROOT/usr/sbin" \
           "$ROOT/usr/lib/systemd/system" "$ROOT/usr/share/doc/pbo/examples"
install -m 0755 "$SRC/pbo" "$ROOT/usr/lib/pbo/pbo"
install -m 0644 "$SRC"/lib/*.sh "$ROOT/usr/lib/pbo/lib/"
ln -s ../lib/pbo/pbo "$ROOT/usr/sbin/pbo"
for u in "$SRC"/systemd/*.service "$SRC"/systemd/*.timer; do
    case "$(basename "$u")" in pbo-catalog.*|pbo-mount.*) continue ;; esac   # Proxmox integration: the pbo-pve-storage package
    unit_rewrite "$u" > "$ROOT/usr/lib/systemd/system/$(basename "$u")"
    chmod 0644 "$ROOT/usr/lib/systemd/system/$(basename "$u")"
done
install -m 0644 "$SRC"/etc/config.example "$SRC"/etc/config.janitor.example "$ROOT/usr/share/doc/pbo/examples/"
install -d "$ROOT/etc/logrotate.d"; install -m 0644 "$SRC/etc/logrotate.d/pbo" "$ROOT/etc/logrotate.d/pbo"
install -d "$ROOT/usr/share/pbo/templates"; install -m 0644 "$SRC"/templates/pbo-*.hbs "$ROOT/usr/share/pbo/templates/"
install -m 0644 "$SRC"/README.md "$SRC"/RUNBOOK.md "$SRC"/SECURITY.md "$SRC"/CHANGELOG.md "$ROOT/usr/share/doc/pbo/"
install -m 0644 "$SRC"/LICENSE "$ROOT/usr/share/doc/pbo/copyright"

# restic >= 0.14.0: the default of RESTIC_MIN (lib/config_schema.sh; doctor and
# install.sh check the config's own minimum). acl: setfacl/getfacl for the
# CACHE_DIR entry of unprivileged CTs; util-linux: flock, setpriv, findmnt.
cat > "$ROOT/DEBIAN/control" <<CTL
Package: pbo
Version: $DEBVER
Architecture: all
Maintainer: TubalQ <71977914+TubalQ@users.noreply.github.com>
Depends: bash (>= 5), restic (>= 0.14.0), jq, zstd, util-linux, acl, curl, openssl, openssh-client
Suggests: proxmox-ve
Breaks: pbo-web
Section: admin
Priority: optional
Homepage: https://github.com/TubalQ/pbo
Description: offsite backup of Proxmox guests with restic
 pbo runs vzdump, stores the archive in a restic repository and copies it
 offsite over SFTP or to an append-only rest-server. Restore always goes to a
 new vmid. Also runs as a janitor next to an append-only repo.
CTL
echo /etc/logrotate.d/pbo > "$ROOT/DEBIAN/conffiles"
cat > "$ROOT/DEBIAN/postinst" <<'PI'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    install -d -m 0700 /etc/pbo
    install -d -m 0755 /var/log/pbo /var/lib/pbo /var/lib/pbo/jobs
    # pbo 0.6 reads the config instead of sourcing it: name the lines it
    # refuses (every command then stops with 78) or warns about. Reported only:
    # dpkg cannot stop an upgrade that is already unpacked (install.sh refuses
    # before changing anything).
    if [ -f /etc/pbo/config ]; then
        rc=0; out="$(/usr/sbin/pbo config check 2>&1)" || rc=$?
        if [ "$rc" != 0 ] || printf '%s\n' "$out" | grep -q -e ': warning: '; then
            echo "pbo: 'pbo config check' on /etc/pbo/config (exit $rc):"
            printf '%s\n' "$out" | sed 's/^/    /'
        fi
    fi
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
    # the timer schedules of an existing config (SCHEDULE_*) as drop-ins next to
    # the units: drop-ins in /etc survive an upgrade, this re-applies a config
    # edited by hand. Reported only, like the config check.
    if [ -f /etc/pbo/config ]; then
        rc=0; out="$(/usr/sbin/pbo timers apply 2>&1)" || rc=$?
        [ "$rc" = 0 ] || { echo "pbo: 'pbo timers apply' (exit $rc):"; printf '%s\n' "$out" | sed 's/^/    /'; }
    fi
    # the permission table on the files an earlier install left (an existing
    # config, the DR key, the directories), as install.sh does: through
    # `pbo doctor --fix --perms-only`, only when a config exists (without one
    # there is nothing of the operator's to fix yet). Reported only: it never
    # fails the install (pbo doctor --fix can run any time).
    if [ -f /etc/pbo/config ]; then
        rc=0; out="$(/usr/sbin/pbo doctor --fix --perms-only 2>&1)" || rc=$?
        [ -z "$out" ] || { echo "pbo: 'pbo doctor --fix --perms-only':"; printf '%s\n' "$out" | sed 's/^/    /'; }
        [ "$rc" = 0 ] || echo "pbo: the permission check reported problems (exit $rc); fix them, then run 'pbo doctor --fix'."
    fi
    # Proxmox notification templates, cluster-wide via pmxcfs (plain cp, no chmod)
    if [ -d /etc/pve ]; then
        mkdir -p /etc/pve/notification-templates/default 2>/dev/null \
            && cp /usr/share/pbo/templates/pbo-*.hbs /etc/pve/notification-templates/default/ 2>/dev/null \
            || echo "pbo: could not install notification templates into /etc/pve (no quorum?)"
    fi
    echo "pbo: run 'pbo setup' (PVE host) or see /usr/share/doc/pbo/examples/config.janitor.example (janitor). Timers are not enabled."
    echo "pbo: on a janitor, ./install.sh --janitor --user <rest-server user> sets the unit's User= and the state/log ownership;"
    echo "     with only this package, do it by hand (systemctl edit pbo-janitor.service; chown <user> /var/lib/pbo /var/log/pbo)."
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

# --- pbo-pve-storage (all): the Proxmox VE integration ------------------------
# The storage plugin, the catalogue and mount units, and the vzdump hook.
# Installing it changes nothing in PVE's configuration: postinst never edits
# storage.cfg or vzdump.conf (`pbo integrate enable` does), and prerm
# refuses removal while a pbo storage or the pbo hook is configured, since PVE
# would drop the storage.cfg section or fail every vzdump run.
install -d "$PROOT/DEBIAN" "$PROOT/usr/share/perl5/PVE/Storage/Custom" "$PROOT/usr/lib/systemd/system" \
           "$PROOT/usr/share/doc/pbo-pve-storage"
install -m 0644 "$SRC/pve-plugin/PboPlugin.pm" "$PROOT/usr/share/perl5/PVE/Storage/Custom/PboPlugin.pm"
for u in pbo-catalog.service pbo-catalog.timer pbo-mount.service; do
    unit_rewrite "$SRC/systemd/$u" > "$PROOT/usr/lib/systemd/system/$u"
    chmod 0644 "$PROOT/usr/lib/systemd/system/$u"
done
# the vzdump hook (ADR 0006 amendment 8): `pbo integrate enable` names it in vzdump.conf
install -d "$PROOT/usr/lib/pbo"; install -m 0755 "$SRC/lib/vzdump-hook" "$PROOT/usr/lib/pbo/vzdump-hook"
install -m 0644 "$SRC"/LICENSE "$PROOT/usr/share/doc/pbo-pve-storage/copyright"
cat > "$PROOT/DEBIAN/control" <<CTL
Package: pbo-pve-storage
Version: $DEBVER
Architecture: all
Maintainer: TubalQ <71977914+TubalQ@users.noreply.github.com>
Depends: pbo (= $DEBVER), libpve-storage-perl (>= 9.1.18), pve-manager (>= 9.2.29)
Section: admin
Priority: optional
Homepage: https://github.com/TubalQ/pbo
Description: Proxmox VE storage plugin for pbo
 Adds the storage type 'pbo' to Proxmox VE: pbo's restic snapshots show up as
 ordinary vzdump archives that the GUI lists, shows and restores, and PVE
 backup jobs can write to it (pbo ingests each archive). Nothing in PVE can
 delete a pbo backup; retention stays with pbo. Installing the package does not
 add a storage: run 'pbo integrate enable both' (or integrated).
CTL
# pve-manager restarts pvedaemon, pveproxy, pvestatd and pvescheduler on this
# trigger, so they load (or unload) the plugin.
echo "activate-noawait pve-api-updates" > "$PROOT/DEBIAN/triggers"
cat > "$PROOT/DEBIAN/postinst" <<'PI'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
    echo "pbo-pve-storage: plugin installed; storage.cfg was not changed."
    echo "pbo-pve-storage: run 'pbo integrate enable both' (or integrated) to add the pbo storage."
fi
PI
cat > "$PROOT/DEBIAN/prerm" <<'PR'
#!/bin/sh
set -e
# Refuse removal while PVE still uses the integration: without the plugin, PVE
# skips the 'pbo:' section of storage.cfg and drops it on the next write, and a
# vzdump.conf script: pointing at a missing hook fails every backup on the node.
HOOK=/usr/lib/pbo/vzdump-hook   # this package's hook (install.sh hosts use /usr/local/lib/pbo)
case "$1" in
    remove|deconfigure)
        if grep -q '^pbo: ' /etc/pve/storage.cfg 2>/dev/null; then
            echo "pbo-pve-storage: a storage of type pbo is still configured in /etc/pve/storage.cfg;" >&2
            echo "pbo-pve-storage: run 'pbo integrate disable' first. Nothing was removed." >&2
            exit 1
        fi
        if grep -Eq "^[[:space:]]*script:[[:space:]]*${HOOK}([[:space:]]|\$)" /etc/vzdump.conf 2>/dev/null; then
            echo "pbo-pve-storage: /etc/vzdump.conf still runs the pbo hook (script: $HOOK);" >&2
            echo "pbo-pve-storage: run 'pbo integrate disable' first. Nothing was removed." >&2
            exit 1
        fi
        ;;
esac
exit 0
PR
cat > "$PROOT/DEBIAN/postrm" <<'PR'
#!/bin/sh
set -e
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
PR
chmod 0755 "$PROOT/DEBIAN/postinst" "$PROOT/DEBIAN/prerm" "$PROOT/DEBIAN/postrm"
pdeb="$OUT/pbo-pve-storage_${DEBVER}_all.deb"
dpkg-deb --root-owner-group -Zxz --build "$PROOT" "$pdeb" >/dev/null
( cd "$OUT" && sha256sum "$(basename "$pdeb")" > "$(basename "$pdeb").sha256" )
echo "$pdeb"
