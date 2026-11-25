#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/perms.sh: the permission rule table and its engine (lib/perms.sh, ADR
# 0009 "Permissions"): each rule's check and fix on a tree under
# run-perms/, a second --fix that changes nothing, --dry-run that changes
# nothing, symlink and hard-link refusal, shared and system directories left
# alone, a config outside pbo's own directory or on pmxcfs, a missing or
# dangling DR key, CACHE_DIR's ACL (masked entries, the dry-run mask, a
# filesystem without POSIX ACLs), --fix-parents with a 0700 parent and an
# unprivileged CT fixture, the janitor (JANITOR_USER: a system user with a
# group of its name) and its root pass before the re-exec, doctor's lines, JSON
# and audit record, install.sh's call. As root the owners are tested too; as a
# plain user only the modes. Nothing outside run-perms/ is changed: the
# directories above the checkout are compared before and after.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start) are the
# machine's own files: point them into the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.creds" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
    PBO_PVE_CFS_DIR="$PWD/run-none/pve" PVE_STORAGE_CFG="$PWD/run-none/pve/storage.cfg"
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
skip() { printf '  SKIP %s\n' "$1"; }
command -v jq >/dev/null 2>&1 || { echo "jq not installed, skipping permission tests"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "perl not installed, skipping permission tests"; exit 0; }

printf 'pbo: permission rules (lib/perms.sh)\n'
RUN="$ROOT/run-perms"; rm -rf "$RUN"; mkdir -p "$RUN"/{bin,lxc}
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm tests/mocks/systemctl "$RUN/bin/"
export PATH="$RUN/bin:$PATH" MOCK_CONF_DIR="$RUN/lxc" MOCK_LOG="$RUN/calls"; : > "$MOCK_LOG"
is_root=0; [[ "$(id -u)" == 0 ]] && is_root=1
have_acl=0; command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && have_acl=1
have_setpriv=0; (( is_root )) && command -v setpriv >/dev/null 2>&1 && have_setpriv=1

# the directories above the checkout: the suite must leave them as they are
# and the secret files at their schema defaults (the rule table fixes them when
# a config leaves its key out): each test config points them into run-perms/
deffiles="$(bash -c 'source lib/config_schema.sh; _cs_load; for k in RESTIC_ENV_FILE RESTIC_PASSWORD_FILE RESTIC_REST_PASSWORD_FILE NTFY_CREDS_FILE PBO_KNOWN_HOSTS; do printf "%s\n" "${CS_DEFAULT[$k]}"; done')"
hostfp() {
    local d="$ROOT" f
    while [[ "$d" != / ]]; do d="$(dirname "$d")"; stat -c '%n %a %u %g' "$d"; getfacl -cpn "$d" 2>/dev/null; done
    while IFS= read -r f; do [[ -n "$f" ]] || continue; stat -c '%n %a %u %g %Y' -- "$f" 2>/dev/null || printf '%s absent\n' "$f"; done <<<"$deffiles"
}
host_before="$(hostfp)"

# an unprivileged CT whose root maps to 200000 (its own idmap), and a privileged one
printf 'arch: amd64\nhostname: web\nunprivileged: 1\nlxc.idmap: u 0 200000 65536\nlxc.idmap: g 0 200000 65536\n' > "$RUN/lxc/8001.conf"
printf 'arch: amd64\nhostname: priv\n' > "$RUN/lxc/8002.conf"
ctuid=200000

# --- the host tree: every rule's path, each with the wrong mode -------------------
H="$RUN/h"
mkhost() {
    rm -rf "$H"; mkdir -p "$H"/{etc,cache/repo,cache/spool/dump,cache/staging,lock,log,state/runs,state/catalog,state/restic-cache,mnt/m}
    cat > "$H/etc/config" <<EOF
CACHE_DIR=$H/cache
LOG_DIR=$H/log
STATE_DIR=$H/state
LOCK_DIR=$H/lock
RESTIC_PASSWORD_FILE=$H/etc/restic-pass
RESTIC_REST_PASSWORD_FILE=$H/etc/rest-pass
NTFY_CREDS_FILE=$H/etc/ntfy.creds
PVE_CATALOG_MOUNT_DIR=$H/mnt/m
PBO_CATALOG=$H/state/catalog/index.json
PBO_PVE_LXC_DIR=$RUN/lxc
RESTIC_ENV_FILE=$H/etc/restic.env
PBO_PERMS_PARENTS_TOP=$RUN
PBO_PERMS_CONFIG_DIR=$H/etc
BACKUP_ORDER=8001
OFFSITE_ENABLED=false
EOF
    printf 'pw\n' > "$H/etc/restic-pass"; printf 'pw\n' > "$H/etc/rest-pass"; printf 'NTFY_URL=x\n' > "$H/etc/ntfy.creds"
    : > "$H/log/audit.jsonl"; printf '{}' > "$H/state/catalog/index.json"; printf 'x' > "$H/cache/staging/a.vma"
    printf 'outside\n' > "$RUN/outside"; chmod 0644 "$RUN/outside"; ln -s "$RUN/outside" "$H/cache/staging/b.vma"
    chmod 0644 "$H/etc/config" "$H/etc/restic-pass" "$H/etc/ntfy.creds" "$H/log/audit.jsonl" "$H/cache/staging/a.vma"
    chmod 0640 "$H/etc/rest-pass"; chmod 0600 "$H/state/catalog/index.json"
    chmod 0755 "$H/etc" "$H/cache" "$H/cache/repo" "$H/cache/staging" "$H/lock" "$H/state/runs" "$H/state/restic-cache" "$H/mnt"
    chmod 0700 "$H/cache/spool" "$H/cache/spool/dump" "$H/log" "$H/state" "$H/state/catalog"
    chmod 0700 "$H"   # blocks the CT's mapped root above CACHE_DIR (--fix-parents)
}
# path → the mode the table wants
want=(
    "$H/cache 750" "$H/cache/repo 750" "$H/cache/spool 755" "$H/cache/spool/dump 755"
    "$H/cache/staging 700" "$H/cache/staging/a.vma 600" "$H/lock 700" "$H/log 755"
    "$H/log/audit.jsonl 600" "$H/state 755" "$H/state/runs 750" "$H/state/catalog 755"
    "$H/state/catalog/index.json 644" "$H/state/restic-cache 700" "$H/etc 700" "$H/etc/config 600"
    "$H/etc/restic-pass 600" "$H/etc/rest-pass 600" "$H/etc/ntfy.creds 640"
)
snap() { find "$1" -exec stat -c '%n %a %u %g %h' {} + | sort; getfacl -RPpn "$1" 2>/dev/null; }
P() { PBO_CONFIG="$H/etc/config" "$BIN" "$@"; }
has_warn() {   # <json> <path>: a warn/fail finding names the path
    jq -e --arg p "$2" 'any(.findings[]; .level != "ok" and (.message | contains($p + " ")))' >/dev/null 2>&1 <<<"$1"
}

mkhost
# --- check: every rule names its path ---------------------------------------------
out="$(P --json doctor --perms-only 2>/dev/null)"; rc=$?
miss=""; for w in "${want[@]}"; do has_warn "$out" "${w% *}" || miss+=" ${w% *}"; done
[[ $rc == 0 && -z "$miss" ]] && ok "check: a finding for each rule's path with the wrong mode (warnings, exit 0)" || bad "check: rc=$rc missing:$miss $(jq -c '[.findings[].message]' <<<"$out")"
has_warn "$out" "$H/mnt" && jq -e --arg p "$H/mnt " 'any(.findings[]; (.message | contains($p)) and (.message | contains("doctor --fix") | not))' >/dev/null <<<"$out" \
    && ok "check: the mount's parent (class check) is reported without a fix hint" || bad "mount parent: $(jq -c '[.findings[].message | select(contains("mnt"))]' <<<"$out")"
jq -e '.findings[0].message | startswith("DR key ")' >/dev/null <<<"$out" && ok "check: the DR key line comes first, as before" || bad "first: $(jq -c '.findings[0]' <<<"$out")"
jq -e 'has("changes") | not' >/dev/null <<<"$out" && ok "check: no changes field without --fix" || bad "changes without --fix"

# --- dry run: lists, changes nothing ------------------------------------------------
before="$(snap "$H")"
out="$(P --json doctor --fix --dry-run --perms-only 2>/dev/null)"; rc=$?
after="$(snap "$H")"
[[ "$before" == "$after" ]] && ok "--dry-run: nothing changed (stat and ACLs of the tree)" || bad "dry run changed: $(diff <(echo "$before") <(echo "$after") | head -5)"
n="$(jq '[.changes[] | select(.applied == false)] | length' <<<"$out" 2>/dev/null)"
[[ $rc == 0 ]] && (( ${n:-0} >= ${#want[@]} )) && jq -e '.dry_run == true and all(.changes[]; .applied == false)' >/dev/null <<<"$out" \
    && ok "--dry-run: the changes are listed ($n), none applied" || bad "dry run json: rc=$rc n=$n $(jq -c .changes <<<"$out")"
out2="$(P doctor --fix --perms-only --dry-run 2>&1)"
grep -q "WOULD FIX $H/etc/config: mode 0644 -> 0600" <<<"$out2" && ok "--dry-run: text lists 'WOULD FIX <path>: mode A -> B'" || bad "dry run text: $out2"
! grep -q 'perms fix' "$H/log/audit.log" 2>/dev/null && ok "--dry-run: nothing audited" || bad "dry run audited: $(grep 'perms fix' "$H/log/audit.log")"

# --- owners (root): files given to another user come back -------------------------
if (( is_root )) && id nobody >/dev/null 2>&1; then
    chown nobody "$H/lock" "$H/log/audit.jsonl" "$H/cache/staging/a.vma" "$H/state/catalog/index.json" "$H/etc/restic-pass"
fi

# --- fix ----------------------------------------------------------------------------
out="$(P --json doctor --fix --perms-only 2>/dev/null)"; rc=$?
wrong=""; for w in "${want[@]}"; do [[ "$(stat -c %a "${w% *}")" == "${w#* }" ]] || wrong+=" ${w% *}=$(stat -c %a "${w% *}")"; done
[[ $rc == 0 && -z "$wrong" ]] && ok "--fix: every path has the mode of the table" || bad "fix: rc=$rc wrong:$wrong"
[[ "$(stat -c %a "$H/mnt")" == 755 ]] && ok "--fix: a class check rule is not changed (the mount's parent)" || bad "mount parent changed: $(stat -c %a "$H/mnt")"
[[ "$(stat -c %a "$RUN/outside")" == 644 ]] && ok "--fix: a symlink in the staging dir is left alone (its target too)" || bad "staged link target: $(stat -c %a "$RUN/outside")"
jq -e --arg p "$H/cache" 'any(.changes[]; .path == $p and .change == "mode" and .from == "0755" and .to == "0750" and .applied)' >/dev/null <<<"$out" \
    && ok "--fix JSON: {name, path, change, from, to, applied}" || bad "fix json: $(jq -c .changes <<<"$out")"
grep -q "perms fix $H/cache mode 0755->0750" "$H/log/audit.log" && grep -q "perms fix $H/etc/config mode 0644->0600" "$H/log/audit.log" \
    && ok "--fix: each change audit-logged ('perms fix <path> mode A->B')" || bad "audit: $(grep 'perms' "$H/log/audit.log")"
if (( have_acl )) && (( ${#ctuid} )); then
    getfacl -cpn "$H/cache" 2>/dev/null | grep -qx "user:$ctuid:--x" && grep -q "perms fix $H/cache acl +u:$ctuid:--x" "$H/log/audit.log" \
        && ok "--fix: CACHE_DIR gets u:<mapped root>:--x of the unprivileged CT before it is closed" || bad "cache acl: $(getfacl -cpn "$H/cache" 2>/dev/null | tr '\n' ' ')"
    ! getfacl -cpn "$H" 2>/dev/null | grep -q "user:$ctuid" && ok "--fix without --fix-parents: the parent is not touched (class ask)" || bad "parent changed without --fix-parents"
else skip "CACHE_DIR ACL (no setfacl/getfacl)"; fi
if (( is_root )); then
    bado=""; for f in "$H/lock" "$H/log/audit.jsonl" "$H/cache/staging/a.vma" "$H/state/catalog/index.json"; do [[ "$(stat -c %u "$f")" == 0 ]] || bado+=" $f"; done
    [[ -z "$bado" ]] && ok "--fix (root): owners set back to root" || bad "owners: $bado"
    [[ "$(stat -c %U "$H/etc/restic-pass")" == nobody ]] && jq -e --arg p "$H/etc/restic-pass" 'any(.findings[]; .level == "warn" and (.message | contains($p + " (RESTIC_PASSWORD_FILE) is owned by nobody, should be root")))' >/dev/null <<<"$out" \
        && ok "--fix (host): the DR key's owner is reported, never changed" || bad "dr key owner: $(stat -c %U "$H/etc/restic-pass") $(jq -c '[.findings[].message|select(contains("restic-pass"))]' <<<"$out")"
    chown root "$H/etc/restic-pass"
else skip "owners (not root)"; fi

# --- idempotent ---------------------------------------------------------------------
before="$(snap "$H")"
out="$(P --json doctor --fix --perms-only 2>/dev/null)"
after="$(snap "$H")"
[[ "$before" == "$after" ]] && jq -e '.changes == []' >/dev/null <<<"$out" && ok "a second --fix changes nothing (changes: [])" || bad "second fix: $(jq -c .changes <<<"$out") $(diff <(echo "$before") <(echo "$after") | head -3)"

# --- --fix-parents: a 0700 parent and an unprivileged CT ----------------------------
if (( have_setpriv && have_acl )); then
    grep -q "^PBO_PERMS_PARENTS_TOP=$RUN\$" "$H/etc/config" || { echo "the test config lacks PBO_PERMS_PARENTS_TOP: refusing --fix-parents"; exit 1; }
    out="$(P --json doctor --perms-only 2>/dev/null)"
    jq -e --arg p "$H" 'any(.findings[]; .level == "warn" and (.message | startswith("CACHE_DIR parent " + $p + " is not traversable by uid 200000 (the mapped root of unprivileged CT(s) 8001)")))' >/dev/null <<<"$out" \
        && ok "parents: the 0700 parent is named with the uid and the CT (tested with setpriv)" || bad "parents check: $(jq -c '[.findings[].message|select(contains("parent"))]' <<<"$out")"
    out="$(P --json doctor --fix-parents --perms-only 2>/dev/null)"
    getfacl -cpn "$H" 2>/dev/null | grep -qx "user:$ctuid:--x" && [[ "$(stat -c %a "$H")" == 710 ]] \
        && jq -e --arg p "$H" '.changes == [{name:"CACHE_DIR", path:$p, change:"acl", from:"-", to:"u:200000:--x", applied:true}]' >/dev/null <<<"$out" \
        && ok "--fix-parents: a traverse-only ACL entry on the parent that blocks, nothing else" || bad "fix-parents: $(getfacl -cpn "$H" 2>/dev/null | tr '\n' ' ') $(jq -c .changes <<<"$out")"
    jq -e 'any(.findings[]; .level == "ok" and (.message | startswith("CACHE_DIR parents: the mapped root of unprivileged CT(s) 8001 can pass")))' >/dev/null <<<"$out" \
        && ok "--fix-parents: the check after it passes" || bad "parents ok: $(jq -c '[.findings[].message|select(contains("parent"))]' <<<"$out")"
    setpriv --reuid "$ctuid" --regid "$ctuid" --clear-groups -- test -x "$H/cache" 2>/dev/null \
        || ( cd "$H" && setpriv --reuid "$ctuid" --regid "$ctuid" --clear-groups -- test -x cache ) \
        && ok "--fix-parents: the CT's mapped root can now enter CACHE_DIR from its parent" || bad "uid $ctuid still cannot enter $H/cache"
    out="$(P --json doctor --fix-parents --perms-only 2>/dev/null)"
    jq -e '.changes == []' >/dev/null <<<"$out" && ok "--fix-parents twice: no change" || bad "fix-parents twice: $(jq -c .changes <<<"$out")"
else skip "--fix-parents (needs root, setpriv and setfacl)"; fi

# --- refusals -----------------------------------------------------------------------
mkdir -p "$RUN/lock-real"; chmod 0777 "$RUN/lock-real"; ln -sfn "$RUN/lock-real" "$RUN/lock-link"
printf 'pw\n' > "$RUN/real-pass"; chmod 0644 "$RUN/real-pass"; ln -sfn "$RUN/real-pass" "$RUN/pass-link"
printf 'x' > "$RUN/outside2"; chmod 0644 "$RUN/outside2"; ln -f "$RUN/outside2" "$H/cache/staging/h.vma"
sed -i -e "s#^LOCK_DIR=.*#LOCK_DIR=$RUN/lock-link#" -e "s#^RESTIC_PASSWORD_FILE=.*#RESTIC_PASSWORD_FILE=$RUN/pass-link#" "$H/etc/config"
out="$(P --json doctor --fix --perms-only 2>/dev/null)"
[[ "$(stat -c %a "$RUN/lock-real")" == 777 && "$(stat -c %a "$RUN/real-pass")" == 644 ]] \
    && jq -e --arg l "$RUN/lock-link" --arg k "$RUN/pass-link" 'any(.findings[]; .level == "warn" and (.message | startswith($l + " (LOCK_DIR) is a symlink")))
        and any(.findings[]; .level == "warn" and (.message | startswith($k + " (RESTIC_PASSWORD_FILE) is a symlink")))' >/dev/null <<<"$out" \
    && ok "symlink where a dir/file is expected: refused and reported, the target unchanged" || bad "symlink: $(stat -c %a "$RUN/lock-real" "$RUN/real-pass") $(jq -c '[.findings[].message|select(contains("link"))]' <<<"$out")"
jq -e --arg k "$RUN/pass-link" 'any(.findings[]; .level == "warn" and (.message | startswith("DR key " + $k + " -> target is 644, should be 0600")))' >/dev/null <<<"$out" \
    && ok "a DR key behind a symlink: a world-readable target is still named (read through the link, never changed)" || bad "dr key link target: $(jq -c '[.findings[].message|select(contains("pass-link"))]' <<<"$out")"
ln -sfn "$RUN/gone-pass" "$RUN/dangling-pass"
sed -i "s#^RESTIC_PASSWORD_FILE=.*#RESTIC_PASSWORD_FILE=$RUN/dangling-pass#" "$H/etc/config"
out="$(P --json doctor --perms-only 2>/dev/null)"; rc=$?
[[ $rc != 0 ]] && jq -e --arg k "$RUN/dangling-pass" '.findings[0].level == "fail" and (.findings[0].message | startswith("DR key " + $k + " missing or unreadable")) and .problems >= 1' >/dev/null <<<"$out" \
    && ok "a dangling DR key symlink: FAIL 'DR key ... missing or unreadable' first, doctor exits non-zero (as in 0.5)" || bad "dangling dr key: rc=$rc $(jq -c '.findings[0:3]' <<<"$out")"
out="$(P --json doctor --fix --perms-only 2>/dev/null)"; rc=$?
[[ $rc != 0 && -L "$RUN/dangling-pass" && ! -e "$RUN/gone-pass" ]] && ok "a dangling DR key symlink: --perms-only --fix still fails (only a key that does not exist at all is a warning)" || bad "dangling dr key --fix: rc=$rc"
[[ "$(stat -c %a "$RUN/outside2")" == 644 ]] && jq -e --arg p "$H/cache/staging/h.vma" 'any(.findings[]; .level == "warn" and (.message | contains("could not change the mode of " + $p) and contains("2 hard links")))' >/dev/null <<<"$out" \
    && ok "a staged file with a second hard link is not changed (its other name could be anywhere)" || bad "hard link: $(stat -c %a "$RUN/outside2") $(jq -c '[.findings[].message|select(contains("h.vma"))]' <<<"$out")"
rm -f "$H/cache/staging/h.vma"
mkdir -p "$RUN/shared"; chmod 1777 "$RUN/shared"
sed -i -e "s#^LOCK_DIR=.*#LOCK_DIR=$RUN/shared#" -e "s#^RESTIC_PASSWORD_FILE=.*#RESTIC_PASSWORD_FILE=$H/etc/restic-pass#" "$H/etc/config"
out="$(P --json doctor --fix --perms-only 2>/dev/null)"
[[ "$(stat -c %a "$RUN/shared")" == 1777 ]] && jq -e --arg p "$RUN/shared" 'any(.findings[]; .level == "warn" and (.message | startswith("LOCK_DIR " + $p + " is world-writable: a local user can block pbo'"'"'s locks")))' >/dev/null <<<"$out" \
    && ok "a shared (sticky, world-writable) directory is named, never changed" || bad "shared dir: $(stat -c %a "$RUN/shared") $(jq -c '[.findings[].message|select(contains("LOCK"))]' <<<"$out")"
cp "$H/etc/config" "$RUN/ww.cfg"; sed -i "s#^LOCK_DIR=.*#LOCK_DIR=/var/lock#" "$RUN/ww.cfg"; chmod 600 "$RUN/ww.cfg"
out="$(PBO_CONFIG="$RUN/ww.cfg" "$BIN" doctor --perms-only 2>&1)"   # check only: /var/lock is the host's
grep -q "WARN.*LOCK_DIR /var/lock is world-writable: a local user can block pbo's locks (remove LOCK_DIR from the config to use" <<<"$out" \
    && ok "LOCK_DIR=/var/lock: the world-writable warning as before" || bad "var/lock: $out"
sed -i "s#^LOCK_DIR=.*#LOCK_DIR=$H/lock#" "$H/etc/config"
sed -i "s#^RESTIC_PASSWORD_FILE=.*#RESTIC_PASSWORD_FILE=$H/etc/no-key-yet#" "$H/etc/config"
out="$(P doctor --fix --perms-only 2>&1)"; rc=$?
[[ $rc == 0 ]] && ! grep -q 'FAIL' <<<"$out" && grep -q "WARN  DR key $H/etc/no-key-yet not created yet ('pbo setup' creates it)" <<<"$out" \
    && ok "doctor --fix --perms-only before 'pbo setup' (no DR key yet): a warning, exit 0 (install.sh prints no WARNING)" || bad "no key yet: rc=$rc $out"
out="$(P doctor 2>/dev/null)"; rc=$?
[[ $rc != 0 && "$(head -1 <<<"$out")" == "  FAIL  DR key $H/etc/no-key-yet missing or unreadable" ]] && ok "full doctor without a DR key: FAIL as before" || bad "no key full doctor: rc=$rc $(head -1 <<<"$out")"
sed -i "s#^RESTIC_PASSWORD_FILE=.*#RESTIC_PASSWORD_FILE=$H/etc/restic-pass#" "$H/etc/config"
P doctor --bogus >/dev/null 2>&1; [[ $? == 64 ]] && ok "doctor: an unknown flag is a usage error" || bad "doctor --bogus accepted"

# --- doctor: the lines and the JSON ---------------------------------------------------
out="$(P doctor 2>/dev/null)"
[[ "$(head -1 <<<"$out")" == "  OK  DR key $H/etc/restic-pass (600)" ]] && ok "doctor: the DR key line first, as before" || bad "doctor first line: $(head -1 <<<"$out")"
grep -qx '  OK  CACHE_DIR closed to local users (mode 750)' <<<"$out" && grep -qE '^  OK  permissions: [0-9]+ more path\(s\) as the rule table wants' <<<"$out" \
    && ok "doctor: CACHE_DIR closed, and one summary line for the other paths" || bad "doctor lines: $(grep -iE 'cache|perm' <<<"$out")"
chmod 0644 "$H/log/audit.jsonl"
out="$(P --json doctor 2>/dev/null)"
jq -e --arg p "$H/log/audit.jsonl" 'any(.findings[]; .level == "warn" and (.message | startswith($p + " (AUDIT_JSON) is mode 0644, should be 0600")))
    and (has("changes") | not)' >/dev/null <<<"$out" && ok "doctor --json: a new check (logs) as a warning finding" || bad "doctor json: $(jq -c '[.findings[]|select(.message|contains("audit"))]' <<<"$out")"
out="$(P --json doctor --fix 2>/dev/null)"
[[ "$(stat -c %a "$H/log/audit.jsonl")" == 600 ]] && jq -e --arg p "$H/log/audit.jsonl" '.changes == [{name:"AUDIT_JSON", path:$p, change:"mode", from:"0644", to:"0600", applied:true}]
    and (any(.findings[]; .message | contains("audit.jsonl")) | not)' >/dev/null <<<"$out" \
    && ok "doctor --fix --json: the full report after the fix, with the changes" || bad "doctor fix json: $(jq -c '.changes' <<<"$out")"
lastcmd() { grep '"kind":"command"' "$H/log/audit.jsonl" | tail -1; }
r_fix="$(lastcmd)"
P doctor --fix --dry-run >/dev/null 2>&1; r_dry="$(lastcmd)"
P doctor >/dev/null 2>&1; r_ro="$(lastcmd)"
jq -e '.command == "doctor" and .read_only == false and .dry_run == false' >/dev/null <<<"$r_fix" \
    && jq -e '.command == "doctor" and .read_only == true and .dry_run == true' >/dev/null <<<"$r_dry" \
    && jq -e '.command == "doctor" and .read_only == true' >/dev/null <<<"$r_ro" \
    && ok "audit.jsonl: doctor --fix is read_only:false; --fix --dry-run and plain doctor stay read_only:true" || bad "audit read_only: fix=$r_fix dry=$r_dry ro=$r_ro"
chmod 0755 "$H/cache"; [[ "$have_acl" == 1 ]] && setfacl -b "$H/cache"
out="$(P --json doctor 2>/dev/null)"
jq -e '[.findings[] | select(.level == "warn" and (.message | test("CACHE_DIR .* is open to local users")))] | length == 1' >/dev/null <<<"$out" \
    && ok "doctor: CACHE_DIR open → the warning as before (once)" || bad "open cache: $(jq -c '[.findings[].message|select(contains("CACHE_DIR"))]' <<<"$out")"
if (( have_acl )); then
    chmod 0750 "$H/cache"
    out="$(P --json doctor 2>/dev/null)"
    jq -e '[.findings[] | select(.level == "fail" and (.message | test("CACHE_DIR .* is closed but has no ACL entry .* 8001")))] | length == 1' >/dev/null <<<"$out" \
        && ok "doctor: CACHE_DIR closed without the CT's entry → FAIL as before" || bad "closed no acl: $(jq -c '[.findings[].message|select(contains("CACHE_DIR"))]' <<<"$out")"
fi

E() {   # <code>: lib/perms.sh sourced, with this tree's values
    env -i PATH="$PATH" HOME="$RUN" H="$H" RUN="$RUN" bash -c 'set -u; SELF_DIR="$PWD"
        source lib/common.sh; source lib/appendonly.sh; source lib/perms.sh
        PBO_CONFIG="$H/etc/config"; set -a; source "$PBO_CONFIG"; set +a; set_defaults; LOG_FILE=""; AUDIT_FILE=""
        pf() { local f; for f in "${PERM_FINDINGS[@]+"${PERM_FINDINGS[@]}"}"; do printf "%s\n" "$f"; done; }
        '"$1"
}
if (( have_acl )); then
    # 0705 without the entry: setfacl widens the mask to --x (0715), the fix then
    # sets 0710; the dry run must list that target, not 0700 (which masks it)
    setfacl -b "$H/cache"; chmod 0705 "$H/cache"
    out="$(P doctor --fix --dry-run --perms-only 2>&1)"
    grep -q "WOULD FIX $H/cache: acl +u:$ctuid:--x" <<<"$out" && grep -q "WOULD FIX $H/cache: mode 0715 -> 0710" <<<"$out" && [[ "$(stat -c %a "$H/cache")" == 705 ]] \
        && ok "--dry-run: CACHE_DIR 0705 lists the mode the real fix sets (0715 -> 0710, the mask setfacl widens)" || bad "dry run mask: $(grep cache <<<"$out")"
    out="$(P --json doctor --fix --perms-only 2>/dev/null)"
    [[ "$(stat -c %a "$H/cache")" == 710 ]] && jq -e --arg p "$H/cache" 'any(.changes[]; .path == $p and .change == "mode" and .from == "0715" and .to == "0710")' >/dev/null <<<"$out" \
        && ok "--fix: CACHE_DIR 0705 ends at 0710, the target the dry run listed" || bad "fix mask: $(stat -c %a "$H/cache") $(jq -c .changes <<<"$out")"
    # an entry the mask hides (chmod after setfacl) lets the CT in no more
    setfacl -b "$H/cache"; chmod 0750 "$H/cache"; setfacl -m "u:$ctuid:x" "$H/cache"; chmod 0700 "$H/cache"
    if getfacl -cpn "$H/cache" 2>/dev/null | grep -qE "^user:$ctuid:--x[[:space:]]+#effective:---"; then
        out="$(P --json doctor --perms-only 2>/dev/null)"; rc=$?
        [[ $rc != 0 ]] && jq -e '([.findings[] | select(.level == "fail" and (.message | test("CACHE_DIR .* is closed but has no ACL entry in effect .* 8001")))] | length == 1)
            and (any(.findings[]; .message | startswith("CACHE_DIR closed to local users")) | not)' >/dev/null <<<"$out" \
            && ok "doctor: a CT entry the ACL mask hides (chmod 700) is a FAIL, not OK" || bad "masked entry check: rc=$rc $(jq -c '[.findings[].message|select(contains("CACHE_DIR"))]' <<<"$out")"
        P doctor --fix --perms-only >/dev/null 2>&1
        a="$(getfacl -cpn "$H/cache" 2>/dev/null)"
        grep -qE "^user:$ctuid:..x([[:space:]]+#effective:..x)?\$" <<<"$a" && grep -qE '^mask::..x$' <<<"$a" && (( (8#$(stat -c %a "$H/cache") & 8#007) == 0 )) \
            && ok "--fix: the masked entry is in effect again (mask with x), CACHE_DIR still closed" || bad "masked entry fix: $(stat -c %a "$H/cache") $(tr '\n' ' ' <<<"$a")"
    else skip "masked ACL entry (chmod did not set the mask here)"; fi
    # a filesystem without POSIX ACLs (ZFS acltype=off): setfacl says so
    mkdir -p "$RUN/nosup"
    printf '#!/usr/bin/env bash\necho "setfacl: ${!#}: Operation not supported" >&2\nexit 1\n' > "$RUN/nosup/setfacl"; chmod 755 "$RUN/nosup/setfacl"
    setfacl -b "$H/cache"; chmod 0755 "$H/cache"   # -b first: it resets the group bits to the group entry
    out="$(PATH="$RUN/nosup:$PATH" P doctor --fix --perms-only 2>&1)"
    [[ "$(stat -c %a "$H/cache")" == 755 ]] && grep -q "CACHE_DIR $H/cache stays open to local users: its filesystem does not support POSIX ACLs (setfacl: Operation not supported).*zfs set acltype=posixacl" <<<"$out" \
        && ! grep -q 'needs setfacl, package acl' <<<"$out" && [[ "$(grep -c 'does not support POSIX ACLs' <<<"$out")" == 1 ]] \
        && ok "--fix on a filesystem without POSIX ACLs: named once with the real fix, no 'needs setfacl, package acl'" || bad "no acl support: $(grep -i cache <<<"$out")"
    out="$(PATH="$RUN/nosup:$PATH" E '_cache_dir_protect 2>&1; stat -c %a "$CACHE_DIR"')"
    [[ "$(tail -1 <<<"$out")" == 755 && "$(grep -c 'does not support POSIX ACLs' <<<"$out")" == 1 ]] && ! grep -q 'is open to local users' <<<"$out" \
        && ok "_cache_dir_protect on a filesystem without POSIX ACLs: one specific warning per backup" || bad "wrapper no acl support: $out"
    chmod 0750 "$H/cache"; setfacl -m "u:$ctuid:x" "$H/cache"
fi
out="$(E 'setfacl -b "$CACHE_DIR" 2>/dev/null; chmod 0755 "$CACHE_DIR"; _perm_acl_unsupported() { return 0; }; _perm_apply --check --only CACHE_DIR:dir; pf; chmod 0750 "$CACHE_DIR"')"
if (( have_acl )); then
    grep -q 'its filesystem does not support POSIX ACLs (ZFS acltype=off)' <<<"$out" && ! grep -q 'is open to local users' <<<"$out" \
        && ok "check pass: a ZFS dataset with acltype=off is named as such (read-only probe)" || bad "probe: $out"
    setfacl -m "u:$ctuid:x" "$H/cache"
fi

# --- the config in a directory that is not pbo's own, or on pmxcfs -------------------
mkdir -p "$RUN/shared-etc"; printf 'other\n' > "$RUN/shared-etc/other.conf"
cp "$H/etc/config" "$RUN/shared-etc/pbo.conf"; chmod 0644 "$RUN/shared-etc/pbo.conf"; chmod 0755 "$RUN/shared-etc"
g0="$(stat -c %g "$RUN/shared-etc")"
out="$(PBO_CONFIG="$RUN/shared-etc/pbo.conf" "$BIN" --json doctor --fix --perms-only 2>/dev/null)"
[[ "$(stat -c '%a %g' "$RUN/shared-etc")" == "755 $g0" && "$(stat -c %a "$RUN/shared-etc/pbo.conf")" == 600 ]] \
    && jq -e --arg p "$RUN/shared-etc" 'all(.changes[]; .path != $p) and (any(.findings[]; .level != "ok" and (.message | contains($p + " "))) | not)' >/dev/null <<<"$out" \
    && ok "config in a shared 0755 directory: the directory is left as it is (only the config file is fixed)" || bad "shared config dir: $(stat -c '%a %g' "$RUN/shared-etc") $(jq -c '[.changes, [.findings[].message|select(contains("shared-etc"))]]' <<<"$out")"
chmod 0775 "$RUN/shared-etc"
out="$(PBO_CONFIG="$RUN/shared-etc/pbo.conf" "$BIN" --json doctor --fix --perms-only 2>/dev/null)"
[[ "$(stat -c %a "$RUN/shared-etc")" == 775 ]] \
    && jq -e --arg p "$RUN/shared-etc" 'all(.changes[]; .path != $p) and any(.findings[]; .level == "warn" and (.message | startswith($p + " (config/..) is mode 0775, should be at most 0755: the config in it names programs root runs (exec keys)") and (contains("doctor --fix") | not)))' >/dev/null <<<"$out" \
    && ok "config in a shared group-writable directory: a finding, no change, no fix hint" || bad "shared config dir 775: $(stat -c %a "$RUN/shared-etc") $(jq -c '[.changes, [.findings[].message|select(contains("shared-etc"))]]' <<<"$out")"
mkdir -p "$RUN/pve/pbo"; chmod 0755 "$RUN/pve/pbo"
{ cat "$H/etc/config"; printf 'PBO_PVE_CFS_DIR=%s\n' "$RUN/pve"; } > "$RUN/pve/pbo/config"; chmod 0640 "$RUN/pve/pbo/config"
out="$(PBO_CONFIG="$RUN/pve/pbo/config" "$BIN" --json doctor --fix --perms-only 2>/dev/null)"
[[ "$(stat -c %a "$RUN/pve/pbo" "$RUN/pve/pbo/config" | paste -sd' ' -)" == "755 640" ]] \
    && jq -e --arg p "$RUN/pve/" 'all(.changes[]; .path | startswith($p) | not)
        and (any(.findings[]; .message | (contains("(config)") or contains("(config/..)") or contains("could not"))) | not)
        and any(.findings[]; .message | startswith("cluster-shared config " + $p + "pbo/config"))' >/dev/null <<<"$out" \
    && ok "an explicit PBO_CONFIG on pmxcfs: no mode rules, no fix errors, only the shared-config key check" || bad "pmxcfs config: $(stat -c %a "$RUN/pve/pbo" "$RUN/pve/pbo/config" | paste -sd' ' -) $out"

# --- the engine on its own: --only, shared config, no setfacl, the backup wrapper ----
out="$(E '_perm_apply --check --only LOCK_DIR; pf')"
[[ -n "$out" ]] && ! grep -qv $'^[a-z]*\tLOCK_DIR:dir\t' <<<"$out" && ok "_perm_apply --only NAME: that rule alone" || bad "--only: $out"
printf 'NTFY_TOKEN=tk\nRESTIC_BIN=/x/restic\nKEEP_LOCAL=3\n' > "$RUN/shared.cfg"
out="$(E '_cs_ensure; PBO_CONFIG_SHARED_LOADED="$RUN/shared.cfg"; _perm_apply --check --only config-shared; pf')"
grep -q $'^warn\tconfig-shared:keys\t.*sets NTFY_TOKEN (secret), RESTIC_BIN (runs a program): pmxcfs copies it to every node' <<<"$out" && ! grep -q 'KEEP_LOCAL' <<<"$out" \
    && ok "cluster-shared config: secret and exec keys named (check only)" || bad "shared: $out"
chmod 0755 "$H/cache"; [[ "$have_acl" == 1 ]] && setfacl -b "$H/cache"
out="$(E 'command() { [[ "${1:-} ${2:-}" == "-v setfacl" || "${1:-} ${2:-}" == "-v getfacl" ]] && return 1; builtin command "$@"; }
         _cache_dir_protect 2>&1; stat -c %a "$CACHE_DIR"')"
[[ "$(tail -1 <<<"$out")" == 755 ]] && grep -q 'stays open to local users: setfacl/getfacl (package acl) are needed' <<<"$out" \
    && ok "without setfacl: CACHE_DIR stays open (an unprivileged CT's vzdump would fail) and the backup warns" || bad "no setfacl: $out"
if (( have_acl )); then
    out="$(E '_cache_dir_protect 8001 2>&1; stat -c %a "$CACHE_DIR"')"
    [[ "$(tail -1 <<<"$out")" == 750 ]] && grep -q "CACHE_DIR $H/cache closed to other users (mode 750; unprivileged CTs pass through an ACL)" <<<"$out" \
        && getfacl -cpn "$H/cache" | grep -qx "user:$ctuid:--x" && ok "_cache_dir_protect (backup path): entry first, then closed, logged as before" || bad "wrapper: $out"
    out="$(E 'DRY_RUN=1; chmod 0755 "$CACHE_DIR"; _cache_dir_protect 2>&1; stat -c %a "$CACHE_DIR"')"
    [[ "$out" == 755 ]] && ok "_cache_dir_protect: never in a dry run" || bad "wrapper dry run: $out"
fi
chmod 0750 "$H/cache"

# --- janitor: JANITOR_USER owns its directories, root:<the group named like it> the config
# jusr: a system user with a group of its own name (install.sh's `restic`, and
# pbo-janitor.service's Group=, follow that convention)
jusr=""; for c in daemon backup bin; do id "$c" >/dev/null 2>&1 && getent group "$c" >/dev/null 2>&1 && [[ "$(id -u "$c")" != 0 ]] && { jusr="$c"; break; }; done
if (( is_root )) && [[ -n "$jusr" ]]; then
    jdir="$RUN/j"
    mkjan() {   # [JANITOR_USER]
        rm -rf "$jdir"; mkdir -p "$jdir"/{etc,cache,log,state/restic-cache,lock}
        printf '%s\n' "PBO_ROLE=janitor" "JANITOR_USER=${1:-$jusr}" "LOCAL_REPO=false" "OFFSITE_ENABLED=true" \
            "RESTIC_OFFSITE_REPO=$jdir/repo" "CACHE_DIR=$jdir/cache" "LOG_DIR=$jdir/log" "STATE_DIR=$jdir/state" \
            "LOCK_DIR=$jdir/lock" "RESTIC_PASSWORD_FILE=$jdir/etc/restic-pass" "NTFY_CREDS_FILE=$jdir/etc/ntfy.creds" \
            "RESTIC_ENV_FILE=$jdir/etc/restic.env" "PBO_PERMS_CONFIG_DIR=$jdir/etc" > "$jdir/etc/config"
        printf 'pw\n' > "$jdir/etc/restic-pass"; chmod 0644 "$jdir/etc/restic-pass"; chmod 0600 "$jdir/etc/config"
        : > "$jdir/log/audit.jsonl"   # a janitor run as root (the test) would make it at exit, after the check
        chmod 0755 "$jdir/etc" "$jdir/cache" "$jdir/state/restic-cache" "$jdir/lock"
    }
    mkjan
    out="$(PBO_JANITOR_ALLOW_ROOT=1 PBO_CONFIG="$jdir/etc/config" "$BIN" --json doctor --fix --perms-only 2>/dev/null)"
    got="$(stat -c '%n %U:%G %a' "$jdir/cache" "$jdir/log" "$jdir/log/pbo.log" "$jdir/state" "$jdir/state/restic-cache" "$jdir/lock" "$jdir/etc" "$jdir/etc/config" "$jdir/etc/restic-pass" | sed "s#$jdir/##")"
    exp="cache $jusr:root 750
log $jusr:root 755
log/pbo.log $jusr:root 600
state $jusr:root 755
state/restic-cache $jusr:root 700
lock $jusr:root 700
etc root:$jusr 750
etc/config root:$jusr 640
etc/restic-pass $jusr:root 400"
    [[ "$got" == "$exp" ]] && ok "janitor --fix: JANITOR_USER's dirs (LOCK_DIR too), logs and DR key (0400), config root:<group named like it> 0640 in a 0750 dir" || bad "janitor tree: $(diff <(echo "$exp") <(echo "$got"))"
    out="$(PBO_JANITOR_ALLOW_ROOT=1 PBO_CONFIG="$jdir/etc/config" "$BIN" --json doctor --fix --perms-only 2>/dev/null)"
    jq -e '.changes == [] and all(.findings[]; .level == "ok")' >/dev/null <<<"$out" && ok "janitor: a second --fix changes nothing, all OK" || bad "janitor twice: $out"

    # LOCK_DIR=/var/lock on a janitor: the 0.5 world-writable warning (check only)
    cp "$jdir/etc/config" "$RUN/jww.cfg"; sed -i "s#^LOCK_DIR=.*#LOCK_DIR=/var/lock#" "$RUN/jww.cfg"; chmod 600 "$RUN/jww.cfg"
    out="$(PBO_JANITOR_ALLOW_ROOT=1 PBO_CONFIG="$RUN/jww.cfg" "$BIN" doctor --perms-only 2>&1)"
    grep -q "WARN.*LOCK_DIR /var/lock is world-writable: a local user can block pbo's locks" <<<"$out" \
        && ok "janitor with LOCK_DIR=/var/lock: the world-writable warning" || bad "janitor var/lock: $out"
    # started as root without LOCK_DIR in the config, the root pass has root's
    # default (/run/pbo); the janitor itself uses STATE_DIR/lock. Only the path
    # is resolved here: nothing is created.
    out="$(E '_cs_ensure; PBO_ROLE=janitor; LOCK_DIR=/run/pbo; STATE_DIR="$RUN/j/state"; _perm_path_r LOCK_DIR; printf "%s\n" "$_PERM_P"')"
    [[ "$out" == "$jdir/state/lock" ]] && ok "janitor root pass: LOCK_DIR is the janitor's (STATE_DIR/lock), not root's /run/pbo" || bad "janitor lock path: $out"

    # JANITOR_USER's primary group is not used: nobody's is nogroup, which other
    # daemons share (and there is no group named nobody)
    if id nobody >/dev/null 2>&1 && ! getent group nobody >/dev/null 2>&1; then
        mkjan nobody
        out="$(PBO_JANITOR_ALLOW_ROOT=1 PBO_CONFIG="$jdir/etc/config" "$BIN" --json doctor --fix --perms-only 2>/dev/null)"
        [[ "$(stat -c %G "$jdir/etc" "$jdir/etc/config" | paste -sd' ' -)" == "root root" ]] \
            && jq -e --arg p "$jdir/etc/config" 'any(.findings[]; .level == "warn" and (.message | startswith($p + " (config): group nobody does not exist")))' >/dev/null <<<"$out" \
            && ok "janitor: the config is never given to JANITOR_USER's primary group (nogroup); a missing group of its name is reported" || bad "janitor primary group: $(stat -c %G "$jdir/etc" "$jdir/etc/config" | paste -sd' ' -) $(jq -c '[.findings[].message|select(contains("group"))]' <<<"$out")"
    else skip "janitor primary group (needs a nobody user without a nobody group)"; fi

    # started as root: the fix pass runs as root, then the re-exec reports it
    mkjan
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s"\n[[ "$1" == -u ]] && shift 2; [[ "$1" == -- ]] && shift\nPBO_JANITOR_ALLOW_ROOT=1 exec "$@"\n' "$RUN/runuser.argv" > "$RUN/bin/fake-runuser"
    chmod 755 "$RUN/bin/fake-runuser"
    out="$(PBO_JANITOR_ALLOW_ROOT=0 PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" PBO_CONFIG="$jdir/etc/config" "$BIN" --json doctor --fix --perms-only 2>/dev/null)"
    grep -q -- "-u $jusr -- .*/pbo --json doctor --fix --perms-only" "$RUN/runuser.argv" 2>/dev/null && [[ "$(stat -c %U "$jdir/cache")" == "$jusr" ]] \
        && jq -e --arg p "$jdir/cache" --arg u "$jusr" 'any(.changes[]; .path == $p and .change == "owner" and .to == $u and .applied)' >/dev/null <<<"$out" \
        && ok "janitor started as root: fixed as root, then re-exec'd as JANITOR_USER, which reports the changes (PBO_PERMS_FIXED: not fixed twice)" \
        || bad "janitor root pass: argv=$(cat "$RUN/runuser.argv" 2>/dev/null) owner=$(stat -c %U "$jdir/cache") $(jq -c .changes <<<"$out")"
    grep -q "perms fix $jdir/cache owner root->$jusr (as root, before dropping to $jusr)" "$jdir/log/audit.log" \
        && ok "janitor: the root pass's changes are audited by the re-exec'd doctor" || bad "janitor audit: $(grep perms "$jdir/log/audit.log")"
    mkjan
    PBO_JANITOR_ALLOW_ROOT=0 PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" PBO_CONFIG="$jdir/etc/config" "$BIN" --json doctor --fix --dry-run --perms-only >"$RUN/jdry.json" 2>/dev/null
    [[ "$(stat -c %U "$jdir/cache")" == root ]] && jq -e 'all(.changes[]; .applied == false) and (.changes | length) > 3' >/dev/null "$RUN/jdry.json" \
        && ok "janitor started as root, --dry-run: nothing changed, the plan reported" || bad "janitor dry: $(stat -c %U "$jdir/cache") $(cat "$RUN/jdry.json")"
else skip "janitor owners (needs root and a system user with a group of its name)"; fi

# --- install.sh runs it, and never fails on it ---------------------------------------
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s"\necho "  WARN  something"\nexit 69\n' "$RUN/pbo.argv" > "$RUN/bin/fake-pbo"; chmod 755 "$RUN/bin/fake-pbo"
out="$(PBO_INSTALL_TEST=1 PBO_INSTALL_PBO="$RUN/bin/fake-pbo" bash -c 'source ./install.sh; set -Eeuo pipefail; inst_perms; echo "survived"' 2>&1)"; rc=$?
[[ $rc == 0 ]] && grep -qx 'doctor --fix --perms-only' "$RUN/pbo.argv" && grep -q '^      WARN  something' <<<"$out" && grep -q 'WARNING: the permission check reported problems' <<<"$out" && grep -qx survived <<<"$out" \
    && ok "install.sh: inst_perms runs 'pbo doctor --fix --perms-only', shows it, and a failure does not stop the install" || bad "inst_perms: rc=$rc $out"
body="$(bash -c 'source ./install.sh; declare -f main')"
jl="$(grep -n 'inst_perms;' <<<"$body" | cut -d: -f1 | paste -sd' ' -)"
[[ "$jl" =~ ^([0-9]+)\ ([0-9]+)$ ]] && (( BASH_REMATCH[1] + 1 == $(grep -n 'inst_janitor_units;' <<<"$body" | cut -d: -f1) )) \
    && (( BASH_REMATCH[2] > $(grep -n 'inst_integration;' <<<"$body" | cut -d: -f1) )) \
    && ok "install.sh: inst_perms after the files are in place (host and janitor)" || bad "install main order"

[[ "$(hostfp)" == "$host_before" ]] && ok "nothing above the checkout and no secret file at its default path was changed" || bad "host files changed: $(diff <(echo "$host_before") <(hostfp))"
printf '\nperms: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
