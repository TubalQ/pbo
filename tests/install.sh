#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/install.sh: install.sh's logic, sourced (its main never runs): Debian
# version comparison, the PVE version refusal, how the integration mode is
# resolved (flag, existing config, terminal prompt, default), the --janitor
# conflict, and the plugin install/remove steps against files under run/ with
# systemctl and dpkg-query mocked. Nothing is installed on the host.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
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
rm -f "$RUN/etc/config"

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
