#!/usr/bin/env bash
# install.sh: installs pbo on a Proxmox host. Idempotent.
# NEVER enables the timer automatically (it prints how to do that yourself).
# A host install writes no /etc/pbo/config: pbo runs on the schema defaults
# until `pbo setup` writes one (the example config stays in SHAREDIR, see
# inst_program). A janitor gets its config from the janitor example, whose
# repo path is commented out, so nothing points at a repo until it is set.
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
# PBO_INSTALL_LIBDIR, PBO_INSTALL_UNITDIR, PBO_INSTALL_SHAREDIR, PBO_INSTALL_BIN (the pbo symlink;
# the compat alias goes next to it), PBO_INSTALL_SHARED_CFG (the cluster-shared
# config; none in test mode unless set), PBO_INSTALL_PBO (the pbo inst_perms
# runs), PBO_INSTALL_CFS_DIR (pmxcfs, for the member list) and
# PBO_INSTALL_VZDUMP_CONF (both: none in test mode unless set). In test mode
# inst_host_units writes no notification templates (/etc/pve), so
# tests/portability.sh can install the units into a tree.
#
# The closing message (inst_final_message) says what is in place, read the way
# `pbo integrate status` reads it and never changed to find out: each timer
# enabled or not (systemctl is-enabled), the pbo storage in storage.cfg, the
# hook line in vzdump.conf. Only what is missing gets its next step; with
# nothing in place (a fresh install) that is the full guidance.
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
SHAREDIR=/usr/local/share/pbo
BIN=/usr/local/sbin/pbo
CFGDIR=/etc/pbo
UNITDIR=/etc/systemd/system
PLUGIN_DIR=/usr/share/perl5/PVE/Storage/Custom
SYSTEMCTL=systemctl
DPKG_QUERY=dpkg-query
STORAGE_CFG=/etc/pve/storage.cfg
SHARED_CFG=/etc/pve/pbo/config
CFS_DIR=/etc/pve
VZDUMP_CONF=/etc/vzdump.conf
if [[ "${PBO_INSTALL_TEST:-0}" == 1 ]]; then
    CFGDIR="${PBO_INSTALL_CFGDIR:-$CFGDIR}"
    SHARED_CFG="${PBO_INSTALL_SHARED_CFG:-}"
    STORAGE_CFG="${PBO_INSTALL_STORAGE_CFG:-$STORAGE_CFG}"
    # no member list (a single node) unless the test gives one
    CFS_DIR="${PBO_INSTALL_CFS_DIR:-$CFGDIR/no-pmxcfs}"
    VZDUMP_CONF="${PBO_INSTALL_VZDUMP_CONF:-$CFGDIR/no-vzdump.conf}"
    PLUGIN_DIR="${PBO_INSTALL_PLUGIN_DIR:-$PLUGIN_DIR}"
    SYSTEMCTL="${PBO_INSTALL_SYSTEMCTL:-$SYSTEMCTL}"
    DPKG_QUERY="${PBO_INSTALL_DPKG_QUERY:-$DPKG_QUERY}"
    LIBDIR="${PBO_INSTALL_LIBDIR:-$LIBDIR}"
    UNITDIR="${PBO_INSTALL_UNITDIR:-$UNITDIR}"
    SHAREDIR="${PBO_INSTALL_SHAREDIR:-$CFGDIR/no-share}"
    BIN="${PBO_INSTALL_BIN:-$BIN}"
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
# RESTIC_ENV_FILE is checked the same way (inst_env_file_check): pbo stops on
# a file it refuses just as on a refused config line.
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
    inst_env_file_check
    (( ${#CFG_ERRORS[@]} + ${#RENV_ERRORS[@]} )) || return 0
    if (( ${#CFG_ERRORS[@]} )); then
        echo "==> Config: read the way pbo 0.6 reads it (KEY=VALUE, not run as shell code)"
        for e in "${CFG_ERRORS[@]}"; do echo "    $e"; done
        for f in "${PBO_CONFIG_FILES[@]}"; do
            [[ " ${CFG_ERRORS[*]}" == *" $f:"* ]] || continue
            bash -n -- "$f" 2>/dev/null && bashok+=("$f")
        done
        for f in "${bashok[@]+"${bashok[@]}"}"; do
            echo "    $f is valid bash, but pbo 0.6 no longer runs the config as code; see the 0.6.0 migration notes in CHANGELOG.md"
        done
    fi
    if (( ${#RENV_ERRORS[@]} )); then
        echo "==> RESTIC_ENV_FILE (restic's backend environment): pbo would refuse it"
        for e in "${RENV_ERRORS[@]}"; do echo "    $e"; done
        echo "    it holds credentials: chmod 600 and chown root (a systemd EnvironmentFile for other variables belongs elsewhere)"
    fi
    if [[ "$FORCE" == 1 ]]; then
        echo "    WARNING: --force: installing anyway. Every pbo command stops on this config (exit 78) until the problems above are fixed ('$BIN config check' names each one)."
        return 0
    fi
    die "the installed pbo would refuse this config (above). Nothing was changed. Fix the problems (each config line KEY=VALUE, see CHANGELOG.md), check with '$SRC/pbo config check --file <file>', then run install.sh again (or with --force to install anyway)."
}

# inst_env_file_check → RENV_ERRORS: RESTIC_ENV_FILE (from the config just
# read, else the schema default) checked by the code of the version being
# installed (_restic_env_read in lib/restic.sh: owner, mode, symlink, grammar,
# refused names). Only the names of its keys are kept, never a value. In test
# mode the default is moved along with CFGDIR.
inst_env_file_check() {
    _cs_load
    if ! declare -F _restic_env_read >/dev/null; then
        # shellcheck source=lib/restic.sh
        source "$SRC/lib/restic.sh"
    fi
    local def="${CS_DEFAULT[RESTIC_ENV_FILE]}"
    [[ "${PBO_INSTALL_TEST:-0}" != 1 ]] || def="$CFGDIR/${def##*/}"
    local RESTIC_ENV_FILE="${CFG_VAL[RESTIC_ENV_FILE]:-$def}" PBO_ROLE="$ROLE" JANITOR_USER="$JUSER"
    _restic_env_read || true
    _RENV_VAL=()
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

# --- what is in place (the closing message; read only) ------------------------
# inst_unit_enabled <unit>: systemd has <unit> enabled, as `pbo integrate
# status` and `pbo timers` ask it.
inst_unit_enabled() { "$SYSTEMCTL" is-enabled "$1" >/dev/null 2>&1; }

# inst_cfg_value <key> → the value pbo would use for <key> from the existing
# config (read, never sourced), empty when no file sets it: the cluster-shared
# file, then the local one, as pbo merges them. The reader drops an exec or
# local-only key from the shared file (PBO_VZDUMP_HOOK, PVE_STORAGE_ID), as pbo
# does, so those come from the local file only.
inst_cfg_value() {
    inst_cfg_reader
    _cfg_reset; declare -gA CFG_ENV=()
    if [[ -n "$SHARED_CFG" && -r "$SHARED_CFG" ]]; then _cfg_parse_file "$SHARED_CFG" shared || true; fi
    if [[ -r "$CFGDIR/config" ]]; then _cfg_parse_file "$CFGDIR/config" local || true; fi
    printf '%s' "${CFG_VAL[$1]:-}"
}

# inst_vzdump_conf → the vzdump.conf `pbo integrate` writes its hook line to:
# VZDUMP_CONF from the existing config, else the default above (in test mode
# PBO_INSTALL_VZDUMP_CONF). An empty value is the default, as in lib/integrate.sh.
inst_vzdump_conf() {
    local v; v="$(inst_cfg_value VZDUMP_CONF)"
    printf '%s' "${v:-$VZDUMP_CONF}"
}

# inst_storage_id → the id of this node's pbo storage: PVE_STORAGE_ID from the
# existing config (a local-only key, so never from the cluster-shared file),
# else the schema's derived default, which pbo computes the same way: pbo on a
# single node, pbo-<node> in a cluster, an entry pbo made for this node keeps
# its id (_cfgdef_PVE_STORAGE_ID).
inst_storage_id() {
    local id
    id="$(inst_cfg_value PVE_STORAGE_ID)"
    inst_cfg_reader
    if [[ -z "$id" ]]; then
        local PBO_PVE_CFS_DIR="$CFS_DIR" PVE_STORAGE_CFG="$STORAGE_CFG"
        _cfgdef_PVE_STORAGE_ID; id="$_CS_R"
    fi
    printf '%s' "$id"
}

# inst_storage_state <id> → absent | spool | catalog-only: the pbo entry <id>
# in storage.cfg, with a path (the spool PVE jobs write to) or without one
# (`integrate enable both --catalog-only`: browsing and restores only).
inst_storage_state() {
    [[ -r "$STORAGE_CFG" ]] || { printf absent; return 0; }
    awk -v id="$1" '
        /^[A-Za-z][A-Za-z0-9_-]*:[ \t]+[^ \t]+[ \t]*$/ { on = ($1 == "pbo:" && $2 == id); if (on) found = 1; next }
        on && /^[ \t]+[^ \t]/ { if ($1 == "path") path = 1; next }
        { on = 0 }
        END { print (found ? (path ? "spool" : "catalog-only") : "absent") }' "$STORAGE_CFG" 2>/dev/null || printf absent
}

# inst_hook_state → ours | missing | foreign <path>: the script vzdump runs,
# the last `script:` line of VZDUMP_CONF as PVE reads it, against the paths
# `pbo integrate` counts as its own (_integ_is_our_hook): PBO_VZDUMP_HOOK from
# the local config when set, else the hook next to pbo, plus the hooks of both
# install layouts. pbo finds "next to pbo" through readlink -f, so with a
# symlink in LIBDIR the line names the resolved directory: both forms count.
inst_hook_state() {
    local last='' hk p ours=()
    [[ -r "$VZDUMP_CONF" ]] && last="$(sed -nE 's/^script:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$VZDUMP_CONF" | tail -1)"
    [[ -n "$last" ]] || { printf missing; return 0; }
    hk="$(inst_cfg_value PBO_VZDUMP_HOOK)"
    if [[ -n "$hk" ]]; then
        ours=("$hk")
    else
        ours=("$LIBDIR/vzdump-hook")
        p="$(readlink -f -- "$LIBDIR" 2>/dev/null)" && [[ -n "$p" ]] && ours+=("$p/vzdump-hook")
    fi
    ours+=(/usr/local/lib/pbo/vzdump-hook /usr/lib/pbo/vzdump-hook)
    for p in "${ours[@]}"; do
        [[ "$last" == "$p" ]] && { printf ours; return 0; }
    done
    printf 'foreign %s' "$last"
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
    # install.sh enables none of them: `pbo integrate enable` starts the timer,
    # pbo starts the mount when a restore needs it
    local st="not enabled: 'pbo integrate enable' starts it"
    inst_unit_enabled pbo-catalog.timer && st="enabled"
    echo "    units pbo-catalog.service, pbo-catalog.timer ($st), pbo-mount.service (started on demand)"
}

inst_deps() {
    echo "==> Dependencies"
    # restic jq zstd flock curl openssl: the tool + the setup wizard (openssl mints
    # the DR key). ssh/sftp/ssh-keygen/ssh-keyscan come from openssh-client, which
    # the wizard uses to make and pin an SSH key and to test the connection.
    # setfacl/getfacl (acl): the CACHE_DIR entry an unprivileged CT's vzdump
    # passes through; setpriv (util-linux): doctor's check of the directories
    # above it; findmnt (util-linux): pbo-mount.service's cleanup. A minimal
    # Debian has no acl package.
    declare -A pkg=( [restic]=restic [jq]=jq [zstd]=zstd [flock]=util-linux [curl]=curl
                     [openssl]=openssl [ssh-keygen]=openssh-client
                     [setfacl]=acl [getfacl]=acl [setpriv]=util-linux [findmnt]=util-linux )
    local need=() b; for b in "${!pkg[@]}"; do command -v "$b" >/dev/null 2>&1 || need+=("${pkg[$b]}"); done
    if [[ "${#need[@]}" -gt 0 ]]; then
        # unique package list
        mapfile -t need < <(printf '%s\n' "${need[@]}" | sort -u)
        echo "    installing: ${need[*]}"
        apt-get update -qq && apt-get install -y "${need[@]}"
    else
        echo "    all present (restic jq zstd flock curl openssl openssh-client acl util-linux)"
    fi
    [[ "$ROLE" == janitor ]] || for b in vzdump pct qm zfs; do command -v "$b" >/dev/null 2>&1 || echo "    WARNING: '$b' missing, required on a real Proxmox host."; done
}

# inst_restic_check: the restic that pbo will run (RESTIC_BIN from the existing
# config, else restic on PATH) is at least the version the config needs
# (RESTIC_MIN, raised for a rest-server login: _restic_need_version in
# lib/config_schema.sh). The config is the cluster-shared file, then the local
# one, as pbo merges them (RESTIC_BIN is an exec key the reader drops from the
# shared file, so the restic checked is still the node's own). Run after the dependencies and before any pbo file is
# copied: an older restic fails in the middle of the first backup or copy.
# --force installs anyway. No restic is downloaded.
inst_restic_check() {
    local f="$CFGDIR/config" bin=restic min='' ruser='' v need why
    inst_cfg_reader
    _cfg_reset; declare -gA CFG_ENV=()
    if [[ -n "$SHARED_CFG" && -r "$SHARED_CFG" ]]; then _cfg_parse_file "$SHARED_CFG" shared || true; fi
    if [[ -r "$f" ]]; then _cfg_parse_file "$f" local || true; fi
    bin="${CFG_VAL[RESTIC_BIN]:-restic}"; min="${CFG_VAL[RESTIC_MIN]:-}"; ruser="${CFG_VAL[RESTIC_REST_USERNAME]:-}"
    need="$(_restic_need_version "$min" "$ruser")"; why="${need#*|}"; need="${need%%|*}"
    v="$("$bin" version 2>/dev/null | awk '$1 == "restic" { print $2; exit }')" || v=''
    v="${v%%[-+~]*}"
    echo "==> restic: ${v:-not found} ($bin; this config needs >= $need)"
    if [[ -n "$v" ]] && _version_ge "$v" "$need"; then return 0; fi
    local msg="restic ${v:-is missing or does not run} ($bin)"
    [[ -z "$v" ]] || msg="restic $v ($bin) is older than $need ($why)"
    msg+=". No pbo file was installed. Install restic >= $need (a newer distribution or backports package, or the static release binary from the restic project, checked against its published checksum) and set RESTIC_BIN in $f if it is not the restic on PATH, then run install.sh again (--force installs anyway)."
    if [[ "$FORCE" == 1 ]]; then echo "    WARNING: --force: $msg"; return 0; fi
    die "$msg"
}

# inst_program_files: pbo and its libraries into LIBDIR, BIN linked to it
# (tests/portability.sh runs the units against what this installs).
inst_program_files() {
    echo "==> Program files → $LIBDIR"
    install -d -m 0755 "$LIBDIR" "$LIBDIR/lib"
    install -m 0755 "$SRC/pbo" "$LIBDIR/pbo"
    install -m 0644 "$SRC"/lib/*.sh "$LIBDIR/lib/"
    ln -sf "$LIBDIR/pbo" "$BIN"
    echo "    $BIN → $LIBDIR/pbo"
    # Backward-compat: keep the old name working (pbo was formerly 'lxc-offsite').
    ln -sf "$LIBDIR/pbo" "${BIN%/*}/lxc-offsite"
    echo "    ${BIN%/*}/lxc-offsite → $LIBDIR/pbo  (compat alias)"
}

inst_program() {
    inst_program_files

    echo "==> logrotate"
    install -m 0644 "$SRC/etc/logrotate.d/pbo" /etc/logrotate.d/pbo
    # On a janitor /var/log/pbo belongs to $JUSER: rotate as that user, not as root
    # in a directory someone else controls.
    if [[ "$ROLE" == janitor ]]; then
        sed -i -e "s/create 0600 root root/create 0600 $JUSER $JUSER/" -e "/{\$/a\\    su $JUSER $JUSER" /etc/logrotate.d/pbo
    fi

    echo "==> Directories"
    # the schema's default directories (a fresh install's config uses them); a
    # config that moves them gets its own from pbo (ensure_dirs) and their
    # modes from doctor --fix. Never the configured ones here: the janitor's
    # recursive chown must not run on a directory someone pointed elsewhere.
    inst_cfg_reader; _cs_load
    local logd="${CS_DEFAULT[LOG_DIR]}" stated="${CS_DEFAULT[STATE_DIR]}" cached="${CS_DEFAULT[CACHE_DIR]}"
    install -d -m 0755 "$logd" "$stated" "$stated/jobs"
    install -d -m 0700 "$CFGDIR"
    if [[ "$ROLE" == janitor ]]; then
        # The janitor runs as $JUSER: it needs its state/log dirs and to read the config.
        install -d -m 0755 "$cached"
        chown -R "$JUSER:$JUSER" "$logd" "$stated" "$cached"
        chown "root:$JUSER" "$CFGDIR"; chmod 0750 "$CFGDIR"
    fi

    inst_config
}

# inst_config: the examples into SHAREDIR (never read by pbo), and on a
# janitor a first $CFGDIR/config from its example. A host gets no config:
# copied from the example it would pin every key the example sets (the
# CACHE_DIR line among them, which the wizard then keeps as "configured")
# and look like a finished setup; pbo runs on the schema defaults without
# one, and `pbo setup` writes the keys the operator chooses. An example an
# older install.sh left in $CFGDIR is refreshed, so it never goes stale.
inst_config() {
    echo "==> Config"
    local example="$SRC/etc/config.example" name=config.example
    [[ "$ROLE" == janitor ]] && { example="$SRC/etc/config.janitor.example"; name=config.janitor.example; }
    install -d -m 0755 "$SHAREDIR"
    install -m 0644 "$SRC/etc/config.example" "$SRC/etc/config.janitor.example" "$SHAREDIR/"
    [[ ! -f "$CFGDIR/config.example" ]] || install -m 0644 "$example" "$CFGDIR/config.example"
    if [[ -f "$CFGDIR/config" ]]; then
        echo "    $CFGDIR/config already exists, left untouched."
    elif [[ "$ROLE" == janitor ]]; then
        sed "s/^JANITOR_USER=.*/JANITOR_USER=$JUSER/" "$example" > "$CFGDIR/config"
        chown "root:$JUSER" "$CFGDIR/config"; chmod 0640 "$CFGDIR/config"
        echo "    created $CFGDIR/config (0640 root:$JUSER) from $SHAREDIR/$name: set RESTIC_OFFSITE_REPO (commented out) and the password file."
    else
        echo "    no $CFGDIR/config yet: '$BIN setup' writes it (an annotated example: $SHAREDIR/$name)."
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

# inst_schedules: the timer schedules of the config (SCHEDULE_*, lib/timers.sh)
# as drop-ins next to the units just installed, through the pbo just installed
# (`pbo timers apply`): the units carry the defaults, so a reinstall over a
# config with a custom schedule keeps it. A drop-in the config no longer wants
# goes. Its output is shown; it never fails the install (doctor names a drift,
# `pbo doctor --fix` applies it again).
inst_schedules() {
    echo "==> Timer schedules ($BIN timers apply)"
    local pbo="$BIN" out rc=0
    [[ "${PBO_INSTALL_TEST:-0}" == 1 && -n "${PBO_INSTALL_PBO:-}" ]] && pbo="$PBO_INSTALL_PBO"
    out="$(PBO_SYSTEMD_DIR="$UNITDIR" "$pbo" timers apply 2>&1)" || rc=$?
    [[ -z "$out" ]] || printf '%s\n' "$out" | sed 's/^/    /'
    if (( rc != 0 )); then
        echo "    WARNING: the timer schedules could not all be applied (exit $rc); fix the config, then run '$BIN timers apply'."
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

  1. Edit $CFGDIR/config: uncomment RESTIC_OFFSITE_REPO and set it to the repo
     directory on this disk.
  2. Put the repo password in $CFGDIR/restic-pass, chown $JUSER, chmod 0400.
  3. Check it:   $BIN doctor        (drops to $JUSER by itself)
  4. Enable it:  systemctl enable --now pbo-janitor.timer   (daily, SCHEDULE_JANITOR)

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
    # install.sh never enables a unit; which timers are enabled is in the
    # closing message (on an upgrade they may well be)
    echo "==> systemd units (installed; install.sh enables none, their state is listed at the end)"
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
    # Not in test mode: the paths are the host's own.
    if [[ "${PBO_INSTALL_TEST:-0}" != 1 && -d /etc/pve ]]; then
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

# The host's timers and what each does, in the order the closing message lists them.
HOST_TIMERS=(pbo.timer pbo-prune.timer pbo-verify.timer pbo-test-restore.timer)
declare -A HOST_TIMER_DESC=(
    [pbo.timer]="backups, nightly: SCHEDULE_BACKUP"
    [pbo-prune.timer]="prune, weekly: SCHEDULE_PRUNE"
    [pbo-verify.timer]="integrity, weekly, 1/12 of the data per run: SCHEDULE_VERIFY"
    [pbo-test-restore.timer]="restore test, weekly, one guest per run: SCHEDULE_TEST_RESTORE"
)

# inst_final_timers: the timers part of the closing message. None enabled (a
# fresh install): how to enable them. Otherwise each timer's state, and the
# command for each one that is not enabled.
inst_final_timers() {
    local t on=() off=()
    for t in "${HOST_TIMERS[@]}"; do
        if inst_unit_enabled "$t"; then on+=("$t"); else off+=("$t"); fi
    done
    if (( ${#on[@]} == 0 )); then
        printf '\nThe wizard offers to enable the schedule at the end. To do it by hand instead:\n'
        for t in "${HOST_TIMERS[@]}"; do printf '  %-39s  (%s)\n' "systemctl enable --now $t" "${HOST_TIMER_DESC[$t]}"; done
    else
        printf '\nTimers (install.sh never enables or disables one):\n'
        for t in "${HOST_TIMERS[@]}"; do
            if [[ " ${on[*]} " == *" $t "* ]]; then printf '  %-24s %-12s (%s)\n' "$t" enabled "${HOST_TIMER_DESC[$t]}"
            else printf '  %-24s %-12s (%s): systemctl enable --now %s\n' "$t" "NOT enabled" "${HOST_TIMER_DESC[$t]}" "$t"; fi
        done
    fi
    cat <<EOF
'$BIN timers' shows when each runs; 'pbo config set SCHEDULE_BACKUP "<OnCalendar>"'
changes it (a drop-in next to the unit, the timer restarted if enabled).
EOF
}

# inst_final_integration: the Proxmox part of the closing message (both,
# integrated). Nothing in place yet (a fresh install, or the integration never
# enabled): the steps to enable it once the repo exists. All in place: what is
# there, no step. Partly: what is there, what is missing, and `pbo integrate
# enable`, which converges (it adds only what is missing).
# A catalogue-only storage (`integrate enable both --catalog-only`) takes no
# PVE jobs, so it needs no hook and a foreign one blocks nothing; its next
# step keeps --catalog-only, since a plain enable would give the storage a
# spool and the hook line (or refuse, over a foreign hook). Integrated mode has
# no catalogue-only form: there the spool and the hook are what is missing.
inst_final_integration() {
    local id st hook have=() miss=() note='' co=0 co_flag=''
    id="$(inst_storage_id)"; st="$(inst_storage_state "$id")"; hook="$(inst_hook_state)"
    if [[ "$st" == catalog-only && "$MODE" == both ]]; then co=1; co_flag=' --catalog-only'; fi
    case "$st" in
        spool)        have+=("storage $id present") ;;
        catalog-only)
            have+=("storage $id present (catalogue only: no spool, no hook)")
            (( co )) || miss+=("a spool (path) for storage $id: in integrated mode PVE jobs are the only backups, and a catalogue-only storage takes none") ;;
        *)            miss+=("storage $id") ;;
    esac
    case "$hook" in
        ours) have+=("the hook line in $VZDUMP_CONF") ;;
        foreign\ *)
            if (( co )); then
                have+=("$VZDUMP_CONF runs another hook (script: ${hook#foreign }), left as is: a catalogue-only storage needs none")
            else
                note="$VZDUMP_CONF runs another hook (script: ${hook#foreign }): 'pbo integrate enable' refuses to replace it, PVE jobs to '$id' are not ingested until it goes"
                miss+=("the hook line in $VZDUMP_CONF")
            fi ;;
        *)  (( co )) || miss+=("the hook line in $VZDUMP_CONF") ;;
    esac
    if inst_unit_enabled pbo-catalog.timer; then have+=("pbo-catalog.timer enabled"); else miss+=("pbo-catalog.timer enabled"); fi
    # the mode is written last by `integrate enable`: a config that still
    # says another one (or none) has not finished the switch
    [[ "$CFG_MODE" == "$MODE" ]] || miss+=("PBO_INTEGRATION=$MODE in $CFGDIR/config (it says ${CFG_MODE:-standalone})")
    if (( ${#have[@]} == 0 )); then cat <<EOF

Proxmox integration: $MODE. The storage plugin, the vzdump hook and the units are
in place; the storage itself is not created yet. Once the repo exists:
  $BIN --dry-run integrate enable $MODE    (what it would change)
  $BIN integrate enable $MODE              (adds the pbo storage, the hook line in
                                         $VZDUMP_CONF, pbo-catalog.timer)
EOF
        return 0
    fi
    printf '\nProxmox integration: %s.\n' "$MODE"
    local e
    for e in "${have[@]}"; do printf '  in place: %s\n' "$e"; done
    (( ${#miss[@]} )) || return 0
    for e in "${miss[@]}"; do printf '  MISSING:  %s\n' "$e"; done
    [[ -z "$note" ]] || printf '  %s\n' "$note"
    cat <<EOF
To complete it ('$BIN integrate status' shows the details):
  $BIN --dry-run integrate enable $MODE$co_flag    (what it would change)
  $BIN integrate enable $MODE$co_flag              (adds only what is missing)
EOF
}

inst_final_message() {
    # the vzdump.conf `pbo integrate` uses (VZDUMP_CONF in the config): the
    # hook state, the next steps and the uninstall hint all name that file
    VZDUMP_CONF="$(inst_vzdump_conf)"
    cat <<EOF

Installed: pbo (Proxmox Backup Offsite).

  Setup:      $BIN setup      guided wizard: SSH key, SFTP target, repo, DR key,
                              retention, guests, Proxmox integration and (offered)
                              the timers — everything.
  Interface:  $BIN menu       open the interactive prompt
  Health:     $BIN doctor     check repo, timer, key perms, per-guest age
EOF
    inst_final_timers
    [[ "$MODE" == standalone ]] || inst_final_integration
    if (( WEB_REMOVED )); then cat <<EOF

pbo-web (the 0.4 web UI) was removed. Close TCP 8008 in the Proxmox firewall
(and any VPN policy that lets it in). Use the Proxmox GUI (the pbo storage) or
'$BIN menu' / '$BIN doctor' instead.
EOF
    fi
    cat <<EOF

Uninstall: first '$BIN integrate disable' (if the Proxmox integration is on: it
removes the pbo storage and the hook line from $VZDUMP_CONF; a vzdump.conf
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
    inst_restic_check
    inst_program
    if [[ "$ROLE" == janitor ]]; then inst_perms; inst_janitor_units; inst_schedules; exit 0; fi
    inst_web_remove
    inst_host_units
    inst_integration
    "$SYSTEMCTL" daemon-reload
    inst_perms
    inst_schedules
    inst_final_message
    inst_offer_setup
}

# inst_offer_setup: the interactive first-run setup, offered on a terminal
# only. Its exit status is about the configuration, not the install, which is
# complete by now: it is reported, never returned (under set -e a plain call
# would end install.sh with it; right after a first setup that is doctor's
# 69, since no guest has a snapshot before the first backup).
inst_offer_setup() {
    local _ans setup_rc=0
    if inst_is_tty; then
        printf '\n'
        read -r -p "Run the interactive setup wizard now? [Y/n] " _ans
        if [[ -z "$_ans" || "$_ans" == [Yy]* ]]; then
            PBO_SETUP_INTEGRATION="$MODE" "$BIN" setup || setup_rc=$?
            (( setup_rc == 0 )) || echo "    '$BIN setup' ended with exit $setup_rc (its closing text above says what); the install itself is complete. Fix what it named, then run '$BIN setup' again, or '$BIN doctor' after the first backup."
        else
            echo "OK, run '$BIN setup' whenever you're ready."
        fi
    else
        if [[ -f "$CFGDIR/config" ]]; then echo "Non-interactive install: '$BIN setup' changes the configuration, '$BIN doctor' checks it."
        else echo "Non-interactive install, not configured yet: run '$BIN setup'."; fi
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
