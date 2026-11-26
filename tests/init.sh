#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/init.sh: `pbo init` and the probe of a repo it rests on (0.6.1).
#  - `pbo --dry-run init` writes nothing at all: pbo runs as a copy of the
#    entry point that sources tests/fixtures/run_dir_guard.sh with
#    TEST_GUARD_NO_WRITE=1, so any of pbo's writers (the directories, a repo
#    init, a lock, a log, audit or config write) stops it with 99, and the run
#    directory is compared file by file (name, size, mtime) before and after;
#  - the probe (_restic_probe, lib/restic.sh) tells a missing repo, an existing
#    one, a key that does not open it and a target it cannot check apart:
#    against REAL local restic repos (skipped without restic), and against a
#    stub that answers the way restic >= 0.17 does (exit 10/12) and the way
#    0.14 to 0.16 do (exit 1, the reason on stderr);
#  - `pbo init` itself keeps the 0.6 JSON (status, ok, engine).
# Every path pbo resolves lies in run-init/ (the guard stops it otherwise).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
skip() { printf '  SKIP %s\n' "$1"; }
command -v jq >/dev/null 2>&1 || { echo "jq not installed, skipping init tests"; exit 0; }

printf 'pbo: init tests\n'
RUN="$ROOT/run-init"; rm -rf "$RUN"
mkdir -p "$RUN"/{bin,tree,w,none}
for m in systemctl pvesh pvesm pct qm vzdump; do install -m 0755 "tests/mocks/$m" "$RUN/bin/"; done
# the copy of pbo with the guard; lib/ is the checkout's
{ sed '$d' pbo; printf '%s\n' 'source "$SELF_DIR/../../tests/fixtures/run_dir_guard.sh"'; tail -n 1 pbo; } > "$RUN/tree/pbo"
chmod 755 "$RUN/tree/pbo"; ln -s "$ROOT/lib" "$RUN/tree/lib"
BIN="$RUN/tree/pbo"
W="$RUN/w"   # the world pbo works in: nothing outside it may change
export PATH="$RUN/bin:$PATH" MOCK_LOG="$RUN/calls" TMPDIR="$RUN/none" HOME="$RUN/none" TEST_RUN="$RUN"
# the schema defaults that are the machine's own files: here, at paths nothing creates
export RESTIC_ENV_FILE="$RUN/none/restic.env" NTFY_CREDS_FILE="$RUN/none/ntfy.env" PBO_SYSTEMD_DIR="$RUN/none/systemd" \
    PBO_PVE_CFS_DIR="$RUN/none/pve" PVE_STORAGE_CFG="$RUN/none/pve/storage.cfg" PBO_PVE_TEMPLATE_DIR="$RUN/none/templates" \
    TEST_GUARD_CACHE_DEFAULT="$W/dcache"
: > "$MOCK_LOG"

# cfg <extra lines...>: the config, every path in $W (the directories do not
# exist: a dry run must not create them)
cfg() {
    printf '%s\n' "CACHE_DIR=$W/cache" "LOG_DIR=$W/log" "STATE_DIR=$W/state" "LOCK_DIR=$W/lock" \
        "RESTIC_PASSWORD_FILE=$W/pass" "RESTIC_CACHE_DIR=$W/rcache" "RESTIC_CACHE_REPO=$W/repo-cache" \
        "PBO_PVE_LXC_DIR=$W/lxc" "PBO_PVE_QEMU_DIR=$W/qemu" "PBO_CATALOG=$W/catalog.json" \
        "PVE_CATALOG_MOUNT_DIR=$W/mnt" "PBO_PERMS_CONFIG_DIR=$RUN" "NOTIFY_PVE=false" \
        "PVE_STORAGE_CFG=$RUN/none/storage.cfg" "PBO_PVE_STORAGE_CFG=$RUN/none/storage.cfg" "VZDUMP_CONF=$RUN/none/vzdump.conf" \
        "VZDUMP_LOCK=$RUN/none/vzdump.lock" "$@" > "$RUN/config"
    chmod 600 "$RUN/config"
}
export PBO_CONFIG="$RUN/config"
# P [args...]: the guarded pbo; output in $out, status in $rc
P() { out="$("$BIN" "$@" 2>&1)"; rc=$?; }
# PN: the same, with every writer of pbo stopping it (99)
PN() { out="$(TEST_GUARD_NO_WRITE=1 "$BIN" "$@" 2>&1)"; rc=$?; }
PNJ() { out="$(TEST_GUARD_NO_WRITE=1 "$BIN" --json "$@" 2>/dev/null)"; rc=$?; }   # stdout only: the JSON
snap() { find "$W" -printf '%p %y %s %T@\n' 2>/dev/null | sort; }
noguard() { [[ "$out" != *run_dir_guard* ]]; }

# --- the harness: the no-write guard catches a write --------------------------
cfg "RESTIC_OFFSITE_REPO=$W/repo-off"
printf 'k1\n' > "$W/pass"; chmod 600 "$W/pass"
PN version
[[ $rc == 99 && "$out" == *"run_dir_guard: ensure_dirs"* ]] && ok "harness: with TEST_GUARD_NO_WRITE a command that makes its directories stops (99)" \
    || bad "harness: rc=$rc $out"

# --- the stub restic: restic >= 0.17 (exit 10/12) and 0.14-0.16 (exit 1 + stderr)
# STUB_STYLE=new|old, STUB_STATE=absent|exists|wrongkey|down|denied|stale|other;
# every call is logged (STUB_LOG) with its arguments
cat > "$RUN/bin/restic-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_LOG:-/dev/null}"
for a; do [[ "$a" == version ]] && { echo "restic ${STUB_VERSION:-0.18.0} compiled with go1.24 on linux/amd64"; exit 0; }; done
case " $* " in *" cat config "*) ;; *) echo "stub: unexpected call: $*" >&2; exit 3 ;; esac
loc=''; while [ $# -gt 0 ]; do [ "$1" = -r ] && { loc="$2"; break; }; shift; done
case "${STUB_STATE:-absent}:${STUB_STYLE:-new}" in
    absent:new) printf 'Fatal: repository does not exist: unable to open config file: stat %s/config: no such file or directory\nIs there a repository at the following location?\n%s\n' "$loc" "$loc" >&2; exit 10 ;;
    # 0.14-0.16: each backend's own not-exist error
    absent:old) case "$loc" in
                    rest:*) printf 'Fatal: unable to open config file: <config/> does not exist\nIs there a repository at the following location?\n%s\n' "$loc" >&2 ;;
                    sftp:*) printf 'Fatal: unable to open config file: Lstat: file does not exist\nIs there a repository at the following location?\n%s\n' "$loc" >&2 ;;
                    *) printf 'Fatal: unable to open config file: Stat: stat %s/config: no such file or directory\nIs there a repository at the following location?\n%s\n' "$loc" "$loc" >&2 ;;
                esac; exit 1 ;;
    wrongkey:new) echo 'Fatal: wrong password or no key found' >&2; exit 12 ;;
    wrongkey:old) echo 'Fatal: wrong password or no key found' >&2; exit 1 ;;
    exists:*) echo '{"version":2}'; exit 0 ;;
    down:*) echo "Fatal: unable to open repository at $loc: dial tcp 192.0.2.5:22: connect: connection refused" >&2; exit 1 ;;
    denied:*) printf 'Fatal: unable to open config file: Stat: stat %s/config: permission denied\nIs there a repository at the following location?\n' "$loc" >&2; exit 1 ;;
    stale:*) printf 'Fatal: unable to open config file: Stat: stat %s/config: stale file handle\nIs there a repository at the following location?\n' "$loc" >&2; exit 1 ;;
    other:*) echo "Fatal: unable to open repository at $loc: an error the probe does not know" >&2; exit 1 ;;
esac
exit 1
EOF
chmod 755 "$RUN/bin/restic-stub"
export STUB_LOG="$RUN/stub.log"
# curl: the probe's HEAD of a rest-server's config; answers STUB_HTTP (000: no
# answer), logs its arguments and what it got on stdin (-K -: the login)
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$CURL_LOG"' \
    'case " $* " in *" -K - "*) cat >> "$CURL_LOG" ;; esac' \
    'printf "%s" "${STUB_HTTP:-000}"; [ "${STUB_HTTP:-000}" != 000 ]' > "$RUN/bin/curl"
chmod 755 "$RUN/bin/curl"
export CURL_LOG="$RUN/curl.log"
# ST <state> <style> <offsite repo> [cfg lines...]: --dry-run --json init against the stub
ST() {
    local state="$1" style="$2" repo="$3"; shift 3
    cfg "RESTIC_BIN=$RUN/bin/restic-stub" "LOCAL_REPO=false" "RESTIC_OFFSITE_REPO=$repo" "$@"
    : > "$STUB_LOG"
    out="$(STUB_STATE="$state" STUB_STYLE="$style" TEST_GUARD_NO_WRITE=1 "$BIN" --json --dry-run init 2>/dev/null)"; rc=$?
    st="$(jq -r '.repos[0].state // "none"' <<<"$out" 2>/dev/null)"
}
res=''
for c in "absent new sftp:u@backup.example:pbo absent 0" "absent old sftp:u@backup.example:pbo absent 0" \
         "wrongkey new sftp:u@backup.example:pbo wrongkey 78" "wrongkey old sftp:u@backup.example:pbo wrongkey 78" \
         "absent old rest:https://rest.example:8000/u/pbo absent 0" \
         "exists new sftp:u@backup.example:pbo exists 0" "exists old rest:https://rest.example:8000/u/pbo exists 0" \
         "down new sftp:u@backup.example:pbo unknown 69" "down old sftp:u@backup.example:pbo unknown 69" \
         "denied old sftp:u@backup.example:pbo unknown 69"; do
    read -r s y r want wrc <<<"$c"
    ST "$s" "$y" "$r"
    [[ "$st" == "$want" && "$rc" == "$wrc" ]] || res+="$s/$y: state=$st rc=$rc (want $want/$wrc) $out; "
done
[[ -z "$res" ]] && ok "probe (stub): restic >= 0.17's exit 10/12 and 0.14-0.16's messages (each backend's not-exist error: directory, SFTP, rest-server) give absent, exists, wrongkey; an unreachable target or another error is unknown (69)" \
    || bad "probe stub: $res"
[[ ! -s "$CURL_LOG" ]] && ok "probe (stub): no rest-server is asked itself where restic's answer decides" || bad "probe curl: $(cat "$CURL_LOG")"
# a directory repo the message does not decide: its config file does, but
# only on a real ENOENT
mkdir -p "$W/dir-repo"
ST other old "$W/dir-repo"
[[ "$st" == absent && $rc == 0 ]] && ok "probe (stub): a readable directory without a config file is absent when restic's error is no access error" || bad "probe dir fallback: $st rc=$rc $out"
ST other old "$W/dir-repo/new/repo"
[[ "$st" == absent && $rc == 0 && ! -e "$W/dir-repo/new" ]] && ok "probe (stub): ... as is a repo directory not made yet below a readable one" || bad "probe dir missing: $st rc=$rc $out"
res=''
for s in denied stale; do
    ST "$s" old "$W/dir-repo"
    [[ "$st" == unknown && $rc == 69 && "$out" == *"$s"* ]] || res+="$s: state=$st rc=$rc $out; "
done
[[ -z "$res" ]] && ok "probe (stub): restic's 'permission denied' or 'stale file handle' for a directory without a config file is unknown (69), not absent (NFS root_squash, a stale handle)" \
    || bad "probe dir access error: $res"
: > "$W/dir-repo/config"
ST other old "$W/dir-repo"
[[ "$st" == unknown && $rc == 69 ]] && ok "probe (stub): ... and one with a config file is not guessed (unknown)" || bad "probe dir config: $st rc=$rc"
rm -rf "$W/dir-repo"
# a rest-server where restic's answer decides nothing: the server itself is
# asked (HEAD <url>/config), with the login on curl's stdin only
RREPO=rest:https://rest.example:8000/u/pbo
printf 'rest-pw-1\n' > "$RUN/rest-pass"; chmod 600 "$RUN/rest-pass"
: > "$CURL_LOG"
STUB_HTTP=404 ST down old "$RREPO" "RESTIC_REST_USERNAME=u1" "RESTIC_REST_PASSWORD_FILE=$RUN/rest-pass"
[[ "$st" == absent && $rc == 0 ]] && grep -q -- '-I .*-K - https://rest.example:8000/u/pbo/config$' "$CURL_LOG" \
   && grep -qx 'user = "u1:rest-pw-1"' "$CURL_LOG" && ! grep -v '^user = ' "$CURL_LOG" | grep -q rest-pw-1 \
    && ok "probe (stub): restic's error decides nothing on a rest-server: a 404 for <url>/config is absent (the login on curl's stdin, never its arguments)" \
    || bad "probe rest head: $st rc=$rc $out $(cat "$CURL_LOG")"
res=''
for h in 200 401 000; do
    STUB_HTTP=$h ST down old "$RREPO"
    [[ "$st" == unknown && $rc == 69 && "$(jq -r .repos[0].action <<<"$out")" == *"connection refused"* ]] || res+="$h: state=$st rc=$rc $out; "
done
[[ -z "$res" ]] && ok "probe (stub): ... any other answer (200, 401, none) leaves it unknown, with restic's message" || bad "probe rest head other: $res"
: > "$CURL_LOG"
STUB_HTTP=404 ST down old 'rest:https://u2:p%40ss@rest.example:8000/u/pbo'
[[ "$st" == absent ]] && grep -qx 'user = "u2:p@ss"' "$CURL_LOG" && ! grep -v '^user = ' "$CURL_LOG" | grep -q 'p%40ss\|u2' \
    && ok "probe (stub): ... a login in the URL is decoded and handed over the same way (the URL curl gets has none)" || bad "probe rest url login: $st $(cat "$CURL_LOG")"
# restic 0.14 to 0.16 retry the 404 until the probe's timeout: the server is
# asked first, and restic not run when it says 404
: > "$CURL_LOG"
STUB_VERSION=0.16.4 STUB_HTTP=404 ST absent old "$RREPO"
[[ "$st" == absent && $rc == 0 && -s "$CURL_LOG" ]] && ! grep -q 'cat config' "$STUB_LOG" \
    && ok "probe (stub, restic 0.16): a rest-server without the repo is absent from its own 404, restic's retries never waited for" || bad "probe rest old first: $st rc=$rc $(cat "$STUB_LOG")"
STUB_VERSION=0.16.4 STUB_HTTP=200 ST exists old "$RREPO"
[[ "$st" == exists && $rc == 0 ]] && grep -q 'cat config' "$STUB_LOG" && ok "probe (stub, restic 0.16): ... any other answer: restic decides as before" || bad "probe rest old 200: $st rc=$rc"
# what the plan says for it, as the operator sees it
cfg "RESTIC_BIN=$RUN/bin/restic-stub" "LOCAL_REPO=false" "RESTIC_OFFSITE_REPO=$RREPO"
out="$(STUB_VERSION=0.16.4 STUB_STATE=absent STUB_STYLE=old TEST_GUARD_NO_WRITE=1 "$BIN" --dry-run init 2>&1)"; rc=$?
[[ $rc == 0 && "$out" == *"offsite repo $RREPO: would be created (restic init)"* ]] && noguard \
    && ok "dry-run init (restic 0.16, rest-server, no repo yet): 'would be created', exit 0" || bad "dry-run rest old: rc=$rc $out"
ST absent new sftp:u@backup.example:pbo
grep -q -- '--no-lock --no-cache cat config' "$STUB_LOG" && ! grep -qw init "$STUB_LOG" \
    && ok "probe: read only (cat config with --no-lock and --no-cache), never an init" || bad "probe calls: $(cat "$STUB_LOG")"
# without a key file: the throwaway key opens nothing, a repo there is still "exists"
rm -f "$W/pass"
ST wrongkey new sftp:u@backup.example:pbo
[[ "$st" == exists && $rc == 78 && "$(jq -r .dr_key <<<"$out")" == false ]] \
    && ok "probe without a DR key: a repo that refuses the throwaway key exists; the plan stops with 78 as init would" || bad "probe no key: $st rc=$rc $out"
printf 'k1\n' > "$W/pass"; chmod 600 "$W/pass"

# --- real restic: local repos ----------------------------------------------------
if command -v restic >/dev/null 2>&1; then
    cfg "RESTIC_OFFSITE_REPO=$W/repo-off"
    rm -rf "$W"/{cache,log,state,lock,rcache,repo-cache,repo-off}
    s0="$(snap)"
    PN --dry-run init
    [[ $rc == 0 && "$out" == *"cache repo $W/repo-cache: would be created (restic init)"* \
       && "$out" == *"offsite repo $W/repo-off: would be created (restic init --copy-chunker-params --from-repo $W/repo-cache)"* ]] && noguard \
        && ok "dry-run init: no repos yet: each one 'would be created', with the init it would run" || bad "dry-run absent: rc=$rc $out"
    [[ "$(snap)" == "$s0" && ! -e "$W/state" && ! -e "$W/log" && ! -e "$W/lock" && ! -e "$W/cache" && ! -e "$W/rcache" ]] \
        && ok "dry-run init writes nothing: no repo, no STATE/LOG/LOCK/CACHE directory, no restic cache, no log line (the run directory unchanged)" \
        || bad "dry-run wrote: $(diff <(printf '%s\n' "$s0") <(snap))"
    PNJ --dry-run init
    [[ $rc == 0 && "$(jq -r '[.status, .ok, .engine, .dry_run, ([.repos[].state] | join(","))] | join(" ")' <<<"$out")" == "dry_run true restic true absent,absent" ]] \
        && [[ "$(snap)" == "$s0" ]] && ok "dry-run init --json: status dry_run, engine restic, a state per repo, nothing written (no JSON marker file either)" \
        || bad "dry-run json: rc=$rc $out"
    # the real init, then the probe sees both repos
    P init
    P --json init
    [[ $rc == 0 && "$(jq -c '{status, ok, engine}' <<<"$out")" == '{"status":"ok","ok":true,"engine":"restic"}' && -e "$W/repo-cache/config" && -e "$W/repo-off/config" ]] \
        && ok "init: creates both repos, the 0.6 JSON (status, ok, engine) unchanged" || bad "init: rc=$rc $out"
    s1="$(snap)"
    PNJ --dry-run init
    [[ $rc == 0 && "$(jq -r '[.repos[].state] | join(",")' <<<"$out")" == exists,exists && "$(snap)" == "$s1" ]] \
        && ok "probe (restic $(restic version | awk '{print $2}')): existing local repos the key opens: exists, both repo directories untouched" \
        || bad "dry-run exists: rc=$rc $out $(diff <(printf '%s\n' "$s1") <(snap))"
    printf 'another key\n' > "$W/pass"
    s1="$(snap)"
    PNJ --dry-run init
    [[ $rc == 78 && "$(jq -r '[.status, .ok, ([.repos[].state] | join(","))] | join(" ")' <<<"$out")" == "failed false wrongkey,wrongkey" && "$(snap)" == "$s1" ]] \
        && ok "probe (restic): a key that does not open them: wrongkey, the plan says init would fail (78)" || bad "dry-run wrong key: rc=$rc $out"
    rm -f "$W/pass"
    PNJ --dry-run init
    [[ $rc == 78 && "$(jq -r '[.repos[].state] | join(",")' <<<"$out")" == exists,exists ]] \
        && ok "probe (restic) without a key file: the repos exist (the throwaway key never opens one)" || bad "dry-run no key: rc=$rc $out"
    printf 'k1\n' > "$W/pass"; chmod 600 "$W/pass"
    mkdir -p "$W/empty-repo"
    cfg "RESTIC_OFFSITE_REPO=$W/empty-repo" "LOCAL_REPO=false"
    PNJ --dry-run init
    [[ $rc == 0 && "$(jq -r '.repos[0].state' <<<"$out")" == absent && -z "$(ls -A "$W/empty-repo")" ]] \
        && ok "probe (restic): an empty directory is no repo (absent), and stays empty" || bad "dry-run empty: rc=$rc $out"
else
    skip "the probe against real restic repos (restic is not installed)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
