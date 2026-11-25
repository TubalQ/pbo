#!/usr/bin/env bash
# install.sh: installs pbo on a Proxmox host. Idempotent.
# NEVER enables the timer automatically (it prints how to do that yourself).
#
# Run as root on the host:  ./install.sh [--integration standalone|both|integrated] [--force]
#                           ./install.sh --janitor [--user <name>] [--force]
#
# --integration (ADR 0007): how pbo works with Proxmox VE.
#   standalone  pbo.timer backs up every guest (the default, as before 0.5)
#   both        PVE backup jobs to the `pbo` storage own the guests they select,
#               pbo.timer backs up the rest
#   integrated  only PVE backup jobs back up guests
# Resolution: the flag, else PBO_INTEGRATION in the existing config (kept), else
# a question on a terminal, else standalone. For both/integrated the PVE
# versions are checked before any file is copied; then the storage plugin, the
# vzdump hook and the catalogue/mount units are installed (not enabled). The
# storage itself is never created here: `pbo integrate enable` (or `pbo setup`)
# does that once the repo exists. An explicit `--integration standalone` on a
# host whose config is both/integrated runs `pbo integrate disable` first, then
# removes the plugin.
#
# Everything is in functions; main runs only when the script is executed, so
# tests/install.sh can source it. PBO_INSTALL_TEST=1 (tests only) lets these be
# overridden: PBO_INSTALL_CFGDIR, PBO_INSTALL_PLUGIN_DIR, PBO_INSTALL_STORAGE_CFG, PBO_INSTALL_SYSTEMCTL,
# PBO_INSTALL_DPKG_QUERY, PBO_INSTALL_PLUGIN_CHECK, PBO_INSTALL_TTY (0|1),
# PBO_INSTALL_LIBDIR, PBO_INSTALL_UNITDIR, PBO_INSTALL_SHARED_CFG (the
# cluster-shared config; none in test mode unless set), PBO_INSTALL_PBO (the pbo
# inst_perms runs).
#
# Upgrade guard (0.6, ADR 0009): before any file is replaced, the existing
# config is read with the strict reader of this source tree, the way pbo 0.6
# reads it instead of sourcing it (inst_config_guard). A line it refuses stops
# the install with "nothing was changed": the pbo it would install stops on
# that config (every command and timer exits 78). --force installs anyway.
#
# pbo-web (the web UI of 0.4) is gone since 0.5.0: the Proxmox GUI (with the
# integration) and the CLI cover it. An install over 0.4 removes a pbo-web that
# install.sh put there (inst_web_remove).

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIBDIR=/usr/local/lib/pbo
BIN=/usr/local/sbin/pbo
CFGDIR=/etc/pbo
UNITDIR=/etc/systemd/system
PLUGIN_DIR=/usr/share/perl5/PVE/Storage/Custom
SYSTEMCTL=systemctl
DPKG_QUERY=dpkg-query
STORAGE_CFG=/etc/pve/storage.cfg
SHARED_CFG=/etc/pve/pbo/config
if [[ "${PBO_INSTALL_TEST:-0}" == 1 ]]; then
    CFGDIR="${PBO_INSTALL_CFGDIR:-$CFGDIR}"
    SHARED_CFG="${PBO_INSTALL_SHARED_CFG:-}"
    STORAGE_CFG="${PBO_INSTALL_STORAGE_CFG:-$STORAGE_CFG}"
    PLUGIN_DIR="${PBO_INSTALL_PLUGIN_DIR:-$PLUGIN_DIR}"
    SYSTEMCTL="${PBO_INSTALL_SYSTEMCTL:-$SYSTEMCTL}"
    DPKG_QUERY="${PBO_INSTALL_DPKG_QUERY:-$DPKG_QUERY}"
    LIBDIR="${PBO_INSTALL_LIBDIR:-$LIBDIR}"
    UNITDIR="${PBO_INSTALL_UNITDIR:-$UNITDIR}"
fi
PLUGIN_FILE="$PLUGIN_DIR/PboPlugin.pm"
# the minimums of the Proxmox integration (lib/integrate.sh, the pbo-pve-storage package)
MIN_PVE_MANAGER=9.2.29
MIN_LIBPVE_STORAGE=9.1.18
# PVE daemons that load storage plugins (pve-manager's trigger on /usr/share/perl5/PVE)
PVE_DAEMONS=(pvedaemon pveproxy pvestatd pvescheduler)

ROLE=host; JUSER=restic; INTEGRATION=""; MODE=""; MODE_SOURCE=""; MODE_NOTE=""; CFG_MODE=""; FORCE=0

die(){ printf 'install: %s\n' "$*" >&2; exit 1; }

# inst_parse_args "$@": ROLE, JUSER, INTEGRATION (the flag, empty when not given),
# FORCE (--force: install over a config the strict reader refuses).
inst_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --janitor) ROLE=janitor; shift ;;
            --user)    [[ $# -ge 2 ]] || die "--user needs a name"; JUSER="$2"; shift 2 ;;
            --integration|--mode)   # --mode: an undocumented alias
                [[ $# -ge 2 ]] || die "$1 needs standalone|both|integrated"
                INTEGRATION="$2"; shift 2 ;;
            --integration=*|--mode=*) INTEGRATION="${1#*=}"; shift ;;
            --force) FORCE=1; shift ;;
            *) die "unknown flag: $1 (use [--integration standalone|both|integrated] or --janitor [--user <name>], and --force)" ;;
        esac
    done
    if [[ -n "$INTEGRATION" ]]; then
        case "$INTEGRATION" in
            standalone|both|integrated) ;;
            *) die "--integration must be standalone, both or integrated (got '$INTEGRATION')" ;;
        esac
    fi
    if [[ "$ROLE" == janitor && -n "$INTEGRATION" && "$INTEGRATION" != standalone ]]; then
        die "--integration $INTEGRATION cannot be combined with --janitor: a janitor has no Proxmox, it is always standalone"
    fi
    return 0
}

# inst_version_ge <a> <b>: a >= b in Debian version order.
inst_version_ge() {
    if command -v dpkg >/dev/null 2>&1; then dpkg --compare-versions "$1" ge "$2"
    else [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]; fi
}

# inst_pkg_version <package> → the installed version, empty when not installed.
inst_pkg_version() { "$DPKG_QUERY" -W -f='${Version}' "$1" 2>/dev/null || true; }

# inst_version_refusal → the refusal text when the PVE versions are too old
# (or not installed), empty when the integration can be installed.
inst_version_refusal() {
    local pm ls
    pm="$(inst_pkg_version pve-manager)"; ls="$(inst_pkg_version libpve-storage-perl)"
    if [[ -n "$pm" && -n "$ls" ]] && inst_version_ge "$pm" "$MIN_PVE_MANAGER" && inst_version_ge "$ls" "$MIN_LIBPVE_STORAGE"; then
        return 0
    fi
    printf 'Proxmox integration needs pve-manager >= %s and libpve-storage-perl >= %s (installed: %s, %s). Nothing was changed. Upgrade Proxmox VE first, or install with --integration standalone.' \
        "$MIN_PVE_MANAGER" "$MIN_LIBPVE_STORAGE" "${pm:-not installed}" "${ls:-not installed}"
}

# inst_cfg_reader: the strict config reader of this source tree
# (lib/config_parse.sh, with the schema it checks keys against). install.sh
# reads the existing config with it and never sources it.
inst_cfg_reader() {
    declare -F _cfg_parse_file >/dev/null && return 0
    # shellcheck source=lib/config_schema.sh
    source "$SRC/lib/config_schema.sh"
    # shellcheck source=lib/config_parse.sh
    source "$SRC/lib/config_parse.sh"
}

# inst_config_mode [<config>] → PBO_INTEGRATION from the existing config (read,
# never sourced), empty when the file or the key is missing or the value invalid.
# The last assignment the reader accepts counts, as when pbo loads the file.
inst_config_mode() {
    local f="${1:-$CFGDIR/config}" v
    [[ -r "$f" ]] || return 0
    inst_cfg_reader
    _cfg_reset; declare -gA CFG_ENV=()
    _cfg_parse_file "$f" local || true
    v="${CFG_VAL[PBO_INTEGRATION]:-}"
    case "$v" in standalone|both|integrated) printf '%s' "$v" ;; esac
}

# inst_config_guard: before any file is replaced, read the existing config
# (the cluster-shared file, then the local one, as pbo merges them) with the
# strict reader of the version being installed. A line it refuses stops the
# install before anything is changed: the installed pbo would stop on it (exit
# 78 for every command, timer and vzdump hook). The errors are listed, with
# the migration hint for a file bash accepts. --force (FORCE=1) installs anyway,
# with a warning. A line the reader accepts but pbo ignores (an exec or
# local-only key in the shared file) does not stop pbo: named, not refused.
inst_config_guard() {
    local e f bashok=()
    inst_cfg_reader
    _cfg_reset
    declare -gA CFG_ENV=()   # the units start pbo with a clean environment
    if [[ -n "$SHARED_CFG" && -f "$SHARED_CFG" ]]; then
        PBO_CONFIG_FILES+=("$SHARED_CFG"); _cfg_parse_file "$SHARED_CFG" shared || true
    fi
    if [[ -f "$CFGDIR/config" ]]; then
        PBO_CONFIG_FILES+=("$CFGDIR/config"); _cfg_parse_file "$CFGDIR/config" local || true
    fi
    if (( ${#CFG_IGNORED[@]} )); then
        echo "==> Config: lines pbo ignores (doctor reports them as FAIL)"
        for e in "${CFG_IGNORED[@]}"; do echo "    $e"; done
    fi
    (( ${#CFG_ERRORS[@]} )) || return 0
    echo "==> Config: read the way pbo 0.6 reads it (KEY=VALUE, not run as shell code)"
    for e in "${CFG_ERRORS[@]}"; do echo "    $e"; done
    for f in "${PBO_CONFIG_FILES[@]}"; do
        [[ " ${CFG_ERRORS[*]}" == *" $f:"* ]] || continue
        bash -n -- "$f" 2>/dev/null && bashok+=("$f")
    done
    for f in "${bashok[@]+"${bashok[@]}"}"; do
        echo "    $f is valid bash, but pbo 0.6 no longer runs the config as code; see the 0.6.0 migration notes in CHANGELOG.md"
    done
    if [[ "$FORCE" == 1 ]]; then
        echo "    WARNING: --force: installing anyway. Every pbo command stops on this config (exit 78) until the lines above are fixed ('$BIN config check' names each one)."
        return 0
    fi
    die "the installed pbo would refuse this config (above). Nothing was changed. Fix the lines (each KEY=VALUE, see CHANGELOG.md), check with '$SRC/pbo config check --file <file>', then run install.sh again (or with --force to install anyway)."
}

# inst_is_tty: a person at a terminal (PBO_INSTALL_TTY in test mode).
inst_is_tty() {
    if [[ "${PBO_INSTALL_TEST:-0}" == 1 && -n "${PBO_INSTALL_TTY:-}" ]]; then [[ "$PBO_INSTALL_TTY" == 1 ]]; return; fi
    [[ -t 0 && -t 1 ]]
}

# inst_resolve_mode: MODE, MODE_SOURCE (flag|config|prompt|default), MODE_NOTE,
# CFG_MODE (what the config says). Host only.
inst_resolve_mode() {
    CFG_MODE="$(inst_config_mode "$CFGDIR/config")"
    MODE_NOTE=""
    if [[ -n "$INTEGRATION" ]]; then
        MODE="$INTEGRATION"; MODE_SOURCE=flag
    elif [[ -n "$CFG_MODE" ]]; then
        MODE="$CFG_MODE"; MODE_SOURCE=config
        MODE_NOTE="keeping PBO_INTEGRATION=$CFG_MODE from $CFGDIR/config (change it with --integration)"
    elif inst_is_tty; then
        printf '\nHow should pbo work with Proxmox VE?\n'
        printf '  [1] standalone (default): pbo.timer backs up every guest, as before\n'
        printf '  [2] both: PVE backup jobs to the pbo storage own their guests, pbo.timer the rest\n'
        printf '  [3] integrated: only PVE backup jobs back up guests\n'
        local a; read -r -p "Choice [1]: " a || a=""
        case "${a:-1}" in
            1|standalone) MODE=standalone ;;
            2|both) MODE=both ;;
            3|integrated) MODE=integrated ;;
            *) die "no such choice: '$a' (1, 2 or 3)" ;;
        esac
        MODE_SOURCE=prompt
    else
        MODE=standalone; MODE_SOURCE=default
    fi
    return 0
}

# inst_plugin_loads: PVE::Storage loads the pbo plugin.
inst_plugin_loads() {
    if [[ "${PBO_INSTALL_TEST:-0}" == 1 && -n "${PBO_INSTALL_PLUGIN_CHECK:-}" ]]; then
        bash -c "$PBO_INSTALL_PLUGIN_CHECK" >/dev/null 2>&1; return
    fi
    perl -MPVE::Storage -e 'PVE::Storage::Plugin->lookup("pbo") or die' >/dev/null 2>&1
}

inst_reload_pve() {
    echo "    reloading the PVE daemons: ${PVE_DAEMONS[*]}"
    "$SYSTEMCTL" reload-or-restart "${PVE_DAEMONS[@]}" || echo "    WARNING: could not reload ${PVE_DAEMONS[*]}; run: systemctl reload-or-restart ${PVE_DAEMONS[*]}"
}

# inst_plugin_install: PboPlugin.pm into PLUGIN_DIR (0644) when it differs, load
# test, and a daemon reload only when the file changed. A plugin that does not
# load is removed again (the previous one, if any, is put back) and the install
# stops.
inst_plugin_install() {
    local new="$SRC/pve-plugin/PboPlugin.pm" changed=0 backup=""
    [[ -r "$new" ]] || die "missing $new"
    if [[ -f "$PLUGIN_FILE" ]] && cmp -s "$new" "$PLUGIN_FILE"; then
        echo "    $PLUGIN_FILE is up to date"
    else
        install -d -m 0755 "$PLUGIN_DIR"
        if [[ -f "$PLUGIN_FILE" ]]; then backup="$(mktemp)"; cp -p "$PLUGIN_FILE" "$backup"; fi
        install -m 0644 "$new" "$PLUGIN_FILE"
        changed=1
        echo "    storage plugin → $PLUGIN_FILE"
    fi
    if ! inst_plugin_loads; then
        if [[ -n "$backup" ]]; then install -m 0644 "$backup" "$PLUGIN_FILE"; rm -f "$backup"; echo "    the plugin did not load: the previous $PLUGIN_FILE is back"
        elif (( changed )); then rm -f "$PLUGIN_FILE"; echo "    the plugin did not load: $PLUGIN_FILE removed"; fi
        die "the pbo storage plugin does not load into PVE::Storage (perl -MPVE::Storage -e 'PVE::Storage::Plugin->lookup(\"pbo\")'). PVE was left with its previous plugins."
    fi
    [[ -n "$backup" ]] && rm -f "$backup"
    echo "    the plugin loads (PVE::Storage knows the type pbo)"
    (( changed )) && inst_reload_pve
    return 0
}

# inst_cfg_pbo_storages → the pbo storages still in storage.cfg, space separated.
inst_cfg_pbo_storages() {
    [[ -r "$STORAGE_CFG" ]] || return 0
    sed -nE 's/^pbo:[[:space:]]+([^[:space:]]+)[[:space:]]*$/\1/p' "$STORAGE_CFG" | paste -sd' ' -
}

# inst_plugin_remove: PboPlugin.pm out of PLUGIN_DIR, and a daemon reload. Never
# while storage.cfg has a pbo storage: PVE skips a section of an unknown type and
# drops it at the next write of storage.cfg.
inst_plugin_remove() {
    [[ -f "$PLUGIN_FILE" ]] || return 0
    local left; left="$(inst_cfg_pbo_storages)"
    [[ -z "$left" ]] || die "storage.cfg still has pbo storage(s) ($left): run 'pbo integrate disable' first. The plugin was not removed."
    rm -f "$PLUGIN_FILE"
    echo "    removed $PLUGIN_FILE"
    inst_reload_pve
}

# inst_integration_files: the hook and the units the integration needs (installed, not enabled).
inst_integration_files() {
    install -m 0755 "$SRC/lib/vzdump-hook" "$LIBDIR/vzdump-hook"
    echo "    vzdump hook → $LIBDIR/vzdump-hook"
    local u
    for u in pbo-catalog.service pbo-catalog.timer pbo-mount.service; do
        install -m 0644 "$SRC/systemd/$u" "$UNITDIR/$u"
    done
    echo "    units pbo-catalog.service, pbo-catalog.timer, pbo-mount.service (not enabled)"
}

inst_deps() {
    echo "==> Dependencies"
    # restic jq zstd flock curl openssl: the tool + the setup wizard (openssl mints
    # the DR key). ssh/sftp/ssh-keygen/ssh-keyscan come from openssh-client, which
    # the wizard uses to make and pin an SSH key and to test the connection.
    declare -A pkg=( [restic]=restic [jq]=jq [zstd]=zstd [flock]=util-linux [curl]=curl
                     [openssl]=openssl [ssh-keygen]=openssh-client )
    local need=() b; for b in "${!pkg[@]}"; do command -v "$b" >/dev/null 2>&1 || need+=("${pkg[$b]}"); done
    if [[ "${#need[@]}" -gt 0 ]]; then
        # unique package list
        mapfile -t need < <(printf '%s\n' "${need[@]}" | sort -u)
        echo "    installing: ${need[*]}"
        apt-get update -qq && apt-get install -y "${need[@]}"
    else
        echo "    all present (restic jq zstd flock curl openssl openssh-client)"
    fi
    [[ "$ROLE" == janitor ]] || for b in vzdump pct qm zfs; do command -v "$b" >/dev/null 2>&1 || echo "    WARNING: '$b' missing, required on a real Proxmox host."; done
}

inst_program() {
    echo "==> Program files → $LIBDIR"
    install -d -m 0755 "$LIBDIR" "$LIBDIR/lib"
    install -m 0755 "$SRC/pbo" "$LIBDIR/pbo"
    install -m 0644 "$SRC"/lib/*.sh "$LIBDIR/lib/"
    ln -sf "$LIBDIR/pbo" "$BIN"
    echo "    $BIN → $LIBDIR/pbo"
    # Backward-compat: keep the old name working (pbo was formerly 'lxc-offsite').
    ln -sf "$LIBDIR/pbo" /usr/local/sbin/lxc-offsite
    echo "    /usr/local/sbin/lxc-offsite → $LIBDIR/pbo  (compat alias)"

    echo "==> logrotate"
    install -m 0644 "$SRC/etc/logrotate.d/pbo" /etc/logrotate.d/pbo
    # On a janitor /var/log/pbo belongs to $JUSER: rotate as that user, not as root
    # in a directory someone else controls.
    if [[ "$ROLE" == janitor ]]; then
        sed -i -e "s/create 0600 root root/create 0600 $JUSER $JUSER/" -e "/{\$/a\\    su $JUSER $JUSER" /etc/logrotate.d/pbo
    fi

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
    local example="$SRC/etc/config.example"; [[ "$ROLE" == janitor ]] && example="$SRC/etc/config.janitor.example"
    install -m 0644 "$example" "$CFGDIR/config.example"
    if [[ -f "$CFGDIR/config" ]]; then
        echo "    $CFGDIR/config already exists, left untouched."
    elif [[ "$ROLE" == janitor ]]; then
        sed "s/^JANITOR_USER=.*/JANITOR_USER=$JUSER/" "$example" > "$CFGDIR/config"
        chown "root:$JUSER" "$CFGDIR/config"; chmod 0640 "$CFGDIR/config"
        echo "    created $CFGDIR/config (0640 root:$JUSER), EDIT it: repo path, password file."
    else
        install -m 0600 "$SRC/etc/config.example" "$CFGDIR/config"
        echo "    created $CFGDIR/config (0600), run '$BIN setup' or EDIT it."
    fi
}

# inst_perms: the permission table (lib/perms.sh) applied once the files are in
# place, through the pbo just installed (`doctor --fix --perms-only`): the
# directories made above and whatever an older version left too open. On a
# janitor that pbo fixes as root and reports as the janitor user. Its findings
# are shown; it never fails the install (doctor can run again any time).
inst_perms() {
    echo "==> Permissions ($BIN doctor --fix --perms-only)"
    local pbo="$BIN" out rc=0
    [[ "${PBO_INSTALL_TEST:-0}" == 1 && -n "${PBO_INSTALL_PBO:-}" ]] && pbo="$PBO_INSTALL_PBO"
    out="$("$pbo" doctor --fix --perms-only 2>&1)" || rc=$?
    [[ -z "$out" ]] || printf '%s\n' "$out" | sed 's/^/    /'
    if (( rc != 0 )); then
        echo "    WARNING: the permission check reported problems or failed (exit $rc); fix them, then run '$BIN doctor --fix'."
    fi
    return 0
}

inst_janitor_units() {
    echo "==> systemd units (installed, NOT enabled)"
    sed "s/^User=.*/User=$JUSER/; s/^Group=.*/Group=$JUSER/" "$SRC/systemd/pbo-janitor.service" > "$UNITDIR/pbo-janitor.service"
    chmod 0644 "$UNITDIR/pbo-janitor.service"
    install -m 0644 "$SRC/systemd/pbo-janitor.timer" "$UNITDIR/pbo-janitor.timer"
    "$SYSTEMCTL" daemon-reload
    cat <<EOF

Installed: pbo janitor (runs as $JUSER).

  1. Edit $CFGDIR/config: RESTIC_OFFSITE_REPO = the repo directory on this disk.
  2. Put the repo password in $CFGDIR/restic-pass, chown $JUSER, chmod 0400.
  3. Check it:   $BIN doctor        (drops to $JUSER by itself)
  4. Enable it:  systemctl enable --now pbo-janitor.timer   (daily 12:30)

Started as root, pbo re-execs itself as $JUSER (JANITOR_USER in the config), so
plain "$BIN doctor" is fine.
EOF
}

# inst_web_remove → WEB_REMOVED=1 when it removed a pbo-web that install.sh had
# installed (0.4): its services, binary, egress rule, user and its own files in
# CFGDIR (web.env, the TLS key in web-tls). A pbo-web .deb is apt's business:
# pbo >= 0.5.0 Breaks it, so apt removes it.
WEB_REMOVED=0
inst_web_remove() {
    [[ -n "$LIBDIR" && -n "$UNITDIR" && -n "$CFGDIR" ]] || return 0
    local units=("$UNITDIR/pbo-web.service" "$UNITDIR/pbo-web-helper.service") found=0 f
    for f in "${units[@]}" "$LIBDIR/pbo-web" "$LIBDIR/pbo-web-egress.nft"; do [[ -e "$f" ]] && found=1; done
    (( found )) || return 0
    echo "==> removing pbo-web (the 0.4 web UI; gone since 0.5.0)"
    "$SYSTEMCTL" disable --now pbo-web.service pbo-web-helper.service >/dev/null 2>&1 || true
    rm -f -- "${units[@]}" "$LIBDIR/pbo-web" "$LIBDIR/pbo-web-egress.nft" "$CFGDIR/web.env"
    [[ -d "$CFGDIR/web-tls" ]] && rm -r -- "$CFGDIR/web-tls"
    if [[ "${PBO_INSTALL_TEST:-0}" != 1 ]]; then
        if command -v nft >/dev/null 2>&1 && nft list table inet pbo_web_egress >/dev/null 2>&1; then
            nft delete table inet pbo_web_egress 2>/dev/null || true
        fi
        [[ -d /run/pbo-web-tls ]] && rm -r -- /run/pbo-web-tls
        if id pbo-web >/dev/null 2>&1; then userdel pbo-web 2>/dev/null || echo "    WARNING: could not remove the user pbo-web"; fi
    fi
    echo "    removed: pbo-web services, binary, egress rule, user, $CFGDIR/web.env, $CFGDIR/web-tls"
    WEB_REMOVED=1
}

inst_host_units() {
    echo "==> systemd units (installed, NOT enabled)"
    install -m 0644 "$SRC/systemd/pbo.service"       "$UNITDIR/pbo.service"
    install -m 0644 "$SRC/systemd/pbo.timer"         "$UNITDIR/pbo.timer"
    install -m 0644 "$SRC/systemd/pbo-prune.service" "$UNITDIR/pbo-prune.service"
    install -m 0644 "$SRC/systemd/pbo-prune.timer"   "$UNITDIR/pbo-prune.timer"
    install -m 0644 "$SRC/systemd/pbo-verify.service" "$UNITDIR/pbo-verify.service"
    install -m 0644 "$SRC/systemd/pbo-verify.timer"   "$UNITDIR/pbo-verify.timer"
    install -m 0644 "$SRC/systemd/pbo-test-restore.service" "$UNITDIR/pbo-test-restore.service"
    install -m 0644 "$SRC/systemd/pbo-test-restore.timer"   "$UNITDIR/pbo-test-restore.timer"

    # Proxmox notification templates. /etc/pve is pmxcfs: plain cp, no
    # chmod/chown. Cluster-wide, so installing on one node covers all of them.
    if [[ -d /etc/pve ]]; then
        install -d /usr/local/share/pbo/templates
        install -m 0644 "$SRC"/templates/pbo-*.hbs /usr/local/share/pbo/templates/
        if mkdir -p /etc/pve/notification-templates/default 2>/dev/null \
           && cp "$SRC"/templates/pbo-*.hbs /etc/pve/notification-templates/default/ 2>/dev/null; then
            echo "    notification templates → /etc/pve/notification-templates/default/"
        else
            echo "    WARNING: could not write /etc/pve/notification-templates (no quorum?); Proxmox notifications from pbo need them."
        fi
    fi
}

# inst_integration: the Proxmox side for MODE (after the program files).
inst_integration() {
    if [[ "$MODE" == standalone ]]; then
        [[ -f "$PLUGIN_FILE" ]] || return 0
        echo "==> Proxmox integration: standalone"
        # only an explicit --integration standalone removes the plugin
        if [[ "$MODE_SOURCE" == flag ]]; then inst_plugin_remove
        else echo "    $PLUGIN_FILE stays (remove it with --integration standalone)"; fi
        return 0
    fi
    echo "==> Proxmox integration: $MODE"
    inst_plugin_install
    inst_integration_files
}

inst_final_message() {
    cat <<EOF

Installed: pbo (Proxmox Backup Offsite).

  Setup:      $BIN setup      guided wizard: SSH key, SFTP target, repo, DR key,
                              retention, guests, Proxmox integration and (offered)
                              the timers — everything.
  Interface:  $BIN menu       open the interactive prompt
  Health:     $BIN doctor     check repo, timer, key perms, per-guest age

The wizard offers to enable the schedule at the end. To do it by hand instead:
  systemctl enable --now pbo.timer         (backups, 05:00 nightly)
  systemctl enable --now pbo-prune.timer   (prune, Sun 06:30)
  systemctl enable --now pbo-verify.timer  (integrity, Wed 10:00, 1/12 of the data per run)
  systemctl enable --now pbo-test-restore.timer  (restore test, Sat 10:00, one guest per run)
EOF
    if [[ "$MODE" != standalone ]]; then cat <<EOF

Proxmox integration: $MODE. The storage plugin, the vzdump hook and the units are
in place; the storage itself is not created yet. Once the repo exists:
  $BIN --dry-run integrate enable $MODE    (what it would change)
  $BIN integrate enable $MODE              (adds the pbo storage, the hook line in
                                         /etc/vzdump.conf, pbo-catalog.timer)
EOF
    fi
    if (( WEB_REMOVED )); then cat <<EOF

pbo-web (the 0.4 web UI) was removed. Close TCP 8008 in the Proxmox firewall
(and any VPN policy that lets it in). Use the Proxmox GUI (the pbo storage) or
'$BIN menu' / '$BIN doctor' instead.
EOF
    fi
    cat <<EOF

Uninstall: first '$BIN integrate disable' (if the Proxmox integration is on: it
removes the pbo storage and the hook line from /etc/vzdump.conf; a vzdump.conf
naming a missing hook fails every backup on this node), then remove $LIBDIR,
$BIN, units in $UNITDIR and $PLUGIN_FILE. Config/creds in $CFGDIR are kept.
EOF
}

main() {
    set -Eeuo pipefail
    [[ "$(id -u)" == 0 ]] || die "must be run as root."
    inst_parse_args "$@"
    # before anything is changed: the config as the new version reads it
    inst_config_guard
    if [[ "$ROLE" == janitor ]]; then
        id "$JUSER" >/dev/null 2>&1 || die "janitor user '$JUSER' does not exist (it should be the user rest-server runs as)"
        MODE=standalone
    else
        inst_resolve_mode
        echo "==> Proxmox integration: $MODE ($MODE_SOURCE)"
        [[ -z "$MODE_NOTE" ]] || echo "    $MODE_NOTE"
        # before any file is copied
        if [[ "$MODE" != standalone ]]; then
            local why; why="$(inst_version_refusal)"
            [[ -z "$why" ]] || die "$why"
        elif [[ "$MODE_SOURCE" == flag && -n "$CFG_MODE" && "$CFG_MODE" != standalone ]]; then
            # back to standalone: the PVE side goes first; a refusal stops here
            echo "    the config says PBO_INTEGRATION=$CFG_MODE: running 'pbo integrate disable' first"
            "$SRC/pbo" integrate disable --yes \
                || die "'pbo integrate disable' refused or failed (see above); nothing else was changed. Fix that, then run install.sh --integration standalone again."
        fi
    fi

    inst_deps
    inst_program
    if [[ "$ROLE" == janitor ]]; then inst_perms; inst_janitor_units; exit 0; fi
    inst_web_remove
    inst_host_units
    inst_integration
    "$SYSTEMCTL" daemon-reload
    inst_perms
    inst_final_message

    # --- interactive first-run setup (only on a real terminal) ---
    if [[ -t 0 && -t 1 ]]; then
        printf '\n'
        read -r -p "Run the interactive setup wizard now? [Y/n] " _ans
        if [[ -z "$_ans" || "$_ans" == [Yy]* ]]; then
            PBO_SETUP_INTEGRATION="$MODE" "$BIN" setup
        else
            echo "OK, run '$BIN setup' whenever you're ready."
        fi
    else
        echo "Non-interactive install, run '$BIN setup' to configure."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
