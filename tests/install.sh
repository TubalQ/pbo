#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/install.sh: install.sh's logic, sourced (its main never runs): Debian
# version comparison, the PVE version refusal, how the integration mode is
# resolved (flag, existing config, terminal prompt, default), the --janitor
# conflict, and the plugin install/remove steps against files under run/ with
# systemctl and dpkg-query mocked. Nothing is installed on the host.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE and NTFY_CREDS_FILE are the machine's
# own files: point them into the checkout, at paths nothing creates (a config
# line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.creds"
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
