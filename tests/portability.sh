#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/portability.sh: what differs between installations (ADR 0009,
# "Portability"). RESTIC_ENV_FILE (read with the config grammar, exported to
# restic only, refused when others can read it, never shown), `pbo catalog
# _umount` with a mount point of its own, every systemd unit in both install
# layouts (install.sh's /usr/local/lib/pbo, the .deb's /usr/lib/pbo),
# RESTIC_MIN in doctor and install.sh, the thresholds that became config keys,
# the acl/util-linux dependencies, timestamps under three time zones (vzdump
# archive names, the catalogue's ctime, the timers' next run, retention's day
# buckets), _ct_root_uid with custom idmaps (and without: 100000), and `doctor
# --report` (no secret, URL, host name or path in it). restic is a fake
# script except for the retention buckets (a real local repo). Nothing outside
# run-portability/ is touched.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start),
# PBO_PVE_LXC_DIR and PBO_PVE_QEMU_DIR (a guest's current name, read for a
# snapshot that records none) are the machine's own files: point them into
# the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.env" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
    PBO_PVE_CFS_DIR="$PWD/run-none/pve" PVE_STORAGE_CFG="$PWD/run-none/pve/storage.cfg" \
    PBO_PVE_LXC_DIR="$PWD/run-none/pve/lxc" PBO_PVE_QEMU_DIR="$PWD/run-none/pve/qemu-server"
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
skip() { printf '  SKIP %s\n' "$1"; }
command -v jq >/dev/null 2>&1 || { echo "jq not installed, skipping portability tests"; exit 0; }

printf 'pbo: portability tests\n'
RUN="$ROOT/run-portability"; rm -rf "$RUN"
mkdir -p "$RUN"/{bin,cache,state,log,lock,conf,lxc,tmp,mnt}
export TMPDIR="$RUN/tmp"
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm tests/mocks/dpkg-query "$RUN/bin/"
export PATH="$RUN/bin:$PATH" MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/calls"; : > "$MOCK_LOG"
chmod 0700 "$RUN/mnt"
is_root=0; [[ "$(id -u)" == 0 ]] && is_root=1

# systemctl: the usual mock, and the environment of each call recorded (the
# programs pbo runs must never see RESTIC_ENV_FILE's variables). `show` answers
# the timer properties from MOCK_SHOW_<PROPERTY> (pbo timers).
cat > "$RUN/bin/systemctl" <<EOF
#!/usr/bin/env bash
env | grep -E '^(AWS_|B2_|XPROBE_|REFV=)' >> "$RUN/child-env.log"
if [[ "\${1:-}" == show ]]; then
    p=''; for a; do case "\$a" in -p) ;; NextElapseUSecRealtime|LastTriggerUSec|LoadState|UnitFileState|ActiveState|TimersCalendar) p="\$a" ;; esac; done
    case "\$p" in
        NextElapseUSecRealtime) printf '%s\n' "\${MOCK_SHOW_NEXT:-}" ;;
        LoadState) echo loaded ;;
        UnitFileState) echo enabled ;;
        TimersCalendar) echo '{ OnCalendar=*-*-* 05:00:00 ; next_elapse=x }' ;;
    esac
    exit 0
fi
exec "$ROOT/tests/mocks/systemctl" "\$@"
EOF
chmod 0755 "$RUN/bin/systemctl"; : > "$RUN/child-env.log"

# the fake restic: its version from FAKE_RESTIC_VERSION, `snapshots --json`
# from FAKE_SNAPS, `forget --json` from FAKE_FORGET, every other call succeeds. Each call appends its first
# arguments and the backend variables it was given to FAKE_ENV_LOG.
cat > "$RUN/bin/restic-fake" <<'EOF'
#!/usr/bin/env bash
{ printf 'CALL %s\n' "$*"; env | grep -E '^(AWS_|B2_|XPROBE_|REFV=|RESTIC_REST_PASSWORD=)' | sort; } >> "${FAKE_ENV_LOG:-/dev/null}"
for a; do
    case "$a" in
        version) echo "restic ${FAKE_RESTIC_VERSION:-0.18.0} compiled with go1.24 on linux/amd64"; exit 0 ;;
        --help) echo "      --retry-lock duration   retry to lock the repository"; exit 0 ;;
    esac
done
case " $* " in
    *" snapshots "*) if [[ -n "${FAKE_SNAPS:-}" ]]; then cat "$FAKE_SNAPS"; else echo '[]'; fi ;;
    *" forget "*) if [[ -n "${FAKE_FORGET:-}" ]]; then cat "$FAKE_FORGET"; else echo '[]'; fi ;;
esac
exit 0
EOF
chmod 0755 "$RUN/bin/restic-fake"
export FAKE_ENV_LOG="$RUN/restic-env.log"; : > "$FAKE_ENV_LOG"
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"

CFG="$RUN/config"
cfg() {   # cfg <extra lines...>: the suite's config
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
PBO_PVE_LXC_DIR=$RUN/lxc
PBO_PERMS_PARENTS_TOP=$RUN
PBO_PERMS_CONFIG_DIR=$RUN
PVE_CATALOG_MOUNT_DIR=$RUN/mnt/restic
PBO_CATALOG=$RUN/state/catalog/index.json
PBO_PVE_CFS_DIR=$RUN/pve
EOF
      printf '%s\n' "$@"; } > "$CFG"; chmod 600 "$CFG"
}
export PBO_CONFIG="$CFG"

# ============================================================================
# RESTIC_ENV_FILE
# ============================================================================
ENVF="$RUN/restic.env"
cfg "RESTIC_ENV_FILE=$ENVF"
cat > "$ENVF" <<'EOF'
# backend credentials, KEY=VALUE as in the config
AWS_ACCESS_KEY_ID=AKIDPORTABILITYTEST
AWS_SECRET_ACCESS_KEY="s3cr3t value/with+chars"
export B2_ACCOUNT_ID='b2-id-1234'
XPROBE_TOKEN=tok-9f8e7d
REFV=${XPROBE_TOKEN}-ref
EOF
chmod 600 "$ENVF"
: > "$FAKE_ENV_LOG"; : > "$RUN/child-env.log"
out="$($BIN --json list 2>&1)"; rc=$?
calls="$(cat "$FAKE_ENV_LOG")"
snapenv="$(awk '/^CALL .* snapshots/{f=1; next} /^CALL/{f=0} f' "$FAKE_ENV_LOG")"
[[ $rc == 0 && "$snapenv" == *"AWS_ACCESS_KEY_ID=AKIDPORTABILITYTEST"* && "$snapenv" == *"AWS_SECRET_ACCESS_KEY=s3cr3t value/with+chars"* \
   && "$snapenv" == *"B2_ACCOUNT_ID=b2-id-1234"* && "$snapenv" == *"REFV=tok-9f8e7d-ref"* ]] \
    && ok "RESTIC_ENV_FILE: its variables reach restic (quotes, export and \${KEY} references read as the config grammar does)" || bad "env to restic: rc=$rc $out / $calls"
# commands that really run `restic version` (pbo version, doctor) and `restic
# --help` (a write path asks it for --retry-lock): those calls must be in the
# log, without any of the file's variables
: > "$FAKE_ENV_LOG"; $BIN version >/dev/null 2>&1; $BIN doctor >/dev/null 2>&1
bash -c 'set -u; source lib/common.sh; source lib/config_schema.sh; source lib/restic.sh; load_config; _restic_has_retry_lock' >/dev/null 2>&1
vlog="$(cat "$FAKE_ENV_LOG")"
verenv="$(awk '/^CALL (version|--help)/{f=1; next} /^CALL/{f=0} f' "$FAKE_ENV_LOG")"
[[ "$vlog" == *"CALL version"* && "$vlog" == *"CALL --help"* && -z "$verenv" ]] && ok "RESTIC_ENV_FILE: restic version/--help (no repo) get none of them" \
    || bad "env to restic version/--help: ${verenv:-no CALL version and CALL --help in the log: $vlog}"
: > "$RUN/child-env.log"
out="$($BIN doctor 2>&1)"
[[ ! -s "$RUN/child-env.log" ]] && ok "RESTIC_ENV_FILE: the other programs pbo runs (systemctl) see none of them" || bad "env leaked to a child: $(cat "$RUN/child-env.log")"
[[ "$out" == *"OK  RESTIC_ENV_FILE $ENVF: 5 variable(s) for restic only (AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY B2_ACCOUNT_ID XPROBE_TOKEN REFV)"* ]] \
    && ok "doctor: names the file and its keys" || bad "doctor env line: $(grep -i env <<<"$out")"
out2="$($BIN config list 2>&1)"; js="$($BIN --json config show 2>/dev/null)"
[[ "$out2" == *"RESTIC_ENV_FILE $ENVF: 5 variable(s) for restic only (AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY B2_ACCOUNT_ID XPROBE_TOKEN REFV)"* \
   && "$(jq -c '.restic_env | [.present, (.variables | length), .errors]' <<<"$js")" == '[true,5,0]' ]] \
    && ok "config list and config show --json: the file and its variable names" || bad "config env: $(tail -2 <<<"$out2") / $(jq -c .restic_env <<<"$js")"
all="$out$($BIN config list 2>&1)$($BIN --json config show 2>&1)$($BIN config check 2>&1)$($BIN --json doctor 2>&1)$($BIN doctor --report 2>&1)"
leak=""; for v in AKIDPORTABILITYTEST 's3cr3t value' b2-id-1234 tok-9f8e7d; do [[ "$all" == *"$v"* ]] && leak+="$v "; done
[[ -z "$leak" ]] && ok "doctor, config list/show/check and the report never show a value of the file" || bad "values shown: $leak"
# in pbo's own shell: not even as a variable after load_config
out="$(bash -c 'set -u; source lib/common.sh; source lib/config_schema.sh; source lib/restic.sh; load_config; env | grep -c "AWS_\|XPROBE_" ; declare -p _RENV_VAL 2>/dev/null' 2>&1)"
[[ "$out" == "0"*'declare -A _RENV_VAL=()' ]] && ok "load_config keeps only the key names (no value in pbo's shell, nothing exported)" || bad "pbo shell: $out"

# refusals: like the config file (owner and mode), tighter for a secret
chmod 644 "$ENVF"; : > "$FAKE_ENV_LOG"
out="$($BIN list 2>&1)"; rc=$?
[[ $rc == 78 && "$out" == *"REFUSING a restic environment file with mode 0644"* && ! -s "$FAKE_ENV_LOG" ]] \
    && ok "RESTIC_ENV_FILE readable by others: every restic command stops (78), restic never runs" || bad "0644: rc=$rc $out / $(cat "$FAKE_ENV_LOG")"
out="$($BIN doctor 2>&1)"; rc=$?
[[ $rc == 69 && "$out" == *"FAIL  RESTIC_ENV_FILE $ENVF:0: REFUSING"* ]] && ok "doctor runs and says FAIL" || bad "doctor 0644: rc=$rc $(grep -i env <<<"$out")"
out="$($BIN config check 2>&1)"; rc=$?
[[ $rc == 78 && "$out" == *"$ENVF:0: error: REFUSING"* ]] && ok "config check lists it as an error (78)" || bad "check 0644: rc=$rc $out"
out="$($BIN --json config check 2>/dev/null)"
[[ "$(jq -r --arg f "$ENVF" '.files[] | select(.file == $f) | .errors[0].message' <<<"$out")" == REFUSING* ]] && ok "config check --json: the file has its own entry" || bad "check json: $out"
chmod 660 "$ENVF"; out="$($BIN list 2>&1)"; rc=$?
[[ $rc == 78 && "$out" == *"mode 0660"* ]] && ok "group-writable: refused" || bad "0660: rc=$rc $out"
chmod 640 "$ENVF"; out="$($BIN --json list 2>&1)"; rc=$?
[[ $rc == 0 ]] && ok "group-readable 0640 is read (doctor --fix closes it to 0600)" || bad "0640: rc=$rc $out"
out="$($BIN doctor 2>&1)"
[[ "$out" == *"$ENVF"*"0640"*"0600"* || "$out" == *"RESTIC_ENV_FILE"*"0640"* ]] && ok "doctor: the permission table names 0640 (fixable)" || bad "perms 0640: $(grep -n "$ENVF" <<<"$out")"
chmod 600 "$ENVF"
ln -s "$ENVF" "$RUN/env-link"; cfg "RESTIC_ENV_FILE=$RUN/env-link"
out="$($BIN list 2>&1)"; rc=$?
[[ $rc == 78 && "$out" == *"a symlink"* ]] && ok "a symlink: refused" || bad "symlink: rc=$rc $out"
if (( is_root )) && id nobody >/dev/null 2>&1; then
    cp -p "$ENVF" "$RUN/env-nobody"; chown nobody "$RUN/env-nobody"; cfg "RESTIC_ENV_FILE=$RUN/env-nobody"
    out="$($BIN list 2>&1)"; rc=$?
    [[ $rc == 78 && "$out" == *"owned by uid $(id -u nobody)"* ]] && ok "owned by another user: refused" || bad "owner: rc=$rc $out"
else
    skip "owner refusal (needs root)"
fi
for bodyline in 'PATH=/tmp/evil' 'LD_PRELOAD=/x.so' 'RESTIC_PASSWORD_FILE=/x' 'RESTIC_REPOSITORY=s3:x/y' 'RESTIC_HOST=pve1' \
                'RESTIC_BIN=/tmp/other-restic' 'RESTIC_OPTS=--extra-opt' 'RESTIC_REST_PASSWORD_FILE=/tmp/other-pass' \
                'RESTIC_SFTP_COMMAND=/tmp/other-ssh' 'PBO_ROLE=role-probe' 'CFG_VAL=cfgval-probe' '_RENV_ARGS=renvargs-probe'; do
    printf 'AWS_ACCESS_KEY_ID=a\n%s\n' "$bodyline" > "$ENVF"; chmod 600 "$ENVF"; cfg "RESTIC_ENV_FILE=$ENVF"
    k="${bodyline%%=*}"
    out="$($BIN list 2>&1)"; rc=$?
    [[ $rc == 78 && "$out" == *"$ENVF:2: $k may not be set here"* && "$out" != *"${bodyline#*=}"* ]] \
        && ok "RESTIC_ENV_FILE may not set $k (line 2 named, the value not repeated)" || bad "refused name $k: rc=$rc $out"
done
# defence in depth: with the refusal list switched off, the file's variables
# still reach restic alone (env), never pbo's shell, so they cannot change
# which program runs, its options or the rest-server password pbo reads
printf 'RESTIC_BIN=%s\nRESTIC_OPTS=--extra-opt\nRESTIC_REST_PASSWORD_FILE=%s\nAWS_ACCESS_KEY_ID=dd-probe\n' "$RUN/bin/other-restic" "$RUN/other-pass" > "$ENVF"; chmod 600 "$ENVF"
printf '#!/usr/bin/env bash\necho OTHER-RESTIC-RAN >> "%s"\n' "$RUN/other.log" > "$RUN/bin/other-restic"; chmod 0755 "$RUN/bin/other-restic"
printf 'otherpw\n' > "$RUN/other-pass"; printf 'restpw\n' > "$RUN/rest-pass"; chmod 600 "$RUN/other-pass" "$RUN/rest-pass"; : > "$RUN/other.log"
cfg "RESTIC_ENV_FILE=$ENVF" "RESTIC_REST_USERNAME=pve1" "RESTIC_REST_PASSWORD_FILE=$RUN/rest-pass"
: > "$FAKE_ENV_LOG"
out="$(bash -c 'set -u; source lib/common.sh; source lib/config_schema.sh; source lib/appendonly.sh; source lib/restic.sh; PBO_COMMAND=doctor; load_config
    _restic_env_refused() { return 1; }; RENV_ERRORS=()
    _restic rest:https://h.example:8000/x snapshots --json; echo "rc=$? bin=$RESTIC_BIN"' 2>&1)"
call="$(grep '^CALL' "$FAKE_ENV_LOG")"
[[ "$out" == *"rc=0 bin=$RUN/bin/restic-fake"* && ! -s "$RUN/other.log" && "$call" == "CALL -r rest:https://h.example:8000/x snapshots --json" \
   && "$(cat "$FAKE_ENV_LOG")" == *"AWS_ACCESS_KEY_ID=dd-probe"* && "$(cat "$FAKE_ENV_LOG")" == *"RESTIC_REST_PASSWORD=restpw"* ]] \
    && ok "RESTIC_ENV_FILE: even unrefused, RESTIC_BIN/RESTIC_OPTS in it change neither the program nor its arguments (env on restic's command only)" \
    || bad "env file reached pbo's shell: $out / $call / $(cat "$RUN/other.log")"
# the cluster-shared config cannot name RESTIC_ENV_FILE (local-only): a pmxcfs
# file would pass the mode check and hand every node its variables
printf 'RESTIC_ENV_FILE=%s\nKEEP_LOCAL=4\n' "$ENVF" > "$RUN/shared.cfg"; printf 'KEEP_LOCAL=5\n' > "$RUN/local.cfg"
out="$(S="$RUN/shared.cfg" L="$RUN/local.cfg" bash -c 'set -u; source lib/config_schema.sh; source lib/config_parse.sh
    _cfg_config_files() { _CFG_FPATH=("$S" "$L"); _CFG_FORIGIN=(shared local); }
    _cfg_parse_all; echo "env=${CFG_VAL[RESTIC_ENV_FILE]-unset} keep=${CFG_VAL[KEEP_LOCAL]-}"; printf "ignored %s\n" "${CFG_IGNORED[@]}"' 2>&1)"
[[ "$out" == *"env=unset keep=5"* && "$out" == *"ignored $RUN/shared.cfg:1: RESTIC_ENV_FILE may not be set in the cluster-shared config"* ]] \
    && ok "RESTIC_ENV_FILE in the cluster-shared config: ignored (local-only), named" || bad "shared env file: $out"
cfg "RESTIC_ENV_FILE=$ENVF"
printf 'AWS_SECRET_ACCESS_KEY=$(cat /etc/shadow)\nB2_ACCOUNT_KEY=a b\n' > "$ENVF"
out="$($BIN config check 2>&1)"; rc=$?
[[ $rc == 78 && "$out" == *"$ENVF:1: error: command substitution"* && "$out" == *"$ENVF:2: error:"* && "$out" != *"shadow"* ]] \
    && ok "RESTIC_ENV_FILE: the config grammar's refusals, by line, nothing run or quoted" || bad "grammar: rc=$rc $out"
rm -f "$ENVF"; : > "$FAKE_ENV_LOG"
out="$($BIN --json list 2>&1)"; rc=$?
d="$($BIN doctor 2>&1)"
[[ $rc == 0 && "$(grep -c 'AWS_' "$FAKE_ENV_LOG")" == 0 && "$d" != *RESTIC_ENV_FILE* ]] && ok "a missing RESTIC_ENV_FILE is fine (nothing exported, no doctor line)" || bad "missing: rc=$rc $out $(grep ENV <<<"$d")"
# every restic call site goes through the wrapper: RESTIC_BIN runs in two places only
out="$(grep -nE '"\$RESTIC_BIN"|"\$\{RESTIC_BIN[^}]*\}"[[:space:]]' pbo lib/*.sh lib/vzdump-hook | grep -v '^lib/config_schema.sh:')"
n="$(grep -c . <<<"$out")"
pf="$(bash -c 'source lib/restic.sh; declare -f _restic_pf')"
[[ "$n" == 2 && "$out" == *"_restic_bin() {"* && "$out" == *'bin="$RESTIC_BIN"'* && "$pf" == *'"$bin" -r "$1"'* ]] \
    && ok "RESTIC_BIN runs only in the wrappers (_restic_pf with the environment, _restic_bin without a repo)" || bad "restic call sites: $out"
out="$(grep -nE '(^|[;&|]|then|do|else)[[:space:]]*restic[[:space:]]+(-r|backup|snapshots|copy|forget|prune|check|init|dump|mount|restore|key|unlock|stats|ls|cat)\b' pbo lib/*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')"
[[ -z "$out" ]] && ok "no bare restic call bypasses the wrapper" || bad "bare restic: $out"

# ============================================================================
# catalog _umount and the units in both layouts
# ============================================================================
cat > "$RUN/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
# mock findmnt -n -o FSTYPE --mountpoint <dir>: MOCK_MNT_DIR is mounted with MOCK_MNT_TYPE
[[ -n "${MOCK_LOG:-}" ]] && echo "findmnt $*" >> "$MOCK_LOG"
d="${*: -1}"
[[ -n "${MOCK_MNT_TYPE:-}" && "$d" == "${MOCK_MNT_DIR:-}" ]] && echo "$MOCK_MNT_TYPE"
exit 0
EOF
cat > "$RUN/bin/umount" <<'EOF'
#!/usr/bin/env bash
echo "umount $*" >> "$MOCK_LOG"
exit 0
EOF
chmod 0755 "$RUN/bin/findmnt" "$RUN/bin/umount"
cfg
M="$RUN/mnt/restic"
: > "$MOCK_LOG"; out="$(MOCK_MNT_DIR="$M" MOCK_MNT_TYPE=fuse.restic $BIN catalog _umount 2>&1)"; rc=$?
[[ $rc == 0 && "$(grep '^umount' "$MOCK_LOG")" == "umount -l -- $M" ]] && ok "catalog _umount: lazily unmounts the FUSE mount at PVE_CATALOG_MOUNT_DIR (not a fixed path)" || bad "umount fuse: rc=$rc $out / $(cat "$MOCK_LOG")"
: > "$MOCK_LOG"; out="$(MOCK_MNT_DIR="$M" MOCK_MNT_TYPE=ext4 $BIN catalog _umount 2>&1)"; rc=$?
[[ $rc == 0 && -z "$(grep '^umount' "$MOCK_LOG")" && "$out" == *"is a ext4 mount, not restic's FUSE mount: left alone"* ]] && ok "catalog _umount: another filesystem there is left alone" || bad "umount ext4: rc=$rc $out"
: > "$MOCK_LOG"; out="$($BIN catalog _umount 2>&1)"; rc=$?
[[ $rc == 0 && -z "$(grep '^umount' "$MOCK_LOG")" && "$out" == *"nothing mounted at $M"* ]] && ok "catalog _umount: nothing mounted is fine" || bad "umount none: rc=$rc $out"
: > "$MOCK_LOG"; out="$(MOCK_MNT_DIR=/run/pbo/mnt MOCK_MNT_TYPE=fuse.restic $BIN catalog _umount 2>&1)"
[[ -z "$(grep '^umount' "$MOCK_LOG")" ]] && ok "catalog _umount: a mount at the default path is not touched when the config names another" || bad "umount default: $(cat "$MOCK_LOG")"
grep -q 'umount -l /run/pbo/mnt' systemd/pbo-mount.service && bad "pbo-mount.service still unmounts a fixed path" || ok "pbo-mount.service names no mount path"
# the cleanup runs on a RESTIC_ENV_FILE and a config line pbo refuses (restic
# died because of them, the dead mount must go); every other command stops.
# Out of the config corpus: only tests/config_parse.sh's fixtures may hold a
# refused line there.
printf 'AWS_ACCESS_KEY_ID=a\n' > "$RUN/umount.env"; chmod 644 "$RUN/umount.env"
cfg "RESTIC_ENV_FILE=$RUN/umount.env" 'KEEP_LOCAL=$(true)'
: > "$MOCK_LOG"; out="$(env -u PBO_TEST_CONFIG_LOG MOCK_MNT_DIR="$M" MOCK_MNT_TYPE=fuse.restic $BIN catalog _umount 2>&1)"; rc=$?
[[ $rc == 0 && "$(grep '^umount' "$MOCK_LOG")" == "umount -l -- $M" ]] \
    && ok "catalog _umount: runs with a refused RESTIC_ENV_FILE (0644) and a refused config line" || bad "umount refused env: rc=$rc $out / $(cat "$MOCK_LOG")"
out="$(env -u PBO_TEST_CONFIG_LOG $BIN catalog show 2>&1)"; rc=$?
out2="$(env -u PBO_TEST_CONFIG_LOG MOCK_MNT_DIR="$M" MOCK_MNT_TYPE=fuse.restic $BIN catalog _mount 2>&1)"; rc2=$?
[[ $rc == 78 && $rc2 == 78 ]] && ok "... while catalog show and _mount still stop (78)" || bad "catalog show/_mount on a refused config: rc=$rc/$rc2 $out / $out2"
cfg "RESTIC_ENV_FILE=$RUN/umount.env"
out="$($BIN catalog show 2>&1)"; rc=$?
[[ $rc == 78 && "$out" == *"REFUSING a restic environment file with mode 0644"* ]] && ok "... and with the env file alone, catalog show stops on it (78)" || bad "catalog show 0644: rc=$rc $out"
rm -f "$RUN/umount.env"; cfg

# the two layouts: install.sh (/usr/local/lib/pbo + /usr/local/sbin/pbo, units
# copied as they are) and the .deb (packaging/build-deb.sh, units rewritten).
# The install.sh layout is what install.sh's own functions install (program
# files, the integration files and the host and janitor units) into a tree
# below the run directory, with its paths moved there in test mode.
LI="$RUN/layout-install"; LD="$RUN/layout-deb"
mkdir -p "$LI/usr/local/sbin" "$LI/etc/systemd/system" "$RUN/layout-etc"
paths="$(PBO_INSTALL_TEST=0 bash -c 'source ./install.sh; printf "%s %s %s" "$LIBDIR" "$BIN" "$UNITDIR"')"
[[ "$paths" == "/usr/local/lib/pbo /usr/local/sbin/pbo /etc/systemd/system" ]] \
    && ok "install.sh installs to /usr/local/lib/pbo, /usr/local/sbin/pbo and /etc/systemd/system (the layout below)" || bad "install.sh paths: $paths"
out="$(PBO_INSTALL_TEST=1 PBO_INSTALL_LIBDIR="$LI/usr/local/lib/pbo" PBO_INSTALL_BIN="$LI/usr/local/sbin/pbo" \
       PBO_INSTALL_UNITDIR="$LI/etc/systemd/system" PBO_INSTALL_CFGDIR="$RUN/layout-etc" PBO_INSTALL_SYSTEMCTL=true \
       bash -c 'set -Eeuo pipefail; source ./install.sh; JUSER=backup; inst_program_files; inst_integration_files; inst_host_units; inst_janitor_units' 2>&1)" \
    || bad "install.sh into the layout tree failed: $out"
deb_ok=0
if command -v dpkg-deb >/dev/null 2>&1; then
    if packaging/build-deb.sh "$RUN/dist" > "$RUN/build-deb.log" 2>&1; then
        mkdir -p "$LD"
        for f in "$RUN"/dist/*.deb; do dpkg-deb -x "$f" "$LD"; done
        deb_ok=1
        ok "the .deb packages build (TMPDIR in the run directory)"
        ctl="$(dpkg-deb -f "$RUN"/dist/pbo_*_all.deb Depends)"
        [[ ", $ctl," == *", acl,"* && ", $ctl," == *", util-linux,"* && "$ctl" == *"restic (>= 0.14.0)"* ]] \
            && ok "deb Depends: acl, util-linux, restic >= 0.14.0 (RESTIC_MIN's default)" || bad "Depends: $ctl"
    else
        bad "build-deb.sh failed: $(tail -5 "$RUN/build-deb.log")"
    fi
else
    skip "the .deb layout (no dpkg-deb): emulated with build-deb.sh's unit rewrite"
    rw="$(sed -n "s/^unit_rewrite() { sed '\(.*\)' \"\$1\"; }\$/\1/p" packaging/build-deb.sh)"
    mkdir -p "$LD/usr/lib/pbo/lib" "$LD/usr/sbin" "$LD/usr/lib/systemd/system"
    install -m 0755 pbo "$LD/usr/lib/pbo/pbo"; install -m 0644 lib/*.sh "$LD/usr/lib/pbo/lib/"
    install -m 0755 lib/vzdump-hook "$LD/usr/lib/pbo/vzdump-hook"; ln -s ../lib/pbo/pbo "$LD/usr/sbin/pbo"
    for u in systemd/*.service systemd/*.timer; do sed "$rw" "$u" > "$LD/usr/lib/systemd/system/${u##*/}"; done
    deb_ok=1
fi
cmds="$(sed -nE 's/^[[:space:]]{8}([a-z_][a-z_-]*)\)[[:space:]].*/\1/p' pbo | sort -u | tr '\n' ' ')"
csubs="$(sed -n '/^rdo_catalog() {/,/^}/p' lib/catalog.sh | sed -nE 's/^[[:space:]]+(_?[a-z][a-z_-]*)\)[[:space:]].*/\1/p' | sort -u | tr '\n' ' ')"
# unit_check <layout root> <unit dir> <name>: every unit there runs only pbo
# programs that exist in this layout, and only commands pbo has (for catalog,
# its subcommand too: pbo-mount.service runs _mount and _umount)
unit_check() {
    local root="$1" udir="$2" name="$3" u line p sub probs="" n=0 seen=" "
    for u in "$root$udir"/pbo*.service "$root$udir"/pbo*.timer; do
        [[ -f "$u" ]] || continue
        n=$((n+1))
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" == Exec*=* ]] || continue
            for p in $(grep -oE '/[A-Za-z0-9_./-]+' <<<"$line"); do
                case "$p" in
                    */pbo|*/pbo/*)
                        if [[ ! -x "$root$p" ]]; then probs+="${u##*/}: $p missing; "; continue; fi
                        sub="$(grep -oE "$p [a-z_-]+" <<<"$line" | head -1)"; sub="${sub##* }"
                        [[ -z "$sub" || " $cmds " == *" $sub "* ]] || probs+="${u##*/}: unknown command '$sub'; "
                        if [[ "$sub" == catalog ]]; then
                            sub="$(grep -oE "$p catalog [a-z_-]+" <<<"$line" | head -1)"; sub="${sub##* }"
                            [[ -n "$sub" && " $csubs " == *" $sub "* ]] || probs+="${u##*/}: unknown catalog subcommand '$sub'; "
                        fi
                        [[ "$seen" == *" $p "* ]] || { seen+="$p "
                            "$root$p" -V >/dev/null 2>&1 || probs+="${u##*/}: $p -V fails; "; } ;;
                    /usr/local/*) [[ "$name" == deb ]] && probs+="${u##*/}: $p is an install.sh path; " ;;
                esac
            done
        done < "$u"
    done
    (( n >= 13 )) || probs+="only $n units in $root$udir; "
    printf '%s' "$probs"
}
[[ " $csubs " == *" _mount "* && " $csubs " == *" _umount "* ]] || bad "catalog's subcommands not found in lib/catalog.sh: $csubs"
out="$(unit_check "$LI" /etc/systemd/system install)"
[[ -z "$out" ]] && ok "every unit install.sh installs works in its layout (/usr/local/lib/pbo: programs exist, run, commands and catalog subcommands known)" || bad "install layout: $out"
if (( deb_ok )); then
    out="$(unit_check "$LD" /usr/lib/systemd/system deb)"
    [[ -z "$out" ]] && ok "every unit works in the .deb layout (/usr/lib/pbo, no /usr/local path left)" || bad "deb layout: $out"
    [[ "$(grep -h 'ExecStopPost' "$LD/usr/lib/systemd/system/pbo-mount.service")" == "ExecStopPost=-/usr/lib/pbo/pbo catalog _umount" ]] \
        && ok "deb: pbo-mount.service unmounts through the packaged pbo" || bad "deb mount unit: $(grep Exec "$LD/usr/lib/systemd/system/pbo-mount.service")"
    out="$("$LD/usr/sbin/pbo" -V 2>&1)"; [[ "$out" == "pbo "* ]] && ok "deb: /usr/sbin/pbo runs from its symlink" || bad "deb sbin: $out"
fi

# the .deb's postinst runs the permission pass, as install.sh does: taken
# from the built package (dpkg-deb -e), else from build-deb.sh's text, with
# its absolute paths moved below the run directory and pbo a stub that
# records how it was called (STUB_RC: its exit status)
PI="$RUN/postinst"; mkdir -p "$PI/bin"
if command -v dpkg-deb >/dev/null 2>&1 && compgen -G "$RUN/dist/pbo_*_all.deb" >/dev/null; then
    dpkg-deb -e "$(compgen -G "$RUN/dist/pbo_*_all.deb" | head -1)" "$PI/ctl" && cp "$PI/ctl/postinst" "$PI/postinst.orig"
else
    sed -n "/^cat > \"\$ROOT\/DEBIAN\/postinst\" <<'PI'\$/,/^PI\$/p" packaging/build-deb.sh | sed '1d;$d' > "$PI/postinst.orig"
fi
sed -e "s#/usr/sbin/pbo#$PI/bin/pbo#g; s#/etc/pbo#$PI/etc#g; s#/var/log/pbo#$PI/log#g; s#/var/lib/pbo#$PI/state#g" \
    -e "s#/etc/pve#$PI/pve#g; s#/usr/share/pbo#$PI/share#g" "$PI/postinst.orig" > "$PI/postinst"
printf '%s\n' '#!/usr/bin/env bash' "printf '%s\n' \"\$*\" >> \"$PI/pbo.calls\"" 'exit "${STUB_RC:-0}"' > "$PI/bin/pbo"
chmod 755 "$PI/bin/pbo"
# systemctl is the mock, first on PATH: the postinst's daemon-reload never reaches the host
install -m 0755 tests/mocks/systemctl "$PI/bin/systemctl"
left="$(grep -v '^[[:space:]]*#' "$PI/postinst" | sed "s#$PI#<run>#g" | grep -v '/usr/share/doc' | grep -nE '(^|[^>[:alnum:]])/(usr|etc|var)/' || true)"
if [[ -n "$left" || "$(PATH="$PI/bin:$PATH" command -v systemctl)" != "$PI/bin/systemctl" ]]; then
    bad "postinst: a host path is left after the rewrite, or systemctl is not the mock: $(head -3 <<<"$left")"
else
    : > "$PI/pbo.calls"
    out="$(PATH="$PI/bin:$RUN/bin:$PATH" MOCK_LOG="$PI/systemctl.calls" sh "$PI/postinst" configure 2>&1)"; rc=$?
    [[ $rc == 0 ]] && ! grep -q 'perms-only' "$PI/pbo.calls" && [[ -d "$PI/etc" && ! -e "$PI/etc/config" ]] \
        && ok "deb postinst without a config: no permission pass (nothing of the operator's to fix), no config written" || bad "postinst no config: rc=$rc $(cat "$PI/pbo.calls") $out"
    printf 'KEEP_LOCAL=2\n' > "$PI/etc/config"; : > "$PI/pbo.calls"
    out="$(PATH="$PI/bin:$RUN/bin:$PATH" MOCK_LOG="$PI/systemctl.calls" sh "$PI/postinst" configure 2>&1)"; rc=$?
    [[ $rc == 0 ]] && grep -qx 'doctor --fix --perms-only' "$PI/pbo.calls" \
        && ok "deb postinst with a config: runs pbo doctor --fix --perms-only, as install.sh does" || bad "postinst perms: rc=$rc $(cat "$PI/pbo.calls") $out"
    : > "$PI/pbo.calls"
    out="$(STUB_RC=69 PATH="$PI/bin:$RUN/bin:$PATH" MOCK_LOG="$PI/systemctl.calls" sh "$PI/postinst" configure 2>&1)"; rc=$?
    [[ $rc == 0 && "$out" == *"the permission check reported problems (exit 69)"* ]] \
        && ok "deb postinst: a permission pass that fails is reported and never fails the install" || bad "postinst perms fail: rc=$rc $out"
fi

# ============================================================================
# RESTIC_MIN: doctor and install.sh
# ============================================================================
cfg
dl() { FAKE_RESTIC_VERSION="$1" $BIN doctor 2>&1 | grep -E '(OK|FAIL)  restic '; }
[[ "$(dl 0.13.0)" == *"FAIL  restic 0.13.0 is older than 0.14.0, the oldest this config runs with (RESTIC_MIN)"* ]] && ok "doctor: restic 0.13.0 < RESTIC_MIN 0.14.0 → FAIL" || bad "doctor 0.13: $(dl 0.13.0)"
[[ "$(dl 0.14.0)" == *"OK  restic 0.14.0 (>= 0.14.0)"* ]] && ok "doctor: restic 0.14.0 is enough by default" || bad "doctor 0.14: $(dl 0.14.0)"
[[ "$(dl 0.18.0-dev)" == *"OK  restic 0.18.0 (>= 0.14.0)"* ]] && ok "doctor: a -dev suffix is dropped" || bad "doctor dev: $(dl 0.18.0-dev)"
cfg "RESTIC_REST_USERNAME=pve1" "RESTIC_MIN=0.14.0"
[[ "$(dl 0.16.0)" == *"FAIL  restic 0.16.0 is older than 0.16.1"*"RESTIC_REST_USERNAME"* ]] && ok "doctor: a rest-server login raises the floor to 0.16.1" || bad "doctor rest: $(dl 0.16.0)"
[[ "$(dl 0.16.1)" == *"OK  restic 0.16.1"* ]] && ok "doctor: ... which 0.16.1 meets" || bad "doctor rest ok: $(dl 0.16.1)"
cfg "RESTIC_MIN=0.17.2"
[[ "$(dl 0.17.1)" == *"older than 0.17.2"* && "$(dl 0.17.10)" == *"OK  restic 0.17.10"* ]] && ok "doctor: RESTIC_MIN set higher (compared part by part: 0.17.10 > 0.17.2)" || bad "doctor min: $(dl 0.17.1) / $(dl 0.17.10)"
out="$(FAKE_RESTIC_VERSION=0.18.0 $BIN version 2>&1)"; [[ "$out" == *"restic 0.18.0"* ]] && ok "pbo version reads restic through the wrapper" || bad "version: $out"
cfg "RESTIC_MIN=latest"
out="$($BIN doctor 2>&1)"; [[ "$out" == *"RESTIC_MIN='latest' is not a version"* && "$out" == *"OK  restic 0.18.0 (>= 0.14.0)"* ]] && ok "doctor: a malformed RESTIC_MIN is named, the default applies" || bad "bad min: $(grep -i min <<<"$out")"
# install.sh: refuses before any pbo file is copied
IR="$RUN/install"; mkdir -p "$IR/etc"
SI() { PBO_INSTALL_TEST=1 PBO_INSTALL_CFGDIR="$IR/etc" bash -c 'source ./install.sh; '"$1" 2>&1; }
printf 'RESTIC_BIN=%s\n' "$RUN/bin/restic-fake" > "$IR/etc/config"; chmod 600 "$IR/etc/config"
out="$(FAKE_RESTIC_VERSION=0.12.1 SI 'inst_restic_check; echo survived')"; rc=$?
[[ $rc != 0 && "$out" == *"restic 0.12.1 ($RUN/bin/restic-fake) is older than 0.14.0"* && "$out" == *"No pbo file was installed"* && "$out" != *survived* ]] \
    && ok "install.sh: refuses a restic older than RESTIC_MIN, with a hint" || bad "install old: rc=$rc $out"
out="$(FAKE_RESTIC_VERSION=0.12.1 SI 'FORCE=1; inst_restic_check; echo survived')"
[[ "$out" == *"WARNING: --force"* && "$out" == *survived* ]] && ok "install.sh: --force installs anyway (warned)" || bad "install force: $out"
out="$(FAKE_RESTIC_VERSION=0.17.0 SI 'inst_restic_check; echo survived')"
[[ "$out" == *"==> restic: 0.17.0"* && "$out" == *survived* ]] && ok "install.sh: a new enough restic passes" || bad "install ok: $out"
printf 'RESTIC_BIN=%s\nRESTIC_REST_USERNAME=pve1\nRESTIC_MIN=0.15.0\n' "$RUN/bin/restic-fake" > "$IR/etc/config"
out="$(FAKE_RESTIC_VERSION=0.16.0 SI 'inst_restic_check; echo survived')"
[[ "$out" == *"older than 0.16.1"* && "$out" != *survived* ]] && ok "install.sh: the rest-server floor and RESTIC_MIN from the existing config" || bad "install rest: $out"
printf 'RESTIC_BIN=%s\n' "$RUN/nonexistent-restic" > "$IR/etc/config"
out="$(SI 'inst_restic_check; echo survived')"
[[ "$out" == *"is missing or does not run"* && "$out" != *survived* ]] && ok "install.sh: no restic at all: refused" || bad "install none: $out"
body="$(SI 'declare -f main')"
[[ "$(grep -n 'inst_restic_check' <<<"$body" | cut -d: -f1)" -lt "$(grep -n 'inst_program' <<<"$body" | cut -d: -f1)" ]] \
    && ok "install.sh: the restic check runs before the program files are copied" || bad "install order: $body"

# ============================================================================
# list --reasons on restic 0.14-0.16: forget's JSON names a reason's snapshot
# without id/short_id there (both arrived in 0.17.0)
# ============================================================================
cat > "$RUN/lr-snaps.json" <<'EOF'
[{"time":"2026-01-14T05:00:00Z","tree":"tree0000","paths":["/c/101"],"hostname":"pve1","tags":["vmid=101","ts=2026_01_14-05_00_00","type=lxc"],"id":"bbbb2222ffff","short_id":"bbbb2222"},
 {"time":"2026-01-15T05:00:00Z","tree":"tree1111","paths":["/c/101"],"hostname":"pve1","tags":["vmid=101","ts=2026_01_15-05_00_00","type=lxc"],"id":"aaaa1111ffff","short_id":"aaaa1111"}]
EOF
cat > "$RUN/lr-forget.json" <<'EOF'
[{"tags":["vmid=101"],"host":"","paths":null,
  "keep":[{"time":"2026-01-15T05:00:00Z","tree":"tree1111","paths":["/c/101"],"hostname":"pve1","tags":["vmid=101","ts=2026_01_15-05_00_00","type=lxc"],"id":"aaaa1111ffff","short_id":"aaaa1111"}],
  "remove":[{"time":"2026-01-14T05:00:00Z","tree":"tree0000","paths":["/c/101"],"hostname":"pve1","tags":["vmid=101","ts=2026_01_14-05_00_00","type=lxc"],"id":"bbbb2222ffff","short_id":"bbbb2222"}],
  "reasons":[{"snapshot":{"time":"2026-01-15T05:00:00Z","tree":"tree1111","paths":["/c/101"],"hostname":"pve1","tags":["vmid=101","ts=2026_01_15-05_00_00","type=lxc"]},"matches":["daily snapshot"],"counters":{"daily":0}}]}]
EOF
cfg "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RUN/fake-offsite" "KEEP_OFFSITE_DAILY=1" "KEEP_OFFSITE_WEEKLY=0" "KEEP_OFFSITE_MONTHLY=0"
out="$(FAKE_RESTIC_VERSION=0.14.0 FAKE_SNAPS="$RUN/lr-snaps.json" FAKE_FORGET="$RUN/lr-forget.json" $BIN --json list --reasons 2>&1)"
got="$(jq -c '[.archives[] | [.snapshot, .keep, .reasons]] | sort' <<<"$out" 2>/dev/null)"
[[ "$got" == '[["aaaa1111",true,["daily snapshot"]],["bbbb2222",false,[]]]' ]] \
    && ok "list --reasons: a reason without short_id (restic 0.14-0.16) is matched by time and tree; keep and reasons both there" || bad "reasons without ids: $got / $out"
# a reason that matches no snapshot is dropped, and keep survives it
jq -c '.[0].reasons += [{"snapshot":{"time":"2020-01-01T00:00:00Z","tree":"nope"},"matches":["?"]}]' "$RUN/lr-forget.json" > "$RUN/lr-forget2.json"
out="$(FAKE_SNAPS="$RUN/lr-snaps.json" FAKE_FORGET="$RUN/lr-forget2.json" $BIN --json list --reasons 2>&1)"
got="$(jq -c '[.archives[] | [.snapshot, .keep, .reasons]] | sort' <<<"$out" 2>/dev/null)"
[[ "$got" == '[["aaaa1111",true,["daily snapshot"]],["bbbb2222",false,[]]]' ]] \
    && ok "list --reasons: a reason matching no snapshot is dropped, the merge goes on" || bad "unmatched reason: $got / $out"

# ============================================================================
# dependencies: acl and util-linux
# ============================================================================
cfg
out="$(PBO_TOOLS_MISSING="setfacl findmnt" $BIN doctor 2>&1)"
[[ "$out" == *"WARN  missing tools: setfacl (apt install acl) findmnt (apt install util-linux)"* ]] && ok "doctor: a missing tool names the package to install" || bad "doctor tools: $(grep -i tools <<<"$out")"
out="$(SI 'declare -f inst_deps')"
[[ "$out" == *"[setfacl]=acl"* && "$out" == *"[getfacl]=acl"* && "$out" == *"[setpriv]=util-linux"* && "$out" == *"[findmnt]=util-linux"* ]] \
    && ok "install.sh: setfacl/getfacl (acl), setpriv/findmnt (util-linux) are installed when missing" || bad "install deps: $out"

# ============================================================================
# thresholds that became config keys
# ============================================================================
want='BATCH_FIT_PCT=85 PREFLIGHT_POOL_FREE_PCT=150 INGEST_PENDING_MIN=10 PVE_SPOOL_MAX_AGE=86400 PVE_JOB_WINDOW_MIN=60 CATALOG_STAGE_WAIT=10 RESTIC_MIN=0.14.0 RESTIC_ENV_FILE=/etc/pbo/restic.env'
got=""
for kv in $want; do
    k="${kv%%=*}"
    # the suite moves RESTIC_ENV_FILE into the checkout (environment): its default from the schema
    if [[ "$k" == RESTIC_ENV_FILE ]]; then v="$(bash -c 'source lib/config_schema.sh; _cs_load; printf %s "${CS_DEFAULT[RESTIC_ENV_FILE]}"')"
    else v="$($BIN config get "$k" 2>&1)"; fi
    got+="$k=$v "
done
[[ "$got" == "$want " ]] && ok "the new keys have today's values as defaults ($want)" || bad "defaults: $got"
out="$(grep -nE 'readonly (INGEST_PENDING_MIN|INTEG_SPOOL_MAX_AGE|INTEG_JOB_WINDOW_MIN)|\* 3 / 2|need \* 100 / 85|stage_lock "\$base" -w 10' lib/*.sh)"
[[ -z "$out" ]] && ok "the old fixed values are gone from the code" || bad "fixed values: $out"
# (the window against the configured schedule: the systemctl wrapper reports a
# 05:00 calendar for every unit, so systemd's own view is left out here)
L() { bash -c 'set -u; source lib/common.sh; source lib/config_schema.sh; source lib/timers.sh; _sched_effective_r() { _SE_R=""; }
    source lib/integrate.sh 2>/dev/null; source lib/ingest.sh; '"$1" 2>&1; }
[[ "$(L 'PVE_JOB_WINDOW_MIN=60; _integ_near_timers 380')" == "pbo-prune.timer (06:30)" \
   && "$(L 'PVE_JOB_WINDOW_MIN=90; _integ_near_timers 380')" == "pbo.timer (05:00) pbo-prune.timer (06:30)" ]] \
    && ok "PVE_JOB_WINDOW_MIN: the window doctor warns in" || bad "job window: $(L 'PVE_JOB_WINDOW_MIN=90; _integ_near_timers 380')"
[[ "$(L 'PVE_JOB_WINDOW_MIN=abc; _cfg_int_r PVE_JOB_WINDOW_MIN; echo $_CI_R')" == 60 && "$(L 'BATCH_FIT_PCT=070; _cfg_int_r BATCH_FIT_PCT; echo $_CI_R')" == 70 ]] \
    && ok "_cfg_int_r: a malformed threshold falls back to its default (070 is decimal)" || bad "_cfg_int_r"
SP="$RUN/spool"; mkdir -p "$SP/dump"
touch -d '-5 minutes' "$SP/dump/vzdump-lxc-101-2026_01_15-05_00_00.tar"
[[ -z "$(L "PVE_SPOOL_DIR=$SP; INGEST_PENDING_MIN=10; _ingest_pending_list")" \
   && "$(L "PVE_SPOOL_DIR=$SP; INGEST_PENDING_MIN=3; _ingest_pending_list")" == "$SP/dump/vzdump-lxc-101-2026_01_15-05_00_00.tar" ]] \
    && ok "INGEST_PENDING_MIN: ingest --pending leaves younger archives alone" || bad "pending: $(L "PVE_SPOOL_DIR=$SP; INGEST_PENDING_MIN=3; _ingest_pending_list")"
printf 'tank/subvol-8001-disk-0 1000\n' > "$RUN/zfs-used"
cat > "$RUN/bin/zpool" <<'EOF'
#!/usr/bin/env bash
echo "${MOCK_ZPOOL_FREE:-0}"
EOF
chmod 0755 "$RUN/bin/zpool"; install -m 0755 tests/mocks/zfs "$RUN/bin/zfs"
PF() { MOCK_ZFS_USED="$RUN/zfs-used" MOCK_ZPOOL_FREE="$1" bash -c 'set -u; source lib/common.sh; source lib/config_schema.sh; source lib/preflight.sh
       log_info() { :; }; log_error() { :; }; PREFLIGHT_POOL_FREE_PCT='"$2"'
       PF_BACKUP_VOLUMES=("tank|tank/subvol-8001-disk-0"); PF_NONZFS_VOLUMES=(); PF_CHECKS_JSON=""; PF_FAIL=0
       _pf_check_zfs_space; echo "$PF_FAIL"' 2>&1; }
[[ "$(PF 1500 '')" == 0 && "$(PF 1499 '')" == 1 && "$(PF 1100 110)" == 0 && "$(PF 1099 110)" == 1 ]] \
    && ok "PREFLIGHT_POOL_FREE_PCT: 150 % by default, settable" || bad "pool pct: $(PF 1500 '') $(PF 1499 '') $(PF 1100 110) $(PF 1099 110)"

# ============================================================================
# time zones: vzdump names are the node's local time; instants stay instants
# ============================================================================
ZONES=(UTC Asia/Kolkata America/Sao_Paulo)
if ! TZ=Asia/Kolkata date -d '2026-01-15 05:00:00' +%z 2>/dev/null | grep -q '+0530'; then
    skip "time zones: no tzdata for Asia/Kolkata"
else
    # vzdump archive names: the ts is the name's text, in every zone
    out=""; for z in "${ZONES[@]}"; do out+="$(TZ=$z bash -c 'source lib/prune.sh; _archive_ts vzdump-lxc-101-2026_01_15-05_00_00.tar') "; done
    [[ "$out" == "2026_01_15-05_00_00 2026_01_15-05_00_00 2026_01_15-05_00_00 " ]] && ok "TZ: _archive_ts takes the name's text as it is" || bad "archive ts: $out"
    # the storage plugin's ctime fallback: the name is the node's local time
    if command -v perl >/dev/null 2>&1 && perl -I tests/perl/lib -e 'require "./pve-plugin/PboPlugin.pm"' 2>/dev/null; then
        out=""
        for z in "${ZONES[@]}"; do
            got="$(TZ=$z perl -I tests/perl/lib -e 'require "./pve-plugin/PboPlugin.pm"; print PVE::Storage::Custom::PboPlugin::_archive_ctime("vzdump-qemu-200-2026_01_15-05_00_00.vma")' 2>/dev/null)"
            exp="$(TZ=$z date -d '2026-01-15 05:00:00' +%s)"
            [[ "$got" == "$exp" ]] || out+="$z: $got != $exp; "
        done
        [[ -z "$out" ]] && ok "TZ: the plugin reads an archive name as the node's local time (UTC, +05:30, -03:00)" || bad "plugin ctime: $out"
    else
        skip "TZ: the plugin's ctime (perl or the stubbed PVE modules missing)"
    fi
    # the catalogue's ctime: restic's snapshot time, an instant, in every zone
    cat > "$RUN/snaps.json" <<'EOF'
[{"time":"2026-01-15T05:00:10.123456789+05:30","tags":["vmid=101","ts=2026_01_15-05_00_00","type=lxc"],"paths":["/c/101"],"id":"aaaaaaaa11111111","short_id":"aaaaaaaa"},
 {"time":"2026-01-14T23:30:00-03:00","tags":["vmid=102","ts=2026_01_14-23_30_00","type=qemu"],"paths":["/c/102"],"id":"bbbbbbbb22222222","short_id":"bbbbbbbb"},
 {"time":"2026-01-15T02:30:00Z","tags":["vmid=103","ts=2026_01_15-02_30_00","type=lxc"],"paths":["/c/103"],"id":"cccccccc33333333","short_id":"cccccccc"}]
EOF
    cfg; mkdir -p "$RUN/state/catalog"
    out=""; prev=""
    for z in "${ZONES[@]}"; do
        TZ=$z FAKE_SNAPS="$RUN/snaps.json" $BIN catalog refresh --out "$RUN/cat-$z.json" >/dev/null 2>&1
        got="$(jq -c '[.entries[] | [.volname, .ctime]]' "$RUN/cat-$z.json" 2>/dev/null)"
        [[ -z "$prev" || "$got" == "$prev" ]] || out+="$z differs: $got vs $prev; "
        prev="$got"
    done
    exp='[["backup/vzdump-lxc-101-2026_01_15-05_00_00.tar",1768433410],["backup/vzdump-qemu-102-2026_01_14-23_30_00.vma",1768444200],["backup/vzdump-lxc-103-2026_01_15-02_30_00.tar",1768444200]]'
    [[ -z "$out" && "$prev" == "$exp" ]] && ok "TZ: catalogue ctime is the snapshot's instant (offsets +05:30, -03:00, Z) whatever pbo's zone" || bad "catalog ctime: $out / $prev"
    # the timers' next run: systemctl prints it in the local zone with its
    # abbreviation (IST, -03, UTC); pbo timers gives the same instant
    E=1768453200; out=""
    for z in "${ZONES[@]}"; do
        nx="$(TZ=$z date -d "@$E" '+%a %Y-%m-%d %H:%M:%S %Z')"
        got="$(TZ=$z MOCK_SHOW_NEXT="$nx" $BIN --json timers 2>/dev/null | jq -r '.timers[0].next')"
        [[ "$(date -d "$got" +%s 2>/dev/null)" == "$E" ]] || out+="$z: '$nx' -> '$got'; "
    done
    [[ -z "$out" ]] && ok "TZ: pbo timers shows the next run as the same instant in every zone" || bad "timers next: $out"
    # a PVE job's next run (epoch) as the node's minute of the day, like the
    # times of pbo's timers (systemd OnCalendar is local time)
    out=""
    for z in "${ZONES[@]}"; do
        e="$(TZ=$z date -d '2026-01-15 05:00:00' +%s)"
        got="$(TZ=$z L "_integ_minute_of_day '{\"next_run\":$e}'")"
        [[ "$got" == 300 ]] || out+="$z: $got; "
    done
    [[ -z "$out" ]] && ok "TZ: a PVE job at 05:00 local is minute 300 in every zone (compared with the local timer times)" || bad "minute of day: $out"
    # retention's day buckets: pbo hands retention to restic, which buckets
    # each snapshot by the local day of the offset it recorded. As in
    # production, the snapshots are taken in the node's zone (restic stamps
    # its local offset), and pbo must pass that zone's plan through unchanged:
    # with two daily buckets the same four instants fall on other local days
    # in each zone, so each zone keeps another pair (every zone has two days
    # or more: restic's keep-the-oldest rule for unfilled buckets never
    # applies). A pbo that forced UTC on restic or worked keep out itself
    # fails here.
    if command -v restic >/dev/null 2>&1; then
        mkdir -p "$RUN/cache/101"; echo x > "$RUN/cache/101/f"
        # local days: UTC 14 14 14 15, +05:30 14 14 15 15, -03:00 13 14 14 14
        declare -A expz=(
            [UTC]='[["2026_01_14_00_45_00",false],["2026_01_14_03_45_00",false],["2026_01_14_18_45_00",true],["2026_01_15_00_45_00",true]]'
            [Asia/Kolkata]='[["2026_01_14_00_45_00",false],["2026_01_14_03_45_00",true],["2026_01_14_18_45_00",false],["2026_01_15_00_45_00",true]]'
            [America/Sao_Paulo]='[["2026_01_14_00_45_00",true],["2026_01_14_03_45_00",false],["2026_01_14_18_45_00",false],["2026_01_15_00_45_00",true]]' )
        out=""; zi=0
        for z in "${ZONES[@]}"; do
            zi=$((zi+1)); RR="$RUN/rrepo-$zi"; RRC="$RUN/rcache-$zi"
            RX() { RESTIC_PASSWORD_FILE="$RUN/pass" RESTIC_CACHE_DIR="$RRC" restic -r "$RR" "$@"; }
            RX init >/dev/null 2>&1
            for t in '2026-01-14T00:45:00Z' '2026-01-14T03:45:00Z' '2026-01-14T18:45:00Z' '2026-01-15T00:45:00Z'; do
                lt="$(TZ=$z date -d "$t" '+%Y-%m-%d %H:%M:%S')"; u="${t%Z}"; u="${u//[-:T]/_}"
                TZ=$z RX backup -q --time "$lt" --host pve1 --tag "vmid=101,ts=$u" "$RUN/cache/101" >/dev/null 2>&1
            done
            cfg "LOCAL_REPO=false" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=$RR" "RESTIC_BIN=$(command -v restic)" \
                "KEEP_OFFSITE_DAILY=2" "KEEP_OFFSITE_WEEKLY=0" "KEEP_OFFSITE_MONTHLY=0" "KEEP_OFFSITE_YEARLY=0"
            got="$(TZ=$z $BIN --json list --reasons 2>/dev/null | jq -c '[.archives[] | [.ts, .keep]] | sort')"
            [[ "$got" == "${expz[$z]}" ]] || out+="$z: $got (want ${expz[$z]}); "
        done
        [[ -z "$out" ]] && ok "TZ: retention keeps by the local day each snapshot recorded (another pair under UTC, +05:30 and -03:00), passed through as restic plans it" || bad "day buckets: $out"
    else
        skip "TZ: retention day buckets (restic not installed)"
    fi
fi

# ============================================================================
# _ct_root_uid: custom idmaps (fixtures, never the real files); /etc/subuid
# plays no part, as in pve-container
# ============================================================================
CT() { bash -c 'set -u; source lib/common.sh; PBO_PVE_LXC_DIR="$1"; _ct_root_uid "$2" || echo FAIL' _ "$RUN/lxc" "$1" 2>&1; }
printf 'arch: amd64\nunprivileged: 1\n' > "$RUN/lxc/8001.conf"
printf 'arch: amd64\nunprivileged: 1\nlxc.idmap: g 0 300000 65536\nlxc.idmap: u 0 300000 65536\n' > "$RUN/lxc/8002.conf"
printf 'arch: amd64\nunprivileged: 1\nlxc.idmap: u 0 400000 1000\nlxc.idmap: u 1000 1000 1\nlxc.idmap: u 1001 401001 64535\n' > "$RUN/lxc/8003.conf"
printf 'arch: amd64\n' > "$RUN/lxc/8004.conf"
printf 'arch: amd64\nunprivileged: 1\n[snap1]\nlxc.idmap: u 0 999999 65536\n' > "$RUN/lxc/8005.conf"
[[ "$(CT 8001)" == 100000 ]] && ok "_ct_root_uid: no idmap: 100000, Proxmox's fixed default" || bad "no idmap: $(CT 8001)"
out="$(grep -n 'subuid' lib/common.sh | grep -vE '^[0-9]+:[[:space:]]*#')"
[[ -z "$out" ]] && ok "_ct_root_uid: /etc/subuid is never read (pve-container ignores it for CTs without an idmap)" || bad "subuid read: $out"
[[ "$(CT 8002)" == 300000 ]] && ok "_ct_root_uid: an lxc.idmap u line wins (g lines skipped)" || bad "idmap: $(CT 8002)"
[[ "$(CT 8003)" == 400000 ]] && ok "_ct_root_uid: a split idmap: the line that maps uid 0" || bad "split idmap: $(CT 8003)"
[[ "$(CT 8004)" == FAIL ]] && ok "_ct_root_uid: a privileged CT has none" || bad "privileged: $(CT 8004)"
[[ "$(CT 8005)" == 100000 ]] && ok "_ct_root_uid: an idmap in a snapshot section does not count" || bad "snapshot section: $(CT 8005)"

# ============================================================================
# doctor --report: an environment for a bug report, nothing that identifies the host
# ============================================================================
printf 'AWS_ACCESS_KEY_ID=AKIDREPORTVALUE\nAWS_SECRET_ACCESS_KEY=reportsecretvalue\n' > "$ENVF"; chmod 600 "$ENVF"
mkdir -p "$RUN/pve"; printf '{"nodename":"nodename-report-test","version":3,"cluster":{"name":"clustername-report","version":2,"nodes":3,"quorate":1}}\n' > "$RUN/pve/.members"
cfg "RESTIC_ENV_FILE=$ENVF" "OFFSITE_ENABLED=true" "RESTIC_OFFSITE_REPO=sftp:reportuser@backup-report.example:/srv/report-repo" \
    "RESTIC_SFTP_COMMAND=\"ssh -p 2222 reportuser@backup-report.example -i $RUN/id_report -s sftp\"" \
    "NTFY_URL=https://ntfyuser:ntfypw@ntfy-report.example" "NTFY_TOPIC=topic-report-secret" "PRUNE_OWNER=pve-report-owner" \
    "RESTIC_REST_USERNAME=restuser-report"
txt="$($BIN doctor --report 2>&1)"; rc=$?
js="$($BIN --json doctor --report 2>/dev/null)"
[[ $rc == 0 && "$txt" == *"backends: cache local, offsite sftp"* && "$txt" == *"cluster: cluster, 3 nodes, quorate"* \
   && "$txt" == *"restic env file: present, 2 variable(s)"* && "$txt" == *"pbo: "*"(source), role host, integration standalone"* ]] \
    && ok "doctor --report: versions, layout, cluster, backend types, env file" || bad "report text: rc=$rc $txt"
[[ "$(jq -r '.report.backends.offsite + " " + .report.cache_dir.posix_acl + " " + (.report.tools.present | type)' <<<"$js")" =~ ^sftp\ (yes|no|unknown)\ array$ ]] \
    && ok "doctor --report --json: the same as an object" || bad "report json: $js"
leak=""
for v in AKIDREPORTVALUE reportsecretvalue reportuser backup-report.example /srv/report-repo 2222 id_report ntfyuser ntfypw ntfy-report \
         topic-report-secret pve-report-owner restuser-report nodename-report-test clustername-report "$RUN" "$ROOT"; do
    [[ -n "$v" && ( "$txt" == *"$v"* || "$js" == *"$v"* ) ]] && leak+="$v "
done
# the machine's own name as a whole token (pve-manager is one token, not
# "pve"): a node may be called like a word the report always has (a tool, the
# os id), and a name that short identifies nothing
toks=" $(printf '%s\n%s\n' "$txt" "$js" | grep -oE '[A-Za-z0-9._-]+' | tr '\n' ' ') "
vocab=" $(bash -c 'source lib/report.sh; printf "%s" "$REPORT_TOOLS"') $(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}") "
for v in "$(hostname 2>/dev/null)" "$(hostname -s 2>/dev/null)"; do
    [[ -n "$v" && ${#v} -ge 4 && "$vocab" != *" $v "* && "$toks" == *" $v "* ]] && leak+="$v "
done
[[ -z "$leak" ]] && ok "doctor --report: no secret, URL, user, host or node name, port or path from the config or the host" || bad "report leaks: $leak"
for r in 'rest:https://u:p@h.example:8000/x' 's3:s3.example/bucket' 'b2:bucket:path' 'azure:c:/' 'gs:b:/' 'rclone:remote:path' '/srv/local' 'weird-thing'; do
    out="$(bash -c 'source lib/report.sh; _report_repo_type "$1"' _ "$r")"
    printf '%s ' "$out"
done > "$RUN/types"
[[ "$(cat "$RUN/types")" == "rest s3 b2 azure gs rclone local other " ]] && ok "doctor --report: backend type only (rest s3 b2 azure gs rclone local other)" || bad "repo types: $(cat "$RUN/types")"
# a relative CACHE_DIR (the dir type takes one) that does not exist: the
# walk up to an existing parent ends at the cwd instead of looping forever
mkdir -p "$RUN/ro"
out="$(cd "$RUN/ro" && timeout 20 bash -c 'source "$1/lib/common.sh"; source "$1/lib/report.sh"; _report_fs cache-missing' _ "$ROOT" 2>&1)"; rc=$?
[[ $rc == 0 && "$out" =~ ^[A-Za-z0-9._/-]+\|(yes|no|unknown)$ ]] && ok "doctor --report: a relative CACHE_DIR that does not exist gives the cwd's filesystem ($out), no endless walk" || bad "relative cache dir: rc=$rc $out"
if (( ! is_root )); then
    # ensure_dirs cannot create it there either: the whole report still ends
    chmod 0555 "$RUN/ro"
    cfg "CACHE_DIR=cache-missing"
    out="$(cd "$RUN/ro" && timeout 60 "$ROOT/pbo" doctor --report 2>&1)"; rc=$?
    chmod 0755 "$RUN/ro"
    [[ $rc != 124 && "$out" == *"cache"* ]] && ok "doctor --report with that CACHE_DIR in a read-only cwd finishes" || bad "report relative cache: rc=$rc $out"
fi
out="$($BIN doctor --report --fix 2>&1)"; rc=$?
[[ $rc == 64 ]] && ok "doctor --report with --fix: refused (64)" || bad "report+fix: rc=$rc $out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
