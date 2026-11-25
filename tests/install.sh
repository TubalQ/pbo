#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/install.sh: install.sh's logic, sourced (its main never runs): Debian
# version comparison, the PVE version refusal, how the integration mode is
# resolved (flag, existing config, terminal prompt, default), the --janitor
# conflict, and the plugin install/remove steps against files under run/ with
# systemctl and dpkg-query mocked. Nothing is installed on the host.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start) are the
# machine's own files: point them into the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.env" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
    PBO_PVE_CFS_DIR="$PWD/run-none/pve" PVE_STORAGE_CFG="$PWD/run-none/pve/storage.cfg"
ROOT="$PWD"
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

printf 'pbo: install.sh tests\n'
RUN="$ROOT/run/install"; rm -rf "$RUN"; mkdir -p "$RUN"/{bin,etc,plugin}
install -m 0755 tests/mocks/systemctl tests/mocks/dpkg-query "$RUN/bin/"
export PATH="$RUN/bin:$PATH" MOCK_LOG="$RUN/calls"; : > "$MOCK_LOG"
export PBO_INSTALL_TEST=1 PBO_INSTALL_CFGDIR="$RUN/etc" PBO_INSTALL_PLUGIN_DIR="$RUN/plugin/Custom" \
       PBO_INSTALL_STORAGE_CFG="$RUN/storage.cfg" PBO_INSTALL_SYSTEMCTL=systemctl PBO_INSTALL_DPKG_QUERY=dpkg-query
REAL_PLUGIN=/usr/share/perl5/PVE/Storage/Custom/PboPlugin.pm
real_before="$(stat -c '%i %Y' "$REAL_PLUGIN" 2>/dev/null || echo none)"
libdir_before="$(stat -c '%i %Y' /usr/local/lib/pbo 2>/dev/null || echo none)"

# S <bash>: run a snippet with install.sh sourced, in a fresh shell
S() { bash -c 'source ./install.sh; '"$1"; }

# --- sourcing runs nothing ---------------------------------------------------------------
out="$(bash -c 'source ./install.sh; echo "sourced main=$(type -t main) SRC=$SRC"' 2>&1)"; rc=$?
[[ $rc == 0 && "$out" == "sourced main=function SRC=$ROOT" ]] && ok "sourcing install.sh defines functions and runs nothing" || bad "source: rc=$rc $out"
[[ "$(S 'echo "$CFGDIR $PLUGIN_FILE $SYSTEMCTL"')" == "$RUN/etc $RUN/plugin/Custom/PboPlugin.pm systemctl" ]] \
    && ok "test mode: paths overridable" || bad "overrides: $(S 'echo "$CFGDIR $PLUGIN_FILE"')"
[[ "$(PBO_INSTALL_TEST=0 S 'echo "$CFGDIR $PLUGIN_FILE"')" == "/etc/pbo /usr/share/perl5/PVE/Storage/Custom/PboPlugin.pm" ]] \
    && ok "outside test mode the overrides are ignored" || bad "no test mode: $(PBO_INSTALL_TEST=0 S 'echo "$CFGDIR $PLUGIN_FILE"')"

# --- version comparison --------------------------------------------------------------------
vc() { S "inst_version_ge '$1' '$2'" && echo ge || echo lt; }
for c in "9.2.29 9.2.29 ge" "9.2.32 9.2.29 ge" "9.2.3 9.2.29 lt" "9.10.0 9.2.29 ge" "9.1.18-1 9.1.18 ge" \
         "9.1.17 9.1.18 lt" "6.1.24~bpo1 6.1.24 lt" "10.0.1 9.2.29 ge"; do
    read -r a b want <<<"$c"
    [[ "$(vc "$a" "$b")" == "$want" ]] && ok "version: $a $want $b" || bad "version: $a vs $b, want $want"
done

# --- the version refusal -----------------------------------------------------------------------
out="$(MOCK_DPKG_VERSIONS="pve-manager=9.2.32 libpve-storage-perl=9.1.18" S inst_version_refusal)"
[[ -z "$out" ]] && ok "refusal: none for 9.2.32 / 9.1.18" || bad "refusal on a good host: $out"
out="$(MOCK_DPKG_VERSIONS="pve-manager=9.2.20 libpve-storage-perl=9.1.18" S inst_version_refusal)"
[[ "$out" == "Proxmox integration needs pve-manager >= 9.2.29 and libpve-storage-perl >= 9.1.18 (installed: 9.2.20, 9.1.18). Nothing was changed."* ]] \
    && ok "refusal: old pve-manager, the exact message" || bad "refusal text: $out"
out="$(MOCK_DPKG_VERSIONS="pve-manager=9.2.32 libpve-storage-perl=9.1.17" S inst_version_refusal)"
[[ "$out" == *"(installed: 9.2.32, 9.1.17). Nothing was changed."* ]] && ok "refusal: old libpve-storage-perl" || bad "refusal storage: $out"
out="$(MOCK_DPKG_VERSIONS="" S inst_version_refusal)"
[[ "$out" == *"(installed: not installed, not installed)"* ]] && ok "refusal: not a PVE host" || bad "refusal none: $out"

# --- argument parsing ----------------------------------------------------------------------------
out="$(S 'inst_parse_args --janitor --integration both; echo survived' 2>&1)"; rc=$?
[[ $rc != 0 && "$out" == *"cannot be combined with --janitor"* && "$out" != *survived* ]] && ok "--janitor with --integration both: refused" || bad "janitor conflict: rc=$rc $out"
out="$(S 'inst_parse_args --integration integrated --janitor; echo survived' 2>&1)"; rc=$?
[[ $rc != 0 && "$out" == *"cannot be combined with --janitor"* ]] && ok "--integration integrated --janitor (either order): refused" || bad "janitor order: $out"
[[ "$(S 'inst_parse_args --janitor --integration standalone; echo "$ROLE $INTEGRATION"' 2>&1)" == "janitor standalone" ]] \
    && ok "--janitor with --integration standalone: accepted (a janitor is standalone)" || bad "janitor standalone"
[[ "$(S 'inst_parse_args --mode both; echo "$INTEGRATION"' 2>&1)" == both ]] && ok "--mode is an alias of --integration" || bad "--mode alias"
[[ "$(S 'inst_parse_args --integration=integrated; echo "$INTEGRATION"' 2>&1)" == integrated ]] && ok "--integration=<mode>" || bad "--integration="
out="$(S 'inst_parse_args --integration bogus; echo survived' 2>&1)"; rc=$?
[[ $rc != 0 && "$out" == *"must be standalone, both or integrated"* ]] && ok "--integration bogus: refused" || bad "bogus mode: $out"
out="$(S 'inst_parse_args --frobnicate; echo survived' 2>&1)"; rc=$?
[[ $rc != 0 && "$out" == *"unknown flag: --frobnicate"* ]] && ok "unknown flag: refused" || bad "unknown flag: $out"

# --- mode resolution --------------------------------------------------------------------------------
R() { PBO_INSTALL_TTY="${TTY:-0}" S 'inst_parse_args '"$1"'; inst_resolve_mode >/dev/null; echo "$MODE $MODE_SOURCE|$MODE_NOTE"' 2>&1; }
rm -f "$RUN/etc/config"
[[ "$(R '' </dev/null)" == "standalone default|" ]] && ok "mode: no flag, no config, no terminal → standalone" || bad "default: $(R '' </dev/null)"
[[ "$(R '--integration both' </dev/null)" == "both flag|" ]] && ok "mode: the flag" || bad "flag: $(R '--integration both')"
printf 'CACHE_DIR=/x\nPBO_INTEGRATION=integrated\n' > "$RUN/etc/config"
out="$(R '' </dev/null)"
[[ "$out" == "integrated config|keeping PBO_INTEGRATION=integrated from $RUN/etc/config"* ]] && ok "mode: kept from the config, with a note" || bad "config: $out"
[[ "$(R '--integration standalone' </dev/null)" == "standalone flag|" ]] && ok "mode: the flag beats the config" || bad "flag over config: $(R '--integration standalone')"
printf 'PBO_INTEGRATION="both"   # quoted, with a comment\n' > "$RUN/etc/config"
[[ "$(R '' </dev/null | cut -d'|' -f1)" == "both config" ]] && ok "mode: a quoted value with a comment is read" || bad "quoted: $(R '')"
printf 'PBO_INTEGRATION=bogus\n' > "$RUN/etc/config"
[[ "$(R '' </dev/null)" == "standalone default|" ]] && ok "mode: an invalid config value is ignored" || bad "invalid cfg: $(R '')"
printf 'PBO_INTEGRATION=$(touch %s/pwned)\n' "$RUN" > "$RUN/etc/config"
R '' </dev/null >/dev/null; [[ ! -e "$RUN/pwned" ]] && ok "mode: the config is read, never sourced" || bad "config was executed"
rm -f "$RUN/etc/config"
[[ "$(TTY=1 R '' <<<'2' | cut -d'|' -f1)" == "both prompt" ]] && ok "mode: terminal, answer 2 → both" || bad "prompt 2: $(TTY=1 R '' <<<'2')"
[[ "$(TTY=1 R '' <<<'3' | cut -d'|' -f1)" == "integrated prompt" ]] && ok "mode: terminal, answer 3 → integrated" || bad "prompt 3"
[[ "$(TTY=1 R '' <<<'' | cut -d'|' -f1)" == "standalone prompt" ]] && ok "mode: terminal, Enter → standalone (the default)" || bad "prompt enter: $(TTY=1 R '' <<<'')"
out="$(TTY=1 R '' <<<'7')"; [[ "$out" == *"no such choice"* ]] && ok "mode: terminal, a bad answer stops" || bad "prompt bad: $out"
printf 'PBO_INTEGRATION=both\n' > "$RUN/etc/config"
[[ "$(TTY=1 R '' <<<'1' | cut -d'|' -f1)" == "both config" ]] && ok "mode: the config wins over asking" || bad "config vs prompt"
# inst_config_mode reads with the strict reader: the last accepted line counts,
# a refused line elsewhere does not hide the key, export is read too
printf 'PBO_INTEGRATION=both\nCACHE_DIR=$(true)\nexport PBO_INTEGRATION=integrated # last\n' > "$RUN/etc/config"
[[ "$(R '' </dev/null | cut -d'|' -f1)" == "integrated config" ]] && ok "mode: read by the strict reader (the last accepted line, export too)" || bad "strict mode read: $(R '' </dev/null)"
printf 'PBO_INTEGRATION=both\nPBO_INTEGRATION=$(echo integrated)\n' > "$RUN/etc/config"
[[ "$(R '' </dev/null | cut -d'|' -f1)" == "both config" ]] && ok "mode: a refused assignment is not read" || bad "refused line: $(R '' </dev/null)"
rm -f "$RUN/etc/config"

# --- upgrade guard: the existing config read the way the new version reads it ---------------------------
G() { S 'inst_config_guard; echo "rc=$?"' 2>&1; }
printf 'CACHE_DIR=/x\nKEEP_LOCAL=3 # ok\nRESTIC_CACHE_REPO=${CACHE_DIR}/repo\n' > "$RUN/etc/config"
[[ "$(G)" == "rc=0" ]] && ok "guard: a config the strict reader accepts → silent" || bad "guard clean: $(G)"
printf 'CACHE_DIR=/x\nKEEP_LOCAL=$(touch %s/pwned)\nexport FOO=1\n' "$RUN" > "$RUN/etc/config"
out="$(G)"; rc=$?
[[ $rc != 0 && "$out" == *"$RUN/etc/config:2: command substitution"* && "$out" == *"$RUN/etc/config:3: export FOO is not allowed"* \
   && "$out" == *"$RUN/etc/config is valid bash, but pbo 0.6 no longer runs the config as code; see the 0.6.0 migration notes in CHANGELOG.md"* \
   && "$out" == *"install: the installed pbo would refuse this config (above). Nothing was changed."*"--force"* && "$out" != *"rc=0"* && ! -e "$RUN/pwned" ]] \
    && ok "guard: refused lines named with file:line and the migration hint, the install stops (nothing changed), nothing run" || bad "guard bad: rc=$rc $out"
out="$(S 'FORCE=1; inst_config_guard; echo "rc=$?"' 2>&1)"
[[ "$out" == *"$RUN/etc/config:2: command substitution"* && "$out" == *"WARNING: --force: installing anyway. Every pbo command stops on this config (exit 78)"* && "$out" == *"rc=0" ]] \
    && ok "guard: --force installs anyway, with a warning" || bad "guard --force: $out"
[[ "$(S 'inst_parse_args --force; echo "$FORCE"' 2>&1)" == 1 && "$(S 'inst_parse_args; echo "$FORCE"' 2>&1)" == 0 ]] && ok "--force is parsed (off by default)" || bad "--force parse"
printf 'CACHE_DIR="unterminated\n' > "$RUN/etc/config"
out="$(G)"; [[ "$out" == *"unterminated double quote"* && "$out" != *"valid bash"* && "$out" == *"Nothing was changed"* ]] \
    && ok "guard: a file bash cannot parse either: refused, without the 'valid bash' hint" || bad "guard nobash: $out"
printf 'RESTIC_SFTP_COMMAND="ssh -p 23 x"\nCACHE_DIR=/s\n' > "$RUN/shared.cfg"
printf 'RESTIC_CACHE_REPO=${CACHE_DIR}/repo\n' > "$RUN/etc/config"
out="$(PBO_INSTALL_SHARED_CFG="$RUN/shared.cfg" G)"
[[ "$out" == *"lines pbo ignores"*"$RUN/shared.cfg:1: RESTIC_SFTP_COMMAND may not be set in the cluster-shared config"* && "$out" != *"used before it is set"* && "$out" == *"rc=0" ]] \
    && ok "guard: the shared file first (its keys count for the local file); a key pbo ignores there is named, not refused" || bad "guard shared: $out"
# a refused line only in the shared file stops the install too: a clean local
# file does not hide it (pbo on every node would stop on it)
printf 'KEEP_LOCAL=$(touch %s/pwned)\n' "$RUN" > "$RUN/shared.cfg"
printf 'KEEP_LOCAL=3\n' > "$RUN/etc/config"
out="$(PBO_INSTALL_SHARED_CFG="$RUN/shared.cfg" G)"; rc=$?
[[ $rc != 0 && "$out" == *"$RUN/shared.cfg:1: command substitution"* \
   && "$out" == *"$RUN/shared.cfg is valid bash, but pbo 0.6 no longer runs the config as code"* \
   && "$out" != *"$RUN/etc/config is valid bash"* \
   && "$out" == *"Nothing was changed"* && "$out" != *"rc=0"* && ! -e "$RUN/pwned" ]] \
    && ok "guard: a refused line in the cluster-shared file stops the install too (a clean local file does not hide it)" || bad "guard shared bad: rc=$rc $out"
printf 'RESTIC_CACHE_REPO=${CACHE_DIR}/repo\n' > "$RUN/etc/config"
out="$(G)"; [[ "$out" == *"$RUN/etc/config:1: \${CACHE_DIR} is used before it is set"* && "$out" == *"Nothing was changed"* ]] \
    && ok "guard: no shared file in test mode unless given; no key taken from install.sh's environment" || bad "guard local only: $out"
out="$(CACHE_DIR=/from-env G)"; [[ "$out" == *"used before it is set"* ]] && ok "guard: the environment of install.sh is not the one pbo runs in" || bad "guard env: $out"
# main stops in the guard before anything is installed. main wants root: run
# only when we are. Every step main takes after the guard is replaced by a stub
# that says so and exits at once, so even a broken guard installs nothing here.
if [[ "$(id -u)" == 0 ]]; then
    printf 'KEEP_LOCAL=a b\n' > "$RUN/etc/config"
    stubs='for f in inst_resolve_mode inst_version_refusal inst_deps inst_restic_check inst_program inst_janitor_units inst_web_remove inst_host_units inst_integration inst_final_message; do eval "$f() { echo STEP-RAN; exit 99; }"; done; SYSTEMCTL=false'
    out="$(S "$stubs; main" 2>&1)"; rc=$?
    [[ $rc != 0 && "$out" == *"Nothing was changed"* && "$out" != *STEP-RAN* ]] && ok "main: a refused config stops install.sh before the mode, the deps or any file" || bad "main guard: rc=$rc $out"
    printf 'KEEP_LOCAL=3\n' > "$RUN/etc/config"
    out="$(S "$stubs; main" 2>&1)"; rc=$?
    [[ $rc == 99 && "$out" == *STEP-RAN* ]] && ok "main: ... and a clean one gets past it (the stubs are reached)" || bad "main control: rc=$rc $out"
fi
rm -f "$RUN/etc/config" "$RUN/shared.cfg"
[[ "$(G)" == "rc=0" ]] && ok "guard: no config yet → silent" || bad "guard no config: $(G)"
# RESTIC_ENV_FILE: a file pbo refuses (here at the default path, in CFGDIR:
# a 0644 systemd EnvironmentFile, say) stops every command, so the install too
printf 'AWS_ACCESS_KEY_ID=install-probe-value\n' > "$RUN/etc/restic.env"; chmod 0644 "$RUN/etc/restic.env"
snap="$(ls -la "$RUN/etc" "$RUN/plugin" 2>&1)"
out="$(G)"; rc=$?
[[ $rc != 0 && "$out" == *"RESTIC_ENV_FILE"*"$RUN/etc/restic.env:0: REFUSING a restic environment file with mode 0644"* && "$out" == *"chmod 600"* \
   && "$out" == *"Nothing was changed"* && "$out" != *"rc=0"* && "$out" != *install-probe-value* && "$(ls -la "$RUN/etc" "$RUN/plugin" 2>&1)" == "$snap" ]] \
    && ok "guard: a 0644 RESTIC_ENV_FILE at the default path stops the install (nothing changed, no value shown)" || bad "guard env file: rc=$rc $out"
out="$(S 'FORCE=1; inst_config_guard; echo "rc=$?"' 2>&1)"
[[ "$out" == *"REFUSING"* && "$out" == *"WARNING: --force"* && "$out" == *"rc=0" ]] && ok "guard: ... --force installs anyway, warned" || bad "guard env --force: $out"
if [[ "$(id -u)" == 0 ]]; then
    out="$(S "$stubs; main" 2>&1)"; rc=$?
    [[ $rc != 0 && "$out" == *"Nothing was changed"* && "$out" != *STEP-RAN* ]] && ok "main: the refused RESTIC_ENV_FILE stops install.sh before any step" || bad "main env guard: rc=$rc $out"
fi
chmod 0600 "$RUN/etc/restic.env"
[[ "$(G)" == "rc=0" ]] && ok "guard: a 0600 RESTIC_ENV_FILE passes" || bad "guard env 0600: $(G)"
printf 'RESTIC_ENV_FILE=%s\n' "$RUN/etc/other.env" > "$RUN/etc/config"; printf 'PATH=/x\n' > "$RUN/etc/other.env"; chmod 0600 "$RUN/etc/other.env"
out="$(G)"; [[ "$out" == *"$RUN/etc/other.env:1: PATH may not be set here"* && "$out" == *"Nothing was changed"* ]] \
    && ok "guard: the RESTIC_ENV_FILE the config names, checked like pbo checks it" || bad "guard env named: $out"
rm -f "$RUN/etc/restic.env" "$RUN/etc/other.env" "$RUN/etc/config"

# --- the restic version check reads the shared file too, as pbo does ---------------------------------
printf '#!/usr/bin/env bash\necho "restic 0.14.0 compiled with go1.19 on linux/amd64"\n' > "$RUN/bin/restic-014"; chmod 0755 "$RUN/bin/restic-014"
printf 'RESTIC_REST_USERNAME=pve1\n' > "$RUN/shared.cfg"
printf 'RESTIC_BIN=%s\n' "$RUN/bin/restic-014" > "$RUN/etc/config"; chmod 600 "$RUN/etc/config"
out="$(PBO_INSTALL_SHARED_CFG="$RUN/shared.cfg" S 'inst_restic_check; echo survived' 2>&1)"
[[ "$out" == *"restic 0.14.0 ($RUN/bin/restic-014) is older than 0.16.1 (RESTIC_REST_USERNAME"* && "$out" != *survived* ]] \
    && ok "restic check: a rest-server user in the cluster-shared config raises the floor (0.14.0 refused)" || bad "restic shared user: $out"
printf 'RESTIC_MIN=0.17.0\nRESTIC_BIN=/nonexistent-shared-restic\n' > "$RUN/shared.cfg"
out="$(PBO_INSTALL_SHARED_CFG="$RUN/shared.cfg" S 'inst_restic_check; echo survived' 2>&1)"
[[ "$out" == *"restic 0.14.0 ($RUN/bin/restic-014) is older than 0.17.0 (RESTIC_MIN)"* && "$out" != *survived* ]] \
    && ok "restic check: RESTIC_MIN from the shared file counts, its RESTIC_BIN does not (exec, node-local)" || bad "restic shared min: $out"
out="$(S 'inst_restic_check; echo survived' 2>&1)"
[[ "$out" == *"==> restic: 0.14.0"* && "$out" == *survived* ]] && ok "restic check: without the shared file 0.14.0 is enough" || bad "restic local only: $out"
rm -f "$RUN/etc/config" "$RUN/shared.cfg"
# it runs before anything is changed: first in main after the arguments
body="$(S 'declare -f main')"
[[ "$(grep -n 'inst_config_guard' <<<"$body" | cut -d: -f1)" -lt "$(grep -n 'inst_deps' <<<"$body" | cut -d: -f1)" \
   && "$(grep -n 'inst_config_guard' <<<"$body" | cut -d: -f1)" -lt "$(grep -n 'inst_resolve_mode' <<<"$body" | cut -d: -f1)" ]] \
    && ok "guard: runs before the mode is resolved and before any file is installed" || bad "guard order: $body"

# --- plugin install / remove (files under run/, systemctl mocked) -------------------------------------
P() { PBO_INSTALL_PLUGIN_CHECK="${CHECK:-true}" S "$1" 2>&1; }
: > "$MOCK_LOG"
out="$(P inst_plugin_install)"; rc=$?
[[ $rc == 0 ]] && cmp -s pve-plugin/PboPlugin.pm "$RUN/plugin/Custom/PboPlugin.pm" && [[ "$(stat -c %a "$RUN/plugin/Custom/PboPlugin.pm")" == 644 ]] \
    && ok "plugin: installed 0644" || bad "plugin install: rc=$rc $out"
grep -qx 'systemctl reload-or-restart pvedaemon pveproxy pvestatd pvescheduler' "$MOCK_LOG" && ok "plugin: changed → PVE daemons reloaded" || bad "reload: $(cat "$MOCK_LOG")"
: > "$MOCK_LOG"
out="$(P inst_plugin_install)"; rc=$?
[[ $rc == 0 && "$out" == *"is up to date"* && ! -s "$MOCK_LOG" ]] && ok "plugin: unchanged → no copy, no reload" || bad "idempotent: rc=$rc $out $(cat "$MOCK_LOG")"
printf '# an older plugin\n' > "$RUN/plugin/Custom/PboPlugin.pm"; cp "$RUN/plugin/Custom/PboPlugin.pm" "$RUN/old.pm"; : > "$MOCK_LOG"
out="$(CHECK=false P 'inst_plugin_install; echo survived')"; rc=$?
[[ $rc != 0 && "$out" != *survived* && "$out" == *"does not load into PVE::Storage"* ]] && cmp -s "$RUN/old.pm" "$RUN/plugin/Custom/PboPlugin.pm" && [[ ! -s "$MOCK_LOG" ]] \
    && ok "plugin: does not load → the previous one is put back, no reload, install stops" || bad "load fail with previous: rc=$rc $out"
rm -f "$RUN/plugin/Custom/PboPlugin.pm"
out="$(CHECK=false P inst_plugin_install)"; rc=$?
[[ $rc != 0 && ! -e "$RUN/plugin/Custom/PboPlugin.pm" ]] && ok "plugin: does not load, none before → removed again" || bad "load fail fresh: rc=$rc $(ls "$RUN/plugin/Custom")"
P inst_plugin_install >/dev/null
printf 'dir: local\n\tpath /var/lib/vz\n\npbo: pbo\n\tcontent backup\n' > "$RUN/storage.cfg"; : > "$MOCK_LOG"
out="$(P 'inst_plugin_remove; echo survived')"; rc=$?
[[ $rc != 0 && -e "$RUN/plugin/Custom/PboPlugin.pm" && "$out" == *"still has pbo storage(s) (pbo)"* ]] && ok "plugin remove: refused while storage.cfg has a pbo storage" || bad "remove guard: rc=$rc $out"
printf 'dir: local\n\tpath /var/lib/vz\n' > "$RUN/storage.cfg"
out="$(P 'MODE=standalone MODE_SOURCE=default; inst_integration')"
[[ -e "$RUN/plugin/Custom/PboPlugin.pm" && "$out" == *"stays"* ]] && ok "standalone by default: the plugin stays" || bad "default standalone removed it: $out"
out="$(P 'MODE=standalone MODE_SOURCE=flag; inst_integration')"; rc=$?
[[ $rc == 0 && ! -e "$RUN/plugin/Custom/PboPlugin.pm" ]] && grep -q 'reload-or-restart pvedaemon' "$MOCK_LOG" \
    && ok "--integration standalone: plugin removed, daemons reloaded" || bad "remove: rc=$rc $out"

# --- the closing message says what is in place, read only ----------------------------------------------
# systemctl is the mock (is-enabled: MOCK_SYSTEMCTL_ENABLED), storage.cfg,
# vzdump.conf, pmxcfs and the config are files under run/. The message must
# reflect them and change none of them: the mock log may hold is-enabled only.
fm="$RUN/final"; mkdir -p "$fm/etc" "$fm/lib" "$fm/units" "$fm/sbin" "$fm/pve"
all_timers="pbo.timer pbo-prune.timer pbo-verify.timer pbo-test-restore.timer"
# F <mode> <config mode> <snippet>: the closing message (or the snippet) with the run/ paths
# (FLIB: another LIBDIR below $fm, FSHARED: a cluster-shared config below $fm)
F() { PBO_INSTALL_CFGDIR="$fm/etc" PBO_INSTALL_STORAGE_CFG="$fm/storage.cfg" PBO_INSTALL_VZDUMP_CONF="$fm/vzdump.conf" \
      PBO_INSTALL_CFS_DIR="$fm/pve" PBO_INSTALL_LIBDIR="${FLIB:-$fm/lib}" PBO_INSTALL_UNITDIR="$fm/units" PBO_INSTALL_BIN="$fm/sbin/pbo" \
      PBO_INSTALL_SHARED_CFG="${FSHARED:-}" S "MODE=$1 CFG_MODE='$2'; ${3:-inst_final_message}" 2>&1; }
fstate() { cat "$fm/storage.cfg" "$fm/vzdump.conf" "$fm/other-vzdump.conf" "$fm/shared.cfg" "$fm/etc/config" 2>/dev/null | md5sum; ls -la "$fm" "$fm/etc" "$fm/units" 2>&1; }
# every path the closing message reads must be below $fm: a config line that
# moved one out would have it read the machine's own file
fpaths() { F both both 'printf "%s\n" "$(inst_vzdump_conf)" "$CFGDIR" "$STORAGE_CFG" "$CFS_DIR" "$LIBDIR" ${SHARED_CFG:+"$SHARED_CFG"}' | grep -v "^$fm/" || true; }
only_reads() { ! grep -v '^systemctl is-enabled ' "$MOCK_LOG" | grep -q .; }

# a fresh install: no timer enabled, no storage, no hook line, no mode in the config
rm -f "$fm/storage.cfg" "$fm/vzdump.conf" "$fm/etc/config"; : > "$MOCK_LOG"
out="$(MOCK_SYSTEMCTL_ENABLED="" F both '')"
[[ "$out" == *"The wizard offers to enable the schedule at the end. To do it by hand instead:
  systemctl enable --now pbo.timer         (backups, nightly: SCHEDULE_BACKUP)
  systemctl enable --now pbo-prune.timer   (prune, weekly: SCHEDULE_PRUNE)
  systemctl enable --now pbo-verify.timer  (integrity, weekly, 1/12 of the data per run: SCHEDULE_VERIFY)
  systemctl enable --now pbo-test-restore.timer  (restore test, weekly, one guest per run: SCHEDULE_TEST_RESTORE)
'$fm/sbin/pbo timers' shows when each runs"* \
   && "$out" == *"Proxmox integration: both. The storage plugin, the vzdump hook and the units are
in place; the storage itself is not created yet. Once the repo exists:
  $fm/sbin/pbo --dry-run integrate enable both"*"$fm/sbin/pbo integrate enable both              (adds the pbo storage, the hook line in
                                         $fm/vzdump.conf, pbo-catalog.timer)"* \
   && "$out" != *"in place:"* && "$out" != *MISSING* ]] && only_reads \
    && ok "closing message, fresh install: the guidance as before (timers to enable, the storage not created yet)" || bad "final fresh: $out"
out="$(MOCK_SYSTEMCTL_ENABLED="" F standalone '')"
[[ "$out" == *"The wizard offers to enable the schedule"* && "$out" != *"Proxmox integration: "* ]] \
    && ok "closing message, standalone: no integration part" || bad "final standalone: $out"

# an upgrade over a working install: every timer enabled, the storage with its
# spool, our hook line, pbo-catalog.timer, the mode in the config
printf 'dir: local\n\tpath /var/lib/vz\n\tcontent iso\n\npbo: pbo\n\tcontent backup\n\tnodes pve1\n\tpath /var/cache/pbo/pve-spool\n' > "$fm/storage.cfg"
printf '# defaults\ntmpdir: /var/tmp\n# pbo: added by '"'"'pbo integrate enable'"'"'\nscript: %s/vzdump-hook\n' "$fm/lib" > "$fm/vzdump.conf"
printf 'PBO_INTEGRATION=both\n' > "$fm/etc/config"; chmod 600 "$fm/etc/config"
snap="$(fstate)"; : > "$MOCK_LOG"
out="$(MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F both both)"
ok_all=1
for t in $all_timers; do grep -qE "^  $t +enabled +\(" <<<"$out" || ok_all=0; done
[[ $ok_all == 1 && "$out" == *"Timers (install.sh never enables or disables one):"* \
   && "$out" == *"Proxmox integration: both."*"in place: storage pbo present"*"in place: the hook line in $fm/vzdump.conf"*"in place: pbo-catalog.timer enabled"* \
   && "$out" != *"not created yet"* && "$out" != *"integrate enable"* && "$out" != *"NOT enabled"* && "$out" != *MISSING* \
   && "$out" != *"The wizard offers"* && "$out" != *"systemctl enable"* ]] && only_reads && [[ "$(fstate)" == "$snap" ]] \
    && ok "closing message, upgrade with everything in place: each timer enabled, storage pbo present, no next step, nothing changed" || bad "final all: $out $(cat "$MOCK_LOG")"
# the hook of the .deb layout counts as ours too
printf 'script: /usr/lib/pbo/vzdump-hook\n' > "$fm/vzdump.conf"
out="$(MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F both both)"
[[ "$out" == *"in place: the hook line"* && "$out" != *MISSING* ]] && ok "closing message: the packaged hook path is pbo's hook too" || bad "final deb hook: $out"

# a partial state: the storage is there, the hook line and pbo-catalog.timer
# are not, pbo-verify.timer is not enabled
printf '# defaults\ntmpdir: /var/tmp\n' > "$fm/vzdump.conf"
snap="$(fstate)"; : > "$MOCK_LOG"
out="$(MOCK_SYSTEMCTL_ENABLED="pbo.timer pbo-prune.timer pbo-test-restore.timer" F both both)"
re_on='(^|'$'\n'')  pbo\.timer +enabled +\(' re_off='(^|'$'\n'')  pbo-verify\.timer +NOT enabled  \([^)]*\): systemctl enable --now pbo-verify\.timer'
[[ "$out" =~ $re_on && "$out" =~ $re_off \
   && "$out" != *"systemctl enable --now pbo.timer"* && "$out" != *"systemctl enable --now pbo-prune.timer"* \
   && "$out" == *"in place: storage pbo present"*"MISSING:  the hook line in $fm/vzdump.conf"*"MISSING:  pbo-catalog.timer enabled"*"To complete it"*"$fm/sbin/pbo integrate enable both              (adds only what is missing)"* \
   && "$out" != *"not created yet"* && "$out" != *"in place: the hook"* ]] && only_reads && [[ "$(fstate)" == "$snap" ]] \
    && ok "closing message, partial state: each timer's state, what is there, what is missing and the step to complete it, nothing changed" || bad "final partial: $out"
# the mode is written last by integrate enable: a config without it is not finished
out="$(MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F integrated both)"
[[ "$out" == *"MISSING:  PBO_INTEGRATION=integrated in $fm/etc/config (it says both)"*"integrate enable integrated"* ]] \
    && ok "closing message: a mode the config does not have yet is named as missing" || bad "final mode: $out"
# a foreign hook is named (integrate enable refuses to replace it)
printf 'script: /usr/local/bin/other-hook\n' > "$fm/vzdump.conf"
out="$(MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F both both)"
[[ "$out" == *"MISSING:  the hook line"*"runs another hook (script: /usr/local/bin/other-hook)"* ]] \
    && ok "closing message: a foreign script: line is named as such" || bad "final foreign: $out"
# a catalogue-only storage (no path) needs no hook line
printf 'pbo: pbo\n\tcontent backup\n\tnodes pve1\n' > "$fm/storage.cfg"; rm -f "$fm/vzdump.conf"
out="$(MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F both both)"
[[ "$out" == *"in place: storage pbo present (catalogue only: no spool, no hook)"* && "$out" != *MISSING* && "$out" != *"integrate enable"* ]] \
    && ok "closing message: a catalogue-only storage without a hook line is complete" || bad "final catalog-only: $out"
# ... and with a foreign hook: --catalog-only is what integrate enable offers
# then, the foreign hook stays and blocks nothing (no jobs, nothing to ingest)
printf 'script: /usr/local/bin/other-hook\n' > "$fm/vzdump.conf"
snap="$(fstate)"; : > "$MOCK_LOG"
out="$(MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F both both)"
[[ "$out" == *"in place: storage pbo present (catalogue only: no spool, no hook)"* \
   && "$out" == *"in place: $fm/vzdump.conf runs another hook (script: /usr/local/bin/other-hook), left as is: a catalogue-only storage needs none"* \
   && "$out" != *MISSING* && "$out" != *"integrate enable"* && "$out" != *"not ingested"* ]] && only_reads && [[ "$(fstate)" == "$snap" ]] \
    && ok "closing message: a catalogue-only storage with a foreign hook is complete (the hook left as is), nothing changed" || bad "final catalog-only foreign: $out"
# a partial catalogue-only setup: the next step keeps --catalog-only (a plain
# enable would add a spool and the hook line, or refuse over a foreign hook)
for vz in '' 'script: /usr/local/bin/other-hook'; do
    if [[ -n "$vz" ]]; then printf '%s\n' "$vz" > "$fm/vzdump.conf"; else rm -f "$fm/vzdump.conf"; fi
    : > "$MOCK_LOG"
    out="$(MOCK_SYSTEMCTL_ENABLED="$all_timers" F both both)"
    [[ "$out" == *"MISSING:  pbo-catalog.timer enabled"* && "$out" != *"MISSING:  the hook line"* \
       && "$out" == *"$fm/sbin/pbo --dry-run integrate enable both --catalog-only    (what it would change)"* \
       && "$out" == *"$fm/sbin/pbo integrate enable both --catalog-only              (adds only what is missing)"* \
       && "$out" != *"integrate enable both "[!-]* ]] && only_reads \
        && ok "closing message: catalogue-only, pbo-catalog.timer not enabled (${vz:-no script: line}) → 'integrate enable both --catalog-only'" || bad "final catalog-only partial ($vz): $out"
    out="$(MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F both '')"
    [[ "$out" == *"MISSING:  PBO_INTEGRATION=both in $fm/etc/config (it says standalone)"* && "$out" == *"integrate enable both --catalog-only "* \
       && "$out" != *"MISSING:  the hook line"* ]] \
        && ok "closing message: catalogue-only, the mode not in the config yet (${vz:-no script: line}) → --catalog-only too" || bad "final catalog-only mode ($vz): $out"
done
# integrated has no catalogue-only form (enable refuses it): the spool and the
# hook are what is missing, and the plain enable is the step
rm -f "$fm/vzdump.conf"
out="$(MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F integrated integrated)"
[[ "$out" == *"MISSING:  a spool (path) for storage pbo"* && "$out" == *"MISSING:  the hook line in $fm/vzdump.conf"* \
   && "$out" == *"$fm/sbin/pbo integrate enable integrated              (adds only what is missing)"* && "$out" != *"--catalog-only"* ]] \
    && ok "closing message: integrated over a catalogue-only storage names the spool and the hook as missing, no --catalog-only" || bad "final catalog-only integrated: $out"

# the hook pbo counts as its own (_integ_is_our_hook): PBO_VZDUMP_HOOK from the
# local config, the hook next to pbo (also through a symlinked LIBDIR)
printf 'dir: local\n\tpath /var/lib/vz\n\npbo: pbo\n\tcontent backup\n\tnodes pve1\n\tpath /var/cache/pbo/pve-spool\n' > "$fm/storage.cfg"
printf 'script: %s/site-hook\n' "$fm" > "$fm/vzdump.conf"
printf 'PBO_INTEGRATION=both\nPBO_VZDUMP_HOOK=%s/site-hook\n' "$fm" > "$fm/etc/config"; chmod 600 "$fm/etc/config"
[[ -z "$(fpaths)" ]] && ok "closing message: every path it reads is below the run dir" || bad "final paths outside the run dir: $(fpaths)"
snap="$(fstate)"; : > "$MOCK_LOG"
out="$(MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F both both)"
[[ "$out" == *"in place: the hook line in $fm/vzdump.conf"* && "$out" != *MISSING* && "$out" != *"another hook"* && "$out" != *"integrate enable"* ]] \
   && only_reads && [[ "$(fstate)" == "$snap" ]] \
    && ok "closing message: the hook PBO_VZDUMP_HOOK names is pbo's hook, nothing changed" || bad "final PBO_VZDUMP_HOOK: $out"
# PBO_VZDUMP_HOOK is exec: pbo ignores it in the cluster-shared file, so does this
printf 'PBO_VZDUMP_HOOK=%s/site-hook\n' "$fm" > "$fm/shared.cfg"
printf 'PBO_INTEGRATION=both\n' > "$fm/etc/config"
out="$(FSHARED="$fm/shared.cfg" MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F both both)"
[[ "$out" == *"MISSING:  the hook line"*"runs another hook (script: $fm/site-hook)"* ]] \
    && ok "closing message: PBO_VZDUMP_HOOK in the cluster-shared file does not count (pbo ignores it there)" || bad "final shared hook: $out"
rm -f "$fm/shared.cfg"
mkdir -p "$fm/real-lib"; ln -sfn "$fm/real-lib" "$fm/lib-link"
printf 'script: %s/real-lib/vzdump-hook\n' "$fm" > "$fm/vzdump.conf"
out="$(FLIB="$fm/lib-link" MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F both both)"
[[ "$out" == *"in place: the hook line"* && "$out" != *MISSING* && "$out" != *"another hook"* ]] \
    && ok "closing message: a symlinked LIBDIR: the resolved hook path (what pbo writes) is pbo's hook" || bad "final symlinked libdir: $out"
# VZDUMP_CONF from the config: the file pbo integrate writes the hook line to
printf '# defaults\ntmpdir: /var/tmp\n' > "$fm/vzdump.conf"
printf 'script: %s/lib/vzdump-hook\n' "$fm" > "$fm/other-vzdump.conf"
printf 'PBO_INTEGRATION=both\nVZDUMP_CONF=%s/other-vzdump.conf\n' "$fm" > "$fm/etc/config"
[[ -z "$(fpaths)" ]] && ok "closing message: ... also with VZDUMP_CONF set in the config" || bad "final paths outside the run dir: $(fpaths)"
snap="$(fstate)"; : > "$MOCK_LOG"
out="$(MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F both both)"
[[ "$out" == *"in place: the hook line in $fm/other-vzdump.conf"* && "$out" != *MISSING* \
   && "$out" == *"the hook line from $fm/other-vzdump.conf"* && "$out" != *"$fm/vzdump.conf"* ]] && only_reads && [[ "$(fstate)" == "$snap" ]] \
    && ok "closing message: VZDUMP_CONF from the config is the file checked and named (the uninstall hint too), nothing changed" || bad "final VZDUMP_CONF: $out"
# ... from the cluster-shared file (an ordinary key there), the local one winning
printf 'PBO_INTEGRATION=both\n' > "$fm/etc/config"
printf 'VZDUMP_CONF=%s/other-vzdump.conf\n' "$fm" > "$fm/shared.cfg"
out="$(FSHARED="$fm/shared.cfg" MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F both both)"
[[ "$out" == *"in place: the hook line in $fm/other-vzdump.conf"* ]] && ok "closing message: VZDUMP_CONF from the cluster-shared file" || bad "final shared VZDUMP_CONF: $out"
printf 'PBO_INTEGRATION=both\nVZDUMP_CONF=%s/vzdump.conf\n' "$fm" > "$fm/etc/config"
out="$(FSHARED="$fm/shared.cfg" MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F both both)"
[[ "$out" == *"MISSING:  the hook line in $fm/vzdump.conf"* ]] && ok "closing message: ... the local VZDUMP_CONF wins over the shared one" || bad "final local VZDUMP_CONF: $out"
rm -f "$fm/shared.cfg" "$fm/other-vzdump.conf"
printf 'PBO_INTEGRATION=both\n' > "$fm/etc/config"
# the storage id: PVE_STORAGE_ID from the config, else derived as pbo derives
# it (pbo-<node> in a cluster); another node's entry is not this node's
printf 'pbo: pbo-pve2\n\tcontent backup\n\tnodes pve2\n\tpath /x\n' > "$fm/storage.cfg"
printf '{"nodename":"pve1","version":3,"cluster":{"name":"lab","version":2,"nodes":2,"quorate":1}}\n' > "$fm/pve/.members"
out="$(MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F both both)"
[[ "$out" == *"MISSING:  storage pbo-pve1"* && "$out" != *"storage pbo-pve2 present"* ]] && ok "closing message: in a cluster this node's storage is pbo-<node>" || bad "final cluster: $out"
printf 'PBO_INTEGRATION=both\nPVE_STORAGE_ID=pbo-pve2\n' > "$fm/etc/config"
out="$(MOCK_SYSTEMCTL_ENABLED="$all_timers pbo-catalog.timer" F both both)"
[[ "$out" == *"in place: storage pbo-pve2 present"* ]] && ok "closing message: PVE_STORAGE_ID from the config names the storage" || bad "final storage id: $out"
rm -f "$fm/pve/.members"
# the integration files' line says whether pbo-catalog.timer is enabled
out="$(MOCK_SYSTEMCTL_ENABLED="pbo-catalog.timer" F both both inst_integration_files)"
[[ "$out" == *"pbo-catalog.timer (enabled)"* && -x "$fm/lib/vzdump-hook" && -f "$fm/units/pbo-catalog.timer" ]] \
    && ok "integration files: pbo-catalog.timer shown as enabled when it is" || bad "integration files enabled: $out"
out="$(MOCK_SYSTEMCTL_ENABLED="" F both both inst_integration_files)"
[[ "$out" == *"pbo-catalog.timer (not enabled: 'pbo integrate enable' starts it)"* ]] && ok "integration files: ... and as not enabled when it is not" || bad "integration files off: $out"

# --- the hook is not a lib .sh ----------------------------------------------------------------------
[[ "$(printf '%s\n' lib/*.sh | grep -c vzdump-hook)" == 0 && -x lib/vzdump-hook ]] && ok "lib/*.sh does not match the hook (installed on its own, 0755)" || bad "hook glob"

# --- a pbo-web left by 0.4 is removed; without one nothing happens ----------------------------------------
W="$RUN/web"; mkdir -p "$W/lib" "$W/units" "$W/etc/web-tls"
for f in "$W/units/pbo-web.service" "$W/units/pbo-web-helper.service" "$W/lib/pbo-web" "$W/lib/pbo-web-egress.nft" "$W/etc/web.env" "$W/etc/web-tls/tls.key"; do : > "$f"; done
: > "$W/units/pbo.service"; : > "$W/etc/config"
: > "$MOCK_LOG"
out="$(PBO_INSTALL_LIBDIR="$W/lib" PBO_INSTALL_UNITDIR="$W/units" PBO_INSTALL_CFGDIR="$W/etc" S 'inst_web_remove; echo "removed=$WEB_REMOVED"' 2>&1)"
[[ "$out" == *"removed=1"* && -z "$(ls "$W/lib")" && "$(ls "$W/units")" == pbo.service && "$(ls "$W/etc")" == config ]] \
    && ok "inst_web_remove: pbo-web units, binary, egress rule, web.env and web-tls removed; pbo's own files kept" || bad "web remove: $out; $(ls -R "$W")"
grep -q 'systemctl disable --now pbo-web.service pbo-web-helper.service' "$MOCK_LOG" && ok "inst_web_remove: stops and disables both services" || bad "web remove systemctl: $(cat "$MOCK_LOG")"
out="$(PBO_INSTALL_LIBDIR="$W/lib" PBO_INSTALL_UNITDIR="$W/units" PBO_INSTALL_CFGDIR="$W/etc" S 'inst_web_remove; echo "removed=$WEB_REMOVED"' 2>&1)"
[[ "$out" == "removed=0" ]] && ok "inst_web_remove: nothing to remove → silent, WEB_REMOVED=0" || bad "web remove twice: $out"

# --- nothing outside run/ -------------------------------------------------------------------------------
[[ "$(stat -c '%i %Y' "$REAL_PLUGIN" 2>/dev/null || echo none)" == "$real_before" && "$(stat -c '%i %Y' /usr/local/lib/pbo 2>/dev/null || echo none)" == "$libdir_before" ]] \
    && ok "the real plugin path and /usr/local/lib/pbo are untouched" || bad "something outside run/ changed"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
