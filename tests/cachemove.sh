#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/cachemove.sh: moving CACHE_DIR with its data, `pbo config set CACHE_DIR
# <new>` (0.6 M7, lib/cachemove.sh, ADR 0009 "Cache move"). A real restic repo
# (made by a real `pbo backup` with pct, qm and vzdump mocked), a fake spool and
# staging, pvesm and systemctl mocked (storage.cfg and the units are files in
# run-cachemove/). pbo runs as a copy of the entry point that sources
# tests/fixtures/cachemove_hook.sh: it stops (99) before anything runs when a
# path pbo resolves (config, directories, repos, PVE files, the old and the new
# cache) lies outside run-cachemove/.
#
# Covered: a rename on the same filesystem and a copy (forced by a test hook:
# a second filesystem needs a root mount), with the PVE storage and the mount;
# a failure after every step before the config write (rollback: the old tree,
# config, storage.cfg and the mount exactly as before); an interruption after
# the config write (--resume finishes it, --abort is refused) and before it
# (--abort undoes it, --resume finishes it); every preflight refusal; --fix-parents;
# --dry-run; an empty cache; the cache lock against a backup; a queued backup
# that restarts with the new config; _restic_ensure at the old place. Also:
# a damaged copy (tree diff, restic check), a failed config rename, failing
# pvesm and systemctl calls and a failing rollback, a storage that was already
# disabled, created parents, a filesystem mounted below the cache, bind mounts
# (another mount: a copy), a target another uid owns, open files below a
# symlinked ancestor, the mount started only on a final journal, the lock
# held exclusive during the move, an empty-cache change back to a former
# place, a pinned cache repo, a scheduled test-restore whose config changes
# between guests, and a config replaced with an older mtime. As root the CT
# traversal checks run for real (setpriv); as a plain user they are skipped
# with a visible SKIP. A run directory on a filesystem the move refuses
# (tmpfs: the move's filesystem check is faked; FUSE, NFS, no ACLs) skips.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
skip() { printf '  SKIP %s\n' "$1"; }
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping cache move tests"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "jq not installed, skipping cache move tests"; exit 0; }

printf 'pbo: cache move tests (lib/cachemove.sh)\n'
RUN="$ROOT/run-cachemove"; rm -rf "$RUN"
( umask 022; mkdir -p "$RUN"/{bin,lxc,qemu,sysd,lock,state,log,tree,etc,c,vz,mnt} ); chmod 0755 "$RUN"
chmod 0700 "$RUN/etc" "$RUN/lock" "$RUN/mnt"
for m in tests/mocks/*; do install -m 0755 "$m" "$RUN/bin/"; done   # never the real host
export PATH="$RUN/bin:$PATH" MOCK_LOG="$RUN/calls" MOCK_CONF_DIR="$RUN/lxc" MOCK_SYSTEMCTL_DIR="$RUN/sysd" MOCK_STORAGE_CFG="$RUN/storage.cfg"
: > "$MOCK_LOG"
is_root=0; [[ "$(id -u)" == 0 ]] && is_root=1
have_setpriv=0; (( is_root )) && command -v setpriv >/dev/null 2>&1 && command -v setfacl >/dev/null 2>&1 && have_setpriv=1
have_acl=0; command -v setfacl >/dev/null 2>&1 && setfacl -m u:65534:x "$RUN/vz" 2>/dev/null && have_acl=1 && setfacl -b "$RUN/vz"
# every move here goes to a directory below RUN: a filesystem the move refuses
# would fail them all (the refusals themselves are tested with a faked type)
fst="$(stat -f -c %T -- "$RUN" 2>/dev/null)"
case "$fst" in tmpfs|ramfs) export PBO_TEST_CM_FSTYPE=ext2/ext3 ;; esac
case "$fst" in fuse*|nfs*|cifs|smb*|v9fs) echo "  SKIP cache move tests (the run directory is on $fst)"; rm -rf "$RUN"; exit 0 ;; esac
(( have_acl )) || { echo "  SKIP cache move tests (no setfacl, or the run directory's filesystem has no POSIX ACLs: every move with the unprivileged CT fixture is refused)"; rm -rf "$RUN"; exit 0; }

# the entry point with the guard (tests/fixtures/cachemove_hook.sh) sourced
# right before main, and lib/ linked: its children (catalog refresh, the
# re-exec) run through the same guard
if [[ "$(tail -n 1 pbo)" != 'main "$@"' ]]; then
    bad "the entry point no longer ends in main \"\$@\": the harness needs a new hook"; printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi
{ sed '$d' pbo; printf '%s\n' 'source "$SELF_DIR/../../tests/fixtures/cachemove_hook.sh"'; tail -n 1 pbo; } > "$RUN/tree/pbo"
{ sed '$d' pbo; printf '%s\n' 'source "$SELF_DIR/../../tests/fixtures/cachemove_hook.sh"'; } > "$RUN/tree/pbo-lib"
chmod 755 "$RUN/tree/pbo"; ln -s "$ROOT/lib" "$RUN/tree/lib"
CFG="$RUN/etc/config"
P() { env TEST_RUN="$RUN" TEST_NODE=pve1 PBO_CONFIG="$CFG" "$RUN/tree/pbo" "$@"; }

printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
# an unprivileged CT whose root maps to 200000 (its own lxc.idmap: pve-container
# ignores /etc/subuid, so does pbo); the subuid fixture says otherwise on purpose
printf 'root:300000:65536\n' > "$RUN/subuid"
printf 'arch: amd64\nhostname: ct8001\nrootfs: teststore:8001/vm-8001-disk-0.raw,size=2G\nunprivileged: 1\nlxc.idmap: u 0 200000 65536\nlxc.idmap: g 0 200000 65536\n' > "$RUN/lxc/8001.conf"
ctuid=200000

# mkcfg CACHE [line...]: the suite's config, every path below run-cachemove/
mkcfg() {
    local c="$1"; shift
    printf '%s\n' "CACHE_DIR=$c" "STATE_DIR=$RUN/state" "LOG_DIR=$RUN/log" "LOCK_DIR=$RUN/lock" \
        "RESTIC_PASSWORD_FILE=$RUN/pass" "RESTIC_CACHE_DIR=$RUN/rcache" "LOCAL_REPO=true" "OFFSITE_ENABLED=false" \
        "BACKUP_ORDER=8001" "KEEP_LOCAL=5" "STORAGE_BOX_SNAPSHOTS_CONFIRMED=true" "GLOBAL_LOCK_TIMEOUT=60" \
        "PBO_PVE_LXC_DIR=$RUN/lxc" "PBO_PVE_QEMU_DIR=$RUN/qemu" "PBO_SUBUID_FILE=$RUN/subuid" "PBO_PERMS_PARENTS_TOP=$RUN" \
        "PBO_PERMS_CONFIG_DIR=$RUN/etc" "PBO_PVE_CFS_DIR=$RUN/pve" "PVE_STORAGE_CFG=$RUN/storage.cfg" "PBO_PVE_STORAGE_CFG=$RUN/storage.cfg" \
        "VZDUMP_CONF=$RUN/vzdump.conf" "VZDUMP_LOCK=$RUN/vzdump.lock" "PVE_CATALOG_MOUNT_DIR=$RUN/mnt/m" \
        "PBO_CATALOG=$RUN/state/catalog/index.json" "PBO_PVE_PLUGIN_PATH=$RUN/plugin.pm" "NTFY_CREDS_FILE=$RUN/ntfy.creds" \
        "TR_STORAGE=teststore" "TR_WAIT_TRIES=1" "TR_WAIT_SLEEP=0" "$@" > "$CFG"
    chmod 600 "$CFG"
}
# storage CACHE [nodes]: storage.cfg with the pbo storage on CACHE's spool
storage() {
    { printf 'dir: local\n\tpath %s\n\tcontent iso,vztmpl,backup\n\npbo: pbo\n\tpath %s/spool\n\tcontent backup\n' "$RUN/vz" "$1"
      [[ -z "${2-pve1}" ]] || printf '\tnodes %s\n' "${2-pve1}"; } > "$RUN/storage.cfg"
}
# fp DIR: everything about a tree: type, mode, owner, size, mtime, link, path,
# every file's checksum and every ACL
fp() {
    [[ -e "$1" ]] || { echo "<missing $1>"; return; }
    ( cd "$1" && find . -printf '%y %m %U %G %s %T@ %l %P\n' | LC_ALL=C sort
      find . -type f -exec sha256sum {} + | LC_ALL=C sort -k2
      getfacl -Rpn . 2>/dev/null )
}
jget() { jq -r "$1" "$RUN/state/cache-move.json" 2>/dev/null; }
mount_on()  { : > "$RUN/sysd/pbo-mount.service.active"; }
mount_is()  { [[ -e "$RUN/sysd/pbo-mount.service.active" ]]; }
# the journal's state at each `systemctl start` (pbo-mount.service's `catalog
# _mount` stops at a journal that is not final, and systemctl returns at once)
printf '%s\n' '#!/usr/bin/env bash' "jq -r .state '$RUN/state/cache-move.json' >> '$RUN/start-states' 2>/dev/null || echo none >> '$RUN/start-states'" > "$RUN/start-hook.sh"
export MOCK_SYSTEMCTL_START_HOOK="$RUN/start-hook.sh"
starts() { [[ -e "$RUN/start-states" ]] || return 0; tr '\n' ' ' < "$RUN/start-states" | sed 's/ $//'; }

# --- the golden cache: a real repo with a real backup of CT 8001 ------------------------------------
gold="$RUN/golden"
mkcfg "$gold"
out="$(P init 2>&1)" || bad "init: $out"
out="$(P backup 8001 2>&1)"; rc=$?
if [[ $rc != 0 || ! -f "$gold/repo/config" ]]; then
    bad "golden: backup 8001 rc=$rc $(tail -n 3 <<<"$out")"; printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi
mkdir -p "$gold/spool/dump" "$gold/staging"; chmod 0755 "$gold/spool" "$gold/spool/dump"; chmod 0700 "$gold/staging"
nsnap() { RESTIC_PASSWORD_FILE="$RUN/pass" RESTIC_CACHE_DIR="$RUN/rcache" restic -r "$1" snapshots --json 2>/dev/null | jq length; }
[[ "$(nsnap "$gold/repo")" == 1 ]] && ok "golden cache: a real restic repo with one backup, a spool and staging" || bad "golden snapshots: $(nsnap "$gold/repo")"

# --- the guard itself --------------------------------------------------------------------------------
printf '%s\n' "CACHE_DIR=/var/cache/pbo" "STATE_DIR=$RUN/state" "LOG_DIR=$RUN/log" "LOCK_DIR=$RUN/lock" > "$RUN/etc/outside"; chmod 600 "$RUN/etc/outside"
out="$(env TEST_RUN="$RUN" TEST_NODE=pve1 PBO_CONFIG="$RUN/etc/outside" "$RUN/tree/pbo" config get CACHE_DIR 2>&1)"; rc=$?
[[ $rc == 99 ]] && grep -q 'outside' <<<"$out" && ok "harness: a config that resolves a path outside the run directory stops pbo (99) before any command" || bad "guard: rc=$rc $out"

A="$RUN/c/a" B="$RUN/c/b"
# reset [mkcfg lines...]: the golden cache at A, nothing at B, a clean state
reset() {
    rm -rf "$RUN/c" "$RUN/state/cache-move.json" "$RUN/state/ingest-deferred" "$RUN/sysd"/* "$RUN/vzdump.pids" "$RUN/storage.cfg" "$RUN/closed" "$RUN/far" \
        "$RUN/start-states" "$RUN/pinned" "$RUN/lnk" "$RUN/mountinfo"
    ( umask 022; mkdir -p "$RUN/c" ); chmod 0755 "$RUN/c"
    cp -a "$gold" "$A"
    mkcfg "$A" "$@"
    : > "$MOCK_LOG"
}
snapshot_state() { FP_A="$(fp "$A")"; cp "$CFG" "$RUN/cfg.before"; cp "$RUN/storage.cfg" "$RUN/st.before" 2>/dev/null || : > "$RUN/st.before"; }
same_state() {   # the old tree, the config and storage.cfg as snapshot_state saw them, nothing at B
    [[ "$(fp "$A")" == "$FP_A" ]] && cmp -s "$RUN/cfg.before" "$CFG" && [[ ! -e "$B" ]] \
        && { [[ ! -s "$RUN/st.before" && ! -e "$RUN/storage.cfg" ]] || cmp -s "$RUN/st.before" "$RUN/storage.cfg"; }
}
# fp_ns DIR: fp without the staging directory (its entries, their sums and ACLs)
fp_ns() {
    fp "$1" | awk '/^# file: / { skip = ($3 ~ /^(\.\/)?staging(\/|$)/) } skip && /^$/ { skip = 0; next } skip { next }
        $NF ~ /^(\.\/)?staging(\/|$)/ { next } { print }'
}
cfgval() { env -i PATH="$PATH" bash -c 'source lib/config_schema.sh; source lib/config_parse.sh; _cs_core; _cfg_reset
    _cfg_parse_file "$1" local >/dev/null; printf %s "${CFG_VAL[$2]-<unset>}"' _ "$CFG" "$1"; }

# --- --dry-run: the whole plan, nothing changed ----------------------------------------------------------
reset "PBO_INTEGRATION=both"; storage "$A"; mount_on; snapshot_state
out="$(P --dry-run config set CACHE_DIR "$B" 2>&1)"; rc=$?
[[ $rc == 0 ]] && same_state && [[ ! -e "$RUN/state/cache-move.json" ]] && mount_is && ! grep -q '^pvesm set\|^systemctl stop' "$MOCK_LOG" \
    && grep -q 'cache move plan:' <<<"$out" && grep -q 'checks:' <<<"$out" && grep -q 'steps:' <<<"$out" \
    && grep -q 'pvesm set pbo --disable 1' <<<"$out" && grep -q "mv -T $A $B" <<<"$out" && grep -q "pvesm set pbo --path $B/spool" <<<"$out" \
    && grep -q "^+CACHE_DIR=$B" <<<"$out" && [[ -z "$(find "$RUN/c" -maxdepth 1 -name '.pbo-acl-probe*' -print -quit)" ]] \
    && ok "--dry-run: the checks and every step (storage, mount, rename, config diff), nothing changed (tree, config, storage.cfg, mount, no journal)" \
    || bad "dry run: rc=$rc $out"
out="$(P --json --dry-run config set CACHE_DIR "$B" 2>/dev/null)"; rc=$?
[[ $rc == 0 ]] && jq -e '.dry_run and .written == false and any(.hooks[]; .hook == "move-cache" and .status == "would" and (.message | test("steps:")))' >/dev/null <<<"$out" \
    && same_state && ok "--dry-run --json: the plan in hooks[], nothing written" || bad "dry json: rc=$rc $out"

# --- same filesystem: a rename, with the PVE storage and the mount ------------------------------------
reset "PBO_INTEGRATION=both" "RESTIC_CACHE_REPO=$A/repo"; storage "$A"; mount_on
fp_gold="$(cd "$A" && find . -mindepth 1 ! -path './spool*' ! -path './staging*' -printf '%y %s %P\n' | LC_ALL=C sort)"
out="$(P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc == 0 && ! -e "$A" && -f "$B/repo/config" && "$(cfgval CACHE_DIR)" == "$B" && "$(cfgval RESTIC_CACHE_REPO)" == '<unset>' ]] \
    && [[ "$(jget .state)" == "done" && "$(jget .method)" == rename ]] \
    && [[ "$(cd "$B" && find . -mindepth 1 ! -path './spool*' ! -path './staging*' -printf '%y %s %P\n' | LC_ALL=C sort)" == "$fp_gold" ]] \
    && ok "rename: the data is at the new place, CACHE_DIR written, RESTIC_CACHE_REPO pinned at the old default removed (it follows), the journal done" \
    || bad "rename: rc=$rc $out $(jget .state) $(jget .error)"
grep -q "path $B/spool" "$RUN/storage.cfg" && ! grep -q 'disable' "$RUN/storage.cfg" \
    && grep -q '^pvesm set pbo --disable 1' "$MOCK_LOG" && grep -q "^pvesm set pbo --path $B/spool" "$MOCK_LOG" && grep -q '^pvesm set pbo --delete disable' "$MOCK_LOG" \
    && ok "rename: the storage was disabled during the move, then points at the new spool and is enabled again" || bad "storage: $(cat "$RUN/storage.cfg") $(grep pvesm "$MOCK_LOG")"
mount_is && grep -q '^systemctl stop pbo-mount.service' "$MOCK_LOG" && grep -q '^systemctl start pbo-mount.service' "$MOCK_LOG" && [[ "$(starts)" == "done" ]] \
    && ok "rename: pbo-mount.service stopped for the move and started again, once the journal said done" || bad "mount: $(grep systemctl "$MOCK_LOG") states=$(starts)"
[[ -f "$RUN/state/catalog/index.json" ]] && [[ "$(jq -r .staging_dir "$RUN/state/catalog/index.json")" == "$B/staging" ]] \
    && ok "rename: the catalogue is refreshed with the new staging directory (the plugin reads it)" || bad "catalog: $(jq -c '{staging_dir}' "$RUN/state/catalog/index.json" 2>&1)"
[[ "$(stat -c %a "$B")" == 750 || "$(stat -c %a "$B")" == 710 ]] && [[ "$(stat -c %a "$B/spool")" == 755 && "$(stat -c %a "$B/staging")" == 700 ]] \
    && getfacl -cpn "$B" 2>/dev/null | grep -q "^user:$ctuid:--x" \
    && ok "rename: the permission rules hold on the new paths (cache closed with the CT root's ACL entry, spool 0755, staging 0700)" || bad "perms: $(stat -c '%a %n' "$B" "$B/spool" "$B/staging") $(getfacl -cpn "$B" 2>&1 | tr '\n' ' ')"
out="$(P backup 8001 2>&1)"; rc=$?
[[ $rc == 0 && "$(nsnap "$B/repo")" == 2 && ! -e "$A" ]] && ok "rename: a backup afterwards goes to the moved repo; the old directory is not made again" || bad "backup after: rc=$rc $(tail -n 3 <<<"$out")"
out="$(P doctor 2>&1)"
grep -q "last cache move: $A -> $B (rename" <<<"$out" && ! grep -q 'is unfinished' <<<"$out" && ok "doctor names the last move (no FAIL)" || bad "doctor after move: $(grep -i 'cache move' <<<"$out")"

# --- another filesystem: a copy, compared and checked, the old copy removed -----------------------------
reset; snapshot_state
out="$(PBO_TEST_CM_COPY=1 P config set CACHE_DIR "$B" --yes --verify-data 2>&1)"; rc=$?
[[ $rc == 0 && ! -e "$A" && -f "$B/repo/config" && "$(cfgval CACHE_DIR)" == "$B" && "$(jget .method)" == copy && "$(jget .state)" == "done" ]] \
    && grep -q 'the copy matches' <<<"$out" && grep -q 'restic check --read-data on the copied cache repo' <<<"$out" \
    && [[ "$(RESTIC_PASSWORD_FILE="$RUN/pass" RESTIC_CACHE_DIR="$RUN/rcache" restic -r "$B/repo" check 2>&1 | tail -n 1)" == *"no errors were found"* ]] \
    && ok "copy: cp -a, the trees compared, restic check --read-data of the copy, the config written, the old directory (pbo's own entries only) removed" \
    || bad "copy: rc=$rc $out"
reset; snapshot_state
out="$(PBO_TEST_CM_NEW_MOUNT="$RUN/elsewhere" P --dry-run config set CACHE_DIR "$B" 2>&1)"
grep -q 'a copy: the same filesystem through another mount' <<<"$out" || bad "other mount, the plan: $(grep -E 'plan:|copied' <<<"$out")"
out="$(PBO_TEST_CM_NEW_MOUNT="$RUN/elsewhere" P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc == 0 && ! -e "$A" && -f "$B/repo/config" && "$(jget .method)" == copy && "$(jget .state)" == "done" ]] \
    && grep -q 'the copy matches' <<<"$out" \
    && ok "the same filesystem through another mount (a bind mount: rename gives EXDEV there): a checked copy, not a rename" \
    || bad "other mount: rc=$rc method=$(jget .method) $(tail -n 3 <<<"$out")"
reset; mkdir "$A/notes"; : > "$A/notes/mine"
out="$(PBO_TEST_CM_COPY=1 P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc == 0 && -e "$A/notes/mine" && -f "$A/repo/config" && -f "$B/repo/config" && -f "$B/notes/mine" ]] && grep -q 'is kept: it holds entries pbo does not know (notes)' <<<"$out" \
    && ok "copy: an old directory with entries pbo does not know is kept and named" || bad "copy unknown: rc=$rc $out"
reset
out="$(PBO_TEST_CM_COPY=1 P config set CACHE_DIR "$B" --yes --keep-old 2>&1)"; rc=$?
[[ $rc == 0 && -f "$A/repo/config" && -f "$B/repo/config" ]] && grep -q 'kept (--keep-old)' <<<"$out" && ok "copy --keep-old: the old copy stays" || bad "keep-old: rc=$rc $out"
# a key pinned below the cache under a name of its own moves with it; one
# pinned elsewhere stays (and its data is not moved)
reset "RESTIC_CACHE_REPO=$A/myrepo" "PVE_STAGING_DIR=$RUN/far/staging"; mv "$A/repo" "$A/myrepo"; mkdir -p "$RUN/far/staging"; chmod 0755 "$RUN/far"
out="$(P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc == 0 && "$(cfgval RESTIC_CACHE_REPO)" == "$B/myrepo" && -f "$B/myrepo/config" && "$(cfgval PVE_STAGING_DIR)" == "$RUN/far/staging" && -d "$RUN/far/staging" ]] \
    && ok "keys: a repo pinned below the cache moves with it (rewritten in the same write), staging pinned elsewhere stays" || bad "pinned keys: rc=$rc $out $(grep -E 'REPO|STAGING' "$CFG")"

# --- a failure after each step before the config write: rolled back --------------------------------------
for method in rename copy; do
    for s in lock mount-stop storage-disable staging-clear target-create data config-write; do
        reset "PBO_INTEGRATION=both"; storage "$A"; mount_on
        if [[ "$s" == staging-clear ]]; then
            # staged archives (a copy, a link into the mount) the step removes,
            # and what it must keep: another file, a directory
            : > "$A/staging/vzdump-lxc-8001-2026_01_15-05_00_00.tar"
            ln -s ../spool/x "$A/staging/vzdump-qemu-8002-2026_01_15-05_00_00.vma.zst"
            printf 'keep\n' > "$A/staging/keep.txt"; mkdir "$A/staging/vzdump-dir"
        fi
        snapshot_state; fpns="$(fp_ns "$A")"
        cenv=(); [[ "$method" == copy ]] && cenv=(PBO_TEST_CM_COPY=1)
        out="$(env "${cenv[@]+"${cenv[@]}"}" PBO_TEST_CM_FAIL="$s" TEST_RUN="$RUN" TEST_NODE=pve1 PBO_CONFIG="$CFG" "$RUN/tree/pbo" config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
        if [[ "$s" == staging-clear ]]; then
            st_ok=0
            [[ "$(fp_ns "$A")" == "$fpns" ]] && cmp -s "$RUN/cfg.before" "$CFG" && cmp -s "$RUN/st.before" "$RUN/storage.cfg" && [[ ! -e "$B" ]] \
                && [[ ! -e "$A/staging/vzdump-lxc-8001-2026_01_15-05_00_00.tar" && ! -L "$A/staging/vzdump-qemu-8002-2026_01_15-05_00_00.vma.zst" ]] \
                && [[ "$(cat "$A/staging/keep.txt" 2>/dev/null)" == keep && -d "$A/staging/vzdump-dir" && "$(stat -c %a "$A/staging")" == 700 ]] && st_ok=1
        else
            st_ok=0; same_state && st_ok=1
        fi
        # the mount was stopped from mount-stop on: started again once the journal was final
        want=rolled-back; [[ "$s" == lock ]] && want=''
        if [[ $rc == 69 ]] && (( st_ok )) && mount_is && [[ "$(jget .state)" == rolled-back && "$(starts)" == "$want" ]] && grep -q 'rolled back, nothing was changed' <<<"$out"; then
            if [[ "$s" == staging-clear ]]; then
                ok "$method, failure after $s: rolled back (69): the staged archives (file and link) gone, another file and a directory in staging kept, the rest of the old tree byte-identical, the mount running"
            else
                ok "$method, failure after $s: rolled back (69): the old tree byte-identical, config and storage.cfg unchanged, the mount started once the journal was final, nothing at the target"
            fi
        else
            bad "$method fail $s: rc=$rc state=$(jget .state) starts=$(starts) $(tail -n 4 <<<"$out") $(diff <(printf '%s\n' "$FP_A") <(fp "$A") | head -n 4)"
        fi
    done
done

# --- a step's own command fails, the rollback fails, the storage was disabled before -------------------------
reset "PBO_INTEGRATION=both"; storage "$A"; mount_on; snapshot_state
out="$(MOCK_SYSTEMCTL_FAIL=stop P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc == 69 && "$(jget .state)" == rolled-back ]] && same_state && mount_is && ! grep -q '^pvesm set' "$MOCK_LOG" \
    && ok "systemctl stop of the mount fails: rolled back (69), nothing changed, the mount still runs, the storage never touched" \
    || bad "systemctl stop fails: rc=$rc state=$(jget .state) $(tail -n 3 <<<"$out") $(grep pvesm "$MOCK_LOG")"
reset "PBO_INTEGRATION=both"; storage "$A"; mount_on; snapshot_state
out="$(MOCK_PVESM_FAIL_ARGS='--disable 1' P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc == 69 && "$(jget .state)" == rolled-back && "$(fp "$A")" == "$FP_A" && ! -e "$B" ]] && cmp -s "$RUN/cfg.before" "$CFG" \
    && ! grep -q disable "$RUN/storage.cfg" && mount_is \
    && ok "pvesm set --disable 1 fails: rolled back (69), the old tree and config unchanged, the storage enabled, the mount running" \
    || bad "pvesm disable fails: rc=$rc state=$(jget .state) $(tail -n 3 <<<"$out") $(cat "$RUN/storage.cfg")"
reset "PBO_INTEGRATION=both"; storage "$A"; mount_on; snapshot_state
out="$(PBO_TEST_CM_FAIL=data MOCK_PVESM_FAIL_ARGS='--delete disable' P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc != 0 && "$(jget .state)" == rollback-failed && "$(fp "$A")" == "$FP_A" && ! -e "$B" ]] && grep -q -- '--abort' <<<"$out" && grep -q 'is still disabled' <<<"$out" \
    && ! mount_is && [[ -z "$(starts)" ]] \
    && ok "the rollback's pvesm set --delete disable fails: rollback-failed, says the storage is still disabled and --abort; the old tree back; the mount not started on an unfinished journal" \
    || bad "rollback fails: rc=$rc state=$(jget .state) starts=$(starts) $(tail -n 3 <<<"$out")"
out="$(P backup 8001 2>&1)"; rc=$?
[[ $rc == 75 ]] && grep -q -- '--abort' <<<"$out" && ok "after a failed rollback a backup is blocked (75)" || bad "backup after rollback-failed: rc=$rc $(tail -n 2 <<<"$out")"
out="$(P config set CACHE_DIR "$B" --abort 2>&1)"; rc=$?
[[ $rc == 0 && "$(jget .state)" == aborted ]] && same_state && mount_is && [[ "$(starts)" == aborted ]] \
    && ok "--abort after the failed rollback: the storage enabled, the journal aborted, then the mount started; everything as before" \
    || bad "abort after rollback-failed: rc=$rc state=$(jget .state) starts=$(starts) $(tail -n 3 <<<"$out")"
reset "PBO_INTEGRATION=both"; storage "$A"; mount_on; snapshot_state
out="$(PBO_TEST_CM_FAIL=data MOCK_SYSTEMCTL_FAIL=start P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc == 69 && "$(jget .state)" == rolled-back ]] && same_state && ! mount_is && grep -q 'could not start pbo-mount.service' <<<"$out" \
    && ok "the mount does not start after a rollback: a warning (it starts on the next restore), the journal final, nothing changed" \
    || bad "start fails in rollback: rc=$rc state=$(jget .state) $(tail -n 3 <<<"$out")"
# a storage disabled before the move stays disabled, and the move does not touch the flag
reset "PBO_INTEGRATION=both"; storage "$A"; printf '\tdisable 1\n' >> "$RUN/storage.cfg"; mount_on; snapshot_state
out="$(PBO_TEST_CM_FAIL=data P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc == 69 && "$(jget .state)" == rolled-back ]] && same_state && ! grep -q 'pvesm set pbo --disable 1\|--delete disable' "$MOCK_LOG" \
    && ok "a storage disabled before the move: rolled back with storage.cfg byte-identical, its disable flag never touched" \
    || bad "disabled before, rollback: rc=$rc $(grep pvesm "$MOCK_LOG")"
reset "PBO_INTEGRATION=both"; storage "$A"; printf '\tdisable 1\n' >> "$RUN/storage.cfg"; mount_on
out="$(P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc == 0 && "$(jget .state)" == "done" ]] && grep -q "path $B/spool" "$RUN/storage.cfg" && grep -q 'disable 1' "$RUN/storage.cfg" \
    && ! grep -q 'pvesm set pbo --disable 1\|--delete disable' "$MOCK_LOG" \
    && ok "a storage disabled before the move: moved, the path follows, it stays disabled" || bad "disabled before, move: rc=$rc $(cat "$RUN/storage.cfg")"
# parents the move created are removed by the rollback and by --abort
for method in rename copy; do
    reset; snapshot_state
    cenv=(); [[ "$method" == copy ]] && cenv=(PBO_TEST_CM_COPY=1)
    out="$(env "${cenv[@]+"${cenv[@]}"}" PBO_TEST_CM_FAIL=data TEST_RUN="$RUN" TEST_NODE=pve1 PBO_CONFIG="$CFG" "$RUN/tree/pbo" config set CACHE_DIR "$RUN/c/n1/n2/b" --yes 2>&1)"; rc=$?
    [[ $rc == 69 && "$(jget .state)" == rolled-back && ! -e "$RUN/c/n1" && -d "$RUN/c" ]] && same_state \
        && ok "$method into new parents: the rollback removes the parents it created (and nothing above them)" || bad "$method new parents: rc=$rc $(ls "$RUN/c")"
done
reset; snapshot_state
out="$(PBO_TEST_CM_KILL=data P config set CACHE_DIR "$RUN/c/n1/n2/b" --yes 2>&1)"; rc=$?
out="$(P config set CACHE_DIR "$RUN/c/n1/n2/b" --abort 2>&1)"; rc2=$?
[[ $rc == 137 && $rc2 == 0 && "$(jget .state)" == aborted && ! -e "$RUN/c/n1" ]] && same_state \
    && ok "killed after the rename into new parents: --abort renames it back and removes the parents" || bad "abort new parents: rc=$rc rc2=$rc2 $(ls "$RUN/c") $(tail -n 2 <<<"$out")"

# --- a damaged copy: the checks that guard removing the old copy -----------------------------------------
for dmg in drop flip; do
    reset; snapshot_state
    if [[ "$dmg" == drop ]]; then pat='the copy in .* differs from'; else pat='restic check --read-data of the copied repo .* failed'; fi
    out="$(TEST_CM_DAMAGE="$dmg" PBO_TEST_CM_COPY=1 P config set CACHE_DIR "$B" --yes --verify-data 2>&1)"; rc=$?
    [[ $rc == 69 && "$(jget .state)" == rolled-back ]] && grep -q "$pat" <<<"$out" && same_state \
        && ok "a copy with $([[ "$dmg" == drop ]] && echo 'a pack missing (tree diff)' || echo 'a changed pack of the same size (restic check --read-data)'): rolled back (69), the old tree byte-identical, nothing at the target" \
        || bad "damage $dmg: rc=$rc state=$(jget .state) $(grep -E 'differs|restic check|rolling' <<<"$out" | head -n 3)"
done

# --- the writer's rename of the config fails after the data moved: undone ------------------------------------
for method in rename copy; do
    reset "PBO_INTEGRATION=both"; storage "$A"; mount_on; snapshot_state
    cenv=(); [[ "$method" == copy ]] && cenv=(PBO_TEST_CM_COPY=1)
    out="$(env "${cenv[@]+"${cenv[@]}"}" TEST_CFG_MV_FAIL=1 TEST_RUN="$RUN" TEST_NODE=pve1 PBO_CONFIG="$CFG" "$RUN/tree/pbo" config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
    [[ $rc != 0 && "$(cfgval CACHE_DIR)" == "$A" && "$(jget .state)" == rolled-back ]] && grep -q 'the config could not be written' <<<"$out" && same_state && mount_is \
        && ok "$method, the config rename fails after the data step: the move undone (rc $rc), the old tree, config and storage as before, the mount running" \
        || bad "$method config rename fails: rc=$rc state=$(jget .state) cache=$(cfgval CACHE_DIR) $(tail -n 3 <<<"$out")"
done

# --- interrupted after the config write: --abort refused, --resume finishes ---------------------------------
reset "PBO_INTEGRATION=both"; storage "$A"; mount_on
out="$(PBO_TEST_CM_KILL=config P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc == 137 && "$(cfgval CACHE_DIR)" == "$B" && "$(jget .state)" == running ]] && ok "killed right after the config rename: the config names $B, the journal is not final" || bad "kill config: rc=$rc $(jget .state) $out"
out="$(P backup 8001 2>&1)"; rc=$?
[[ $rc == 75 ]] && grep -q -- "--resume" <<<"$out" && ok "an unfinished move blocks a backup (75, with how to finish it)" || bad "blocked backup: rc=$rc $out"
out="$(P init 2>&1)"; rc=$?
[[ $rc == 75 ]] && grep -q 'unfinished' <<<"$out" && ok "an unfinished move blocks restic init (75)" || bad "blocked init: rc=$rc $out"
out="$(P doctor 2>&1)"; rc=$?
[[ $rc != 0 ]] && grep -q 'FAIL.*is unfinished' <<<"$out" && ok "doctor FAILs on an unfinished move" || bad "doctor fail: rc=$rc $(grep -i unfinished <<<"$out")"
out="$(P config set CACHE_DIR "$B" 2>&1)"; rc=$?
[[ $rc == 75 ]] && grep -q -- '--resume' <<<"$out" && ok "config set CACHE_DIR without --resume/--abort while unfinished: 75" || bad "plain set unfinished: rc=$rc $out"
out="$(P config set CACHE_DIR "$B" --abort 2>&1)"; rc=$?
[[ $rc == 64 ]] && grep -q 'only undone before its config write' <<<"$out" && [[ "$(cfgval CACHE_DIR)" == "$B" && -f "$B/repo/config" ]] \
    && ok "--abort after the config write: refused (64), nothing undone" || bad "abort after write: rc=$rc $out"
out="$(P config set CACHE_DIR "$B" --resume 2>&1)"; rc=$?
[[ $rc == 0 && "$(jget .state)" == "done" ]] && grep -q "path $B/spool" "$RUN/storage.cfg" && ! grep -q disable "$RUN/storage.cfg" && mount_is \
    && ok "--resume after the config write: the storage repointed and enabled, the mount started, the journal done" || bad "resume after write: rc=$rc $out $(cat "$RUN/storage.cfg")"
out="$(P backup 8001 2>&1)"; rc=$?
[[ $rc == 0 ]] && ok "after --resume a backup runs again" || bad "backup after resume: rc=$rc $(tail -n 2 <<<"$out")"
# killed in a step after the write: --resume runs what is left
reset; out="$(PBO_TEST_CM_COPY=1 PBO_TEST_CM_KILL=perms P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc == 137 && -d "$A" && "$(jget .state)" == config-written ]] || bad "kill perms: rc=$rc $(jget .state)"
out="$(P config set CACHE_DIR "$B" --resume 2>&1)"; rc=$?
[[ $rc == 0 && "$(jget .state)" == "done" && ! -e "$A" ]] && ok "killed in a step after the write (copy): --resume does the rest (the old copy removed)" || bad "resume perms: rc=$rc $out"

# --- interrupted before the config write: --abort undoes it, --resume finishes it ---------------------------
reset "PBO_INTEGRATION=both"; storage "$A"; mount_on; snapshot_state
out="$(PBO_TEST_CM_KILL=data P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc == 137 && ! -e "$A" && -d "$B/repo" && "$(cfgval CACHE_DIR)" == "$A" ]] || bad "kill data: rc=$rc $(ls "$RUN/c")"
out="$(P config set CACHE_DIR "$B" --abort 2>&1)"; rc=$?
[[ $rc == 0 && "$(jget .state)" == aborted ]] && same_state && mount_is && [[ "$(starts)" == aborted ]] \
    && ok "killed after the rename, before the config write: --abort renames it back (the old tree byte-identical), the storage enabled, the mount started" \
    || bad "abort: rc=$rc $out $(diff <(printf '%s\n' "$FP_A") <(fp "$A") | head -n 4)"
reset; snapshot_state
out="$(PBO_TEST_CM_COPY=1 PBO_TEST_CM_KILL=target-create P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
out="$(PBO_TEST_CM_COPY=1 P config set CACHE_DIR "$B" --resume 2>&1)"; rc=$?
[[ $rc == 0 && "$(jget .state)" == "done" && "$(cfgval CACHE_DIR)" == "$B" && -f "$B/repo/config" && ! -e "$A" ]] \
    && ok "killed before the copy: --resume copies, checks, writes the config and finishes" || bad "resume before write: rc=$rc $out"
reset
out="$(P config set CACHE_DIR "$B" --resume 2>&1)"; rc=$?
[[ $rc == 64 ]] && grep -q 'no unfinished cache move' <<<"$out" && ok "--resume without an unfinished move: 64" || bad "resume nothing: rc=$rc $out"
out="$(P config set KEEP_LOCAL 3 --keep-old 2>&1)"; rc=$?
[[ $rc == 64 ]] && grep -q 'only with CACHE_DIR' <<<"$out" && ok "the move's flags without CACHE_DIR: 64" || bad "flags without cache: rc=$rc $out"

# --- preflight: each refusal, nothing changed -----------------------------------------------------------------
# refused CODE PATTERN DESC [env...] -- ARGS: config set CACHE_DIR ARGS is refused with CODE
refused() {
    local code="$1" pat="$2" desc="$3"; shift 3
    local -a e=(); while [[ "$1" != -- ]]; do e+=("$1"); shift; done; shift
    snapshot_state
    out="$(env "${e[@]+"${e[@]}"}" TEST_RUN="$RUN" TEST_NODE=pve1 PBO_CONFIG="$CFG" "$RUN/tree/pbo" config set CACHE_DIR "$@" --yes 2>&1)"; rc=$?
    if [[ $rc == "$code" ]] && grep -q -- "$pat" <<<"$out" && same_state && [[ ! -e "$RUN/state/cache-move.json" ]]; then ok "refused ($code): $desc; nothing changed"
    else bad "refused $desc: rc=$rc (want $code) $(grep -E 'refused|WARN' <<<"$out" | head -n 3)"; fi
}
reset; ln -s "$RUN/c/real" "$RUN/c/link"; mkdir "$RUN/c/real"
refused 78 'is a symlink' "the target is a symlink" -- "$RUN/c/link"
refused 78 'goes through a symlink' "the target lies below a symlink" -- "$RUN/c/link/x"
rm -f "$RUN/c/link"; rmdir "$RUN/c/real"
refused 78 'lies inside the current one' "the target inside the current cache" -- "$A/sub"
mkdir -p "$RUN/c/outer"; mv "$A" "$RUN/c/outer/a"; mkcfg "$RUN/c/outer/a"; A="$RUN/c/outer/a"
refused 78 'lies inside' "the current cache inside the target" -- "$RUN/c/outer"
A="$RUN/c/a"; reset
refused 78 'not a canonical path' "a path with .." -- "$RUN/c/x/../b"
mkdir -p "$RUN/c/full"; : > "$RUN/c/full/x"
refused 78 'is not empty' "a target that holds files" -- "$RUN/c/full"
rm -rf "$RUN/c/full"
refused 69 'not enough space' "not enough space for a copy" PBO_TEST_CM_COPY=1 PBO_TEST_CM_FREE=1000 -- "$B"
refused 69 'lost on a reboot' "a tmpfs target" PBO_TEST_CM_FSTYPE=tmpfs -- "$B"
refused 69 'FUSE' "a FUSE target" PBO_TEST_CM_FSTYPE=fuse.sshfs -- "$B"
refused 69 'network filesystem' "an NFS target without --force" PBO_TEST_CM_FSTYPE=nfs -- "$B"
refused 69 'network filesystem' "a 9p target (stat names it v9fs)" PBO_TEST_CM_FSTYPE=v9fs -- "$B"
refused 78 'comes from the environment' "a key that follows, set below the old cache by the environment" PVE_SPOOL_DIR="$A/spool" -- "$B"
printf '%s\n' "21 1 0:20 / / rw,relatime - ext4 /dev/vda1 rw" "40 21 0:41 / $A/repo rw,relatime - zfs tank/cache/repo rw" \
    "41 21 0:42 / $A/my\\040dir rw,relatime - zfs tank/cache/x rw" "42 21 0:43 / $A/.zfs/snapshot/s1 ro,relatime - zfs tank/cache@s1 ro" > "$RUN/mountinfo"
refused 69 "$A/repo is a separate filesystem mounted below the current CACHE_DIR" "a filesystem (a child dataset) mounted below the old cache" PBO_TEST_CM_MOUNTINFO="$RUN/mountinfo" -- "$B"
grep -q "$A/my dir is a separate filesystem" <<<"$out" && ! grep -q 'snapshot/s1 is a separate' <<<"$out" \
    && ok "a mount point below the old cache is named with its escapes decoded (\\040); a snapshot ZFS mounted below .zfs is not" || bad "mountinfo escapes: $(grep 'separate' <<<"$out")"
rm -f "$RUN/mountinfo"
out="$(PBO_TEST_CM_FSTYPE=nfs P config set CACHE_DIR "$B" --yes --force 2>&1)"; rc=$?
[[ $rc == 0 && "$(cfgval CACHE_DIR)" == "$B" ]] && grep -q 'accepted with --force' <<<"$out" && ok "an NFS target with --force: moved, with a warning" || bad "nfs force: rc=$rc $out"
reset; mkdir -p "$RUN/c/gw"; chmod 0775 "$RUN/c/gw"
refused 69 'group- or world-writable' "a group-writable parent" -- "$RUN/c/gw/b"
rm -rf "$RUN/c/gw"
if (( is_root )); then
    # a directory another user owns: no probe file is made there (they could
    # swap it for a symlink before root's setfacl)
    mkdir -p "$RUN/c/home/u1"; chown 65534 "$RUN/c/home/u1"; snapshot_state
    out="$(P --dry-run config set CACHE_DIR "$RUN/c/home/u1/pbo" 2>&1)"; rc=$?
    [[ $rc == 69 ]] && grep -q 'belongs to uid 65534' <<<"$out" && grep -q 'checked once the directories above the target belong to root' <<<"$out" && same_state \
        && ok "a parent another user owns: refused (69), and the ACL probes are not run in it" || bad "user parent: rc=$rc $(grep -E 'uid|checked once' <<<"$out")"
    refused 69 'belongs to uid 65534' "a parent another user owns" -- "$RUN/c/home/u1/pbo"
    mkdir "$RUN/c/owned"; chown 65534 "$RUN/c/owned"
    refused 69 'exists and belongs to uid 65534' "an existing empty target another user owns" -- "$RUN/c/owned"
    rm -rf "$RUN/c/home" "$RUN/c/owned"
else
    skip "targets below a directory another user owns (needs root to chown)"
fi
exec 8>>"$RUN/lock/pbo.global"; flock -n 8
refused 69 'busy: a backup or prune holds the global lock' "the global lock held" -- "$B"
exec 8>&-
printf '%s\n' 4242 > "$RUN/vzdump.pids"
refused 69 'vzdump runs (pid 4242)' "a vzdump process" -- "$B"
rm -f "$RUN/vzdump.pids"
( flock -s 9 && exec sleep 30 ) 9>>"$RUN/lock/pbo.cache" & holder=$!
for _ in $(seq 50); do flock -n -x "$RUN/lock/pbo.cache" true 2>/dev/null || break; sleep 0.1; done
refused 69 'reads the cache (lock pbo.cache)' "a shared cache-lock holder (a restore or fetch)" -- "$B"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
# a process with a file open below the old cache, reached through a symlinked
# ancestor (/proc names the resolved path)
ln -s "$RUN/c" "$RUN/lnk"; mkcfg "$RUN/lnk/a"
( exec 3<"$A/repo/config"; exec sleep 30 ) & holder=$!
for _ in $(seq 50); do [[ -n "$(find "/proc/$holder/fd" -lname "$A/repo/config" -print -quit 2>/dev/null)" ]] && break; sleep 0.1; done
snapshot_state
out="$(P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[[ $rc == 69 ]] && grep -q "busy: process $holder has $A/repo/config open" <<<"$out" && same_state \
    && ok "a file open below the old cache, whose path goes through a symlinked ancestor: busy (69)" || bad "open below symlink: rc=$rc $(grep -E 'busy|refused' <<<"$out" | head -n 3)"
rm -f "$RUN/lnk"; mkcfg "$A"
: > "$A/spool/dump/vzdump-lxc-8001-2026_01_15-05_00_00.tar"
refused 69 'wait in the spool' "an archive in the spool" -- "$B"
rm -f "$A/spool/dump/vzdump-lxc-8001-2026_01_15-05_00_00.tar"
mkdir -p "$RUN/state/ingest-deferred"; : > "$RUN/state/ingest-deferred/vzdump-lxc-8001-2026_01_15-05_00_00.tar"
refused 69 'wait for their job' "a deferred stop-mode ingest record" -- "$B"
rm -rf "$RUN/state/ingest-deferred"
mkcfg "$A" "PBO_INTEGRATION=both"; storage "$A" ''
refused 69 'not restricted to this node (nodes: all)' "the pbo storage for every node (storage.cfg is cluster-wide)" -- "$B"
storage "$A" 'pve1,pve2'
# the hint must not tell a cluster to pin a shared storage to one node: that
# takes it from every other node (and their jobs and GUI restores)
refused 69 "not restricted to this node.*only if no other node uses it.*move this node to its own storage first" "the pbo storage on two nodes (the hint points a cluster to its own storage)" -- "$B"
# every failure at once
storage "$A" ''; exec 8>>"$RUN/lock/pbo.global"; flock -n 8; : > "$A/spool/dump/vzdump-lxc-8001-2026_01_15-05_00_00.tar"
snapshot_state
out="$(PBO_TEST_CM_FSTYPE=tmpfs P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
exec 8>&-; rm -f "$A/spool/dump/vzdump-lxc-8001-2026_01_15-05_00_00.tar"
[[ $rc == 69 ]] && grep -q 'not restricted' <<<"$out" && grep -q 'global lock' <<<"$out" && grep -q 'wait in the spool' <<<"$out" && grep -q 'tmpfs' <<<"$out" \
    && ok "all failures at once: storage, filesystem, lock and spool in one refusal" || bad "all at once: rc=$rc $out"
reset
out="$(P config set CACHE_DIR "$B" 2>&1 </dev/null)"; rc=$?
[[ $rc == 64 ]] && grep -q 'add --yes' <<<"$out" && [[ ! -e "$B" && "$(cfgval CACHE_DIR)" == "$A" ]] && ok "a cache with data and no --yes (not a terminal): 64, nothing changed" || bad "no yes: rc=$rc $out"

# --- the CTs: a 0700 parent, --fix-parents (as root: setpriv for real) ---------------------------------------
if (( have_setpriv )); then
    reset; ( umask 022; mkdir -p "$RUN/closed" ); chmod 0700 "$RUN/closed"
    refused 69 "setfacl -m u:$ctuid:x $RUN/closed" "a 0700 parent the unprivileged CT's root cannot pass (the exact setfacl line)" -- "$RUN/closed/b"
    out="$(P config set CACHE_DIR "$RUN/closed/b" --yes --fix-parents 2>&1)"; rc=$?
    [[ $rc == 0 && -f "$RUN/closed/b/repo/config" ]] && getfacl -cpn "$RUN/closed" 2>/dev/null | grep -q "^user:$ctuid:--x" \
        && [[ "$(stat -c %a "$RUN/closed")" == 710 || "$(stat -c %a "$RUN/closed")" == 700 ]] \
        && ( cd "$RUN" && setpriv --reuid "$ctuid" --regid "$ctuid" --clear-groups -- test -x closed/b ) \
        && ok "--fix-parents: a traverse-only entry u:$ctuid:--x on the parent, the move done, the CT root can reach the new cache" \
        || bad "fix-parents: rc=$rc $out $(getfacl -cpn "$RUN/closed" 2>&1 | tr '\n' ' ')"
else
    skip "a 0700 parent and --fix-parents (need root, setpriv and setfacl)"
fi

# --- an empty cache: the directory is only created -------------------------------------------------------------
reset; rm -rf "$A"; mkcfg "$A"; rm -rf "$A"
out="$(P config set CACHE_DIR "$B" 2>&1 </dev/null)"; rc=$?
[[ $rc == 0 && -d "$B" && "$(cfgval CACHE_DIR)" == "$B" && ! -e "$RUN/state/cache-move.json" ]] && grep -q 'the cache was empty' <<<"$out" \
    && ok "an empty install: the new directory is created, the config written, no move (no --yes needed, no journal)" || bad "empty: rc=$rc $out"

# --- the cache lock: a backup while a move holds it -----------------------------------------------------------
reset
exec 8>>"$RUN/lock/pbo.cache"; flock -n -x 8
out="$(P backup 8001 2>&1)"; rc=$?
out2="$(P fetch 8001 2026_01_15-05_00_00 2>&1)"; rc2=$?
exec 8>&-
[[ $rc == 75 ]] && grep -q 'being moved' <<<"$out" && ok "the cache lock held exclusive (a move): a backup exits 75 at once" || bad "cache lock backup: rc=$rc $out"
[[ $rc2 == 75 ]] && grep -q 'being moved' <<<"$out2" && ok "the cache lock held exclusive: a fetch exits 75 too" || bad "cache lock fetch: rc=$rc2 $out2"
: > "$A/spool/dump/vzdump-lxc-8001-2026_01_15-05_00_00.tar"
exec 8>>"$RUN/lock/pbo.cache"; flock -n -x 8
for c in "restore 8001 2026_01_15-05_00_00 --to 8101 --yes" "test-restore 8001" "backup-host" \
         "ingest --vmid 8001 --archive $A/spool/dump/vzdump-lxc-8001-2026_01_15-05_00_00.tar" "run-schedule --batch"; do
    read -r -a cargs <<<"$c"
    out="$(P "${cargs[@]}" 2>&1)"; rc=$?
    [[ $rc == 75 ]] && grep -q 'being moved' <<<"$out" && ok "the cache lock held exclusive: ${cargs[0]} exits 75" || bad "cache lock ${cargs[0]}: rc=$rc $(tail -n 2 <<<"$out")"
done
exec 8>&-
rm -f "$A/spool/dump/vzdump-lxc-8001-2026_01_15-05_00_00.tar"

# --- a backup queued behind the move restarts with the new config --------------------------------------------
reset; PD="$RUN/pause"; rm -rf "$PD"; mkdir -p "$PD"
TEST_PAUSE_DIR="$PD" P config set CACHE_DIR "$B" --yes > "$RUN/move.out" 2>&1 & mj=$!
paused=0; for _ in $(seq 100); do [[ -e "$PD/in" ]] && { paused=1; break; }; sleep 0.1; done
(( paused )) || bad "requeue setup: the move did not reach its pause within 10 s ($(tail -n 3 "$RUN/move.out"))"
if (( paused )); then
    # the move holds pbo.cache exclusive: a reader cannot take it shared, and
    # fetch and restore (no global lock) stop at it, not only at the journal
    held=0; exec 9>>"$RUN/lock/pbo.cache"; flock -n -s 9 || held=1; exec 9>&-
    (( held )) && ok "the paused move holds pbo.cache exclusive" || bad "the paused move does not hold pbo.cache exclusive"
    out="$(P fetch 8001 2026_01_15-05_00_00 2>&1)"; rc=$?
    [[ $rc == 75 ]] && grep -q 'being moved' <<<"$out" && ok "during the move a fetch exits 75 at the cache lock" || bad "fetch during move: rc=$rc $(tail -n 2 <<<"$out")"
    out="$(P restore 8001 2026_01_15-05_00_00 --to 8101 --yes 2>&1)"; rc=$?
    [[ $rc == 75 ]] && grep -q 'being moved' <<<"$out" && ok "during the move a restore exits 75 at the cache lock" || bad "restore during move: rc=$rc $(tail -n 2 <<<"$out")"
    ! flock -n "$RUN/lock/pbo.global" true || bad "requeue setup: the paused move does not hold the global lock"
fi
P backup --queue 8001 > "$RUN/queued.out" 2>&1 & bj=$!
queued=0
if (( paused )); then for _ in $(seq 150); do grep -q 'waiting for global lock' "$RUN/queued.out" 2>/dev/null && { queued=1; break; }; sleep 0.1; done; fi
(( !paused || queued )) || bad "requeue setup: the queued backup did not reach the global-lock wait within 15 s ($(tail -n 3 "$RUN/queued.out"))"
touch "$PD/go"; wait "$mj"; mrc=$?; wait "$bj"; brc=$?
if (( paused && queued )); then
    lastpath="$(RESTIC_PASSWORD_FILE="$RUN/pass" RESTIC_CACHE_DIR="$RUN/rcache" restic -r "$B/repo" snapshots --json 2>/dev/null | jq -r 'max_by(.time) | .paths[0]')"
    [[ $mrc == 0 && $brc == 0 && ! -e "$A" && "$lastpath" == "$B/8001" ]] && grep -q 'starting again with the new config' "$RUN/queued.out" \
        && ok "a backup queued behind the move (global lock) starts again with the new config and backs up below the new cache" \
        || bad "requeue: move rc=$mrc backup rc=$brc path=$lastpath $(tail -n 3 "$RUN/queued.out")"
fi

# a config with an mtime in the future (a restored file, a clock that went back)
# is no change: the run does not start again (it would, every time)
touch -d '+1 hour' "$CFG"
out="$(P backup --queue 8001 2>&1)"; rc=$?
touch "$CFG"
[[ $rc == 0 ]] && ! grep -q 'starting again' <<<"$out" && ok "a config dated in the future does not make a queued run start again" || bad "future mtime: rc=$rc $(tail -n 3 <<<"$out")"

# --- _restic_ensure: no empty repo at the old place, nor at a path the config no longer names -------------------
# (the move above is done: A is where the cache was)
sed "s|^CACHE_DIR=.*|CACHE_DIR=$A|" "$CFG" > "$RUN/etc/stale"; chmod 600 "$RUN/etc/stale"
out="$(env TEST_RUN="$RUN" TEST_NODE=pve1 PBO_CONFIG="$RUN/etc/stale" "$RUN/tree/pbo" init 2>&1)"; rc=$?
[[ $rc == 75 && ! -e "$A/repo" ]] && grep -q 'where the cache was before it moved' <<<"$out" && [[ ! -e "$A" ]] \
    && ok "_restic_ensure: a process with the config of before the move creates no repo at the old place (75), not even the directory" || bad "stale init: rc=$rc $out $(ls -d "$A" 2>&1)"
cat > "$RUN/lib-ensure.sh" <<EOF
source "$RUN/tree/pbo-lib"
set +e; PBO_ORIG_ARGS=(); load_config
printf '%s\n' "RESTIC_CACHE_REPO=$RUN/c/other/repo" >> "\$PBO_CONFIG"
_restic_ensure "\$RESTIC_CACHE_REPO"; echo "rc=\$? \$CM_INIT_MSG"
EOF
cp "$CFG" "$RUN/etc/config.lib"; sed -i "s|^CACHE_DIR=.*|CACHE_DIR=$RUN/c/fresh|" "$RUN/etc/config.lib"
out="$(env TEST_RUN="$RUN" TEST_NODE=pve1 PBO_CONFIG="$RUN/etc/config.lib" bash "$RUN/lib-ensure.sh" 2>&1)"
grep -q 'rc=4 the config no longer names' <<<"$out" && [[ ! -e "$RUN/c/fresh/repo/config" ]] \
    && ok "_restic_ensure: a repo the config no longer names (it changed after the start) is not created" || bad "ensure fresh: $out"

# --- a cache repo pinned outside the cache stays where it is: it may be created again -------------------
reset "RESTIC_CACHE_REPO=$RUN/pinned/repo"
out="$(P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc == 0 && "$(jget .state)" == "done" && "$(jget .keys.RESTIC_CACHE_REPO.how)" == stays ]] || bad "pinned repo move: rc=$rc $(tail -n 3 <<<"$out")"
out="$(P init 2>&1)"; rc=$?
[[ $rc == 0 && -f "$RUN/pinned/repo/config" ]] && ! grep -q 'where the cache was before it moved' <<<"$out" \
    && ok "RESTIC_CACHE_REPO pinned outside the cache (it stayed): init creates it after the move" || bad "pinned repo init: rc=$rc $(tail -n 3 <<<"$out")"

# --- an empty-cache change back to where a move came from ----------------------------------------------------
reset
out="$(P config set CACHE_DIR "$B" --yes 2>&1)"; rc=$?
[[ $rc == 0 && "$(jget .state)" == "done" && ! -e "$A" ]] || bad "move for the way back: rc=$rc $(tail -n 3 <<<"$out")"
find "$B" -mindepth 1 -delete
out="$(P config set CACHE_DIR "$A" 2>&1 </dev/null)"; rc=$?
[[ $rc == 0 && -d "$A" && "$(cfgval CACHE_DIR)" == "$A" ]] && grep -q 'the cache was empty' <<<"$out" \
    && [[ "$(jget .new)" == "$A" && "$(jget .old)" == "$B" && "$(jget .method)" == empty && "$(jget '.history[0].old')" == "$A" ]] \
    && ok "an empty cache set back to where a move came from: the journal records the change (the former place is the current one)" \
    || bad "empty back: rc=$rc new=$(jget .new) old=$(jget .old) $(tail -n 3 <<<"$out")"
out="$(P init 2>&1)"; rc=$?
[[ $rc == 0 && -f "$A/repo/config" ]] && ! grep -q 'where the cache was before it moved' <<<"$out" \
    && ok "... and init creates the cache repo there" || bad "init after back: rc=$rc $(tail -n 3 <<<"$out")"
rm -rf "$A"
out="$(P config get CACHE_DIR 2>&1)"; rc=$?
[[ $rc == 0 && -d "$A" ]] && ok "... and a pbo start makes the directory again (ensure_dirs)" || bad "ensure_dirs after back: rc=$rc $(ls "$RUN/c")"
sed "s|^CACHE_DIR=.*|CACHE_DIR=$B|" "$CFG" > "$RUN/etc/stale"; chmod 600 "$RUN/etc/stale"
out="$(env TEST_RUN="$RUN" TEST_NODE=pve1 PBO_CONFIG="$RUN/etc/stale" "$RUN/tree/pbo" init 2>&1)"; rc=$?
[[ $rc == 75 && ! -e "$B/repo" ]] && grep -q 'where the cache was before it moved' <<<"$out" \
    && ok "... while the emptied directory is now a place the cache left (no repo there)" || bad "stale init at B: rc=$rc $(tail -n 2 <<<"$out")"

# --- a scheduled test-restore whose config changes between guests -------------------------------------------
# each guest runs in a subshell: one that found the config changed must fail
# that guest alone, never exec a second run inside the first
reset; printf 'arch: amd64\nhostname: ct8002\nrootfs: teststore:8002/vm-8002-disk-0.raw,size=2G\n' > "$RUN/lxc/8002.conf"
sed -i 's/^BACKUP_ORDER=.*/BACKUP_ORDER="8001 8002"/' "$CFG"
out="$(P backup 8002 2>&1)" || bad "backup 8002: $(tail -n 3 <<<"$out")"
rm -f "$RUN/tr-touched"
out="$(TEST_TR_TOUCH_CONFIG=1 TR_PER_RUN=2 P --json test-restore --scheduled 2>"$RUN/tr.err")"; rc=$?
# the guests' subshells log to stdout (JSON_OUTPUT=0 there); the run's JSON is one line
ndoc="$(grep -c '^{' <<<"$out")"
[[ $rc != 0 && "$ndoc" == 1 && -e "$RUN/tr-touched" ]] && grep '^{' <<<"$out" | jq -e '(.tested | length) == 2 and (.failed | length) == 1 and .failed[0] == .tested[1]' >/dev/null \
    && [[ "$(grep -c 'test-restore --scheduled: testing vmid' "$RUN/tr.err")" == 2 ]] && ! grep -q 'starting again' "$RUN/tr.err" \
    && grep -q 'the config changed during this run; skipped' "$RUN/tr.err" \
    && ok "test-restore --scheduled, the config changed between guests: the second guest fails alone, one run, one JSON document" \
    || bad "tr nested: rc=$rc docs=$ndoc $(head -c 300 <<<"$out") $(grep -E 'testing vmid|starting again|changed' "$RUN/tr.err" | head -n 5)"
rm -f "$RUN/lxc/8002.conf"

# --- a config replaced by a rename with an older mtime: a queued run starts again -----------------------------
# (the writer's temp file is older than a process that read the config while
# a move ran, and some filesystems keep whole seconds: the inode tells)
reset
exec 8>>"$RUN/lock/pbo.global"; flock -n 8
# not with the test's lock fd: the backup would wait for a lock it holds itself
P backup --queue 8001 > "$RUN/queued.out" 2>&1 8>&- & bj=$!
queued=0; for _ in $(seq 150); do grep -q 'waiting for global lock' "$RUN/queued.out" 2>/dev/null && { queued=1; break; }; sleep 0.1; done
cp -p "$CFG" "$RUN/etc/.config.new"; touch -d '-1 hour' "$RUN/etc/.config.new"; mv -f "$RUN/etc/.config.new" "$CFG"
exec 8>&-; wait "$bj"; brc=$?
(( queued )) || bad "inode setup: the queued backup did not reach the global-lock wait within 15 s ($(tail -n 3 "$RUN/queued.out"))"
(( queued )) && { [[ $brc == 0 ]] && grep -q 'starting again with the new config' "$RUN/queued.out" \
    && ok "a config replaced by a rename with an older mtime: the queued backup starts again (the file's inode changed)" \
    || bad "inode: rc=$brc $(tail -n 3 "$RUN/queued.out")"; }

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ -n "${KEEP_RUN:-}" ]] || rm -rf "$RUN"
(( fail == 0 ))
