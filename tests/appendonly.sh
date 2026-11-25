#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
export PBO_JANITOR_ALLOW_ROOT=1   # the suite may run as root; one test below turns it off
# tests/appendonly.sh: append-only offsite + janitor role (ADR 0004). Real local
# restic repos stand in for cache and offsite; the rest-server is faked where
# the test is about what pbo sends (curl/restic argv and env), not about HTTP.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start) are the
# machine's own files: point them into the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.env" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
    PBO_PVE_CFS_DIR="$PWD/run-none/pve" PVE_STORAGE_CFG="$PWD/run-none/pve/storage.cfg"
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping append-only tests"; exit 0; }

printf 'pbo: append-only + janitor tests\n'
RUN="$ROOT/run-ao"; rm -rf "$RUN"
mkdir -p "$RUN"/{cache,state,log,lock,conf,bin,data}
export MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/calls"; : > "$MOCK_LOG"
# systemctl mocked too: prune/verify never reach the host's units (pbo-mount.service)
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm tests/mocks/systemctl "$RUN/bin/"
export PATH="$RUN/bin:$PATH"
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
R() { RESTIC_PASSWORD_FILE="$RUN/pass" RESTIC_CACHE_DIR="$RUN/rcache" restic -r "$1" "${@:2}"; }

base_cfg() {   # <file> <extra lines...>
    local f="$1"; shift
    { cat <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
BACKUP_ORDER=8001
RESTIC_CACHE_REPO=$RUN/cache-repo
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
KEEP_LOCAL=1
KEEP_OFFSITE_DAILY=1
KEEP_OFFSITE_WEEKLY=0
KEEP_OFFSITE_MONTHLY=0
EOF
      printf '%s\n' "$@"; } > "$f"
    chmod 600 "$f"
}
# three same-day snapshots of vmid 8001 in a repo
seed() {
    R "$1" init >/dev/null 2>&1
    echo x > "$RUN/data/f"
    for i in 1 2 3; do echo "$i" >> "$RUN/data/f"; R "$1" backup -q --tag "vmid=8001,ts=t$i" "$RUN/data" >/dev/null 2>&1; done
}
count() { R "$1" snapshots --json 2>/dev/null | jq length; }

# --- host, append-only: prune touches the cache only ---
seed "$RUN/cache-repo"; seed "$RUN/off-repo"
base_cfg "$RUN/host.cfg" "LOCAL_REPO=true" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/off-repo" "OFFSITE_APPEND_ONLY=true"
out="$(PBO_CONFIG="$RUN/host.cfg" $BIN --json prune 2>/dev/null)"
[[ "$(count "$RUN/cache-repo")" == 1 ]] && ok "append-only host: cache pruned (keep-last 1)" || bad "cache count $(count "$RUN/cache-repo")"
[[ "$(count "$RUN/off-repo")" == 3 ]] && ok "append-only host: offsite left alone" || bad "offsite count $(count "$RUN/off-repo")"
jq -e '.offsite_skipped=="append_only" and .ok==true' <<<"$out" >/dev/null && ok "prune envelope says offsite_skipped=append_only" || bad "envelope: $out"

# --- janitor: owns offsite retention ---
base_cfg "$RUN/jan.cfg" "PBO_ROLE=janitor" "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/off-repo"
PBO_CONFIG="$RUN/jan.cfg" $BIN --json prune >/dev/null 2>&1; rc=$?
[[ $rc == 0 && "$(count "$RUN/off-repo")" == 1 ]] && ok "janitor: GFS prune on the offsite repo" || bad "janitor prune rc=$rc count=$(count "$RUN/off-repo")"

# --- role checks ---
PBO_CONFIG="$RUN/jan.cfg" $BIN backup 8001 >/dev/null 2>&1; rc=$?
[[ $rc == 64 ]] && ok "janitor refuses guest commands (backup → EX_USAGE)" || bad "janitor backup rc=$rc"
PBO_CONFIG="$RUN/jan.cfg" $BIN restore 8001 t1 --to 9001 >/dev/null 2>&1; rc=$?
[[ $rc == 64 ]] && ok "janitor refuses restore" || bad "janitor restore rc=$rc"
base_cfg "$RUN/both.cfg" "PBO_ROLE=janitor" "OFFSITE_APPEND_ONLY=true" "LOCAL_REPO=false" "RESTIC_OFFSITE_REPO=$RUN/off-repo"
PBO_CONFIG="$RUN/both.cfg" $BIN doctor >/dev/null 2>&1; rc=$?
[[ $rc == 78 ]] && ok "janitor + OFFSITE_APPEND_ONLY=true is a config error" || bad "both roles rc=$rc"
base_cfg "$RUN/badrole.cfg" "PBO_ROLE=nonsense"
PBO_CONFIG="$RUN/badrole.cfg" $BIN status >/dev/null 2>&1; rc=$?
[[ $rc == 78 ]] && ok "unknown PBO_ROLE is a config error" || bad "bad role rc=$rc"

PBO_CONFIG="$RUN/does-not-exist" $BIN status >/dev/null 2>&1; rc=$?
[[ $rc == 78 ]] && ok "missing explicit PBO_CONFIG is a config error, not silent defaults" || bad "missing PBO_CONFIG rc=$rc"

# --- janitor started as root re-execs as JANITOR_USER (never writes as root) ---
if [[ "$(id -u)" == 0 ]]; then
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s"\n' "$RUN/runuser.argv" > "$RUN/bin/fake-runuser"; chmod 755 "$RUN/bin/fake-runuser"
    PBO_JANITOR_ALLOW_ROOT=0 PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" PBO_CONFIG="$RUN/jan.cfg" JANITOR_USER=nobody $BIN --json prune >/dev/null 2>&1
    grep -q -- "-u nobody -- .*/pbo --json prune" "$RUN/runuser.argv" 2>/dev/null \
        && ok "janitor as root re-execs as JANITOR_USER with the same args" || bad "re-exec argv: $(cat "$RUN/runuser.argv" 2>/dev/null)"
    PBO_JANITOR_ALLOW_ROOT=0 PBO_CONFIG="$RUN/jan.cfg" JANITOR_USER=root $BIN status >/dev/null 2>&1; rc=$?
    [[ $rc == 78 ]] && ok "JANITOR_USER=root is refused" || bad "root janitor user rc=$rc"
    # config check|set|unset are about /etc/pbo/config itself, which the janitor
    # user may read but not write: they stay root (set/unset arrive in 0.6 M4)
    rm -f "$RUN/runuser.argv"
    # (runuser is called, but only to ask whether the janitor user can read the file)
    out="$(PBO_JANITOR_ALLOW_ROOT=0 PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" PBO_CONFIG="$RUN/jan.cfg" JANITOR_USER=nobody $BIN config check 2>&1)"; rc=$?
    [[ $rc == 0 && "$(cat "$RUN/runuser.argv" 2>/dev/null)" == "-u nobody -- test -r $RUN/jan.cfg" && "$out" == *"pbo config check: 0 error(s)"* ]] \
        && ok "janitor as root: config check stays root (no re-exec), asks whether JANITOR_USER can read the file" || bad "config check re-exec: rc=$rc $(cat "$RUN/runuser.argv" 2>/dev/null) $out"
    # root writes nothing into the janitor user's LOG_DIR: not as the command
    # that stays root (its audit line, at exit), not before a die() on the way
    # to the re-exec. A file root made there would be root's (the janitor user
    # locked out of its own log), and one the janitor user planted could be a
    # symlink root follows.
    mkdir -p "$RUN/jlog"; chown nobody "$RUN/jlog"
    sed "s#^LOG_DIR=.*#LOG_DIR=$RUN/jlog#" "$RUN/jan.cfg" > "$RUN/jlog.cfg"; chmod 600 "$RUN/jlog.cfg"
    PBO_JANITOR_ALLOW_ROOT=0 PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" PBO_CONFIG="$RUN/jlog.cfg" JANITOR_USER=nobody $BIN config check >/dev/null 2>&1; rc=$?
    PBO_JANITOR_ALLOW_ROOT=0 PBO_CONFIG="$RUN/jlog.cfg" JANITOR_USER=pbo-no-such-user $BIN status >/dev/null 2>&1; rc2=$?
    PBO_JANITOR_ALLOW_ROOT=0 PBO_CONFIG="$RUN/jlog.cfg" JANITOR_USER=nobody PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" $BIN status >/dev/null 2>&1
    [[ $rc == 0 && $rc2 == 78 && -z "$(ls -A "$RUN/jlog")" ]] \
        && ok "janitor as root: no audit.jsonl, pbo.log or audit.log in the janitor user's LOG_DIR (config check, a die before the re-exec, the re-exec)" \
        || bad "root wrote into the janitor LOG_DIR: rc=$rc rc2=$rc2 $(ls -la "$RUN/jlog")"
    out="$(PBO_JANITOR_ALLOW_ROOT=0 PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" PBO_CONFIG="$RUN/jlog.cfg" JANITOR_USER=pbo-no-such-user $BIN config check 2>&1)"; rc=$?
    [[ $rc == 78 && "$out" == *"JANITOR_USER 'pbo-no-such-user' does not exist: every other janitor command stops on it"* && "$out" == *"pbo stops on this config"* ]] \
        && ok "janitor as root: config check names a JANITOR_USER that does not exist (78)" || bad "check missing janitor user: rc=$rc $out"
    PBO_JANITOR_ALLOW_ROOT=0 PBO_RUNUSER_BIN="$RUN/bin/fake-runuser" PBO_CONFIG="$RUN/jan.cfg" JANITOR_USER=nobody $BIN config get KEEP_LOCAL >/dev/null 2>&1
    grep -q -- "-u nobody -- .*/pbo config get KEEP_LOCAL" "$RUN/runuser.argv" 2>/dev/null && ok "... every other config subcommand re-execs as JANITOR_USER" || bad "config get re-exec: $(cat "$RUN/runuser.argv" 2>/dev/null)"
fi

# --- the janitor user reads the config again after the re-exec (real runuser) ---
# root loads the 0640 root:<group> config, drops to the janitor user, and that
# pbo reads the same file with the strict reader. A world-readable copy of the
# tree under /tmp (nobody cannot enter /root). LOCK_DIR is not in the config:
# its default (/run/pbo as root, STATE_DIR/lock otherwise) shows who answered.
if [[ "$(id -u)" == 0 ]] && id nobody >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
    jt="$(mktemp -d -p /tmp)"; chmod 0755 "$jt"; cp -a pbo lib "$jt/"; mkdir -p "$jt"/{cache,state,log}
    chown nobody "$jt"/{cache,state,log}
    printf 'PBO_ROLE=janitor\nJANITOR_USER=nobody\nLOCAL_REPO=false\nOFFSITE_ENABLED=true\nRESTIC_OFFSITE_REPO=%s/repo\nCACHE_DIR=%s/cache\nSTATE_DIR=%s/state\nLOG_DIR=%s/log\nKEEP_LOCAL=4\n' \
        "$jt" "$jt" "$jt" "$jt" > "$jt/config"
    chown root:"$(id -gn nobody)" "$jt/config"; chmod 0640 "$jt/config"; chmod -R a+rX "$jt/pbo" "$jt/lib"
    # root's own load (before the re-exec, and config check, which stays root)
    # runs ensure_dirs with the root default LOCK_DIR=/run/pbo: an empty
    # directory there is all it can leave, removed again if this made it
    had_rl=0; [[ -d /run/pbo ]] && had_rl=1
    out="$(cd /tmp && env -u PBO_TEST_CONFIG_LOG PBO_JANITOR_ALLOW_ROOT=0 PBO_CONFIG="$jt/config" "$jt/pbo" config get LOCK_DIR 2>&1)"; rc=$?
    out2="$(cd /tmp && env -u PBO_TEST_CONFIG_LOG PBO_JANITOR_ALLOW_ROOT=0 PBO_CONFIG="$jt/config" "$jt/pbo" config get KEEP_LOCAL 2>&1)"
    out3="$(cd /tmp && env -u PBO_TEST_CONFIG_LOG PBO_JANITOR_ALLOW_ROOT=0 PBO_CONFIG="$jt/config" "$jt/pbo" config check 2>&1)"; rc3=$?
    [[ $rc == 0 && "$out" == "$jt/state/lock" && "$out2" == 4 ]] && ok "janitor: root re-execs as JANITOR_USER, which reads the 0640 root:group config again" || bad "janitor re-read: rc=$rc [$out] [$out2]"
    [[ $rc3 == 0 && "$out3" == *"0 error(s)"* ]] && ok "janitor: config check as root: 0 errors when the janitor user can read the 0640 file" || bad "janitor check as root: rc=$rc3 $out3"
    # 0600 root:root (an editor, `install -m 0600`): root reads it, the janitor
    # user cannot, so every other janitor command stops (78). config check,
    # still root, says so; re-exec'd as nobody it would fail the read itself
    # ("cannot read the file" without the JANITOR_USER part).
    chmod 0600 "$jt/config"; chown root:root "$jt/config"
    out4="$(cd /tmp && env -u PBO_TEST_CONFIG_LOG PBO_JANITOR_ALLOW_ROOT=0 PBO_CONFIG="$jt/config" "$jt/pbo" config check 2>&1)"; rc4=$?
    out5="$(cd /tmp && env -u PBO_TEST_CONFIG_LOG PBO_JANITOR_ALLOW_ROOT=0 PBO_CONFIG="$jt/config" "$jt/pbo" status 2>&1)"; rc5=$?
    [[ $rc4 == 78 && "$out4" == *"$jt/config:0: error: JANITOR_USER nobody cannot read the file"* && "$out4" == *"pbo stops on this config"* \
       && "$out4" != *"valid bash"* && $rc5 == 78 ]] \
        && ok "janitor: config check stays root and names a 0600 file the janitor user cannot read (78, as every other command)" || bad "janitor 0600: rc=$rc4 $out4 / status rc=$rc5 $out5"
    rm -rf "$jt"
    (( had_rl )) || rmdir /run/pbo 2>/dev/null || true
fi

# --- janitor doctor: freshness per vmid seen in the repo, host-* ignored ---
R "$RUN/off-repo" backup -q --time "2020-01-01 00:00:00" --tag "vmid=8002,ts=old" "$RUN/data" >/dev/null 2>&1
R "$RUN/off-repo" backup -q --time "2020-01-01 00:00:00" --tag "vmid=host-pve1,type=host" "$RUN/data" >/dev/null 2>&1
out="$(PBO_CONFIG="$RUN/jan.cfg" $BIN doctor 2>&1)"
grep -q 'guest 8001 newest snapshot 0h old' <<<"$out" && ok "janitor doctor: fresh guest OK" || bad "janitor fresh: $out"
grep -qE 'FAIL.*guest 8002 newest snapshot.*stopped sending' <<<"$out" && ok "janitor doctor: a stale guest is a problem (its host stopped sending)" || bad "janitor stale: $out"
grep -q 'host-pve1' <<<"$out" && bad "janitor doctor: manual host backup should not be age-checked" || ok "janitor doctor: host-* backups not age-checked"
grep -q 'pbo-janitor.timer' <<<"$out" && ok "janitor doctor checks pbo-janitor.timer" || bad "janitor timer line"
if [[ "$(id -u)" == 0 ]] && id nobody >/dev/null 2>&1; then
    f="$(find "$RUN/off-repo/index" -type f | head -1)"; chown nobody "$f"
    out="$(PBO_CONFIG="$RUN/jan.cfg" $BIN doctor 2>&1)"
    grep -qE 'FAIL.*not owned by' <<<"$out" && ok "janitor doctor: foreign-owned repo file flagged" || bad "ownership: $out"
    chown "$(id -un)" "$f"
fi

# --- doctor probe: fake curl, the code it returns decides the verdict ---
# restic is faked too: a real one would retry an unreachable rest URL for minutes.
cat > "$RUN/bin/fake-restic" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_RESTIC_ARGV"
printf 'user=%s pass=%s\n' "${RESTIC_REST_USERNAME:-}" "${RESTIC_REST_PASSWORD:-}" >> "$MOCK_RESTIC_ENV"
echo '[]'
EOF
chmod 755 "$RUN/bin/fake-restic"
export MOCK_RESTIC_ARGV="$RUN/restic.argv" MOCK_RESTIC_ENV="$RUN/restic.env"
cat > "$RUN/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$MOCK_CURL_ARGV"
# only read stdin when pbo hands credentials that way (-K -); otherwise an open,
# silent stdin would block the mock forever
if [[ " $* " == *" -K - "* ]]; then cat > "$MOCK_CURL_STDIN"; else : > "$MOCK_CURL_STDIN"; fi
printf '%s' "${MOCK_CURL_CODE:-000}"
EOF
chmod 755 "$RUN/bin/curl"
export MOCK_CURL_ARGV="$RUN/curl.argv" MOCK_CURL_STDIN="$RUN/curl.stdin"
printf 'httpsecret\n' > "$RUN/rest-pass"; chmod 600 "$RUN/rest-pass"
base_cfg "$RUN/rest.cfg" "LOCAL_REPO=true" "OFFSITE_ENABLED=true" "OFFSITE_APPEND_ONLY=true" \
    "RESTIC_OFFSITE_REPO=rest:https://janitor.invalid:8000/pve1/pbo" \
    "RESTIC_REST_USERNAME=pve1" "RESTIC_REST_PASSWORD_FILE=$RUN/rest-pass" "RESTIC_CACERT=$RUN/ca.pem" \
    "RESTIC_BIN=$RUN/bin/fake-restic"
out="$(MOCK_CURL_CODE=403 PBO_CONFIG="$RUN/rest.cfg" $BIN doctor 2>&1)"
grep -q 'OK.*append-only enforced' <<<"$out" && ok "doctor: 403 → append-only enforced" || bad "probe 403: $out"
grep -q 'ransomware backstop' <<<"$out" && bad "doctor still nags about provider snapshots when append-only is verified" || ok "doctor: verified append-only counts as the backstop"
grep -q 'DELETE.*/pve1/pbo/keys/0000' "$RUN/curl.argv" && ok "probe DELETEs a nonexistent key under the repo" || bad "probe argv: $(cat "$RUN/curl.argv")"
grep -q -- "--cacert $RUN/ca.pem" "$RUN/curl.argv" && ok "probe pins the CA" || bad "probe cacert"
grep -q httpsecret "$RUN/curl.argv" && bad "HTTP password leaked into curl argv" || ok "HTTP password not on curl's command line"
grep -q 'pve1:httpsecret' "$RUN/curl.stdin" && ok "credentials passed to curl on stdin" || bad "curl stdin: $(cat "$RUN/curl.stdin")"
out="$(MOCK_CURL_CODE=200 PBO_CONFIG="$RUN/rest.cfg" $BIN doctor 2>&1)"; rc=$?
grep -q 'FAIL.*ACCEPTS deletes' <<<"$out" && [[ $rc != 0 ]] && ok "doctor: 200 → FAIL, not append-only" || bad "probe 200 rc=$rc: $out"
out="$(MOCK_CURL_CODE=401 PBO_CONFIG="$RUN/rest.cfg" $BIN doctor 2>&1)"
grep -q 'FAIL.*authentication failed' <<<"$out" && ok "doctor: 401 → auth failure" || bad "probe 401: $out"
base_cfg "$RUN/rest2.cfg" "LOCAL_REPO=true" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=rest:https://janitor.invalid:8000/pve1/pbo" "RESTIC_BIN=$RUN/bin/fake-restic"
out="$(MOCK_CURL_CODE=403 PBO_CONFIG="$RUN/rest2.cfg" $BIN doctor 2>&1)"
grep -q 'WARN.*OFFSITE_APPEND_ONLY=false' <<<"$out" && ok "doctor: append-only server but setting off → warn" || bad "unclaimed 403: $out"

# --- restic gets --cacert and the rest password via env, never argv ---
: > "$RUN/restic.argv"; : > "$RUN/restic.env"
PBO_CONFIG="$RUN/rest.cfg" $BIN --json list >/dev/null 2>&1
grep -q -- "--cacert $RUN/ca.pem" "$RUN/restic.argv" && ok "restic: --cacert passed" || bad "restic argv: $(cat "$RUN/restic.argv")"
grep -q 'sftp\.' "$RUN/restic.argv" && bad "sftp options sent to a rest repo" || ok "no sftp options on a rest repo"
grep -q httpsecret "$RUN/restic.argv" && bad "rest password in restic argv" || ok "rest password not in restic argv"
grep -q 'user=pve1 pass=httpsecret' "$RUN/restic.env" && ok "rest credentials reach restic via env" || bad "restic env: $(cat "$RUN/restic.env")"

# --- rotate-key leaves the old key on an append-only offsite, rotates the cache ---
R "$RUN/off2" init >/dev/null 2>&1
base_cfg "$RUN/rot.cfg" "LOCAL_REPO=true" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/off2" "OFFSITE_APPEND_ONLY=true"
cp "$RUN/pass" "$RUN/pass.orig"; printf 'newpass\n' > "$RUN/newpass"
out="$(PBO_CONFIG="$RUN/rot.cfg" $BIN --json rotate-key "$RUN/newpass" 2>"$RUN/rot.err")"
nk() { RESTIC_PASSWORD_FILE="$RUN/newpass" RESTIC_CACHE_DIR="$RUN/rcache" restic -r "$1" key list --json 2>/dev/null | jq length; }
[[ "$(nk "$RUN/cache-repo")" == 1 ]] && ok "rotate-key: cache has only the new key" || bad "cache keys $(nk "$RUN/cache-repo")"
[[ "$(nk "$RUN/off2")" == 2 ]] && ok "rotate-key: append-only offsite keeps the old key (removal is the janitor's)" || bad "offsite keys $(nk "$RUN/off2")"
jq -e '.offsite_old_key_pending|length>0' <<<"$out" >/dev/null && grep -q 'STILL VALID' "$RUN/rot.err" \
    && ok "rotate-key reports the pending old key" || bad "rotate pending: $out"

rm -rf "$RUN"
printf '%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
