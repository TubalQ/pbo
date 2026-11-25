#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/config_write.sh: the config writer (lib/config.sh _cfg_write) and `pbo
# config set|unset`, ADR 0009 "Writer" (0.6 M4). Every write is checked from the
# outside: the strict reader and bash read the file the test wrote, its comments,
# template lines, owner, group and mode are compared with the file before. The
# cluster-shared file and a missing local file are tested through a copy of the
# entry point whose file list names files in run-config-write/ (TEST_SHARED,
# TEST_LOCAL): nothing outside run-config-write/ is read or written, and every
# PVE tool and systemctl is a mock.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
printf 'pbo: config writer tests\n'
RUN="$ROOT/run-config-write"; rm -rf "$RUN"; mkdir -p "$RUN"/{cache,state,log,lock,bin,lxc,sysd,tree}
for m in tests/mocks/*; do install -m 0755 "$m" "$RUN/bin/"; done   # never the real host
export PATH="$RUN/bin:$PATH" MOCK_LOG="$RUN/calls" MOCK_SYSTEMCTL_DIR="$RUN/sysd" MOCK_CONF_DIR="$RUN"
# the directories pbo uses, also for a run whose config does not name them
export CACHE_DIR="$RUN/cache" LOG_DIR="$RUN/log" STATE_DIR="$RUN/state" LOCK_DIR="$RUN/lock"
# the cache-move preflight must not see the host's vzdump (a PVE host that runs
# the suite may run a backup job meanwhile): no vzdump runs
export PBO_TEST_CM_VZDUMP_PIDS=''
CFG="$RUN/config"; export PBO_CONFIG="$CFG"

# mk [line...]: the generated example with this run's directories, then the lines
mk() {
    sed -e "s|^CACHE_DIR=/var/cache/pbo|CACHE_DIR=$RUN/cache|; s|^LOG_DIR=/var/log/pbo|LOG_DIR=$RUN/log|; s|^STATE_DIR=/var/lib/pbo|STATE_DIR=$RUN/state|" etc/config.example > "$CFG"
    # the PVE files a cache move reads (tests/cachemove.sh moves for real)
    printf '%s\n' "LOCK_DIR=$RUN/lock" "PBO_PVE_LXC_DIR=$RUN/lxc" "PBO_PVE_QEMU_DIR=$RUN/qemu" "PBO_SUBUID_FILE=$RUN/subuid" \
        "PVE_STORAGE_CFG=$RUN/storage.cfg" "VZDUMP_LOCK=$RUN/vzdump.lock" "PBO_PERMS_PARENTS_TOP=$RUN" "NTFY_CREDS_FILE=/nonexistent" "$@" >> "$CFG"
    chmod 600 "$CFG"
}
# rd FILE KEY: KEY as the strict reader reads FILE; bs FILE KEY: as bash sources it
rd() { env -i PATH="$PATH" bash -c 'source lib/config_schema.sh; source lib/config_parse.sh; _cs_core; _cfg_reset
    _cfg_parse_file "$1" local >/dev/null || echo "<refused: ${CFG_ERRORS[*]}>"; printf %s "${CFG_VAL[$2]-<unset>}"' _ "$1" "$2"; }
bs() { env -i PATH=/usr/bin:/bin bash -c 'source "$1" >/dev/null 2>&1 </dev/null; printf %s "${!2-<unset>}"' _ "$1" "$2"; }
# only the lines that are not KEY's (comments, blanks, other keys) of a file
others() { grep -vE "^[[:blank:]]*#?$2=" "$1"; }
tmpleft() { find "$RUN" "$RUN/pve/pbo" -maxdepth 1 -name '.*.pbo.*' 2>/dev/null | grep -q .; }

# the entry point with the file list replaced (TEST_SHARED, then TEST_LOCAL) and
# lib/ linked: the cluster-shared file and a missing local file, never /etc.
# tests/fixtures/config_write_hook.sh also stops pbo (99) if it would read or
# write anything else. The shared file lies in a fake cluster filesystem
# (PBO_PVE_CFS_DIR=$RUN/pve with a .members file, as a mounted pmxcfs has).
if [[ "$(tail -n 1 pbo)" != 'main "$@"' ]]; then
    bad "the entry point no longer ends in main \"\$@\": the harness needs a new hook"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi
{ sed '$d' pbo; printf '%s\n' 'source "$SELF_DIR/../../tests/fixtures/config_write_hook.sh"'; tail -n 1 pbo; } > "$RUN/tree/pbo"
chmod 755 "$RUN/tree/pbo"; ln -s "$ROOT/lib" "$RUN/tree/lib"
SH="$RUN/pve/pbo/config"; mkdir -p "$RUN/pve/pbo"; : > "$RUN/pve/.members"
TB() { env -u PBO_CONFIG TEST_RUN="$RUN" TEST_SHARED="$SH" TEST_LOCAL="$RUN/local.cfg" PBO_PVE_CFS_DIR="$RUN/pve" PBO_PVE_LXC_DIR="$RUN/lxc" "$RUN/tree/pbo" "$@"; }
# the harness itself: a run that would read the real files stops with 99
out="$(env -u PBO_CONFIG TEST_RUN="$RUN" TEST_SHARED=/etc/pve/pbo/config TEST_LOCAL=/etc/pbo/config "$RUN/tree/pbo" config get KEEP_LOCAL 2>&1)"; rc=$?
[[ $rc == 99 ]] && ok "harness: a copy of pbo pointed at files outside the run directory stops (99) before it reads them" || bad "harness guard: rc=$rc $out"

# --- quoting: every value reads back the same with the strict reader and bash ---------------------
mk
# (literal on purpose: none of these may be expanded, here or in the config)
# shellcheck disable=SC2016,SC2088
vals=('a b' "it's" 'say "hi"' '$HOME' '${CACHE_DIR}' '`id`' '$(id)' 'back\slash' 'trail\' 'x #y' '#start'
      '~/x' 'a:~/b' 'tab	in' '*' '{a,b}' 'a;b|c&d' '(x)' '!bang' 'ümlaut' "q'\"\$\`\\" ' lead' 'trail ' 'plain/v-1.2:3,4@5%6+7=8')
args=(); i=0
for v in "${vals[@]}"; do i=$((i+1)); args+=("TQ$i" "$v"); done
out="$($BIN config set --force "${args[@]}" 2>&1)"; rc=$?
bad_q=''
i=0; for v in "${vals[@]}"; do
    i=$((i+1)); r="$(rd "$CFG" "TQ$i")"; b="$(bs "$CFG" "TQ$i")"
    [[ "$r" == "$v" && "$b" == "$v" ]] || bad_q+=" [$v: reader=$r bash=$b]"
done
[[ $rc == 0 && -z "$bad_q" ]] && ok "quoting: ${#vals[@]} values (spaces, quotes, \$, backticks, backslashes, #, ~, operators) read back the same by the strict reader and bash" \
    || bad "quoting: rc=$rc$bad_q $out"
grep -qxF "TQ${#vals[@]}=plain/v-1.2:3,4@5%6+7=8" "$CFG" && grep -qxF 'TQ5="\${CACHE_DIR}"' "$CFG" \
    && ok "quoting: plain when safe, double quotes with \\\$ escaped otherwise" || bad "quoting style: $(grep -E "^TQ(5|${#vals[@]})=" "$CFG")"
$BIN config set VERIFY_SUBSET 'a "b" $c `d` \e #f' >/dev/null 2>&1
[[ "$($BIN config get VERIFY_SUBSET 2>/dev/null)" == 'a "b" $c `d` \e #f' ]] && ok "config get prints the value config set wrote" \
    || bad "get after set: $($BIN config get VERIFY_SUBSET 2>&1)"
out="$($BIN config check --compare-bash 2>&1)"; rc=$?
[[ $rc == 0 ]] && grep -q 'bash reads every key the same' <<<"$out" && ok "the written file is valid bash and bash reads every key the same (config check --compare-bash)" \
    || bad "compare-bash: rc=$rc $out"

# --- the file around the change: comments, template lines, sections, duplicates --------------------
mk 'KEEP_LOCAL=2   # my comment'
cp "$CFG" "$RUN/before"
$BIN config set KEEP_LOCAL 5 >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && grep -qx 'KEEP_LOCAL=5   # my comment' "$CFG" && [[ "$(grep -c '^KEEP_LOCAL=' "$CFG")" == 1 ]] \
    && diff <(others "$RUN/before" KEEP_LOCAL) <(others "$CFG" KEEP_LOCAL) >/dev/null \
    && ok "set: the active line is replaced in place, its comment kept; an earlier line of the key (which never counted) goes; every other line unchanged" \
    || bad "in place: rc=$rc $(grep -n KEEP_LOCAL "$CFG")"
# a quoted old value with blanks, # and quotes in it: the comment after it is
# found past the quotes (_cfg_value_len), not at the # inside them
for q in '"a # b"' "'x # y'" '"a \" # b"'; do
    mk "VERIFY_SUBSET=$q   # my note"
    $BIN config set VERIFY_SUBSET 5% >/dev/null 2>&1; rc=$?
    [[ $rc == 0 ]] && grep -qx 'VERIFY_SUBSET=5% *# my note' "$CFG" && [[ "$(grep -c '^VERIFY_SUBSET=' "$CFG")" == 1 ]] \
        && ok "set: replacing the quoted value $q keeps the line's comment" || bad "quoted in place $q: rc=$rc $(grep -n VERIFY_SUBSET "$CFG")"
done
mk 'KEEP_LOCAL=2   # my comment'
$BIN config set KEEP_LOCAL 5 >/dev/null 2>&1
n0="$(grep -n '^#VERIFY_SUBSET=' "$CFG" | cut -d: -f1)"
$BIN config set VERIFY_SUBSET 5% >/dev/null 2>&1
n1="$(grep -n '^VERIFY_SUBSET=5%' "$CFG" | cut -d: -f1)"
[[ -n "$n0" && "$n0" == "$n1" ]] && grep -q '^VERIFY_SUBSET=5% *# a manual verify reads this sample' "$CFG" && ! grep -q '^#VERIFY_SUBSET=' "$CFG" \
    && ok "set: a commented template line #KEY= becomes the line, in place, with its description" || bad "template: $n0 $n1 $(grep -n VERIFY_SUBSET "$CFG")"
sed -i '/^#TR_STORAGE=/d' "$CFG"
$BIN config set TR_STORAGE local-zfs >/dev/null 2>&1
h="$(grep -n '^# --- scheduled restore tests' "$CFG" | cut -d: -f1)"; nx="$(grep -n '^# --- Proxmox integration' "$CFG" | cut -d: -f1)"; t="$(grep -n '^TR_STORAGE=local-zfs$' "$CFG" | cut -d: -f1)"
[[ -n "$t" && "$t" -gt "$h" && "$t" -lt "$nx" ]] && ok "set: a key without a line goes under its section header" || bad "section: header $h next $nx line $t"
$BIN config set --force ZZ_NEW 1 >/dev/null 2>&1
[[ "$(tail -n 1 "$CFG")" == ZZ_NEW=1 ]] && ok "set --force: a key the schema does not know goes at the end" || bad "end: $(tail -n 2 "$CFG")"
mk 'KEEP_OFFSITE_DAILY=9' 'KEEP_OFFSITE_DAILY=10'
cp "$CFG" "$RUN/before"
$BIN config unset KEEP_OFFSITE_DAILY >/dev/null 2>&1; rc=$?
[[ $rc == 0 && "$(rd "$CFG" KEEP_OFFSITE_DAILY)" == '<unset>' ]] && ! grep -q '^KEEP_OFFSITE_DAILY=' "$CFG" \
    && diff <(others "$RUN/before" KEEP_OFFSITE_DAILY) <(others "$CFG" KEEP_OFFSITE_DAILY) >/dev/null \
    && ok "unset: every active line of the key goes (an earlier one would count otherwise), nothing else" || bad "unset dup: rc=$rc $(grep -n KEEP_OFFSITE_DAILY "$CFG")"
mk 'KEEP_LOCAL=4'
sed -i 's|^KEEP_LOCAL=2 |#KEEP_LOCAL=2|' "$CFG"
$BIN config unset KEEP_LOCAL >/dev/null 2>&1
grep -q '^#KEEP_LOCAL=2 *# local cache repo' "$CFG" && ! grep -q '^KEEP_LOCAL=' "$CFG" && ok "unset: a #KEY= template line stays" || bad "unset template: $(grep -n KEEP_LOCAL "$CFG")"
out="$($BIN config unset KEEP_LOCAL 2>&1)"; rc=$?
[[ $rc == 0 ]] && grep -q 'nothing to change' <<<"$out" && ok "unset of a key the file does not set: nothing to change (0)" || bad "unset absent: rc=$rc $out"
mk; cp "$CFG" "$RUN/before"
out="$($BIN config set KEEP_LOCAL 2 2>&1)"; rc=$?
[[ $rc == 0 ]] && grep -q 'nothing to change' <<<"$out" && cmp -s "$RUN/before" "$CFG" && ok "set to the value the file has: nothing to change, file untouched" || bad "noop: rc=$rc $out"
out="$($BIN --json config set KEEP_LOCAL 2 2>/dev/null)"; rc=$?
[[ $rc == 0 ]] && jq -e '.changed == false and .written == false and .changes[0].before == "2" and .changes[0].after == "2" and .changes[0].file_before == "2"' >/dev/null <<<"$out" \
    && ok "--json of a change that changes nothing: the values as they are" || bad "noop json: rc=$rc $out"

# --- owner, group and mode ---------------------------------------------------------------------------
# a group the new file would not get by itself (mktemp gives the caller's
# primary group): as non-root a supplementary one, so the copy is really tested
grpnote=''
if [[ "$(id -u)" == 0 ]]; then
    grp="$(getent group nogroup >/dev/null && echo nogroup || echo daemon)"
else
    grp="$(id -Gn | tr ' ' '\n' | grep -vxF "$(id -gn)" | head -n 1)"
    [[ -n "$grp" ]] || { grp="$(id -gn)"; grpnote=' (the group check needs root or a supplementary group)'; }
fi
mk; chgrp "$grp" "$CFG"; chmod 0640 "$CFG"
want="$(stat -c '%U:%G %a' "$CFG")"
$BIN config set KEEP_LOCAL 3 >/dev/null 2>&1; rc=$?
[[ $rc == 0 && "$(stat -c '%U:%G %a' "$CFG")" == "$want" && "$(rd "$CFG" KEEP_LOCAL)" == 3 ]] && ! tmpleft \
    && ok "owner, group and mode kept: $want (a janitor's 0640 root:<user> survives), no temp file left$grpnote" || bad "mode: want $want got $(stat -c '%U:%G %a' "$CFG") rc=$rc"
chmod 600 "$CFG"
# an extended ACL (a reader the admin added) survives the replace, and the
# group bits stay the mask (skipped where the filesystem has no ACLs)
mk
if command -v setfacl >/dev/null 2>&1 && setfacl -m u:65534:r "$CFG" 2>/dev/null; then
    $BIN config set KEEP_LOCAL 3 >/dev/null 2>&1; rc=$?
    [[ $rc == 0 && "$(rd "$CFG" KEEP_LOCAL)" == 3 ]] && getfacl -cn --skip-base "$CFG" 2>/dev/null | grep -qx 'user:65534:r--' \
        && getfacl -cn "$CFG" 2>/dev/null | grep -qx 'group::---' && [[ "$(stat -c %a "$CFG")" == 640 ]] \
        && ok "an extended ACL entry is copied to the new file (group:: and the mask as before)" || bad "acl: rc=$rc $(getfacl -cn "$CFG" 2>&1 | tr '\n' ' ')"
    setfacl -b "$CFG"; chmod 600 "$CFG"
else
    ok "ACL copy: skipped (no setfacl, or the filesystem of the run directory has no ACLs)"
fi

# --- the lock ----------------------------------------------------------------------------------------
mk; cp "$CFG" "$RUN/before"
exec 9>>"$RUN/lock/pbo.config"; flock -n 9
out="$($BIN config set KEEP_LOCAL 7 2>&1)"; rc=$?
exec 9>&-
[[ $rc == 75 ]] && grep -q 'another config change is running' <<<"$out" && cmp -s "$RUN/before" "$CFG" \
    && ok "lock pbo.config busy: exit 75, file unchanged" || bad "lock: rc=$rc $out"
out="$($BIN config set KEEP_LOCAL 7 2>&1)"; rc=$?
[[ $rc == 0 ]] && ok "lock free again: the change goes through" || bad "after lock: rc=$rc $out"
# the lock is held for the whole read-modify-write: a writer paused inside
# _cfg_write_locked (the harness's TEST_PAUSE_DIR) still holds it
printf '%s\n' "LOCK_DIR=$RUN/lock" "LOG_DIR=$RUN/log" "STATE_DIR=$RUN/state" > "$RUN/local.cfg"; chmod 600 "$RUN/local.cfg"; rm -f "$SH"
P="$RUN/pause"; rm -rf "$P"; mkdir -p "$P"
TEST_PAUSE_DIR="$P" TB config set KEEP_LOCAL 7 >"$RUN/pause.out" 2>&1 & pj=$!
paused=0; for _ in $(seq 100); do [[ -e "$P/in" ]] && { paused=1; break; }; sleep 0.1; done
(( paused )) || bad "lock setup: the first writer did not reach its pause within 10 s ($(tail -n 3 "$RUN/pause.out"))"
out="$(TB config set KEEP_OFFSITE_WEEKLY 5 2>&1)"; rc2=$?
held=0; exec 9>>"$RUN/lock/pbo.config"; flock -n 9 || held=1; exec 9>&-
touch "$P/go"; wait "$pj"; rc=$?
if (( paused )); then
    [[ $rc == 0 && $rc2 == 75 && $held == 1 ]] && grep -q 'another config change is running' <<<"$out" \
        && [[ "$(rd "$RUN/local.cfg" KEEP_LOCAL)" == 7 && "$(rd "$RUN/local.cfg" KEEP_OFFSITE_WEEKLY)" == '<unset>' ]] && ! tmpleft \
        && ok "lock: held while the first writer is inside the read-modify-write (a second writer gets 75), the first one's change written" \
        || bad "lock held: first rc=$rc $(cat "$RUN/pause.out") second rc=$rc2 $out held=$held"
fi

# --- dry run -----------------------------------------------------------------------------------------
mk; cp "$CFG" "$RUN/before"; touch -d '2026-01-15 05:00:00' "$CFG"; m0="$(stat -c %Y "$CFG")"
out="$($BIN --dry-run config set KEEP_LOCAL 9 NTFY_TOKEN tk_dry_secret_1 2>&1)"; rc=$?
[[ $rc == 0 && "$(stat -c %Y "$CFG")" == "$m0" ]] && cmp -s "$RUN/before" "$CFG" && ! tmpleft \
    && grep -q '^+KEEP_LOCAL=9 ' <<<"$out" && grep -q '^-KEEP_LOCAL=2 ' <<<"$out" && grep -q '^+NTFY_TOKEN=<hidden>' <<<"$out" \
    && ! grep -q tk_dry_secret_1 <<<"$out" && grep -q 'dry run: .* not changed' <<<"$out" \
    && ok "--dry-run: a unified diff (secrets hidden), the file and its mtime unchanged, no temp file" || bad "dry run: rc=$rc $out"
out="$($BIN --json config set KEEP_LOCAL 9 --dry-run 2>/dev/null)"; rc=$?
[[ $rc == 0 ]] && cmp -s "$RUN/before" "$CFG" && jq -e '.dry_run and .written == false and .changed and (.diff | test("\\+KEEP_LOCAL=9"))' >/dev/null <<<"$out" \
    && ok "--dry-run after the command, --json: the diff in the result, nothing written" || bad "dry json: rc=$rc $out"

# --- JSON and audit ------------------------------------------------------------------------------------
mk; rm -f "$RUN/log/audit.log" "$RUN/log/audit.jsonl"
out="$($BIN --json config set KEEP_LOCAL 4 NTFY_TOKEN tk_json_secret_2 2>/dev/null)"; rc=$?
[[ $rc == 0 ]] && jq -e --arg f "$CFG" '.ok and .file == $f and .written and .action == "set"
    and any(.changes[]; .key == "KEEP_LOCAL" and .before == "2" and .after == "4" and .file_before == "2" and .file_after == "4" and (.secret | not))
    and any(.changes[]; .key == "NTFY_TOKEN" and .secret and .before == "<unset>" and .after == "<set>" and .file_after == "<set>")
    and any(.effective[]; .key == "RESTIC_KEEP_LAST" and .before == "2" and .after == "4")' >/dev/null <<<"$out" \
    && ! grep -q tk_json_secret_2 <<<"$out" && ok "--json: before/after per key (a secret masked), the file, the keys that follow" || bad "json: rc=$rc $out"
grep -q "config set file=$CFG KEEP_LOCAL=4 NTFY_TOKEN=<secret>" "$RUN/log/audit.log" && ! grep -q tk_json_secret_2 "$RUN/log/audit.log" "$RUN/log/audit.jsonl" \
    && jq -se 'any(.[]; .kind == "command" and .command == "config" and .read_only == false and (.args | index("<secret>")))' "$RUN/log/audit.jsonl" >/dev/null \
    && ok "audit: the change recorded with the secret masked (audit.log, the event and the command's args in audit.jsonl)" \
    || bad "audit: $(cat "$RUN/log/audit.log" 2>&1) $(cat "$RUN/log/audit.jsonl" 2>&1)"
rm -f "$RUN/log/audit.jsonl"; $BIN config list >/dev/null 2>&1; $BIN config get KEEP_LOCAL >/dev/null 2>&1
jq -se 'length == 2 and all(.[]; .command == "config" and .read_only == true)' "$RUN/log/audit.jsonl" >/dev/null \
    && ok "audit: config list/get stay read-only records (only set and unset change anything)" || bad "audit ro: $(cat "$RUN/log/audit.jsonl")"

# --- refusals ------------------------------------------------------------------------------------------
mk; cp "$CFG" "$RUN/before"
t_ref() {   # t_ref <rc> <pattern> <what> <pbo args...>
    local want="$1" pat="$2" what="$3"; shift 3
    out="$($BIN "$@" 2>&1)"; rc=$?
    [[ $rc == "$want" ]] && grep -q -- "$pat" <<<"$out" && cmp -s "$RUN/before" "$CFG" && ok "$what (exit $want, file unchanged)" || bad "$what: rc=$rc $out"
}
t_ref 64 "managed by 'pbo integrate enable both|integrated' or 'pbo integrate disable'" "a managed key is refused with the command that manages it" config set PBO_INTEGRATION both
t_ref 64 'managed by install.sh' "PBO_ROLE is managed by install.sh" config unset PBO_ROLE
t_ref 64 "not a known config key" "an unknown key is refused without --force" config set KEEP_OFSITE_DAILY 3
t_ref 64 "environment switch" "an environment switch is refused, also with --force" config set --force PBO_REPO cache
t_ref 64 "not even with --force" "PATH is refused even with --force" config set --force PATH /tmp
t_ref 78 "KEEP_LOCAL='x' is not a whole number" "a value of the wrong type: exit 78 with the reason" config set KEEP_LOCAL x
t_ref 78 "must be an absolute path" "a relative path is refused" config set TR_HISTORY relative/file
t_ref 78 "control character" "a value with a newline is refused" config set VERIFY_SUBSET $'a\nb'
t_ref 64 "has no value" "a key without a value" config set KEEP_LOCAL
t_ref 64 "given twice" "a key given twice" config set KEEP_LOCAL 3 KEEP_LOCAL 4
t_ref 64 "no cluster-shared config" "--shared with PBO_CONFIG set: there is no shared file" config set --shared KEEP_LOCAL 3
t_ref 78 "is not a URL" "two changes, one invalid: neither is written" config set KEEP_LOCAL 3 NTFY_URL not-a-url
out="$($BIN config set NTFY_URL not-a-url-secret 2>&1)"; ! grep -q not-a-url-secret <<<"$out" && ok "a refused secret's value is not repeated" || bad "secret in refusal: $out"
# KEY=VALUE as one argument: refused at once, and what follows the = reaches
# neither the output, pbo.log nor the audit record's arguments
rm -f "$RUN/log/audit.jsonl"
for a in "NTFY_TOKEN=tk_onearg_secret" "NTFY_TOKEN=tk_onearg_secret KEEP_LOCAL" "NOT_A_KEY=tk_onearg_secret 3"; do
    # (split on purpose: the tokens as a user types them)
    # shellcheck disable=SC2086
    out="$($BIN config set $a 2>&1)"; rc=$?
    [[ $rc == 64 ]] && grep -q "'${a%%=*}=\.\.\.' is one argument: write config set ${a%%=*} VALUE" <<<"$out" && ! grep -q tk_onearg_secret <<<"$out" \
        && cmp -s "$RUN/before" "$CFG" && ok "set ${a%%=*}=... as one argument: exit 64 naming the key only" || bad "one arg $a: rc=$rc $out"
done
out="$($BIN config unset NTFY_TOKEN=tk_onearg_secret 2>&1)"; rc=$?
[[ $rc == 64 ]] && grep -q "write config unset NTFY_TOKEN" <<<"$out" && ! grep -q tk_onearg_secret <<<"$out" && ok "unset KEY=VALUE: exit 64 naming the key only" || bad "unset one arg: rc=$rc $out"
! grep -rq tk_onearg_secret "$RUN/log" && jq -se 'map(select(.kind == "command" and .command == "config")) | length == 4 and any(.[]; .args | index("NTFY_TOKEN=<secret>"))' "$RUN/log/audit.jsonl" >/dev/null \
    && ok "KEY=VALUE as one argument: the value is in no log file, the audit record has KEY=<secret>" \
    || bad "one arg leak: $(grep -rl tk_onearg_secret "$RUN/log" 2>&1) $(cat "$RUN/log/audit.jsonl" 2>&1)"
cfj="$RUN/jan.cfg"; ju="$(id -un)"; [[ "$(id -u)" != 0 ]] || ju=nobody
printf '%s\n' "PBO_ROLE=janitor" "JANITOR_USER=$ju" "LOCAL_REPO=false" "CACHE_DIR=$RUN/cache" "LOG_DIR=$RUN/log" "STATE_DIR=$RUN/state" "LOCK_DIR=$RUN/lock" \
    "RESTIC_OFFSITE_REPO=$RUN/jrepo" "KEEP_OFFSITE_DAILY=7" > "$cfj"
chgrp "$grp" "$cfj"; chmod 0640 "$cfj"; jw="$(stat -c '%U:%G %a' "$cfj")"
printf '#!/bin/sh\necho "runuser $*" >> "%s"\nexit 1\n' "$RUN/runuser.log" > "$RUN/bin/fake-runuser"; chmod 755 "$RUN/bin/fake-runuser"
out="$(PBO_CONFIG="$cfj" PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" $BIN config set BACKUP_ORDER 101 2>&1)"; rc=$?
[[ $rc == 78 ]] && grep -q 'BACKUP_ORDER is not used on a janitor' <<<"$out" && ok "janitor: a host-only key is refused (78)" || bad "janitor host key: rc=$rc $out"
out="$(PBO_CONFIG="$cfj" PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" $BIN config set KEEP_OFFSITE_DAILY 14 2>&1)"; rc=$?
if [[ "$(id -u)" == 0 ]]; then
    [[ $rc == 0 && "$(rd "$cfj" KEEP_OFFSITE_DAILY)" == 14 && "$(stat -c '%U:%G %a' "$cfj")" == "$jw" && ! -e "$RUN/runuser.log" ]] \
        && ok "janitor: config set run as root stays root (no switch to the janitor user), $jw kept" || bad "janitor set: rc=$rc $out $(cat "$RUN/runuser.log" 2>/dev/null)"
    # root takes the lock on the config's own directory, not in the janitor
    # user's LOCK_DIR, where that user could plant a symlink or a FIFO
    rm -f "$RUN/lock/pbo.config" "$RUN/victim"; ln -s "$RUN/victim" "$RUN/lock/pbo.config"
    out="$(PBO_CONFIG="$cfj" PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" timeout 30 $BIN config set KEEP_OFFSITE_DAILY 15 2>&1)"; rc=$?
    rm -f "$RUN/lock/pbo.config"; mkfifo "$RUN/lock/pbo.config"
    out2="$(PBO_CONFIG="$cfj" PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" timeout 30 $BIN config set KEEP_OFFSITE_DAILY 16 2>&1)"; rc2=$?
    rm -f "$RUN/lock/pbo.config"
    [[ $rc == 0 && $rc2 == 0 && ! -e "$RUN/victim" && "$(rd "$cfj" KEEP_OFFSITE_DAILY)" == 16 ]] \
        && ok "janitor as root: a symlink or a FIFO in LOCK_DIR is never opened (the lock is on the config's directory)" \
        || bad "janitor lock: rc=$rc $out rc2=$rc2 $out2 victim=$([[ -e "$RUN/victim" ]] && echo yes)"
else
    [[ $rc == 0 && "$(rd "$cfj" KEEP_OFFSITE_DAILY)" == 14 && "$(stat -c '%U:%G %a' "$cfj")" == "$jw" ]] \
        && ok "janitor: config set works as the calling user, $jw kept (the root no-switch path and its lock are not exercised)" || bad "janitor set: rc=$rc $out"
fi

# --- the cluster-shared file: written only with --shared ----------------------------------------------
printf '%s\n' "KEEP_OFFSITE_DAILY=14" "CACHE_DIR=$RUN/cache" > "$SH"; chmod 600 "$SH"
printf '%s\n' "LOCK_DIR=$RUN/lock" "LOG_DIR=$RUN/log" "STATE_DIR=$RUN/state" "KEEP_OFFSITE_WEEKLY=5" > "$RUN/local.cfg"; chmod 600 "$RUN/local.cfg"
cp "$SH" "$RUN/shared.before"
out="$(TB config set KEEP_OFFSITE_DAILY 21 2>&1)"; rc=$?
[[ $rc == 0 ]] && cmp -s "$RUN/shared.before" "$SH" && [[ "$(rd "$RUN/local.cfg" KEEP_OFFSITE_DAILY)" == 21 ]] \
    && ok "regression: a set without --shared writes the local file, never the shared one (which set the key)" || bad "local only: rc=$rc $out; shared: $(cat "$SH")"
cp "$RUN/local.cfg" "$RUN/local.before"
out="$(TB --json config set --shared KEEP_OFFSITE_DAILY 28 KEEP_OFFSITE_MONTHLY 9 2>/dev/null)"; rc=$?
[[ $rc == 0 ]] && cmp -s "$RUN/local.before" "$RUN/local.cfg" && [[ "$(rd "$SH" KEEP_OFFSITE_DAILY)" == 28 && "$(rd "$SH" KEEP_OFFSITE_MONTHLY)" == 9 ]] \
    && jq -e --arg l "$RUN/local.cfg" '.shared and any(.changes[]; .key == "KEEP_OFFSITE_DAILY" and .overridden_by == $l and .before == "21" and .after == "21")
          and any(.changes[]; .key == "KEEP_OFFSITE_MONTHLY" and .overridden_by == null and .after == "9")' >/dev/null <<<"$out" \
    && ok "--shared writes the shared file only, and names the local file that overrides a key on this node" || bad "shared: rc=$rc $out"
cp "$SH" "$RUN/shared.before"
for a in "NTFY_TOKEN tk_x:secret" "RESTIC_SFTP_COMMAND ssh:secret" "RESTIC_BIN /usr/bin/restic:runs a program" "PBO_VZDUMP_HOOK /x:runs a program" \
         "CACHE_DIR $RUN/x:decides where each node keeps its cache" "RESTIC_CACHE_REPO $RUN/x/repo:decides where each node keeps its cache" \
         "PVE_SPOOL_DIR $RUN/x/spool:decides where each node keeps its cache"; do
    # (split on purpose: KEY VALUE)
    # shellcheck disable=SC2086
    out="$(TB config set --shared ${a%%:*} --yes 2>&1)"; rc=$?
    [[ $rc == 78 ]] && grep -q "${a#*:}" <<<"$out" && cmp -s "$RUN/shared.before" "$SH" \
        && ok "--shared refuses ${a%% *} (${a#*:})" || bad "shared refusal ${a%% *}: rc=$rc $out"
done
out="$(TB config unset --shared CACHE_DIR 2>&1)"; rc=$?
[[ $rc == 78 ]] && grep -q 'decides where each node keeps its cache' <<<"$out" && cmp -s "$RUN/shared.before" "$SH" \
    && ok "unset --shared CACHE_DIR is refused too (every node's cache would move), the shared file unchanged" || bad "unset shared cache: rc=$rc $out"
out="$(TB config unset --shared KEEP_OFFSITE_DAILY 2>&1)"; rc=$?
[[ $rc == 0 && "$(rd "$SH" KEEP_OFFSITE_DAILY)" == '<unset>' ]] && cmp -s "$RUN/local.before" "$RUN/local.cfg" \
    && ok "unset --shared removes the key from the shared file only" || bad "unset shared: rc=$rc $out"
# pmxcfs keeps modes of its own and refuses chmod/chown: below PBO_PVE_CFS_DIR
# the writer never calls them (fakes that fail for that path come first in PATH)
mkdir -p "$RUN/fakebin"; rm -f "$RUN/cfs-calls"
for t in chmod chown chgrp; do
    printf '#!/bin/sh\nfor a; do case "$a" in %s/*) echo "%s $*" >> %s; exit 1 ;; esac; done\nexec %s "$@"\n' \
        "$RUN/pve" "$t" "$RUN/cfs-calls" "$(command -v "$t")" > "$RUN/fakebin/$t"
    chmod 755 "$RUN/fakebin/$t"
done
out="$(PATH="$RUN/fakebin:$PATH" TB config set --shared KEEP_OFFSITE_DAILY 30 2>&1)"; rc=$?
[[ $rc == 0 && "$(rd "$SH" KEEP_OFFSITE_DAILY)" == 30 && ! -e "$RUN/cfs-calls" ]] && grep -q 'pmxcfs copies' <<<"$out" \
    && ok "--shared on the cluster filesystem: written without chmod/chown (pmxcfs keeps its own modes)" || bad "cfs write: rc=$rc $out $(cat "$RUN/cfs-calls" 2>&1)"
cp "$SH" "$RUN/shared.keep"; rm -rf "$RUN/pve/pbo"
out="$(PATH="$RUN/fakebin:$PATH" TB config set --shared KEEP_OFFSITE_DAILY 31 2>&1)"; rc=$?
[[ $rc == 0 && -d "$RUN/pve/pbo" && "$(rd "$SH" KEEP_OFFSITE_DAILY)" == 31 && ! -e "$RUN/cfs-calls" ]] \
    && ok "--shared without the pbo directory on the cluster filesystem: created there, no permission-table mode applied" || bad "cfs mkdir: rc=$rc $out $(cat "$RUN/cfs-calls" 2>&1)"
cp "$RUN/shared.keep" "$SH"
# another node replaces the shared file while this one checks its candidate:
# the per-node lock cannot see that, the re-read before the rename does
cp "$SH" "$RUN/shared.before"
out="$(TEST_SHARED_EDIT='KEEP_OFFSITE_MONTHLY=4' TB config set --shared KEEP_OFFSITE_DAILY 33 2>&1)"; rc=$?
[[ $rc == 75 ]] && grep -q 'was changed on another node while this change was prepared; nothing was changed' <<<"$out" \
    && cmp -s <(cat "$RUN/shared.before"; echo 'KEEP_OFFSITE_MONTHLY=4') "$SH" && ! tmpleft \
    && ok "--shared: the shared file changed on another node meanwhile: exit 75, that change kept, this one not made" || bad "shared race: rc=$rc $out $(cat "$SH")"
cp "$RUN/shared.before" "$SH"
# no live cluster filesystem (pve-cluster stopped: /etc/pve is a plain
# directory), or a janitor (no Proxmox at all): --shared writes nothing
mv "$RUN/pve/.members" "$RUN/pve/.members.off"; cp "$SH" "$RUN/shared.keep"; rm -rf "$RUN/pve/pbo"
out="$(TB config set --shared KEEP_OFFSITE_DAILY 3 2>&1)"; rc=$?
[[ $rc == 69 ]] && grep -q 'is not the mounted cluster filesystem (is pve-cluster running?): nothing was written' <<<"$out" && [[ ! -e "$RUN/pve/pbo" ]] \
    && ok "--shared without a mounted cluster filesystem (no .members/.version): exit 69, nothing created" || bad "no cfs: rc=$rc $out"
mv "$RUN/pve/.members.off" "$RUN/pve/.members"; mkdir -p "$RUN/pve/pbo"; cp "$RUN/shared.keep" "$SH"
cp "$RUN/local.cfg" "$RUN/local.keep"; mv "$SH" "$RUN/shared.keep"
printf '%s\n' "PBO_ROLE=janitor" "JANITOR_USER=$ju" "LOCAL_REPO=false" "LOCK_DIR=$RUN/lock" "LOG_DIR=$RUN/log" "STATE_DIR=$RUN/state" \
    "RESTIC_OFFSITE_REPO=$RUN/jrepo" > "$RUN/local.cfg"; chmod 600 "$RUN/local.cfg"
out="$(PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" TB config set --shared KEEP_OFFSITE_DAILY 3 2>&1)"; rc=$?
[[ $rc == 64 ]] && grep -q 'a janitor has no Proxmox cluster filesystem' <<<"$out" && [[ ! -e "$SH" ]] \
    && ok "--shared on a janitor: exit 64, no shared file created" || bad "janitor shared: rc=$rc $out"
cp "$RUN/local.keep" "$RUN/local.cfg"; mv "$RUN/shared.keep" "$SH"
# a bash difference the files already had (a CRLF line in the shared file)
# does not block a write to the local one
# (CRLF fixtures on purpose: their loads stay out of tests/all.sh's config
# corpus, which only tests/config_parse.sh's own fixtures may fail)
cp "$SH" "$RUN/shared.keep"; printf 'KEEP_OFFSITE_MONTHLY=4\r\n' >> "$SH"; cp "$SH" "$RUN/shared.before"
out="$(unset PBO_TEST_CONFIG_LOG; TB config set KEEP_OFFSITE_WEEKLY 6 2>&1)"; rc=$?
[[ $rc == 0 && "$(rd "$RUN/local.cfg" KEEP_OFFSITE_WEEKLY)" == 6 ]] && cmp -s "$RUN/shared.before" "$SH" && grep -q 'KEEP_OFFSITE_MONTHLY reads differently when bash sources the files, as before' <<<"$out" \
    && ok "a CRLF line in the shared file: a local write still goes through (a warning names the key)" || bad "shared crlf: rc=$rc $out"
cp "$RUN/shared.keep" "$SH"
# a key that follows CACHE_DIR, pinned in the shared file: set at its derived
# default on this node, the line is written (an unset would leave the shared
# value in force)
cp "$SH" "$RUN/shared.keep"; printf '%s\n' "RESTIC_CACHE_REPO=$RUN/elsewhere/repo" >> "$SH"
out="$(TB config set RESTIC_CACHE_REPO "$RUN/cache/repo" --yes 2>&1)"; rc=$?
[[ $rc == 0 && "$(rd "$RUN/local.cfg" RESTIC_CACHE_REPO)" == "$RUN/cache/repo" && "$(TB config get RESTIC_CACHE_REPO 2>/dev/null)" == "$RUN/cache/repo" ]] \
    && ok "follows: RESTIC_CACHE_REPO at its derived default is written when the shared file pins another value" || bad "follows shared: rc=$rc $out $(grep -n CACHE_REPO "$RUN/local.cfg")"
cp "$RUN/shared.keep" "$SH"
# a missing local file is created with the mode of the permission table
rm -f "$RUN/local.cfg"
out="$(TB config set KEEP_LOCAL 3 2>&1)"; rc=$?
[[ $rc == 0 && "$(stat -c %a "$RUN/local.cfg" 2>/dev/null)" == 600 && "$(rd "$RUN/local.cfg" KEEP_LOCAL)" == 3 \
   && "$(rd "$RUN/local.cfg" PBO_CONFIG_VERSION)" == 1 ]] && grep -q '^created ' <<<"$out" \
    && ok "a missing local config is created (0600, with PBO_CONFIG_VERSION)" || bad "create: rc=$rc $out $(stat -c %a "$RUN/local.cfg" 2>&1)"
# the environment pins it (a systemd Environment=): written as well
mk
out="$(RESTIC_CACHE_REPO="$RUN/elsewhere/repo" $BIN config set RESTIC_CACHE_REPO "$RUN/cache/repo" --yes 2>&1)"; rc=$?
[[ $rc == 0 && "$(rd "$CFG" RESTIC_CACHE_REPO)" == "$RUN/cache/repo" ]] \
    && ok "follows: RESTIC_CACHE_REPO at its derived default is written when the environment sets another value" || bad "follows env: rc=$rc $out"
mk
out="$($BIN config set RESTIC_CACHE_REPO "$RUN/cache/repo" --yes 2>&1)"; rc=$?
[[ $rc == 0 && "$(rd "$CFG" RESTIC_CACHE_REPO)" == '<unset>' ]] && grep -q 'not pinned: it follows CACHE_DIR' <<<"$out" \
    && ok "follows: with no other source, RESTIC_CACHE_REPO at its derived default is not pinned" || bad "follows plain: rc=$rc $out"

# --- the 0.5 writers go through _cfg_write: _cfg_set (setup, menu) and _integ_set_mode -----------------
printf '%s\n' "LOCK_DIR=$RUN/lock" "KEEP_LOCAL=2  # kept comment" > "$RUN/local.cfg"; chgrp "$grp" "$RUN/local.cfg"; chmod 0640 "$RUN/local.cfg"
lw="$(stat -c '%U:%G %a' "$RUN/local.cfg")"; cp "$SH" "$RUN/shared.before"
cw() {   # cw SHAREDFILE SCRIPT: SCRIPT with lib/ loaded, the file list replaced, load_config done
    env -u PBO_CONFIG SHARED="$1" LOCAL="$RUN/local.cfg" bash -c 'set -u; SELF_DIR="$PWD"
    source lib/common.sh; source lib/config_parse.sh; source lib/menu.sh; source lib/integrate.sh
    _cfg_config_files() { _CFG_FPATH=("$SHARED" "$LOCAL"); _CFG_FORIGIN=(shared local); }
    _integration_mode() { printf standalone; }
    load_config
    eval "$1"' _ "$2" 2>&1
}
# shellcheck disable=SC2016
out="$(cw "$SH" '_cfg_set RESTIC_SFTP_COMMAND "ssh u@h -p 23 -i /root/.ssh/id -s sftp" && _cfg_set KEEP_LOCAL 6 && _cfg_set CACHE_DIR "$CACHE_DIR"
    _cfg_set RESTIC_CACHE_REPO "$CACHE_DIR/repo"; echo "repo=$RESTIC_CACHE_REPO keep=$KEEP_LOCAL"
    _cfg_set KEEP_LOCAL abc; echo "bad=$?"
    INTEG_STEPS=(); _integ_set_mode both >/dev/null; echo "mode=$PBO_INTEGRATION"')"
[[ "$(rd "$RUN/local.cfg" RESTIC_SFTP_COMMAND)" == "ssh u@h -p 23 -i /root/.ssh/id -s sftp" && "$(bs "$RUN/local.cfg" RESTIC_SFTP_COMMAND)" == "ssh u@h -p 23 -i /root/.ssh/id -s sftp" ]] \
    && grep -qx 'KEEP_LOCAL=6  # kept comment' "$RUN/local.cfg" && [[ "$(stat -c '%U:%G %a' "$RUN/local.cfg")" == "$lw" ]] \
    && ok "_cfg_set: quotes a value with spaces, keeps comments, owner, group and mode" || bad "_cfg_set: $out $(cat "$RUN/local.cfg")"
grep -q "repo=$RUN/cache/repo keep=6" <<<"$out" && ! grep -q '^RESTIC_CACHE_REPO=' "$RUN/local.cfg" \
    && ok "_cfg_set: a key at the default it derives from the one it follows is not pinned (RESTIC_CACHE_REPO)" || bad "_cfg_set follows: $out"
grep -q 'bad=1' <<<"$out" && grep -q "KEEP_LOCAL='abc' is not a whole number, not written" <<<"$out" && grep -q '^KEEP_LOCAL=6 ' "$RUN/local.cfg" \
    && ok "_cfg_set: a value of the wrong type is not written (returns 1, says why)" || bad "_cfg_set bad: $out"
grep -q 'mode=both' <<<"$out" && grep -qx 'PBO_INTEGRATION=both' "$RUN/local.cfg" && cmp -s "$RUN/shared.before" "$SH" \
    && ok "_integ_set_mode writes the managed key through the writer, in the local file only" || bad "_integ_set_mode: $out"
printf '%s\n' "KEEP_OFFSITE_DAILY=14" "RESTIC_CACHE_REPO=$RUN/elsewhere/repo" > "$RUN/pin-shared.cfg"; chmod 600 "$RUN/pin-shared.cfg"
# shellcheck disable=SC2016
out="$(cw "$RUN/pin-shared.cfg" '_cfg_set RESTIC_CACHE_REPO "$CACHE_DIR/repo"; echo "repo=$RESTIC_CACHE_REPO"')"
grep -qx "repo=$RUN/cache/repo" <<<"$out" && [[ "$(rd "$RUN/local.cfg" RESTIC_CACHE_REPO)" == "$RUN/cache/repo" ]] \
    && ok "_cfg_set: the key that follows is written at its derived default when the shared file pins another value" || bad "_cfg_set follows shared: $out $(grep -n CACHE_REPO "$RUN/local.cfg")"
# the wizard's step on a config whose bash reading differs already (a CRLF
# line, as 0.5 wrote nothing about): it still writes
printf 'BACKUP_ORDER=101\r\n' >> "$RUN/local.cfg"
out="$(unset PBO_TEST_CONFIG_LOG; cw "$SH" '_cfg_set KEEP_LOCAL 8; echo "rc=$?"')"
grep -qx 'rc=0' <<<"$out" && grep -q '^KEEP_LOCAL=8 ' "$RUN/local.cfg" && grep -q $'^BACKUP_ORDER=101\r$' "$RUN/local.cfg" \
    && ok "_cfg_set on a file with a CRLF line: written, the CRLF line left as it is" || bad "_cfg_set crlf: $out"
sed -i '/^BACKUP_ORDER=101\r$/d' "$RUN/local.cfg"

# --- on_change hooks -------------------------------------------------------------------------------------
mk "PVE_CATALOG_MOUNT=true"; : > "$RUN/calls"; rm -f "$RUN"/sysd/*
$BIN config set PVE_CATALOG_MOUNT_DIR "$RUN/mnt" >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ! grep -q 'systemctl restart' "$RUN/calls" && ok "restart-mount: pbo-mount.service not running, not restarted" || bad "restart idle: rc=$rc $(cat "$RUN/calls")"
: > "$RUN/sysd/pbo-mount.service.active"; : > "$RUN/calls"
out="$($BIN --json config set PVE_CATALOG_MOUNT false 2>/dev/null)"; rc=$?
[[ $rc == 0 ]] && grep -qx 'systemctl restart pbo-mount.service' "$RUN/calls" && jq -e 'any(.hooks[]; .hook == "restart-mount" and .status == "ok")' >/dev/null <<<"$out" \
    && ok "restart-mount: a running pbo-mount.service is restarted after the write (mocked systemctl)" || bad "restart: rc=$rc $out $(cat "$RUN/calls")"
: > "$RUN/calls"; $BIN --dry-run config set PVE_CATALOG_MOUNT true >/dev/null 2>&1
! grep -q 'systemctl restart' "$RUN/calls" && ok "restart-mount: a dry run restarts nothing" || bad "restart dry: $(cat "$RUN/calls")"
: > "$RUN/calls"; MOCK_SYSTEMCTL_FAIL=restart $BIN config set PVE_CATALOG_MOUNT true >/dev/null 2>&1; rc=$?
[[ $rc == 69 && "$(rd "$CFG" PVE_CATALOG_MOUNT)" == true ]] && ok "restart-mount failing: the config is written, exit 69" || bad "restart fail: rc=$rc"
rm -f "$RUN"/sysd/*
# the dispatcher: restart-mount once for the two keys that name it, nothing for
# a key without a hook; PBO_INTEGRATION has none (managed: `pbo integrate`
# converges PVE's side itself, config set refuses it, see the refusals)
out="$(env -u PBO_CONFIG bash -c 'set -u; SELF_DIR="$PWD"; source lib/common.sh; source lib/config_schema.sh; source lib/config.sh; _cs_load
    _cfg_hook_restart_mount() { echo "restart"; }
    declare -gA CFGW_EB=([PBO_INTEGRATION]=standalone [PVE_CATALOG_MOUNT_DIR]=/a [PVE_CATALOG_MOUNT]=true [KEEP_LOCAL]=2) CFGW_EA=([PBO_INTEGRATION]=both [PVE_CATALOG_MOUNT_DIR]=/b [PVE_CATALOG_MOUNT]=false [KEEP_LOCAL]=3)
    _cfg_hooks_post; echo "rc=$?"' 2>&1)"
[[ "$out" == $'restart\nrc=0' ]] && ! _cs_out="$(bash -c 'source lib/config_schema.sh; _cs_load; _cs_flag PBO_INTEGRATION on_change' 2>/dev/null)" \
    && ok "on_change dispatch: restart-mount once for the keys whose value changes; PBO_INTEGRATION has no hook" || bad "dispatch: $out ${_cs_out:-}"
# confirm-repo: the repo pbo writes to changes, no data moves
mk; cp "$CFG" "$RUN/before"
out="$($BIN config set RESTIC_OFFSITE_REPO "$RUN/other-repo" 2>&1 </dev/null)"; rc=$?
[[ $rc == 64 ]] && grep -q 'moves no data' <<<"$out" && grep -q 'add --yes' <<<"$out" && cmp -s "$RUN/before" "$CFG" \
    && ok "confirm-repo: a new repo without --yes and without a terminal is refused, nothing written" || bad "confirm no: rc=$rc $out"
out="$($BIN config set RESTIC_OFFSITE_REPO "$RUN/other-repo" --yes 2>&1 </dev/null)"; rc=$?
[[ $rc == 0 && "$(rd "$CFG" RESTIC_OFFSITE_REPO)" == "$RUN/other-repo" ]] && grep -q 'moves no data' <<<"$out" \
    && ok "confirm-repo: --yes writes it and says that no data is moved" || bad "confirm yes: rc=$rc $out"
out="$($BIN config set RESTIC_CACHE_REPO "$RUN/cache2/repo" 2>&1 </dev/null)"; rc=$?
[[ $rc == 64 ]] && grep -q 'RESTIC_CACHE_REPO' <<<"$out" && ok "confirm-repo: RESTIC_CACHE_REPO asks too" || bad "confirm cache repo: rc=$rc $out"

# --- CACHE_DIR: an empty cache is created through the permission table; one with data is moved -------
# (the move itself: tests/cachemove.sh; here only that it needs --yes and changes nothing without it)
mk "RESTIC_CACHE_REPO=$RUN/cache/repo"; rm -rf "$RUN/cache"; mkdir -p "$RUN/cache/repo" "$RUN/cache/spool/dump" "$RUN/cache/staging"
out="$($BIN config set CACHE_DIR "$RUN/newcache" 2>&1)"; rc=$?
[[ $rc == 0 && -d "$RUN/newcache" && "$(stat -c %a "$RUN/newcache")" == 750 && "$(rd "$CFG" CACHE_DIR)" == "$RUN/newcache" ]] \
    && ok "CACHE_DIR on an empty cache: the new directory is created by the CACHE_DIR rule (0750) and the config written" || bad "empty cache: rc=$rc $out $(stat -c %a "$RUN/newcache" 2>&1)"
[[ "$(rd "$CFG" RESTIC_CACHE_REPO)" == '<unset>' ]] \
    && grep -q "RESTIC_CACHE_REPO: $RUN/cache/repo -> $RUN/newcache/repo (removed" <<<"$out" \
    && ok "CACHE_DIR: RESTIC_CACHE_REPO pinned at the old derived default is removed, it follows" || bad "follows: $out $(grep -n CACHE_REPO "$CFG")"
mk; mkdir -p "$RUN/cache/repo"; : > "$RUN/cache/repo/config"; cp "$CFG" "$RUN/before"; rm -rf "$RUN/newcache2"
out="$($BIN config set CACHE_DIR "$RUN/newcache2" 2>&1 </dev/null)"; rc=$?
[[ $rc == 64 ]] && grep -q 'the cache holds data: move CACHE_DIR' <<<"$out" && grep -q 'add --yes' <<<"$out" && cmp -s "$RUN/before" "$CFG" && [[ ! -e "$RUN/newcache2" ]] \
    && ok "CACHE_DIR on a cache with data: a move, which needs --yes (64 without it), nothing changed (file, no new directory)" || bad "data cache: rc=$rc $out"
out="$($BIN --dry-run config set CACHE_DIR "$RUN/newcache2" 2>&1)"; rc=$?
[[ $rc == 0 ]] && grep -q 'cache move plan:' <<<"$out" && cmp -s "$RUN/before" "$CFG" && [[ ! -e "$RUN/newcache2" ]] \
    && ok "CACHE_DIR on a cache with data, --dry-run: the move's plan, nothing changed" || bad "data dry: rc=$rc $out"
# the vzdump probe is this suite's (PBO_TEST_CM_VZDUMP_PIDS, empty above): the
# host's own backup jobs never decide the result
out="$(PBO_TEST_CM_VZDUMP_PIDS=4242 $BIN --dry-run config set CACHE_DIR "$RUN/newcache2" 2>&1)"; rc=$?
[[ $rc == 69 ]] && grep -q 'vzdump runs (pid 4242)' <<<"$out" && cmp -s "$RUN/before" "$CFG" \
    && ok "CACHE_DIR move preflight: the vzdump processes come from the test hook (a running one refuses, 69)" || bad "vzdump hook: rc=$rc $(grep -i vzdump <<<"$out")"
rm -f "$RUN/cache/repo/config"
out="$($BIN --dry-run config set CACHE_DIR "$RUN/newcache2" 2>&1)"; rc=$?
[[ $rc == 0 && ! -e "$RUN/newcache2" ]] && cmp -s "$RUN/before" "$CFG" && grep -q 'would be created' <<<"$out" \
    && ok "CACHE_DIR --dry-run on an empty cache: says it would create the directory, creates nothing" || bad "cache dry: rc=$rc $out"
mkdir -p "$RUN/full"; : > "$RUN/full/other"
out="$($BIN config set CACHE_DIR "$RUN/full" 2>&1)"; rc=$?
[[ $rc == 69 ]] && grep -q 'is not empty' <<<"$out" && cmp -s "$RUN/before" "$CFG" && ok "CACHE_DIR to a directory that holds other files: refused (69)" || bad "full target: rc=$rc $out"
out="$($BIN config set CACHE_DIR /var/cache 2>&1)"; rc=$?
[[ $rc == 78 ]] && grep -q 'system directory' <<<"$out" && cmp -s "$RUN/before" "$CFG" && ok "CACHE_DIR to a system directory: refused (78)" || bad "system dir: rc=$rc $out"
mk "PBO_INTEGRATION=both"; cp "$CFG" "$RUN/before"
out="$($BIN config set CACHE_DIR "$RUN/newcache3" 2>&1 </dev/null)"; rc=$?
[[ $rc == 64 ]] && grep -q 'add --yes' <<<"$out" && cmp -s "$RUN/before" "$CFG" && [[ ! -e "$RUN/newcache3" ]] \
    && ok "CACHE_DIR with the integration on (the spool follows, storage.cfg names it): a move even when empty, which needs --yes" || bad "integrated: rc=$rc $out"

# the same directory with a trailing slash: nothing moves, so a cache with
# data is no reason to refuse
mk; rm -rf "$RUN/cache"; mkdir -p "$RUN/cache/repo"; : > "$RUN/cache/repo/config"
out="$($BIN config set CACHE_DIR "$RUN/cache/" 2>&1)"; rc=$?
[[ $rc == 0 && "$(rd "$CFG" CACHE_DIR)" == "$RUN/cache/" && -e "$RUN/cache/repo/config" ]] && grep -q 'nothing to move' <<<"$out" \
    && ok "CACHE_DIR re-pinned with a trailing slash (a cache with data): not a move, written (0)" || bad "trailing slash: rc=$rc $out"
# the snapshot directories of a ZFS dataset or an NFS export at the cache root
# are not the cache's data, and do not make a new directory non-empty
mk; rm -rf "$RUN/cache" "$RUN/zfsnew"; mkdir -p "$RUN/cache/repo" "$RUN/cache/.zfs/snapshot/s1/repo" "$RUN/zfsnew/.snapshot/s1"
: > "$RUN/cache/.zfs/snapshot/s1/repo/config"; : > "$RUN/zfsnew/.snapshot/s1/f"
out="$($BIN config set CACHE_DIR "$RUN/zfsnew" 2>&1)"; rc=$?
[[ $rc == 0 && "$(rd "$CFG" CACHE_DIR)" == "$RUN/zfsnew" ]] \
    && ok "CACHE_DIR: .zfs/.snapshot at the root of the old cache and of the new one are ignored" || bad "snapdir: rc=$rc $out"
mk; mkdir -p "$RUN/cache/.zfs2"; : > "$RUN/cache/.zfs2/f"; cp "$CFG" "$RUN/before"
out="$($BIN config set CACHE_DIR "$RUN/zfsnew2" 2>&1 </dev/null)"; rc=$?
[[ $rc == 64 ]] && grep -q 'the cache holds data' <<<"$out" && cmp -s "$RUN/before" "$CFG" && ok "CACHE_DIR: only the snapshot directories themselves are exempt (a file elsewhere still counts: a move)" || bad "snapdir other: rc=$rc $out"
rm -rf "$RUN/cache/.zfs2" "$RUN/cache/.zfs"
# CACHE_DIR changes while the shared file pins RESTIC_CACHE_REPO: the local line
# at the old derived default moves to the new one instead of going
rm -rf "$RUN/cache"; mkdir -p "$RUN/cache"
printf '%s\n' "KEEP_OFFSITE_DAILY=14" "RESTIC_CACHE_REPO=$RUN/elsewhere/repo" > "$SH"; chmod 600 "$SH"
printf '%s\n' "LOCK_DIR=$RUN/lock" "LOG_DIR=$RUN/log" "STATE_DIR=$RUN/state" "CACHE_DIR=$RUN/cache" "RESTIC_CACHE_REPO=$RUN/cache/repo" > "$RUN/local.cfg"; chmod 600 "$RUN/local.cfg"
out="$(TB config set CACHE_DIR "$RUN/nc4" 2>&1 </dev/null)"; rc=$?
[[ $rc == 0 && "$(rd "$RUN/local.cfg" RESTIC_CACHE_REPO)" == "$RUN/nc4/repo" && "$(TB config get RESTIC_CACHE_REPO 2>/dev/null)" == "$RUN/nc4/repo" ]] \
    && ok "CACHE_DIR: a key that follows, pinned in the shared file too, is moved to the new default (not removed)" || bad "follows implicit: rc=$rc $out $(grep -n CACHE_REPO "$RUN/local.cfg")"

# --- the read-back refuses what would not read as intended ---------------------------------------------
# a value the writer quotes wrongly (the harness's TEST_QVAL), and a file
# whose bash reading differs: each refused with 78, the file as it was
printf '%s\n' "LOCK_DIR=$RUN/lock" "LOG_DIR=$RUN/log" "STATE_DIR=$RUN/state" "KEEP_LOCAL=2" > "$RUN/local.cfg"; chmod 600 "$RUN/local.cfg"; rm -f "$SH"
cp "$RUN/local.cfg" "$RUN/local.before"
for m in "cr:TR_STORAGE would read differently when bash sources the file" "other:TR_STORAGE would not read back as the value given" "open:would not read as intended"; do
    out="$(TEST_QVAL="${m%%:*}" TB config set TR_STORAGE local-zfs 2>&1)"; rc=$?
    [[ $rc == 78 ]] && grep -q 'would not read as intended, nothing was changed' <<<"$out" && grep -q "${m#*:}" <<<"$out" \
        && cmp -s "$RUN/local.before" "$RUN/local.cfg" && ! tmpleft \
        && ok "read-back (${m%%:*}): refused (78), the file unchanged, no temp file" || bad "read-back ${m%%:*}: rc=$rc $out"
done
# a CRLF line the file had: another key's change goes through and leaves it;
# the key on the CRLF line itself is written clean
mk $'BACKUP_ORDER=101\r'
out="$(unset PBO_TEST_CONFIG_LOG; $BIN config set KEEP_LOCAL 3 2>&1)"; rc=$?
[[ $rc == 0 && "$(rd "$CFG" KEEP_LOCAL)" == 3 ]] && grep -q $'^BACKUP_ORDER=101\r$' "$CFG" && grep -q 'BACKUP_ORDER reads differently when bash sources the files, as before' <<<"$out" \
    && ok "a CRLF line on another key: the change is written, that line left as it is (a warning names it)" || bad "crlf other: rc=$rc $out"
out="$(unset PBO_TEST_CONFIG_LOG; $BIN config set BACKUP_ORDER 102 2>&1)"; rc=$?
[[ $rc == 0 && "$(rd "$CFG" BACKUP_ORDER)" == 102 && "$(bs "$CFG" BACKUP_ORDER)" == 102 ]] && ! grep -q $'\r' "$CFG" \
    && ok "a CRLF line on the key being set: written, and bash reads it clean" || bad "crlf same: rc=$rc $out $(grep -n BACKUP_ORDER "$CFG" | od -c | head -3)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ -n "${KEEP_RUN:-}" ]] || rm -rf "$RUN"
(( fail == 0 ))
