#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/docs.sh: the documentation against the code.
#  - every schema key (lib/config_schema.sh) but the internal and deprecated
#    ones is in the generated example: a host key in etc/config.example, a
#    janitor-only key in `pbo config template --role janitor`; and every key
#    the example names is a schema key;
#  - every command form `pbo help` shows, and the README command list, gets
#    through pbo's parser: each synopsis is expanded into concrete argument
#    lists (tests/fixtures/doc_forms.pl: the minimal form, each option and
#    each alternative alone, all options at once) and run with --dry-run; a
#    usage error (64) is a doc bug, unless allow64 below names it as a state
#    check;
#  - the README command list names the same commands as `pbo help`;
#  - every `pbo ...` line in a code block of README.md, RUNBOOK.md and
#    SECURITY.md parses the same way (placeholders filled in, absolute paths
#    moved below the run directory, --dry-run added); `./pbo ...` (a checkout),
#    `sudo pbo ...` and `runuser -u USER -- pbo ...` count too;
#  - a `--dry-run` a doc line puts after the command is a doc bug, unless the
#    command takes one of its own (doctor, config set, config unset): the
#    parser reads the global one only before the command, so the line would
#    run for real. The harness still adds the global one in front.
#
# The limit of a 64: it catches a misspelt flag only where the command's
# parser rejects a word it does not know. So every form `pbo help` shows is
# also run with a trailing --zz-bogus, which must exit 64, unless the command
# is in `lenient` below with the reason its parser ignores extra words. A
# lenient command's documented forms are checked against the flags it takes
# (a list kept here, not read from the help it checks), and the suite names
# the lenient commands as unchecked for a misspelt flag. A lenient command
# that starts to reject the probe fails the suite until it leaves the list,
# so the list can only shrink, and a new flag on one forces a decision.
#
# Nothing runs for real: every form gets the global --dry-run, restic is a
# fake that answers with an empty repo, systemctl, systemd-run, pct, qm,
# vzdump, pvesh, pvesm are mocks, stdin is closed (setup and menu stop at the
# end of the input). pbo runs as a copy of the entry point that sources
# tests/fixtures/run_dir_guard.sh: it stops (99) before any command runs when
# a path it resolved (config, directories, PVE paths, the systemd directory)
# lies outside run-docs/, and before any config, drop-in or wizard write
# there. A 99 fails the form like a 64 does.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
command -v jq >/dev/null 2>&1 || { echo "jq not installed, skipping docs tests"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "perl not installed, skipping docs tests"; exit 0; }

printf 'pbo: docs against the code\n'
RUN="$ROOT/run-docs"; rm -rf "$RUN"
mkdir -p "$RUN"/{bin,cache,state/runs/42,log,lock,sysd,units,tree,pve,lxc,qemu,tmp,none,mnt,abs,spool/dump}
for m in systemctl pvesh pvesm pct qm vzdump dpkg-query pveum zfs zpool; do install -m 0755 "tests/mocks/$m" "$RUN/bin/"; done
export PATH="$RUN/bin:$PATH" MOCK_LOG="$RUN/calls" MOCK_CONF_DIR="$RUN/lxc" MOCK_SYSTEMCTL_DIR="$RUN/sysd" TMPDIR="$RUN/tmp"
export MOCK_SYSTEMCTL_ENABLED=""
export PBO_PVE_TEMPLATE_DIR="$RUN/none/templates" RESTIC_ENV_FILE="$RUN/none/restic.env" NTFY_CREDS_FILE="$RUN/none/ntfy.creds"
export HOME="$RUN"   # the wizard's ssh key and known_hosts default below HOME
# integrate enable/disable refuse a non-root caller with 64 (a state check,
# not the parser); CI runs the suites unprivileged, as tests/integrate.sh does
export PBO_INTEGRATE_ALLOW_NONROOT=1
: > "$MOCK_LOG"; chmod 0700 "$RUN/mnt"
printf '{"nodename":"pve1","version":3,"cluster":{"name":"lab","version":1,"nodes":1,"quorate":1},"nodelist":{"pve1":{"id":1,"online":1,"ip":"192.0.2.11"}}}\n' > "$RUN/pve/.members"
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
printf 'newpass\n' > "$RUN/newpass"; chmod 600 "$RUN/newpass"
printf 'arch: amd64\nhostname: ct8001\nunprivileged: 1\nrootfs: local:subvol-8001-disk-0,size=1G\n' > "$RUN/lxc/8001.conf"
: > "$RUN/spool/dump/vzdump-lxc-8001-2026_01_15-05_00_00.tar"
# a finished job (show, log, log --follow return at once)
printf '{"id":42,"command":"verify","args":[],"started_by":"root","via":"cli","created":"2026-01-15T05:00:00+00:00","created_epoch":1768453200,"runner":"systemd","unit":"pbo-job-42","dry_run":true}\n' > "$RUN/state/runs/42/meta.json"
printf '{"exit":0,"ended":"2026-01-15T05:00:10+00:00","ended_epoch":1768453210,"result":null}\n' > "$RUN/state/runs/42/result.json"
printf 'job line\n' > "$RUN/state/runs/42/log"
# restic: an empty repo; systemd-run: records, starts nothing
cat > "$RUN/bin/restic-fake" <<'EOF'
#!/usr/bin/env bash
for a; do case "$a" in version) echo "restic 0.18.0 compiled with go1.24 on linux/amd64"; exit 0 ;; --help) exit 0 ;; esac; done
case " $* " in *" snapshots "*|*" forget "*) echo '[]' ;; *" stats "*) echo '{"total_size":0,"total_file_count":0}' ;; esac
exit 0
EOF
printf '#!/usr/bin/env bash\necho "systemd-run $*" >> "$MOCK_LOG"\nexit 0\n' > "$RUN/bin/systemd-run"
chmod 0755 "$RUN/bin/restic-fake" "$RUN/bin/systemd-run"

# the entry point with the guard sourced right before main (lib/ linked)
if [[ "$(tail -n 1 pbo)" != 'main "$@"' ]]; then
    bad "the entry point no longer ends in main \"\$@\": the harness needs a new hook"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi
{ sed '$d' pbo; printf '%s\n' 'source "$SELF_DIR/../../tests/fixtures/run_dir_guard.sh"'; tail -n 1 pbo; } > "$RUN/tree/pbo"
chmod 755 "$RUN/tree/pbo"; ln -s "$ROOT/lib" "$RUN/tree/lib"
export TEST_RUN="$RUN" TEST_GUARD_KEYS="PBO_KNOWN_HOSTS RESTIC_REST_PASSWORD_FILE METRICS_FILE TR_HISTORY AUDIT_JSON"
# a cluster-shared file in the run directory, so `config set --shared` has a target
export TEST_GUARD_SHARED="$RUN/shared.config"
: > "$TEST_GUARD_SHARED"; chmod 600 "$TEST_GUARD_SHARED"
BIN="$RUN/tree/pbo"

CFG="$RUN/config"
cfg() {   # cfg [--no-sysdir]: the suite's config, every path in $RUN
    local sysd=1; [[ "${1:-}" == --no-sysdir ]] && sysd=0
    { cat <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
RESTIC_CACHE_REPO=$RUN/cache/repo
RESTIC_OFFSITE_REPO=$RUN/offsite
RESTIC_BIN=$RUN/bin/restic-fake
PBO_KNOWN_HOSTS=$RUN/known_hosts
METRICS_FILE=$RUN/state/pbo.prom
BACKUP_ORDER=8001
STORAGE_BOX_SNAPSHOTS_CONFIRMED=true
NOTIFY_PVE=false
JOB_RUNNER=systemd
PBO_PVE_LXC_DIR=$RUN/lxc
PBO_PVE_QEMU_DIR=$RUN/qemu
PBO_PVE_CFS_DIR=$RUN/pve
PVE_STORAGE_CFG=$RUN/storage.cfg
PBO_PVE_STORAGE_CFG=$RUN/storage.cfg
VZDUMP_CONF=$RUN/vzdump.conf
VZDUMP_LOCK=$RUN/vzdump.lock
PBO_CATALOG=$RUN/state/catalog/index.json
PVE_CATALOG_MOUNT_DIR=$RUN/mnt/restic
PBO_PVE_PLUGIN_PATH=$RUN/none/PboPlugin.pm
PBO_PERMS_PARENTS_TOP=$RUN
PBO_PERMS_CONFIG_DIR=$RUN
EOF
      (( sysd )) && printf 'PBO_SYSTEMD_DIR=%s\n' "$RUN/units"; } > "$CFG"; chmod 600 "$CFG"
}
export PBO_CONFIG="$CFG"
P() { out="$(timeout 60 "$BIN" "$@" </dev/null 2>"$RUN/err")"; rc=$?; }

# --- the harness ---------------------------------------------------------------------------
cfg --no-sysdir
out="$(env -u PBO_SYSTEMD_DIR "$BIN" help 2>"$RUN/err")"; rc=$?   # (tests/all.sh points it into the checkout)
[[ $rc == 99 ]] && grep -q 'PBO_SYSTEMD_DIR=/etc/systemd/system is outside' "$RUN/err" \
    && ok "harness: a config that leaves PBO_SYSTEMD_DIR at the host's directory stops pbo (99) before it runs" || bad "guard: rc=$rc $(cat "$RUN/err")"
cfg
P help
[[ $rc == 0 && "$out" == *Commands:* ]] && ok "harness: with every path in the run directory pbo runs" || bad "guarded run: rc=$rc $(cat "$RUN/err")"
help_text="$out"

# --- schema keys in the generated example ---------------------------------------------------
# internal keys are test hooks, deprecated ones are honoured but no longer
# offered: the template leaves both out on purpose
keys="$(bash -c 'source lib/config_schema.sh; _cs_load
    for k in "${CS_ORDER[@]}"; do
        _cs_flag "$k" internal >/dev/null && continue
        _cs_flag "$k" deprecated >/dev/null && continue
        printf "%s %s\n" "$k" "${CS_ROLES[$k]}"
    done')"
P config template --role janitor; jtmpl="$out"
miss='' n=0
while read -r k roles; do
    n=$((n+1))
    if [[ ",$roles," == *,host,* ]]; then
        grep -Eq "^#?$k=" etc/config.example || miss+="$k (etc/config.example) "
    else
        grep -Eq "^#?$k=" <<<"$jtmpl" || miss+="$k (config template --role janitor) "
    fi
done <<<"$keys"
(( n > 50 )) && [[ -z "$miss" ]] && ok "every schema key ($n, internal and deprecated ones aside) is in the generated example (janitor-only keys in the janitor template)" \
    || bad "keys missing from the example ($n read): $miss"
miss=''
while IFS= read -r k; do
    grep -q "^$k " <<<"$keys" || miss+="$k "
done < <(sed -nE 's/^#?([A-Z][A-Z0-9_]*)=.*/\1/p' etc/config.example)
[[ -z "$miss" ]] && ok "every key etc/config.example names is a schema key" || bad "etc/config.example names keys the schema does not offer: $miss"

# --- synopses and documented commands through the parser ------------------------------------
# the placeholders the docs use, and what a run fills in (a name given twice:
# its first and second use in one line)
ph=(--abs="$RUN/abs"
    '<vmid>=8001' 'vmid=8001' '<new-vmid>=8101' '<ts>=2026_01_15-05_00_00' '<node>=pve1'
    'N=8101' "F=$CFG" 'S=local' '<pool>=local' '<id>=42' 'args=' '<command>=verify'
    '<KEY>=KEEP_LOCAL' '<KEY>=KEEP_OFFSITE_DAILY' '<VALUE>=3' '<VALUE>=7'
    "<file>=$RUN/newpass" "<dir>=$RUN/abs/newcache" "<new>=$RUN/abs/newcache" "<old>=$RUN/cache"
    '<p>=/etc/hostname' '<archive>=vzdump-lxc-8001-2026_01_15-05_00_00.tar'
    "<path>=$RUN/spool/dump/vzdump-lxc-8001-2026_01_15-05_00_00.tar")
# A 64 that is a state check, not the parser: FORM-ERE <tab> STDERR-ERE <tab> why
# setup is the one command without a dry run: it refuses one with 64 in its
# own handler, after the dispatcher took it (so the command parsed), and is
# never run for real here (tests/menu.sh runs it with scripted answers).
allow64=$'^config set CACHE_DIR .*--(resume|abort)\tno unfinished cache move\tneeds an unfinished move (tests/cachemove.sh runs both)
^policy set 8001$\tnothing to change\tat least one of --skip, --stop, --keep (the synopsis shows them as options)
^job cancel 42$\tnothing to cancel\ta finished job (tests/jobs.sh cancels a running one)
^restore .*--keep-network\tstill exists in the cluster\tdisaster recovery: refused while the original exists (tests/run.sh)
^setup$\tsetup has no --dry-run\tinteractive; it asks before each change'
_allowed64() {   # _allowed64 FORM ERRFILE: the 64 of FORM is a listed state check
    local fe se why
    while IFS=$'\t' read -r fe se why; do
        [[ "$1" =~ $fe ]] && grep -Eq -- "$se" "$2" && return 0
    done <<<"$allow64"
    return 1
}
# Commands whose parser ignores a word it does not know, so a 64 cannot catch
# a misspelt flag on them: PREFIX <tab> the flags it takes (`*`: the words
# are another command's) <tab> why. Their documented forms may carry only
# those flags. Shrink it by making a parser strict, never grow it to pass.
lenient=$'setup\t\tinteractive and without a dry run (64 before it reads its arguments): never probed
menu\t\tinteractive; takes no arguments
init\t\ttakes no arguments
backup\t--queue --now\treads flags only before the vmid and ignores what follows it
preflight\t\ttakes the vmid alone
run-schedule\t--stream --batch\tchecks its first word only
verify\t--scheduled\tchecks its first word only
job show\t\tchecks the id only
job cancel\t\tchecks the id only (a finished job refuses with 64 before the probe could tell)
catalog release\t--all\tchecks its first word only
status\t\ttakes no arguments
notify-test\t\ttakes no arguments
guests\t\ttakes no arguments
job start\t*\tthe words after the command are that command\'s (its own form is checked)
policy get\t\ttakes the vmid alone
version\t\ttakes no arguments
usage\t\ttakes no arguments
fetch\t\ttakes the vmid and timestamp alone
unlock\t\ttakes no arguments
rotate-key\t\ttakes the file alone
backup-host\t\ttakes no arguments
help\t\ttakes no arguments'
# subcommand groups: their prefix is the first two words
groups=" config job policy timers catalog integrate "
_prefix() {   # _prefix WORD...: the command (and subcommand) a form starts with
    local p="${1:-}"
    [[ "$groups" == *" $p "* && "${2:-}" =~ ^[a-z][a-z-]*$ ]] && p+=" $2"
    printf '%s' "$p"
}
_lenient() {   # _lenient PREFIX: the flags a lenient command takes (status 1: strict)
    local pf fl why
    while IFS=$'\t' read -r pf fl why; do
        [[ "$pf" == "$1" ]] && { printf '%s' "$fl"; return 0; }
    done <<<"$lenient"
    return 1
}
# _run_forms < "MODE<tab>ID<tab>TEXT" lines: expand, run each form with
# --dry-run → rf_errs, rf_n, rf_forms (each form's words without the global
# flags, joined by \x1f). A 64 fails (unless allowed), as do 99 (the guard),
# 124 (a hang), a --dry-run after the command, and a lenient command's flag
# it does not take. A form seen before (help and the README list overlap) is
# not run again.
declare -A FORM_RC=()
_run_forms() {
    local id form s key ef w i g pf known
    local -a words cmdw
    rf_errs='' rf_n=0 rf_forms=()
    while IFS=$'\t' read -r id form; do
        if [[ "$form" == ERROR:* ]]; then rf_errs+="[$id] ${form#ERROR: }; "; continue; fi
        IFS=$'\x1f' read -r -a words <<<"$form"
        # the global flags are read only in front of the command: a --dry-run
        # after it does not make the line a dry run
        g=0 i=0
        for w in "${words[@]}"; do
            case "$w" in --dry-run) g=1 ;; --json) ;; *) break ;; esac
            i=$((i+1))
        done
        cmdw=("${words[@]:i}")
        pf="$(_prefix "${cmdw[@]}")"
        if (( ! g )) && [[ " ${cmdw[*]} " == *" --dry-run "* ]]; then
            case "$pf" in doctor|"config set"|"config unset") ;;
                *) rf_errs+="[$id] 'pbo ${words[*]}': --dry-run after the command is ignored ($pf takes no --dry-run of its own: write 'pbo --dry-run $pf ...'); " ;; esac
        fi
        (( g )) || words=(--dry-run "${words[@]}")
        if known="$(_lenient "$pf")" && [[ "$known" != '*' ]]; then
            for w in "${cmdw[@]}"; do
                [[ "$w" == -* && "$w" != --dry-run && " $known " != *" $w "* ]] || continue
                rf_errs+="[$id] 'pbo ${words[*]}': $pf ignores words it does not know, and $w is not a flag it takes (${known:-none}); "
            done
        fi
        rf_n=$((rf_n+1)); rf_forms+=("$id"$'\t'"$(IFS=$'\x1f'; printf '%s' "${cmdw[*]}")")
        key="${words[*]}"
        ef="$RUN/err.$(printf '%s' "$key" | md5sum | cut -c1-16)"
        if [[ -z "${FORM_RC[$key]+x}" ]]; then
            P "${words[@]}"; FORM_RC[$key]=$rc; cp "$RUN/err" "$ef"
        fi
        rc="${FORM_RC[$key]}"
        s="${cmdw[*]}"
        case "$rc" in
            64) _allowed64 "$s" "$ef" || rf_errs+="[$id] 'pbo ${words[*]}' exits 64: $(head -c 300 "$ef" | tr '\n' ' '); " ;;
            99) rf_errs+="[$id] 'pbo ${words[*]}' stopped by the run-directory guard: $(head -c 300 "$ef" | tr '\n' ' '); " ;;
            124) rf_errs+="[$id] 'pbo ${words[*]}' did not end within 60 s; " ;;
        esac
    done < <(perl tests/fixtures/doc_forms.pl "${ph[@]}")
    (( rf_n > 0 )) || rf_errs+="no form was read; "
}
run_forms() {   # run_forms LABEL < lines: _run_forms, then one PASS or FAIL
    _run_forms
    [[ -z "$rf_errs" ]] && ok "$1: $rf_n forms parsed" || bad "$1: $rf_errs"
}

# synopses: a line of a command list that starts with two blanks and a
# lower-case word; the synopsis ends at the first run of two blanks
synopses() {   # synopses < the list: one synopsis per line
    local l s
    while IFS= read -r l; do
        [[ "$l" =~ ^\ \ [a-z] ]] || continue
        s="${l#  }"; s="${s%%  *}"
        printf '%s\n' "$s"
    done
}
help_cmds="$(sed -n '/^Commands:/,/^Exit codes/p' <<<"$help_text" | synopses)"
readme_cmds="$(sed -n '/^## Commands/,/^## [A-Z]/p' README.md | sed -n '/^Commands:/,/^Exit codes/p' | synopses)"
(( $(wc -l <<<"$help_cmds") > 40 )) && ok "pbo help lists $(wc -l <<<"$help_cmds") command forms" || bad "pbo help: too few command lines read ($(wc -l <<<"$help_cmds"))"
awk '{ printf "H\thelp:%d\t%s\n", NR, $0 }' <<<"$help_cmds" > "$RUN/help.forms"
awk '{ printf "H\treadme:%d\t%s\n", NR, $0 }' <<<"$readme_cmds" > "$RUN/readme.forms"
run_forms "pbo help: every command and flag it shows" < "$RUN/help.forms"
help_forms=("${rf_forms[@]}")
run_forms "README command list: every command and flag" < "$RUN/readme.forms"

# every form pbo help shows, with a word no parser takes: a 64 that names it
# (or a 64 where the form alone does not give one) shows the parser checks
# its words; a lenient command is only counted as unchecked
errs='' unchecked=''
declare -A lenient_strict=() lenient_seen=()
for f in "${help_forms[@]}"; do
    IFS=$'\x1f' read -r -a words <<<"${f#*$'\t'}"
    pf="$(_prefix "${words[@]}")"
    [[ "$pf" == setup ]] && { lenient_seen[$pf]=1; continue; }   # no dry run: it would ask
    P --dry-run "${words[@]}" --zz-bogus
    strict=0
    if [[ $rc == 64 ]] && { grep -q -- --zz-bogus "$RUN/err" || [[ "${FORM_RC["--dry-run ${words[*]}"]:-}" != 64 ]]; }; then strict=1; fi
    if _lenient "$pf" >/dev/null; then
        [[ -n "${lenient_seen[$pf]+x}" ]] || lenient_strict[$pf]=1
        lenient_seen[$pf]=1
        (( strict )) || unset 'lenient_strict[$pf]'
    elif (( ! strict )); then
        errs+="'pbo --dry-run ${words[*]} --zz-bogus' rc=$rc (a misspelt flag would pass: make the parser reject it, or list $pf as lenient with its reason); "
    fi
done
for pf in "${!lenient_strict[@]}"; do errs+="$pf now rejects an unknown word: drop it from the lenient list; "; done
while IFS=$'\t' read -r pf _ _; do
    [[ -n "${lenient_seen[$pf]+x}" ]] || errs+="lenient lists $pf, which pbo help does not show; "
    unchecked+="${unchecked:+, }$pf"
done <<<"$lenient"
(( ${#help_forms[@]} > 40 )) && [[ -z "$errs" ]] \
    && ok "a trailing unknown flag exits 64 on every command pbo help shows but the lenient ones (their parser ignores extra words, so a misspelt flag there is caught only by their flag list here: $unchecked)" \
    || bad "unknown-flag probe (${#help_forms[@]} forms): $errs"

# the README command list and pbo help name the same commands
hc="$(awk '{print $1}' <<<"$help_cmds" | sort -u | paste -sd' ')"
rc_="$(awk '{print $1}' <<<"$readme_cmds" | sort -u | paste -sd' ')"
[[ -n "$hc" && "$hc" == "$rc_" ]] && ok "the README command list names the commands pbo help names" \
    || bad "README commands: '$rc_' vs pbo help: '$hc'"

# code blocks: every line that starts with `pbo `, `./pbo ` (the upgrade
# steps run the new version from a checkout), `sudo pbo ` or `runuser -u USER
# -- pbo ` (a synopsis line such as `pbo [global flags] <command>` aside). The
# blank after pbo keeps ./pbo_<version>_all.deb and pbo-janitor.timer out.
code_lines() {   # code_lines FILE...: "C<tab>FILE:LINE<tab>the words after pbo"
    local f
    for f; do
        awk -v F="${f##*/}" '/^[[:space:]]*```/ { inb = !inb; next }
            inb && /^[[:space:]]*(\.\/|runuser -u [a-z_][a-z0-9_-]* -- |sudo )?pbo / && !/\[global flags\]/ {
                sub(/^[[:space:]]*(\.\/|runuser -u [a-z_][a-z0-9_-]* -- |sudo )?pbo /, ""); printf "C\t%s:%d\t%s\n", F, NR, $0 }' "$f"
    done
}
code_lines README.md RUNBOOK.md SECURITY.md > "$RUN/codeblocks"
(( $(wc -l < "$RUN/codeblocks") > 30 )) && ok "the docs' code blocks hold $(wc -l < "$RUN/codeblocks") pbo commands" \
    || bad "too few pbo commands found in the code blocks ($(wc -l < "$RUN/codeblocks"))"
grep -q $'^C\tRUNBOOK.md:[0-9]*\tconfig check --compare-bash' "$RUN/codeblocks" && grep -q $'^C\tREADME.md:[0-9]*\tdoctor$' "$RUN/codeblocks" \
    && ok "the scan reads ./pbo and runuser -u USER -- pbo lines (the upgrade check, the janitor's doctor)" \
    || bad "the scan misses ./pbo or runuser lines: $(grep -c . "$RUN/codeblocks") lines read"
run_forms "README, RUNBOOK, SECURITY code blocks: every pbo command" < "$RUN/codeblocks"

# the method sees each kind of doc bug: a doc with one per line, through the
# same scan and checks, must fail every line of it
printf '%s\n' '```bash' './pbo config check --compare-bsh' 'runuser -u restic -- pbo doctor --fixx' \
    'sudo pbo prune --if-ownr' 'pbo backup <vmid> --dry-run' 'pbo status --verbose' 'pbo list --reason <vmid>' \
    'pbo metrics --nowrite' 'pbo restore <vmid> <ts> --to N --dry-run' '```' > "$RUN/mutant.md"
code_lines "$RUN/mutant.md" > "$RUN/mutant.forms"
_run_forms < "$RUN/mutant.forms"
miss=''
for n in 2 3 4 5 6 7 8 9; do [[ "$rf_errs" == *"[mutant.md:$n]"* ]] || miss+="line $n ($(sed -n "${n}p" "$RUN/mutant.md")); "; done
[[ $(wc -l < "$RUN/mutant.forms") == 8 && -z "$miss" ]] \
    && ok "control: a misspelt flag (./pbo, runuser, sudo, list, metrics), an unknown flag on a lenient command and a --dry-run after the command each fail a doc line" \
    || bad "control: doc bugs not caught: $miss ($(wc -l < "$RUN/mutant.forms") lines scanned) $rf_errs"
# and the misplaced --dry-run did not make the harness run it for real: it
# put the global one in front
[[ -n "${FORM_RC["--dry-run backup 8001 --dry-run"]+x}" && -z "${FORM_RC["backup 8001 --dry-run"]+x}" ]] \
    && ok "control: a doc line with a misplaced --dry-run still runs as a dry run" \
    || bad "the harness ran 'backup 8001 --dry-run' without the global --dry-run"

# the method sees a bad flag (a 64 is what the forms above are checked for)
errs=''
for a in "doctor --bogus" "prune --bogus" "config set KEEP_LOCAL 3 --bogus" "config check --bogus" "timers bogus" "bogus" \
    "metrics --nowrite" "list --reason 8001" "list 8001 --reasons-x"; do
    # shellcheck disable=SC2086  # the words are the point
    P --dry-run $a
    [[ $rc == 64 ]] || errs+="'$a' rc=$rc; "
done
[[ -z "$errs" ]] && ok "control: an unknown flag or command exits 64" || bad "control: $errs"
# the global flags
errs=''
P --json --dry-run version; [[ $rc == 0 ]] || errs+="--json --dry-run version rc=$rc; "
P -h; [[ $rc == 0 && "$out" == *Commands:* ]] || errs+="-h rc=$rc; "
P --help; [[ $rc == 0 ]] || errs+="--help rc=$rc; "
P -V; [[ $rc == 0 && "$out" == "pbo "* ]] || errs+="-V rc=$rc; "
P --version; [[ $rc == 0 ]] || errs+="--version rc=$rc; "
[[ -z "$errs" ]] && ok "the global flags pbo help names (--json, --dry-run, -h/--help, -V/--version) are accepted" || bad "global flags: $errs"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
