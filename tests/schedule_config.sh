#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/schedule_config.sh: the timer schedules as config keys (ADR 0009,
# "Portability", MP part 2; lib/timers.sh). The SCHEDULE_* defaults against
# the units in systemd/, `pbo config set|unset` writing and removing the
# drop-ins (<timer>.d/schedule.conf), daemon-reload, and for a running
# enabled timer stop, clean --what=state (its last-trigger stamp) and start in
# that order, values refused (78, nothing written) with and without
# systemd-analyze, a dry run, `pbo timers` and `pbo timers apply`, doctor's
# drift warnings and `doctor --fix`, the calendar systemd runs compared with
# the config, install.sh re-applying a custom schedule over freshly installed
# units, the janitor's own keys and its root pass, and the PVE job window
# compared with the schedule.
#
# pbo runs as a copy of the entry point that sources
# tests/fixtures/run_dir_guard.sh: it stops (99) before any command when a
# path it resolved (config, directories, PVE paths, the systemd directory)
# lies outside run-schedule-config/, and before any drop-in or config write
# there. systemctl, pvesh, pvesm, pct, qm are mocks; restic is a fake script.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
skip() { printf '  SKIP %s\n' "$1"; }
command -v jq >/dev/null 2>&1 || { echo "jq not installed, skipping schedule config tests"; exit 0; }

printf 'pbo: timer schedule tests\n'
RUN="$ROOT/run-schedule-config"; rm -rf "$RUN"
mkdir -p "$RUN"/{bin,cache,state,log,lock,sysd,units,tree,pve,lxc,qemu,tmp,none,mnt,inst}
for m in systemctl pvesh pvesm pct qm vzdump dpkg-query pveum; do install -m 0755 "tests/mocks/$m" "$RUN/bin/"; done
export PATH="$RUN/bin:$PATH" MOCK_LOG="$RUN/calls" MOCK_CONF_DIR="$RUN/lxc" MOCK_SYSTEMCTL_DIR="$RUN/sysd" TMPDIR="$RUN/tmp"
# only the units a test enables are enabled (the mock: MOCK_SYSTEMCTL_ENABLED set, even empty)
export MOCK_SYSTEMCTL_ENABLED=""
# read from the environment at start (lib/notify.sh), and the env-only defaults
export PBO_PVE_TEMPLATE_DIR="$RUN/none/templates" RESTIC_ENV_FILE="$RUN/none/restic.env" NTFY_CREDS_FILE="$RUN/none/ntfy.env"
: > "$MOCK_LOG"; chmod 0700 "$RUN/mnt"
# a single node, as PVE lists it: a cluster of one
printf '{"nodename":"pve1","version":3,"cluster":{"name":"lab","version":1,"nodes":1,"quorate":1},"nodelist":{"pve1":{"id":1,"online":1,"ip":"192.0.2.11"}}}\n' > "$RUN/pve/.members"
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
cat > "$RUN/bin/restic-fake" <<'EOF'
#!/usr/bin/env bash
for a; do case "$a" in version) echo "restic 0.18.0 compiled with go1.24 on linux/amd64"; exit 0 ;; --help) exit 0 ;; esac; done
case " $* " in *" snapshots "*) echo '[]' ;; esac
exit 0
EOF
chmod 0755 "$RUN/bin/restic-fake"
UNITS="$RUN/units"   # PBO_SYSTEMD_DIR: where the drop-ins go

# the entry point with the guard sourced right before main (lib/ linked)
if [[ "$(tail -n 1 pbo)" != 'main "$@"' ]]; then
    bad "the entry point no longer ends in main \"\$@\": the harness needs a new hook"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi
{ sed '$d' pbo; printf '%s\n' 'source "$SELF_DIR/../../tests/fixtures/run_dir_guard.sh"'; tail -n 1 pbo; } > "$RUN/tree/pbo"
chmod 755 "$RUN/tree/pbo"; ln -s "$ROOT/lib" "$RUN/tree/lib"
export TEST_RUN="$RUN"
BIN="$RUN/tree/pbo"

CFG="$RUN/config"
cfg() {   # cfg [--no-sysdir] <extra lines...>: the suite's config, every path in $RUN
    local sysd=1; [[ "${1:-}" == --no-sysdir ]] && { sysd=0; shift; }
    { cat <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
RESTIC_CACHE_REPO=$RUN/cache/repo
RESTIC_BIN=$RUN/bin/restic-fake
OFFSITE_ENABLED=false
BACKUP_ORDER=8001
STORAGE_BOX_SNAPSHOTS_CONFIRMED=true
NOTIFY_PVE=false
PBO_PVE_LXC_DIR=$RUN/lxc
PBO_PVE_QEMU_DIR=$RUN/qemu
PBO_PVE_CFS_DIR=$RUN/pve
PVE_STORAGE_CFG=$RUN/storage.cfg
PBO_PVE_STORAGE_CFG=$RUN/storage.cfg
VZDUMP_CONF=$RUN/vzdump.conf
VZDUMP_LOCK=$RUN/vzdump.lock
PBO_CATALOG=$RUN/state/catalog/index.json
PVE_CATALOG_MOUNT_DIR=$RUN/mnt/restic
PBO_PERMS_PARENTS_TOP=$RUN
PBO_PERMS_CONFIG_DIR=$RUN
EOF
      (( sysd )) && printf 'PBO_SYSTEMD_DIR=%s\n' "$UNITS"
      printf '%s\n' "$@"; } > "$CFG"; chmod 600 "$CFG"
}
export PBO_CONFIG="$CFG"
P()  { out="$("$BIN" "$@" 2>"$RUN/err")"; rc=$?; }
PJ() { out="$("$BIN" --json "$@" 2>"$RUN/err")"; rc=$?; }
DI() { printf '%s/%s.d/schedule.conf' "$UNITS" "$1"; }   # the drop-in of a timer
calls() { grep -c -- "$1" "$MOCK_LOG"; }
# sdseq UNIT: the state-changing systemctl calls for UNIT (and daemon-reload), in order
sdseq() { sed -nE "s/^systemctl (daemon-reload|(stop|start|restart|clean --what=state) $1)$/\1/p" "$MOCK_LOG" | paste -sd'|' -; }

# --- the harness ---------------------------------------------------------------------------
cfg --no-sysdir
out="$(env -u PBO_SYSTEMD_DIR "$BIN" config get SCHEDULE_BACKUP 2>"$RUN/err")"; rc=$?   # (tests/all.sh points it into the checkout)
[[ $rc == 99 ]] && grep -q 'PBO_SYSTEMD_DIR=/etc/systemd/system is outside' "$RUN/err" \
    && ok "harness: a config that leaves PBO_SYSTEMD_DIR at the host's directory stops pbo (99) before it runs" || bad "guard: rc=$rc $(cat "$RUN/err")"
cfg
P config get SCHEDULE_BACKUP
[[ $rc == 0 ]] && ok "harness: with every path in the run directory pbo runs" || bad "guarded run: rc=$rc $(cat "$RUN/err")"

# --- the defaults are the units' own values ---------------------------------------------------
# every timer in systemd/ has its keys, and the unit's OnCalendar= and
# RandomizedDelaySec= are the schema defaults (the units carry the default,
# a drop-in the rest)
out=""
rows="$(bash -c 'source lib/common.sh; source lib/config_schema.sh; source lib/timers.sh; printf "%s\n" "$SCHED_TIMERS"')"
for f in systemd/*.timer; do
    u="${f##*/}"; row="$(grep "^$u|" <<<"$rows")"
    [[ -n "$row" ]] || { out+="$u has no SCHEDULE_* row; "; continue; }
    IFS='|' read -r _ ck dk role <<<"$row"
    ucal="$(sed -n 's/^OnCalendar=//p' "$f")"; udly="$(sed -n 's/^RandomizedDelaySec=//p' "$f")"
    d="$(bash -c 'source lib/config_schema.sh; _cs_default "$1"' _ "$ck")"
    [[ "$ucal" == "$d" ]] || out+="$u OnCalendar=$ucal vs $ck=$d; "
    if [[ -n "$dk" ]]; then
        d="$(bash -c 'source lib/config_schema.sh; _cs_default "$1"' _ "$dk")"
        [[ "$udly" == "$d" ]] || out+="$u RandomizedDelaySec=$udly vs $dk=$d; "
    else
        [[ -z "$udly" ]] || out+="$u has RandomizedDelaySec=$udly but no delay key; "
    fi
    r="$(bash -c 'source lib/config_schema.sh; _cs_load; printf %s "${CS_ROLES[$1]}"' _ "$ck")"
    [[ "$r" == "$role" ]] || out+="$ck roles $r vs table $role; "
done
[[ -z "$out" ]] && ok "every unit in systemd/ has its SCHEDULE_* keys, and their defaults are the units' OnCalendar= and RandomizedDelaySec=" || bad "units vs schema: $out"
if command -v systemd-analyze >/dev/null 2>&1; then
    out=""
    while IFS='|' read -r u ck dk _; do
        d="$(bash -c 'source lib/config_schema.sh; _cs_default "$1"' _ "$ck")"
        systemd-analyze calendar -- "$d" >/dev/null 2>&1 || out+="$ck='$d' "
        if [[ -n "$dk" ]]; then d="$(bash -c 'source lib/config_schema.sh; _cs_default "$1"' _ "$dk")"; systemd-analyze timespan -- "$d" >/dev/null 2>&1 || out+="$dk='$d' "; fi
    done <<<"$rows"
    [[ -z "$out" ]] && ok "the defaults are valid for systemd-analyze (validation skips them as valid by construction)" || bad "invalid defaults: $out"
else
    skip "systemd-analyze is not installed: the defaults are not checked by systemd"
fi

# --- pbo timers apply with the defaults: nothing --------------------------------------------
: > "$MOCK_LOG"
P timers apply
[[ $rc == 0 && -z "$(find "$UNITS" -mindepth 1 2>/dev/null)" && "$(calls 'daemon-reload')" == 0 ]] \
    && grep -q '^pbo.timer: \*-\*-\* 05:00:00 (default)$' <<<"$out" \
    && ok "timers apply, every key at its default: no drop-in, no daemon-reload" || bad "apply defaults: rc=$rc $out / $(ls -R "$UNITS")"

# --- config set: drop-in written, daemon-reload, restart only when enabled ------------------
# A running enabled timer is stopped before its drop-in changes, its stamp is
# cleared after the reload (Persistent=true computes the next run from the last
# trigger: a time earlier than the last run would start the job at once), then
# it is started again.
: > "$MOCK_LOG"; : > "$RUN/sysd/pbo-prune.timer.active"
MOCK_SYSTEMCTL_ENABLED="pbo-prune.timer" P config set SCHEDULE_PRUNE 'Sat *-*-* 03:00:00'
want="$(printf '%s\n' "# Written by pbo from its config (SCHEDULE_PRUNE, SCHEDULE_PRUNE_DELAY). pbo rewrites or removes" \
    "# this file ('pbo config set', 'pbo timers apply', 'pbo doctor --fix'): change" "# the keys, not this file." \
    '[Timer]' 'OnCalendar=' 'OnCalendar=Sat *-*-* 03:00:00')"
[[ $rc == 0 && "$(cat "$(DI pbo-prune.timer)" 2>/dev/null)" == "$want" && "$(stat -c %a "$(DI pbo-prune.timer)" 2>/dev/null)" == 644 ]] \
    && grep -qx 'SCHEDULE_PRUNE="Sat \*-\*-\* 03:00:00"' "$CFG" \
    && ok "config set SCHEDULE_PRUNE: the config line, and the drop-in (OnCalendar= reset, then the value; 0644; no delay line at the default)" \
    || bad "set prune: rc=$rc $(cat "$RUN/err") / $(cat "$(DI pbo-prune.timer)" 2>&1)"
[[ "$(calls '^systemctl daemon-reload$')" == 1 && "$(sdseq pbo-prune.timer)" == 'stop pbo-prune.timer|daemon-reload|clean --what=state pbo-prune.timer|start pbo-prune.timer' ]] \
    && [[ -e "$RUN/sysd/pbo-prune.timer.active" ]] \
    && ok "config set: the running enabled timer is stopped, then daemon-reload, clean --what=state (its last-trigger stamp), start" || bad "reload/restart: $(sdseq pbo-prune.timer) / $(cat "$MOCK_LOG")"
grep -q 'apply-schedule: pbo-prune.timer: .*written' <<<"$out" \
    && grep -q 'apply-schedule: systemctl daemon-reload, restarted pbo-prune.timer (next run computed from now; a run missed under the old schedule is not caught up)' <<<"$out" \
    && ok "config set reports the hook: drop-in written, reload, restart (and that the next run counts from now)" || bad "hook report: $out"
grep -q 'timers: pbo-prune.timer schedule drop-in written' "$RUN/log/audit.log" 2>/dev/null && ok "the drop-in change is audit-logged" || bad "audit: $(tail -3 "$RUN/log/audit.log" 2>&1)"
: > "$MOCK_LOG"
P config set SCHEDULE_BACKUP '*-*-* 01:30:00'
[[ $rc == 0 && -f "$(DI pbo.timer)" && "$(calls '^systemctl daemon-reload$')" == 1 && "$(sdseq pbo.timer)" == daemon-reload ]] \
    && grep -q 'no timer restarted: none of them is enabled' <<<"$out" \
    && ok "a disabled timer: drop-in written and reloaded, not stopped, cleaned or started (pbo never starts a timer)" || bad "disabled timer: rc=$rc $out / $(cat "$MOCK_LOG")"
# enabled but not running: its stamp is cleared, it stays stopped
: > "$MOCK_LOG"; rm -f "$RUN/sysd/pbo.timer.active"
MOCK_SYSTEMCTL_ENABLED="pbo.timer" P config set SCHEDULE_BACKUP '*-*-* 01:45:00'
[[ $rc == 0 && "$(sdseq pbo.timer)" == 'daemon-reload|clean --what=state pbo.timer' && ! -e "$RUN/sysd/pbo.timer.active" ]] \
    && grep -q 'no timer restarted: pbo.timer enabled but not running, left stopped' <<<"$out" \
    && ok "an enabled timer that is not running: stamp cleared, left stopped" || bad "enabled idle: rc=$rc $(sdseq pbo.timer) $out"
# systemd older than 247 (no clean): said, and the timer still runs again
: > "$MOCK_LOG"; : > "$RUN/sysd/pbo.timer.active"
MOCK_SYSTEMCTL_FAIL=clean MOCK_SYSTEMCTL_ENABLED="pbo.timer" P config set SCHEDULE_BACKUP '*-*-* 01:30:00'
[[ $rc == 0 && "$(sdseq pbo.timer)" == 'stop pbo.timer|daemon-reload|clean --what=state pbo.timer|start pbo.timer' && -e "$RUN/sysd/pbo.timer.active" ]] \
    && grep -q 'could not clear the last-trigger stamp of pbo.timer' <<<"$out" \
    && ok "clean --what=state failing (old systemd): the timer is started again and the report says it may run at once" || bad "no clean: rc=$rc $(sdseq pbo.timer) $out"
rm -f "$RUN/sysd/pbo.timer.active"
[[ ! -e "$(DI pbo-verify.timer)" && ! -e "$(DI pbo-test-restore.timer)" ]] && ok "only the timer whose key changed gets a drop-in" || bad "other drop-ins: $(ls "$UNITS")"
: > "$MOCK_LOG"
MOCK_SYSTEMCTL_ENABLED="pbo-prune.timer" P config set SCHEDULE_PRUNE_DELAY 1h
[[ $rc == 0 && "$(tail -2 "$(DI pbo-prune.timer)")" == $'OnCalendar=Sat *-*-* 03:00:00\nRandomizedDelaySec=1h' ]] \
    && ok "the delay key: RandomizedDelaySec= next to the calendar in the same drop-in" || bad "delay: rc=$rc $(cat "$(DI pbo-prune.timer)")"
: > "$MOCK_LOG"
MOCK_SYSTEMCTL_ENABLED="pbo-prune.timer" P config set SCHEDULE_PRUNE_DELAY 1h
[[ $rc == 0 && "$(calls daemon-reload)" == 0 ]] && ok "the same value again: nothing to change, no reload" || bad "idempotent: rc=$rc $(cat "$MOCK_LOG")"

# --- invalid values: 78, nothing written, no systemctl call ----------------------------------
cp "$CFG" "$RUN/c.before"; cp "$(DI pbo.timer)" "$RUN/d.before"
badv=('Fooday 05:00' $'*-*-* 05:00:00\nExecStart=/bin/sh' '05:00 %n' 'x=y' '[Service]' '*-*-* 05:00:00\' ' 05:00')
out_all=""
for v in "${badv[@]}"; do
    : > "$MOCK_LOG"
    P config set SCHEDULE_BACKUP "$v"
    if [[ $rc != 78 ]] || ! cmp -s "$CFG" "$RUN/c.before" || ! cmp -s "$(DI pbo.timer)" "$RUN/d.before" || [[ -s "$MOCK_LOG" ]]; then
        out_all+="[$(printf %q "$v"): rc=$rc $(head -c 200 "$RUN/err")] "
    fi
done
[[ -z "$out_all" ]] && ok "invalid calendars (a typo, a newline with a unit line, %, =, a section, a backslash, a leading blank): 78, config and drop-in unchanged, no systemctl call" || bad "invalid: $out_all"
P config set SCHEDULE_PRUNE_DELAY 'soon'
[[ $rc == 78 ]] && grep -q 'not a systemd time span' "$RUN/err" && ok "an invalid time span: 78" || bad "timespan: rc=$rc $(cat "$RUN/err")"
# without systemd-analyze (a CI container): the narrow check. Every value it
# takes must be one systemd takes: the drop-in clears the unit's calendar
# first, so a value systemd ignores would leave the timer with no trigger.
out_all=""
for v in 'Fooday 05:00' 'Mon 25:00' '*-13-45 05:00' '99:99' '*-*-* 25:99:00' '2026-13-45 05:00' '1:2:3:4' 'Mon 05:00 Europe/Nowhere' '*-*-* */2:00'; do
    : > "$MOCK_LOG"
    PBO_TOOLS_MISSING=systemd-analyze P config set SCHEDULE_BACKUP "$v"
    if [[ $rc != 78 ]] || ! cmp -s "$CFG" "$RUN/c.before" || ! cmp -s "$(DI pbo.timer)" "$RUN/d.before" || [[ -s "$MOCK_LOG" ]]; then
        out_all+="[$v: rc=$rc $(head -c 200 "$RUN/err")] "
    fi
done
[[ -z "$out_all" ]] && ok "without systemd-analyze: out-of-range times and dates, four time fields, an unknown time zone, a repetition from '*': 78, config and drop-in unchanged" \
    || bad "fallback refusals: $out_all"
out_all=""
for v in 'Mon..Fri 05:00' '*:0/15' 'Mon..Fri *-*-* 22:30:00' 'Sat,Sun *-*-* 23:59:59' '*-*~1 12:00' 'Mon 05:00 UTC'; do
    PBO_TOOLS_MISSING=systemd-analyze P config set SCHEDULE_VERIFY "$v"
    [[ $rc == 0 && -f "$(DI pbo-verify.timer)" ]] || out_all+="[$v: rc=$rc $(head -c 200 "$RUN/err")] "
done
[[ -z "$out_all" ]] && ok "without systemd-analyze: the common forms are still taken (weekday ranges, a repetition, the last day of the month, UTC)" || bad "fallback accepts: $out_all"
P config unset SCHEDULE_VERIFY

# --- dry run ---------------------------------------------------------------------------------
cp "$CFG" "$RUN/c.before"; : > "$MOCK_LOG"
P --dry-run config set SCHEDULE_TEST_RESTORE 'Sun *-*-* 11:00:00'
[[ $rc == 0 && ! -e "$(DI pbo-test-restore.timer)" && "$(calls systemctl)" == 0 ]] && cmp -s "$CFG" "$RUN/c.before" \
    && grep -q 'would write .*pbo-test-restore.timer.d/schedule.conf' <<<"$out" \
    && ok "--dry-run: says which drop-in it would write, writes nothing, calls no systemctl" || bad "dry run: rc=$rc $out / $(cat "$MOCK_LOG")"

# --- unset: the drop-in goes (and its empty directory) ----------------------------------------
: > "$MOCK_LOG"
MOCK_SYSTEMCTL_ENABLED="pbo-prune.timer" P config unset SCHEDULE_PRUNE SCHEDULE_PRUNE_DELAY
[[ $rc == 0 && ! -e "$(DI pbo-prune.timer)" && ! -d "$UNITS/pbo-prune.timer.d" ]] \
    && [[ "$(sdseq pbo-prune.timer)" == 'stop pbo-prune.timer|daemon-reload|clean --what=state pbo-prune.timer|start pbo-prune.timer' ]] \
    && ok "unset (back to the default): the drop-in and its empty directory removed, reloaded, the enabled timer stopped, reset and started" || bad "unset: rc=$rc $out / $(ls -R "$UNITS")"
mkdir -p "$UNITS/pbo.timer.d"; printf '[Timer]\nPersistent=false\n' > "$UNITS/pbo.timer.d/override.conf"
P config set SCHEDULE_BACKUP '*-*-* 05:00:00'
[[ $rc == 0 && ! -e "$(DI pbo.timer)" && -f "$UNITS/pbo.timer.d/override.conf" ]] \
    && ok "a value back at the default removes the drop-in; another drop-in in that directory stays" || bad "default value: rc=$rc $(ls "$UNITS/pbo.timer.d" 2>&1)"
rm -rf "$UNITS/pbo.timer.d"; P config unset SCHEDULE_BACKUP

# --- pbo timers -------------------------------------------------------------------------------
P config set SCHEDULE_VERIFY 'Thu *-*-* 09:00:00'
PJ timers
jq -e '(.timers[] | select(.unit == "pbo-verify.timer") | .schedule | .key == "SCHEDULE_VERIFY" and .value == "Thu *-*-* 09:00:00" and .source == "config" and .default == "Wed *-*-* 10:00:00" and .dropin_current)
       and (.timers[] | select(.unit == "pbo.timer") | .schedule | .source == "default" and .value == "*-*-* 05:00:00" and (.dropin_present | not))' >/dev/null 2>&1 <<<"$out" \
    && ok "timers --json: the configured schedule, its source (config, default) and the drop-in's state" || bad "timers json: $out"
P timers
grep -qE '^pbo-verify\.timer +[a-z ]+ +Thu \*-\*-\* 09:00:00 +config' <<<"$out" && grep -qE '^pbo\.timer +.* +\*-\*-\* 05:00:00 +default' <<<"$out" \
    && ok "timers: the SCHEDULE and SOURCE columns" || bad "timers text: $out"
# what systemd runs is not always the config: an override.conf from
# `systemctl edit` (how a time was changed before 0.6), a reload that failed.
# The mock answers `systemctl show` from <unit>.show.
sdshow() { printf '%s\n' "LoadState=loaded" "UnitFileState=enabled" "ActiveState=active" "$@" > "$RUN/sysd/pbo.timer.show"; }
sdshow 'TimersCalendar={ OnCalendar=*-*-* 23:00:00 ; next_elapse=Thu 2026-01-15 23:00:00 UTC }'
P timers
grep -qE '^pbo\.timer +enabled +\*-\*-\* 23:00:00 +default' <<<"$out" \
    && ok "timers: SCHEDULE shows the calendar systemd runs (23:00 from an override.conf), not the config's default" || bad "timers effective: $out"
if command -v systemd-analyze >/dev/null 2>&1; then
    grep -qF 'note: pbo.timer: systemd runs *-*-* 23:00:00, the config says *-*-* 05:00:00 (another drop-in' <<<"$out" \
        && ok "timers: a note where systemd and the config disagree" || bad "timers effective note: $out"
    PJ doctor
    jq -e 'any(.findings[]; .level == "warn" and (.message | startswith("pbo.timer: systemd runs *-*-* 23:00:00, the config says *-*-* 05:00:00")))
           and (any(.findings[]; .message | test("all defaults")) | not)' >/dev/null 2>&1 <<<"$out" \
        && ok "doctor WARNs: systemd runs another calendar than the config says (no 'as the config says' for it)" || bad "doctor effective: $(jq -c '[.findings[] | select(.message | test("timer"))]' <<<"$out" 2>&1 | head -c 800)"
    L2() { env -i PATH="$PATH" MOCK_SYSTEMCTL_DIR="$RUN/sysd" bash -c 'set -u; source lib/common.sh; source lib/config_schema.sh; source lib/integrate.sh 2>/dev/null; '"$1" 2>&1; }
    [[ "$(L2 'PVE_JOB_WINDOW_MIN=60; _integ_near_timers 1390')" == "pbo.timer (23:00)" && -z "$(L2 'PVE_JOB_WINDOW_MIN=60; _integ_near_timers 310 | grep -F "pbo.timer ("')" ]] \
        && ok "job window: a PVE job is compared with the calendar systemd runs (23:00), not the config's 05:00" || bad "window effective: $(L2 'PVE_JOB_WINDOW_MIN=60; _integ_near_timers 1390')"
    # an override.conf that sets the default again: nothing to say
    sdshow 'TimersCalendar={ OnCalendar=*-*-* 05:00:00 ; next_elapse=Thu 2026-01-15 05:00:00 UTC }'
    P timers
    ! grep -q 'note: pbo.timer' <<<"$out" && ok "timers: no note when systemd runs the config's calendar" || bad "timers same: $out"
    PJ doctor
    jq -e 'any(.findings[]; .message | test("^pbo.timer: systemd runs")) | not' >/dev/null 2>&1 <<<"$out" \
        && ok "doctor: no warning when systemd runs the config's calendar" || bad "doctor same: $(jq -c '[.findings[] | select(.message | test("timer"))]' <<<"$out" 2>&1)"
else
    skip "systemd-analyze is not installed: the calendar systemd runs is not compared with the config"
fi
# a drop-in removed, the reload failed: no drop-in left to look at, systemd still wants a reload
sdshow 'TimersCalendar={ OnCalendar=*-*-* 01:30:00 ; next_elapse=Thu 2026-01-15 01:30:00 UTC }' 'NeedDaemonReload=yes'
PJ doctor
jq -e 'any(.findings[]; .level == "warn" and (.message | startswith("pbo.timer: systemd has not reloaded its unit files")))' >/dev/null 2>&1 <<<"$out" \
    && ok "doctor WARNs: a pending daemon-reload, also when the drop-in was removed (none on disk)" || bad "doctor reload: $(jq -c '[.findings[] | select(.message | test("timer"))]' <<<"$out" 2>&1 | head -c 800)"
rm -f "$RUN/sysd/pbo.timer.show"

# --- doctor: drift, stale, --fix -------------------------------------------------------------
printf '[Timer]\nOnCalendar=\nOnCalendar=Fri *-*-* 09:00:00\n' > "$(DI pbo-verify.timer)"
mkdir -p "$UNITS/pbo-test-restore.timer.d"; printf '[Timer]\nOnCalendar=\nOnCalendar=daily\n' > "$(DI pbo-test-restore.timer)"
PJ doctor
jq -e 'any(.findings[]; .level == "warn" and (.message | test("^pbo-verify.timer its drop-in does not match SCHEDULE_VERIFY=Thu")))
       and any(.findings[]; .level == "warn" and (.message | test("^pbo-test-restore.timer its drop-in is left from another schedule")))' >/dev/null 2>&1 <<<"$out" \
    && ok "doctor WARNs: a drop-in that differs from the config, one the config no longer wants" || bad "doctor drift: $(jq -c '[.findings[] | select(.message | test("timer"))]' <<<"$out" 2>&1 | head -c 800)"
P timers
grep -q 'note: pbo-verify.timer: .* does not match the config' <<<"$out" && ok "timers: a note for a drop-in that does not match" || bad "timers note: $out"
: > "$MOCK_LOG"; : > "$RUN/sysd/pbo-verify.timer.active"
MOCK_SYSTEMCTL_ENABLED="pbo-verify.timer" P doctor --fix
txt="$(sed -E 's/\x1b\[[0-9;]*m//g' <<<"$out")"
grep -q 'FIXED pbo-verify.timer: .*schedule.conf written' <<<"$txt" && grep -q 'FIXED pbo-test-restore.timer: .*removed' <<<"$txt" \
    && ! grep -qE 'does not match|left from another' <<<"$txt" && grep -q 'OK  timer schedules as the config says (custom: pbo-verify.timer Thu' <<<"$txt" \
    && [[ "$(sdseq pbo-verify.timer)" == 'stop pbo-verify.timer|daemon-reload|clean --what=state pbo-verify.timer|start pbo-verify.timer' && "$(sdseq pbo-test-restore.timer)" == daemon-reload ]] \
    && ok "doctor --fix: rewrites the drifted drop-in, removes the stale one, restarts the enabled timer; then OK" \
    || bad "doctor --fix: $(grep -i timer <<<"$txt") / $(cat "$MOCK_LOG")"
printf '[Timer]\nOnCalendar=\nOnCalendar=Fri *-*-* 09:00:00\n' > "$(DI pbo-verify.timer)"
PJ doctor --fix
jq -e 'any(.changes[]; .name == "pbo-verify.timer" and .change == "schedule drop-in written" and .applied)' >/dev/null 2>&1 <<<"$out" \
    && ok "doctor --fix --json: the drop-in change in changes[]" || bad "fix json: $(jq -c .changes <<<"$out" 2>&1)"
# a config edited by hand (no hook ran): doctor names it, timers apply writes it
printf 'SCHEDULE_TEST_RESTORE="Sun *-*-* 11:00:00"\n' >> "$CFG"
PJ doctor
jq -e 'any(.findings[]; .level == "warn" and (.message | test("pbo-test-restore.timer has no drop-in for SCHEDULE_TEST_RESTORE=Sun")))' >/dev/null 2>&1 <<<"$out" \
    && ok "doctor: a schedule edited into the config by hand, without a drop-in, is a WARN" || bad "hand edit: $(jq -c '[.findings[] | select(.message | test("timer"))]' <<<"$out" 2>&1)"
P timers apply
[[ $rc == 0 && "$(tail -1 "$(DI pbo-test-restore.timer)")" == 'OnCalendar=Sun *-*-* 11:00:00' ]] && ok "timers apply writes it" || bad "apply: rc=$rc $out"
jq -e 'select(.command == "timers") | .read_only == false' >/dev/null 2>&1 <<<"$(tail -1 "$RUN/log/audit.jsonl" 2>/dev/null)" \
    && ok "timers apply: its audit record is not read-only (plain timers is)" || bad "audit record: $(tail -1 "$RUN/log/audit.jsonl" 2>&1)"
printf '[Timer]\nOnCalendar=\nOnCalendar=Mon *-*-* 11:00:00\n' > "$(DI pbo-test-restore.timer)"; cp "$(DI pbo-test-restore.timer)" "$RUN/d.before"
: > "$MOCK_LOG"
P --dry-run doctor --fix
grep -q 'WOULD FIX.* pbo-test-restore.timer: would write' <<<"$out" && cmp -s "$(DI pbo-test-restore.timer)" "$RUN/d.before" && [[ "$(calls daemon-reload)" == 0 ]] \
    && ok "doctor --fix --dry-run: WOULD FIX, the drop-in unchanged, no reload" || bad "dry fix: $(grep -i timer <<<"$out") / $(cat "$MOCK_LOG")"
P timers apply
# a value pbo refuses, edited in by hand: not written, apply fails with 78
printf 'SCHEDULE_PRUNE="Sun 06:30 %%n"\n' >> "$CFG"
cp -r "$UNITS" "$RUN/units.before"
P timers apply
[[ $rc == 78 ]] && grep -q 'pbo-prune.timer: FAILED: SCHEDULE_PRUNE=.* not a systemd calendar' <<<"$out" && [[ ! -e "$(DI pbo-prune.timer)" ]] \
    && diff -r "$UNITS" "$RUN/units.before" >/dev/null \
    && ok "a refused value edited in by hand: timers apply writes nothing for it and exits 78" || bad "apply bad: rc=$rc $out"
PJ doctor
jq -e 'any(.findings[]; .level == "warn" and (.message | test("^pbo-prune.timer: SCHEDULE_PRUNE=.*not applied")))' >/dev/null 2>&1 <<<"$out" \
    && ok "doctor: the refused schedule is a WARN (the timer keeps its old one)" || bad "doctor bad: $(jq -c '[.findings[] | select(.message | test("PRUNE"))]' <<<"$out" 2>&1)"
rm -rf "$RUN/units.before"

# --- install.sh re-applies a custom schedule over freshly installed units --------------------
# a reinstall copies the units (the defaults) again: the drop-ins from the
# config must be there afterwards. install.sh's own functions, test mode, into
# a tree; the pbo it runs is the guarded copy, PBO_SYSTEMD_DIR comes from
# install.sh (the config of a real host does not set it)
cfg --no-sysdir 'SCHEDULE_BACKUP="*-*-* 02:15:00"'
IU="$RUN/inst/units"; mkdir -p "$IU"
out="$(PBO_INSTALL_TEST=1 PBO_INSTALL_UNITDIR="$IU" PBO_INSTALL_PBO="$BIN" PBO_INSTALL_CFGDIR="$RUN/inst" PBO_INSTALL_SYSTEMCTL=systemctl \
    bash -c 'set -Eeuo pipefail; source ./install.sh; inst_host_units; inst_schedules' 2>&1)"; rc=$?
[[ $rc == 0 && -f "$IU/pbo.timer" && "$(tail -1 "$IU/pbo.timer.d/schedule.conf" 2>/dev/null)" == 'OnCalendar=*-*-* 02:15:00' ]] \
    && grep -q 'Timer schedules' <<<"$out" && grep -q 'pbo.timer: .*written' <<<"$out" \
    && ok "install.sh: the units installed, then the config's schedule as a drop-in next to them (a reinstall keeps it)" || bad "install: rc=$rc $out"
out="$(PBO_INSTALL_TEST=1 PBO_INSTALL_UNITDIR="$IU" PBO_INSTALL_PBO="$BIN" PBO_INSTALL_CFGDIR="$RUN/inst" PBO_INSTALL_SYSTEMCTL=systemctl \
    bash -c 'set -Eeuo pipefail; source ./install.sh; inst_host_units; inst_schedules' 2>&1)"; rc=$?
[[ $rc == 0 ]] && grep -q 'pbo.timer: \*-\*-\* 02:15:00 (drop-in)' <<<"$out" && ok "install.sh again: the drop-in is already as the config says" || bad "install again: rc=$rc $out"
body="$(bash -c 'source ./install.sh; declare -f main')"
grep -A1 'inst_janitor_units;' <<<"$body" | grep -q 'inst_schedules;' && [[ "$(grep -n 'inst_schedules' <<<"$body" | tail -1 | cut -d: -f1)" -gt "$(grep -n 'inst_host_units' <<<"$body" | head -1 | cut -d: -f1)" ]] \
    && ok "install.sh main: inst_schedules after the units, for a host and a janitor" || bad "main order: $body"
grep -qE '(05:00|06:30|10:00|12:30)' install.sh && bad "install.sh still names fixed timer times: $(grep -nE '(05:00|06:30|10:00|12:30)' install.sh)" \
    || ok "install.sh names the keys, not fixed times"

# --- the janitor -------------------------------------------------------------------------------
cfg 'PBO_ROLE=janitor' 'LOCAL_REPO=false' 'OFFSITE_ENABLED=true' "RESTIC_OFFSITE_REPO=$RUN/jrepo" "JANITOR_USER=$(id -un)"
sed -i '/^RESTIC_CACHE_REPO=/d; /^BACKUP_ORDER=/d; /^STORAGE_BOX/d' "$CFG"
export PBO_JANITOR_ALLOW_ROOT=1
: > "$MOCK_LOG"
: > "$RUN/sysd/pbo-janitor.timer.active"
MOCK_SYSTEMCTL_ENABLED="pbo-janitor.timer" P config set SCHEDULE_JANITOR '*-*-* 13:45:00'
[[ $rc == 0 && "$(tail -1 "$(DI pbo-janitor.timer)" 2>/dev/null)" == 'OnCalendar=*-*-* 13:45:00' ]] && [[ "$(sdseq pbo-janitor.timer)" == *'clean --what=state pbo-janitor.timer|start pbo-janitor.timer' ]] \
    && ok "janitor: SCHEDULE_JANITOR writes pbo-janitor.timer's drop-in and restarts it" || bad "janitor set: rc=$rc $(cat "$RUN/err")"
P config set SCHEDULE_BACKUP '*-*-* 03:00:00'
[[ $rc == 78 ]] && grep -q 'SCHEDULE_BACKUP is not used on a janitor' "$RUN/err" && ok "janitor: a host schedule key is refused (78)" || bad "janitor host key: rc=$rc $(cat "$RUN/err")"
PJ timers
jq -e '(.timers | length) == 1 and .timers[0].unit == "pbo-janitor.timer" and .timers[0].schedule.key == "SCHEDULE_JANITOR" and .timers[0].schedule.value == "*-*-* 13:45:00"' >/dev/null 2>&1 <<<"$out" \
    && ok "janitor: pbo timers shows its own timer and key" || bad "janitor timers: $out"
P timers apply
[[ $rc == 0 ]] && grep -q '^pbo-janitor.timer: \*-\*-\* 13:45:00 (drop-in)$' <<<"$out" && ! grep -q 'pbo.timer' <<<"$out" \
    && ok "janitor: timers apply handles the janitor's timer only" || bad "janitor apply: rc=$rc $out"
unset PBO_JANITOR_ALLOW_ROOT
cfg
P config set SCHEDULE_JANITOR '*-*-* 13:00:00'
[[ $rc == 78 ]] && grep -q 'SCHEDULE_JANITOR is not used on a host' "$RUN/err" && ok "host: the janitor's key is refused (78)" || bad "host janitor key: rc=$rc $(cat "$RUN/err")"
# a janitor started as root: doctor --fix applies the drop-ins as root, then
# drops to JANITOR_USER (a fake runuser that only re-execs, with the root
# guard lifted), whose doctor reports and audit-logs them; timers apply stays
# root. The janitor's own tree below $RUN/j: the permission pass changes its
# owners.
jusr=""; for c in daemon backup bin nobody; do id "$c" >/dev/null 2>&1 && [[ "$(id -u "$c")" != 0 ]] && { jusr="$c"; break; }; done
if [[ "$(id -u)" == 0 && -n "$jusr" ]]; then
    J="$RUN/j"; rm -rf "$J"; mkdir -p "$J"/{etc,cache,log,state,lock}
    cp "$RUN/pass" "$J/etc/pass"
    cfg 'PBO_ROLE=janitor' 'LOCAL_REPO=false' 'OFFSITE_ENABLED=true' "RESTIC_OFFSITE_REPO=$RUN/jrepo" "JANITOR_USER=$jusr" 'SCHEDULE_JANITOR="*-*-* 13:45:00"'
    sed -e '/^RESTIC_CACHE_REPO=/d; /^BACKUP_ORDER=/d; /^STORAGE_BOX/d' \
        -e "s#^CACHE_DIR=.*#CACHE_DIR=$J/cache#; s#^LOG_DIR=.*#LOG_DIR=$J/log#; s#^STATE_DIR=.*#STATE_DIR=$J/state#; s#^LOCK_DIR=.*#LOCK_DIR=$J/lock#" \
        -e "s#^RESTIC_PASSWORD_FILE=.*#RESTIC_PASSWORD_FILE=$J/etc/pass#; s#^RESTIC_CACHE_DIR=.*#RESTIC_CACHE_DIR=$J/state/rcache#; s#^PBO_PERMS_CONFIG_DIR=.*#PBO_PERMS_CONFIG_DIR=$J/etc#" \
        "$CFG" > "$J/etc/config"; chmod 600 "$J/etc/config"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s"\n[[ "$1" == -u ]] && shift 2; [[ "$1" == -- ]] && shift\nPBO_JANITOR_ALLOW_ROOT=1 exec "$@"\n' "$J/runuser.argv" > "$RUN/bin/fake-runuser"
    chmod 755 "$RUN/bin/fake-runuser"
    printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* 01:00:00\n' > "$(DI pbo-janitor.timer)"
    out="$(PBO_JANITOR_ALLOW_ROOT=0 PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" PBO_CONFIG="$J/etc/config" "$BIN" --json doctor --fix 2>"$RUN/err")"
    [[ "$(tail -1 "$(DI pbo-janitor.timer)")" == 'OnCalendar=*-*-* 13:45:00' ]] && grep -q -- "-u $jusr -- .*/pbo --json doctor --fix" "$J/runuser.argv" 2>/dev/null \
        && jq -e 'any(.changes[]; .name == "pbo-janitor.timer" and .change == "schedule drop-in written" and .applied)' >/dev/null 2>&1 <<<"$out" \
        && ok "janitor started as root: doctor --fix rewrites the drifted drop-in as root, then the doctor as JANITOR_USER reports it in changes[]" \
        || bad "janitor root pass: argv=$(cat "$J/runuser.argv" 2>&1) $(tail -1 "$(DI pbo-janitor.timer)") $(jq -c .changes <<<"$out" 2>&1) $(tail -3 "$RUN/err")"
    grep -qF "timers: pbo-janitor.timer schedule drop-in written ($(DI pbo-janitor.timer)) (as root, before dropping to $jusr)" "$J/log/audit.log" 2>/dev/null \
        && ok "janitor: the root pass's drop-in change is audit-logged by the re-exec'd doctor" || bad "janitor sched audit: $(grep timers "$J/log/audit.log" 2>&1)"
    printf '[Timer]\nOnCalendar=\nOnCalendar=*-*-* 01:00:00\n' > "$(DI pbo-janitor.timer)"; rm -f "$J/runuser.argv"
    PBO_JANITOR_ALLOW_ROOT=0 PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" PBO_CONFIG="$J/etc/config" P timers apply
    [[ $rc == 0 && ! -e "$J/runuser.argv" && "$(tail -1 "$(DI pbo-janitor.timer)")" == 'OnCalendar=*-*-* 13:45:00' ]] \
        && ok "janitor started as root: timers apply stays root (no re-exec) and writes the drop-in" || bad "janitor apply as root: rc=$rc $(cat "$J/runuser.argv" 2>&1) $out"
else
    skip "janitor root pass (needs root and a system user)"
fi

# --- the PVE job window uses the configured schedule ------------------------------------------
L() { env -i PATH="$PATH" bash -c 'set -u; source lib/common.sh; source lib/config_schema.sh; source lib/integrate.sh 2>/dev/null; '"$1" 2>&1; }
[[ "$(L 'PVE_JOB_WINDOW_MIN=60; SCHEDULE_BACKUP="*-*-* 02:00:00"; _integ_near_timers 150')" == "pbo.timer (02:00)" \
   && -z "$(L 'PVE_JOB_WINDOW_MIN=60; SCHEDULE_BACKUP="*-*-* 02:00:00"; _integ_near_timers 300')" ]] \
    && ok "job window: a PVE job near the configured backup time is named, one at the old default is not" || bad "window: $(L 'PVE_JOB_WINDOW_MIN=60; SCHEDULE_BACKUP="*-*-* 02:00:00"; _integ_near_timers 150')"
[[ "$(L 'PVE_JOB_WINDOW_MIN=30; SCHEDULE_BACKUP="*-*-* 01,13:10:00"; _integ_near_timers 800')" == "pbo.timer (13:10)" ]] \
    && ok "job window: a list of hours, the run closest to the job" || bad "window list: $(L 'PVE_JOB_WINDOW_MIN=30; SCHEDULE_BACKUP="*-*-* 01,13:10:00"; _integ_near_timers 800')"
if command -v systemd-analyze >/dev/null 2>&1; then
    [[ "$(L 'PVE_JOB_WINDOW_MIN=20; SCHEDULE_BACKUP="*-*-* 0/6:15:00"; _integ_near_timers 370')" == "pbo.timer (06:15)" ]] \
        && ok "job window: a repetition (0/6) expanded by systemd-analyze" || bad "window repeat: $(L 'PVE_JOB_WINDOW_MIN=20; SCHEDULE_BACKUP="*-*-* 0/6:15:00"; _integ_near_timers 370')"
else
    skip "systemd-analyze is not installed: the expanded schedule is not checked"
fi
[[ -z "$(L 'PBO_TOOLS_MISSING=systemd-analyze; PVE_JOB_WINDOW_MIN=600; SCHEDULE_BACKUP="*-*-* 0/6:15:00"; SCHEDULE_PRUNE=weekly; SCHEDULE_VERIFY=x; _integ_near_timers 0 | grep -F "pbo.timer ("')" ]] \
    && ok "job window: a schedule whose times cannot be worked out is left out (no guess)" || bad "window unknown"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
