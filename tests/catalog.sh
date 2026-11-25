#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/catalog.sh: the catalogue the PVE storage plugin reads (lib/catalog.sh,
# ADR 0006 Phase 1). Two REAL local restic repos (cache + offsite); Proxmox and
# systemctl are mocked, so nothing on the host is touched.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping catalog tests"; exit 0; }

printf 'pbo: catalogue tests\n'
RUN="$ROOT/run/catalog"; rm -rf "$RUN"
mkdir -p "$RUN"/{cache,state,log,lock,conf,bin,orig,sysd}
export MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/calls" MOCK_SYSTEMCTL_DIR="$RUN/sysd"; : > "$MOCK_LOG"
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/pvesh tests/mocks/pvesm tests/mocks/systemctl "$RUN/bin/"
install -m 0755 tests/mocks/vzdump "$RUN/bin/vzdump.mock"
# vzdump wrapper: the mock's archive, plus a copy of it to compare restores with
cat > "$RUN/bin/vzdump" <<EOF
#!/usr/bin/env bash
"$RUN/bin/vzdump.mock" "\$@" || exit
d=""; while [[ \$# -gt 0 ]]; do [[ "\$1" == --dumpdir ]] && d="\$2"; shift; done
cp -p "\$d"/vzdump-*.tar "$RUN/orig/"
EOF
chmod 0755 "$RUN/bin/vzdump"
export PATH="$RUN/bin:$PATH"
for id in 8001 8002; do printf 'arch: amd64\nhostname: t%s\nrootfs: teststore:%s/vm-%s-disk-0.raw,size=1G\nunprivileged: 1\n' "$id" "$id" "$id" > "$MOCK_CONF_DIR/$id.conf"; done
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"

# mkcfg <file> [extra lines]: OFFSITE_ENABLED is left out so a single run can
# switch it off through the environment.
mkcfg() { local f="$1"; shift; { cat <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
BACKUP_ORDER=8001
LOCAL_REPO=true
RESTIC_CACHE_REPO=$RUN/repo-cache
RESTIC_OFFSITE_REPO=$RUN/repo-offsite
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
STORAGE_BOX_SNAPSHOTS_CONFIRMED=true
NTFY_URL=
NTFY_CREDS_FILE=/nonexistent
PBO_CATALOG=$RUN/catalog/index.json
PVE_STAGING_DIR=$RUN/staging
PVE_STAGING_TTL=3600
KEEP_LOCAL=5
VZDUMP_CONF=$RUN/vzdump.conf
PVE_STORAGE_CFG=$RUN/storage.cfg
EOF
    for l in "$@"; do echo "$l"; done; } > "$f"; chmod 600 "$f"; }
mkcfg "$RUN/config"; export PBO_CONFIG="$RUN/config"
R() { local repo="$1"; shift; RESTIC_PASSWORD_FILE="$RUN/pass" RESTIC_CACHE_DIR="$RUN/rcache" restic -r "$repo" "$@"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
RE='^backup/vzdump-(lxc|qemu)-[0-9]+-[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}\.(tar|vma)$'

# --- fixtures: 8001 twice in both tiers (the older one then forgotten in the
# cache = offsite only), 8002 cache only, a qemu archive, and a host snapshot ---
$BIN init >/dev/null 2>&1 || bad "init"
$BIN backup 8001 >/dev/null 2>&1 || bad "backup 8001 (1)"
sleep 1.1
$BIN backup 8001 >/dev/null 2>&1 || bad "backup 8001 (2)"
OFFSITE_ENABLED=false $BIN backup 8002 >/dev/null 2>&1 || bad "backup 8002 (cache only)"
old8001="$(R "$RUN/repo-cache" snapshots --json --tag vmid=8001 2>/dev/null | jq -r 'sort_by(.time) | .[0].id')"
old8001_ts="$(R "$RUN/repo-cache" snapshots --json --tag vmid=8001 2>/dev/null | jq -r 'sort_by(.time) | .[0].tags[] | select(startswith("ts=")) | sub("ts=";"")')"
R "$RUN/repo-cache" forget "$old8001" >/dev/null 2>&1 || bad "forget the old 8001 in the cache"
qts=2026_01_02-03_04_05; mkdir -p "$RUN/cache/8003"
head -c 300000 /dev/urandom > "$RUN/cache/8003/vzdump-qemu-8003-$qts.vma"; cp -p "$RUN/cache/8003/vzdump-qemu-8003-$qts.vma" "$RUN/orig/"
printf 'cores: 1\n' > "$RUN/cache/8003/vzdump-qemu-8003-$qts.vma.conf"
R "$RUN/repo-cache" backup -q "$RUN/cache/8003" --tag vmid=8003 --tag "ts=$qts" --tag type=qemu --tag keep=d30.w8 >/dev/null 2>&1 || bad "qemu fixture"
R "$RUN/repo-offsite" copy --from-repo "$RUN/repo-cache" --from-password-file "$RUN/pass" --tag vmid=8003 >/dev/null 2>&1 || bad "qemu fixture copy"
rm -f "$RUN/cache/8003"/vzdump-*
mkdir -p "$RUN/hostfiles"; echo x > "$RUN/hostfiles/f"
R "$RUN/repo-cache" backup -q "$RUN/hostfiles" --tag vmid=host-n1 --tag ts=2026_01_01-00_00_00 --tag type=host >/dev/null 2>&1 || bad "host fixture"
ncs="$(R "$RUN/repo-cache" snapshots --json 2>/dev/null | jq length)"; nos="$(R "$RUN/repo-offsite" snapshots --json 2>/dev/null | jq length)"
[[ "$ncs" == 4 && "$nos" == 3 ]] && ok "fixtures: 4 cache snapshots (one host), 3 offsite" || bad "fixtures: cache $ncs offsite $nos"

# --- refresh --out: merge, volname, flags ---
out="$($BIN --json catalog refresh --out "$RUN/out/sub/index.json" 2>"$RUN/err")"; rc=$?
[[ $rc == 0 ]] && jq -e '.status == "ok" and .entries == 4 and .cache == 3 and .offsite == 3' >/dev/null 2>&1 <<<"$out" \
    && ok "refresh --out: ok, 4 entries (cache 3, offsite 3)" || bad "refresh --out rc=$rc $out $(tail -2 "$RUN/err")"
I="$RUN/out/sub/index.json"
[[ ! -e "$RUN/catalog/index.json" ]] && ok "refresh --out does not write PBO_CATALOG" || bad "--out also wrote PBO_CATALOG"
[[ "$(stat -c %a "$I")" == 644 && "$(stat -c %a "$RUN/out/sub")" == 755 ]] && ok "index mode 0644 in a 0755 directory" || bad "modes: $(stat -c %a "$I") $(stat -c %a "$RUN/out/sub")"
[[ -z "$(find "$RUN/out/sub" -name '.index.*')" ]] && ok "no temp file left next to the index" || bad "temp files: $(ls -a "$RUN/out/sub")"
jq -e --arg re "$RE" 'all(.entries[]; .volname | test($re))' "$I" >/dev/null && ok "every volname is backup/vzdump-<type>-<vmid>-<ts>.<tar|vma>" || bad "volnames: $(jq -c '[.entries[].volname]' "$I")"
jq -e 'all(.entries[]; .vmid != "host-n1") and ([.entries[] | select(.type == "host")] | length == 0)' "$I" >/dev/null && ok "host snapshots are not in the catalogue" || bad "host snapshot listed"
jq -e '.version == 1 and (.generated|type) == "number" and (.node|length) > 0 and .storage_id == "pbo" and (.staging_dir|endswith("/staging"))
       and (.spool_dir|endswith("/spool")) and .tiers.cache == {enabled:true, ok:true, count:3} and .tiers.offsite == {enabled:true, ok:true, count:3}' "$I" >/dev/null \
    && ok "header: version, generated, node, storage_id, staging_dir, spool_dir, tiers" || bad "header: $(jq -c 'del(.entries)' "$I")"
jq -e --arg ts "$old8001_ts" '[.entries[] | select(.vmid == 8001)] | length == 2
    and (map(select(.ts == $ts))[0] | .offsite_only == true and .snapshots.cache == null and (.snapshots.offsite|length) == 64)
    and (map(select(.ts != $ts))[0] | .offsite_only == false and (.snapshots.cache|length) == 64 and (.snapshots.offsite|length) == 64)' "$I" >/dev/null \
    && ok "merge by vmid+ts: the old 8001 is offsite only, the new one in both tiers" || bad "8001 merge: $(jq -c '[.entries[] | select(.vmid == 8001)]' "$I")"
jq -e '.entries[] | select(.vmid == 8002) | .offsite_only == false and .snapshots.offsite == null and .type == "lxc" and (.volname | endswith(".tar"))' "$I" >/dev/null \
    && ok "cache-only entry: offsite null, not offsite_only" || bad "8002: $(jq -c '.entries[] | select(.vmid == 8002)' "$I")"
jq -e --arg v "backup/vzdump-qemu-8003-$qts.vma" '.entries[] | select(.vmid == 8003) | .volname == $v and .type == "qemu" and .keep == "d30.w8" and .size > 300000 and (.ctime|type) == "number" and .ctime > 0' "$I" >/dev/null \
    && ok "qemu entry: .vma volname, keep from the keep= tag, size, ctime" || bad "8003: $(jq -c '.entries[] | select(.vmid == 8003)' "$I")"
jq -e '[.entries[] | select(.vmid != 8003) | .keep] | all(. == "default")' "$I" >/dev/null && ok "untagged snapshots: keep = default" || bad "keep default"
jq -e '[.entries[] | [.vmid, .ts]] == ([.entries[] | [.vmid, .ts]] | sort)' "$I" >/dev/null && ok "entries sorted by vmid, ts" || bad "sort"
# the listing helper must not have changed `pbo list`
lst="$($BIN --json list 2>/dev/null)"
jq -e '.archives | length == 3 and all(.[]; (has("path") or has("epoch") or has("keep_tag")) | not)' >/dev/null 2>&1 <<<"$lst" \
    && ok "list output unchanged (no catalogue fields)" || bad "list: $(head -c 300 <<<"$lst")"

# --- refresh to PBO_CATALOG; then an unreadable tier fails and keeps the old file ---
$BIN catalog refresh >/dev/null 2>&1 && jq -e '.entries | length == 4' "$RUN/catalog/index.json" >/dev/null \
    && ok "refresh writes PBO_CATALOG" || bad "refresh default path"
before="$(sha "$RUN/catalog/index.json")"
mkcfg "$RUN/config-badoff" "RESTIC_OFFSITE_REPO=$RUN/no-such-repo"
PBO_CONFIG="$RUN/config-badoff" $BIN catalog refresh >/dev/null 2>"$RUN/err"; rc=$?
[[ $rc == 69 && "$(sha "$RUN/catalog/index.json")" == "$before" ]] && ok "unreadable offsite tier: exit 69, old index kept byte for byte" || bad "bad offsite rc=$rc"
grep -q 'offsite repo .* not readable' "$RUN/err" && ok "unreadable tier is named" || bad "err: $(tail -2 "$RUN/err")"
mkcfg "$RUN/config-badpass" "RESTIC_PASSWORD_FILE=$RUN/wrongpass"; printf 'nope\n' > "$RUN/wrongpass"; chmod 600 "$RUN/wrongpass"
PBO_CONFIG="$RUN/config-badpass" $BIN --json catalog refresh >"$RUN/out.json" 2>/dev/null; rc=$?
[[ $rc == 69 && "$(sha "$RUN/catalog/index.json")" == "$before" ]] && jq -e '.ok == false' "$RUN/out.json" >/dev/null \
    && ok "wrong password (cache unreadable): exit 69, JSON error, old index kept" || bad "bad pass rc=$rc $(cat "$RUN/out.json")"
[[ -z "$(find "$RUN/catalog" -name '.index.*')" ]] && ok "failed refresh leaves no temp file" || bad "temp after failure"
PBO_CONFIG="$RUN/config-badoff" $BIN catalog refresh --out "$RUN/never.json" >/dev/null 2>&1
[[ ! -e "$RUN/never.json" ]] && ok "failed refresh never creates a new (empty) index" || bad "empty index written"
OFFSITE_ENABLED=false $BIN --json catalog refresh --out "$RUN/cacheonly.json" >/dev/null 2>&1
jq -e '.tiers.offsite == {enabled:false, ok:null, count:0} and (.entries | length == 3) and all(.entries[]; .snapshots.offsite == null)' "$RUN/cacheonly.json" >/dev/null \
    && ok "offsite disabled: cache tier only, offsite marked off" || bad "cache only: $(jq -c '.tiers' "$RUN/cacheonly.json" 2>/dev/null)"
$BIN catalog refresh --bogus >/dev/null 2>&1; [[ $? == 64 ]] && ok "unknown refresh flag → EX_USAGE" || bad "refresh flag"

# --- show ---
out="$($BIN --json catalog show 2>/dev/null)"
jq -e '.schema == 1 and .command == "catalog" and .ok and (.catalog.entries | length == 4) and (.age_seconds|type) == "number"' >/dev/null 2>&1 <<<"$out" \
    && ok "show --json: envelope + index" || bad "show: $(head -c 300 <<<"$out")"
$BIN catalog show 2>/dev/null | grep -q '(offsite only)' && ok "show: human table marks offsite-only" || bad "show human"

# --- materialize ---
for b in "../etc/passwd" "vzdump-lxc-8001-2026_01_01-00_00_00.tar.zst" "vzdump-lxc-8001-2026_01_01-00_00_00.tar/../x" \
         "x/vzdump-lxc-8001-2026_01_01-00_00_00.tar" "vzdump-host-8001-2026_01_01-00_00_00.tar" "vzdump-lxc-8001-2026_1_01-00_00_00.tar" ""; do
    $BIN catalog materialize "$b" >/dev/null 2>&1; rc=$?
    [[ $rc == 64 ]] || bad "bad basename '$b' not refused (rc=$rc)"
done
[[ ! -e "$RUN/staging" ]] && ok "bad basenames refused (EX_USAGE), nothing staged" || bad "staging created by a refused name"
$BIN catalog materialize vzdump-lxc-8001-1999_01_01-00_00_00.tar >/dev/null 2>&1; [[ $? == 65 ]] && ok "unknown archive → EX_DATAERR" || bad "unknown archive"

new8001="$(jq -r --arg ts "$old8001_ts" '.entries[] | select(.vmid == 8001 and .ts != $ts) | .volname | sub("backup/";"")' "$RUN/catalog/index.json")"
out="$($BIN --json catalog materialize "$new8001" 2>"$RUN/err")"; rc=$?
p="$(jq -r '.path // empty' <<<"$out" 2>/dev/null)"
[[ $rc == 0 && "$p" == "$RUN/staging/$new8001" && -f "$p" && ! -L "$p" ]] && jq -e '.tier == "cache" and .method == "dump" and .reused == false' >/dev/null <<<"$out" \
    && ok "materialize (cache tier): restic dump to staging, {path} in --json" || bad "materialize cache rc=$rc $out $(tail -2 "$RUN/err")"
[[ -n "$p" && -f "$p" && "$(sha "$p")" == "$(sha "$RUN/orig/$new8001")" ]] && ok "materialized archive is byte-identical to the original (sha256)" || bad "sha mismatch for $new8001"
[[ "$(stat -c %a "$RUN/staging")" == 700 && "$(stat -c %a "$p")" == 600 ]] && ok "staging dir 0700, archive 0600" || bad "staging modes $(stat -c %a "$RUN/staging") $(stat -c %a "$p")"
[[ -z "$(find "$RUN/staging" -name '*.part.*')" ]] && ok "no .part left behind" || bad ".part left"
out="$($BIN --json catalog materialize "$new8001" 2>/dev/null)"
jq -e '.reused == true' >/dev/null 2>&1 <<<"$out" && ok "second materialize reuses the staged file" || bad "reuse: $out"

oldb="vzdump-lxc-8001-$old8001_ts.tar"
out="$($BIN --json catalog materialize "$oldb" 2>"$RUN/err")"; rc=$?
p="$(jq -r '.path // empty' <<<"$out" 2>/dev/null)"
[[ $rc == 0 && -n "$p" ]] && jq -e '.tier == "offsite" and .method == "dump"' >/dev/null <<<"$out" && [[ "$(sha "$p")" == "$(sha "$RUN/orig/$oldb")" ]] \
    && ok "offsite-only archive: dumped from offsite, byte-identical" || bad "offsite materialize rc=$rc $out $(tail -2 "$RUN/err")"
qb="vzdump-qemu-8003-$qts.vma"
out="$(PVE_CATALOG_MOUNT=true MOCK_SYSTEMCTL_UNITS="" $BIN --json catalog materialize "$qb" 2>"$RUN/err")"; rc=$?
p="$(jq -r '.path // empty' <<<"$out" 2>/dev/null)"
[[ $rc == 0 && -n "$p" && "$(sha "$p")" == "$(sha "$RUN/orig/$qb")" ]] && jq -e '.method == "dump"' >/dev/null <<<"$out" \
    && ok "PVE_CATALOG_MOUNT=true without pbo-mount.service: falls back to dump (qemu .vma, identical)" || bad "mount fallback rc=$rc $out $(tail -2 "$RUN/err")"
# mount path: pbo-mount.service "installed" (mock), the archive at the layout
# _catalog_mount_file expects inside a fake mount dir → a symlink into it
qsnap="$(jq -r --arg v "backup/$qb" '.entries[] | select(.volname == $v) | .snapshots.cache' "$RUN/catalog/index.json")"
fm="$RUN/fakemnt/ids/${qsnap:0:8}$RUN/cache/8003"; mkdir -p "$fm"; cp "$RUN/orig/$qb" "$fm/"
rm -f "$RUN/staging/$qb"; : > "$MOCK_LOG"
out="$(PVE_CATALOG_MOUNT=true PVE_CATALOG_MOUNT_DIR="$RUN/fakemnt" MOCK_SYSTEMCTL_UNITS="pbo-mount.service" $BIN --json catalog materialize "$qb" 2>"$RUN/err")"; rc=$?
[[ $rc == 0 && -L "$RUN/staging/$qb" && "$(readlink "$RUN/staging/$qb")" == "$fm/$qb" ]] && jq -e '.method == "mount" and .tier == "cache"' >/dev/null <<<"$out" \
    && ok "PVE_CATALOG_MOUNT=true: stages a symlink into the mount" || bad "mount path rc=$rc $out $(tail -2 "$RUN/err")"
rm -f "$RUN/staging/$qb" "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active"; rm -rf "$RUN/fakemnt"; : > "$MOCK_LOG"
out="$(PVE_CATALOG_MOUNT=true PVE_CATALOG_MOUNT_DIR="$RUN/fakemnt" CATALOG_MOUNT_WAIT=1 MOCK_SYSTEMCTL_UNITS="pbo-mount.service" $BIN --json catalog materialize "$qb" 2>/dev/null)"; rc=$?
[[ $rc == 0 && -f "$RUN/staging/$qb" && ! -L "$RUN/staging/$qb" ]] && jq -e '.method == "dump"' >/dev/null <<<"$out" \
    && grep -q '^systemctl start pbo-mount.service' "$MOCK_LOG" && ok "mount not up: starts pbo-mount; the archive does not show: falls back to dump" || bad "mount fallback rc=$rc $out"
rm -f "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active"
# the default (no PVE_CATALOG_MOUNT in the config) is the mount; false keeps restic dump
rm -f "$RUN/staging/$qb"; mkdir -p "$fm"; cp "$RUN/orig/$qb" "$fm/"; : > "$MOCK_LOG"
out="$(PVE_CATALOG_MOUNT_DIR="$RUN/fakemnt" MOCK_SYSTEMCTL_UNITS="pbo-mount.service" $BIN --json catalog materialize --background "$qb" 2>"$RUN/err")"; rc=$?
[[ $rc == 0 && -L "$RUN/staging/$qb" && "$(readlink "$RUN/staging/$qb")" == "$fm/$qb" ]] && jq -e '.method == "mount"' >/dev/null <<<"$out" \
    && ok "default config + --background (a GUI request): a cache archive is linked through the mount inline" || bad "bg mount rc=$rc $out $(tail -2 "$RUN/err")"
rm -f "$RUN/staging/$qb" "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active"; : > "$MOCK_LOG"
out="$(PVE_CATALOG_MOUNT=false PVE_CATALOG_MOUNT_DIR="$RUN/fakemnt" MOCK_SYSTEMCTL_UNITS="pbo-mount.service" $BIN --json catalog materialize "$qb" 2>/dev/null)"; rc=$?
[[ $rc == 0 && -f "$RUN/staging/$qb" && ! -L "$RUN/staging/$qb" ]] && jq -e '.method == "dump"' >/dev/null <<<"$out" && ! grep -q 'systemctl start' "$MOCK_LOG" \
    && ok "PVE_CATALOG_MOUNT=false: restic dump, the mount is never started" || bad "mount off rc=$rc $out"
# --background, the mount up but the archive not in it yet (a new snapshot shows
# after a delay): no long wait in the request, exit 75 and a detached staging
rm -f "$RUN/staging/$qb"; rm -rf "$RUN/fakemnt"; : > "$MOCK_LOG"
t0="$(date +%s)"
out="$(PVE_CATALOG_MOUNT_DIR="$RUN/fakemnt" CATALOG_MOUNT_BG_WAIT=1 CATALOG_MOUNT_WAIT=1 MOCK_SYSTEMCTL_UNITS="pbo-mount.service" $BIN --json catalog materialize --background "$qb" 2>/dev/null)"; rc=$?
el=$(( $(date +%s) - t0 ))
[[ $rc == 75 && $el -le 8 ]] && jq -e '.error | test("started staging .* cache repo")' >/dev/null 2>&1 <<<"$out" \
    && ok "--background, archive not in the mount: exit 75 after the short wait (${el}s), staging continues detached" || bad "bg mount miss rc=$rc ${el}s $out"
for _ in $(seq 1 120); do [[ -f "$RUN/staging/$qb" ]] && flock -n "$RUN/lock/pbo.stage.$qb" true && break; sleep 0.5; done
[[ -f "$RUN/staging/$qb" && ! -L "$RUN/staging/$qb" && "$(sha "$RUN/staging/$qb")" == "$(sha "$RUN/orig/$qb")" ]] \
    && ok "--background, archive not in the mount: the detached run fell back to restic dump (identical)" || bad "bg detached dump: $(ls -la "$RUN/staging")"
rm -f "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active"
# human mode prints the path alone on stdout's last line
[[ "$($BIN catalog materialize "$qb" 2>/dev/null | tail -1)" == "$RUN/staging/$qb" ]] && ok "materialize (human): prints the path" || bad "human path"
# the snapshot must really hold that archive: a lying index is refused
jq --arg v "backup/$qb" '(.entries[] | select(.volname == $v) | .volname) |= "backup/vzdump-qemu-8003-2026_01_02-03_04_06.vma"' "$RUN/catalog/index.json" > "$RUN/liar.json"
cp "$RUN/catalog/index.json" "$RUN/good.json"; cp "$RUN/liar.json" "$RUN/catalog/index.json"
$BIN catalog materialize vzdump-qemu-8003-2026_01_02-03_04_06.vma >/dev/null 2>&1; rc=$?
[[ $rc == 69 && ! -e "$RUN/staging/vzdump-qemu-8003-2026_01_02-03_04_06.vma" ]] && ok "archive missing from its snapshot: refused, nothing staged" || bad "liar rc=$rc"
cp "$RUN/good.json" "$RUN/catalog/index.json"

# --- materialize --background (the plugin inside a synchronous PVE API request) ---
stage_free() { flock -n "$RUN/lock/pbo.stage.$1" true; }
rm -f "$RUN/staging/$oldb"
t0="$(date +%s%N)"; out="$($BIN --json catalog materialize --background "$oldb" 2>/dev/null)"; rc=$?; t1="$(date +%s%N)"
[[ $rc == 75 && ! -e "$RUN/staging/$oldb" ]] && jq -e '.ok == false and (.error | test("started staging .* offsite repo .*retry in a few minutes"))' >/dev/null 2>&1 <<<"$out" \
    && ok "--background, not staged: exit 75 at once with 'retry' ($(( (t1 - t0) / 1000000 )) ms)" || bad "--background rc=$rc $out"
for _ in $(seq 1 120); do [[ -f "$RUN/staging/$oldb" ]] && stage_free "$oldb" && break; sleep 0.5; done
[[ -f "$RUN/staging/$oldb" && "$(sha "$RUN/staging/$oldb")" == "$(sha "$RUN/orig/$oldb")" ]] && ls "$RUN/state/jobs/stage-$oldb"-*.log >/dev/null 2>&1 \
    && ok "--background: the detached materialize staged it (byte-identical, job log)" || bad "--background: nothing staged: $(cat "$RUN/state/jobs"/stage-*.log 2>/dev/null | tail -3)"
out="$($BIN --json catalog materialize --background "$oldb" 2>/dev/null)"; rc=$?
[[ $rc == 0 ]] && jq -e --arg p "$RUN/staging/$oldb" '.path == $p and .reused == true' >/dev/null 2>&1 <<<"$out" \
    && ok "--background, already staged: the path at once" || bad "--background staged rc=$rc $out"
rm -f "$RUN/staging/$oldb"; nlog="$(ls "$RUN/state/jobs"/stage-*.log | wc -l)"
( flock 9 && exec sleep 30 ) 9>>"$RUN/lock/pbo.stage.$oldb" & holder=$!
sleep 0.3
out="$($BIN --json catalog materialize --background "$oldb" 2>/dev/null)"; rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[[ $rc == 75 && "$(ls "$RUN/state/jobs"/stage-*.log | wc -l)" == "$nlog" ]] && jq -e '.error | test("staging .* right now")' >/dev/null 2>&1 <<<"$out" \
    && ok "--background while it is being staged: exit 75, no second background run" || bad "--background busy rc=$rc $out"
$BIN catalog materialize "$oldb" >/dev/null 2>&1 || bad "re-stage $oldb"

# --- catalog _mount (pbo-mount.service's ExecStart): allow_other, root-only parent ---
printf '#!/bin/sh\necho "restic $*" >> "%s/restic-mount.calls"\n' "$RUN" > "$RUN/bin/restic-stub"; chmod 0755 "$RUN/bin/restic-stub"
mkdir -p "$RUN/openparent"; chmod 0755 "$RUN/openparent"
RESTIC_BIN="$RUN/bin/restic-stub" PVE_CATALOG_MOUNT_DIR="$RUN/openparent/mnt" $BIN catalog _mount >/dev/null 2>"$RUN/m.err"; rc=$?
[[ $rc == 78 && ! -s "$RUN/restic-mount.calls" ]] && grep -q 'must be owned by root with no group/other access' "$RUN/m.err" \
    && ok "catalog _mount: refuses a mount point whose parent others can enter (allow_other)" || bad "_mount open parent rc=$rc $(cat "$RUN/m.err")"
RESTIC_BIN="$RUN/bin/restic-stub" PVE_CATALOG_MOUNT_DIR="mnt" $BIN catalog _mount >/dev/null 2>&1; rc=$?
[[ $rc == 78 ]] && ok "catalog _mount: refuses a relative mount dir" || bad "_mount relative rc=$rc"
mkdir -p "$RUN/closed2/sub"; chmod 0700 "$RUN/closed2" "$RUN/closed2/sub"; ln -sfn "$RUN/openparent" "$RUN/closed2/link"
for d in "$RUN/closed2/sub/.." "$RUN/closed2/sub/." "$RUN/closed2/link"; do
    RESTIC_BIN="$RUN/bin/restic-stub" PVE_CATALOG_MOUNT_DIR="$d" $BIN catalog _mount >/dev/null 2>&1; rc=$?
    [[ $rc == 78 ]] || bad "_mount accepted $d (rc=$rc)"
done
[[ ! -s "$RUN/restic-mount.calls" ]] && ok "catalog _mount: refuses . / .. components and a symlinked mount path (would escape the root-only parent)" || bad "_mount escaped: $(cat "$RUN/restic-mount.calls")"
if [[ "$(id -u)" == 0 ]]; then
    mkdir -p "$RUN/closedparent"; chmod 0700 "$RUN/closedparent"
    RESTIC_BIN="$RUN/bin/restic-stub" PVE_CATALOG_MOUNT_DIR="$RUN/closedparent/mnt" $BIN catalog _mount >/dev/null 2>&1; rc=$?
    [[ $rc == 0 ]] && grep -qE "^restic -r .* mount --allow-other $RUN/closedparent/mnt\$" "$RUN/restic-mount.calls" \
        && ok "catalog _mount: restic mount --allow-other below a root-only parent" || bad "_mount ok rc=$rc $(cat "$RUN/restic-mount.calls" 2>/dev/null)"
fi

# --- release ---
touch -d '-2 hours' "$RUN/staging/$new8001" "$RUN/staging/$oldb"
: > "$RUN/staging/$new8001.part.abc123"; touch -d '-2 hours' "$RUN/staging/$new8001.part.abc123"
: > "$RUN/staging/unrelated.txt"; touch -d '-2 hours' "$RUN/staging/unrelated.txt"
orph="vzdump-lxc-8001-2001_01_01-00_00_00.tar"; : > "$RUN/staging/$orph"   # fresh, but not in the index (pruned)
$BIN --dry-run catalog release >/dev/null 2>&1
[[ -e "$RUN/staging/$new8001" ]] && ok "release --dry-run removes nothing" || bad "dry-run removed"
out="$($BIN --json catalog release 2>/dev/null)"
[[ ! -e "$RUN/staging/$new8001" && ! -e "$RUN/staging/$oldb" && ! -e "$RUN/staging/$new8001.part.abc123" && -e "$RUN/staging/$qb" && -e "$RUN/staging/unrelated.txt" ]] \
    && jq -e '.removed == 4 and .kept == 1' >/dev/null 2>&1 <<<"$out" \
    && ok "release: archives and .part older than the TTL removed, a fresh one and foreign files kept" || bad "release: $out; $(ls "$RUN/staging")"
[[ ! -e "$RUN/staging/$orph" ]] && jq -e '.orphaned == 1' >/dev/null 2>&1 <<<"$out" \
    && ok "release: a fresh staged archive no longer in the index (pruned) is removed" || bad "release orphan: $out"
: > "$MOCK_LOG"; : > "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active"
# an empty mount dir of our own: the host's /run/pbo/mnt may be in use for real
mkdir -p "$RUN/idlemnt"
out="$(PVE_CATALOG_MOUNT_DIR="$RUN/idlemnt" $BIN --json catalog release --all 2>/dev/null)"
[[ ! -e "$RUN/staging/$qb" ]] && jq -e '.removed == 1 and .mount_stopped == true' >/dev/null 2>&1 <<<"$out" && [[ ! -e "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active" ]] \
    && ok "release --all: everything removed, idle pbo-mount stopped" || bad "release --all: $out"
: > "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active"; ln -s "$RUN/idlemnt/ids/x/f" "$RUN/staging/$qb"
out="$(PVE_CATALOG_MOUNT_DIR="$RUN/idlemnt" $BIN --json catalog release 2>/dev/null)"
jq -e '.mount_stopped == false' >/dev/null 2>&1 <<<"$out" && [[ -e "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active" ]] \
    && ok "release: a staged symlink into the mount keeps pbo-mount running" || bad "mount stopped while in use: $out"
# a symlink older than PVE_STAGING_LINK_TTL (15 min) goes, long before the 6 h TTL, and the idle mount stops
touch -h -d '-20 min' "$RUN/staging/$qb"
out="$(PVE_CATALOG_MOUNT_DIR="$RUN/idlemnt" $BIN --json catalog release 2>/dev/null)"
[[ ! -L "$RUN/staging/$qb" && ! -e "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active" ]] && jq -e '.removed == 1 and .mount_stopped == true' >/dev/null 2>&1 <<<"$out" \
    && ok "release: a mount symlink idle for 20 min is removed and pbo-mount stops (its repo lock goes)" || bad "link ttl: $out; $(ls -la "$RUN/staging")"
# ... unless a restore reads through the mount right now
mkdir -p "$RUN/idlemnt/ids/x"; : > "$RUN/idlemnt/ids/x/f"; : > "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active"
ln -s "$RUN/idlemnt/ids/x/f" "$RUN/staging/$qb"; touch -h -d '-20 min' "$RUN/staging/$qb"
sleep 30 8<"$RUN/idlemnt/ids/x/f" & lreader=$!; sleep 0.3
out="$(PVE_CATALOG_MOUNT_DIR="$RUN/idlemnt" $BIN --json catalog release 2>/dev/null)"
kill "$lreader" 2>/dev/null; wait "$lreader" 2>/dev/null
[[ -L "$RUN/staging/$qb" && -e "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active" ]] && jq -e '.removed == 0 and .mount_stopped == false' >/dev/null 2>&1 <<<"$out" \
    && ok "release: an old mount symlink stays while a process reads through the mount" || bad "busy link: $out"
rm -f "$RUN/staging/$qb"; rm -rf "$RUN/idlemnt/ids"
mkdir -p "$RUN/fakemnt2"; : > "$RUN/fakemnt2/f"
sleep 30 9<"$RUN/fakemnt2/f" & reader=$!
sleep 0.3
out="$(PVE_CATALOG_MOUNT_DIR="$RUN/fakemnt2" $BIN --json catalog release --all 2>/dev/null)"
jq -e '.mount_stopped == false' >/dev/null 2>&1 <<<"$out" && [[ -e "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active" ]] \
    && ok "release: no staged symlink, but a process reads through the mount: pbo-mount keeps running" || bad "busy mount stopped: $out"
$BIN catalog release --bogus >/dev/null 2>&1; [[ $? == 64 ]] && ok "unknown release flag → EX_USAGE" || bad "release flag"
grep -nE '^ExecStart=' systemd/pbo-catalog.service > "$RUN/unit.exec"
[[ "$(sed -n 1p "$RUN/unit.exec")" == *'ExecStart=-/usr/local/lib/pbo/pbo catalog release' && "$(sed -n 2p "$RUN/unit.exec")" == *'ExecStart=/usr/local/lib/pbo/pbo catalog refresh' ]] \
    && ok "pbo-catalog.service runs 'catalog release' (failure ignored), then 'catalog refresh'" || bad "unit: $(cat "$RUN/unit.exec")"

# --- prune and verify stop an active mount first (integration on); never under a reader ---
mkcfg "$RUN/config-both" "PBO_INTEGRATION=both"
: > "$MOCK_LOG"; : > "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active"
$BIN prune >/dev/null 2>&1; rc=$?; $BIN verify >/dev/null 2>&1; rc2=$?
[[ $rc == 0 && $rc2 == 0 && -e "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active" ]] && ! grep -q '^systemctl' "$MOCK_LOG" \
    && ok "standalone: prune and verify make no systemctl call at all" || bad "standalone mount calls rc=$rc/$rc2: $(cat "$MOCK_LOG")"
: > "$MOCK_LOG"
PVE_CATALOG_MOUNT_DIR="$RUN/fakemnt2" CATALOG_MOUNT_BUSY_WAIT=0 PBO_CONFIG="$RUN/config-both" $BIN prune > "$RUN/pr.out" 2>&1; rc=$?
[[ $rc == 75 && -e "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active" ]] && ! grep -q '^systemctl stop' "$MOCK_LOG" && grep -q 'in use' "$RUN/pr.out" \
    && ok "prune while a restore reads through the mount: exit 75, the mount stays up" || bad "busy prune rc=$rc $(tail -2 "$RUN/pr.out")"
PVE_CATALOG_MOUNT_DIR="$RUN/fakemnt2" CATALOG_MOUNT_BUSY_WAIT=0 PBO_CONFIG="$RUN/config-both" $BIN verify >/dev/null 2>&1; rc=$?
[[ $rc == 75 && -e "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active" ]] && ok "verify while a restore reads through the mount: exit 75" || bad "busy verify rc=$rc"
kill "$reader" 2>/dev/null; wait "$reader" 2>/dev/null
( sleep 30 9<"$RUN/fakemnt2/f" & echo $! > "$RUN/reader.pid"; wait ) & sleep 0.3
( sleep 2; kill "$(cat "$RUN/reader.pid")" 2>/dev/null ) &
PVE_CATALOG_MOUNT_DIR="$RUN/fakemnt2" CATALOG_MOUNT_BUSY_WAIT=20 PBO_CONFIG="$RUN/config-both" $BIN prune > "$RUN/pr.out" 2>&1; rc=$?
[[ $rc == 0 && ! -e "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active" ]] && grep -q 'waiting up to 20s' "$RUN/pr.out" \
    && ok "prune waits for the reader to finish, then stops pbo-mount" || bad "prune wait rc=$rc $(tail -3 "$RUN/pr.out")"
wait
: > "$MOCK_LOG"; : > "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active"
PBO_CONFIG="$RUN/config-both" $BIN prune >/dev/null 2>&1; rc=$?
[[ $rc == 0 && ! -e "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active" ]] && grep -q '^systemctl stop pbo-mount.service' "$MOCK_LOG" \
    && ok "prune stops an active pbo-mount before it runs" || bad "prune mount stop rc=$rc: $(cat "$MOCK_LOG")"
: > "$MOCK_LOG"; : > "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active"
PBO_CONFIG="$RUN/config-both" $BIN verify >/dev/null 2>&1; rc=$?
[[ $rc == 0 && ! -e "$MOCK_SYSTEMCTL_DIR/pbo-mount.service.active" ]] && ok "verify stops an active pbo-mount" || bad "verify mount stop rc=$rc"
: > "$MOCK_LOG"
PBO_CONFIG="$RUN/config-both" $BIN prune >/dev/null 2>&1; PBO_CONFIG="$RUN/config-both" $BIN --dry-run prune >/dev/null 2>&1
! grep -qE '^systemctl (stop|start)' "$MOCK_LOG" && ok "inactive mount: prune makes no stop/start call" || bad "calls: $(cat "$MOCK_LOG")"

# --- _catalog_add_entry (ingest): incremental insert, no repo listing ---
H() { bash -c 'set -uo pipefail; SELF_DIR="$PWD"; for l in common json cluster appendonly ownership restic catalog; do source "lib/$l.sh"; done
               load_config; '"$1"; }
cp "$RUN/good.json" "$RUN/catalog/index.json"
: > "$MOCK_LOG"; mv "$RUN/repo-cache" "$RUN/repo-cache.away"
H '_catalog_add_entry 8001 2026_03_04-05_06_07 lxc vzdump-lxc-8001-2026_03_04-05_06_07.tar 1234 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ""' >/dev/null 2>&1; rc=$?
mv "$RUN/repo-cache.away" "$RUN/repo-cache"
jq -e '(.entries | length == 5) and (.entries[] | select(.volname == "backup/vzdump-lxc-8001-2026_03_04-05_06_07.tar")
       | .size == 1234 and .snapshots.cache == ("a" * 64) and .snapshots.offsite == null and .offsite_only == false and .keep == "default")
       and .tiers.cache.count == 4' "$RUN/catalog/index.json" >/dev/null 2>&1 && [[ $rc == 0 ]] \
    && ok "add_entry: inserted without reading a repo (cache repo moved away)" || bad "add_entry rc=$rc: $(jq -c '.tiers' "$RUN/catalog/index.json")"
H '_catalog_add_entry 8001 2026_03_04-05_06_07 lxc vzdump-lxc-8001-2026_03_04-05_06_07.tar 1234 "" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' >/dev/null 2>&1
jq -e '(.entries | length == 5) and (.entries[] | select(.volname == "backup/vzdump-lxc-8001-2026_03_04-05_06_07.tar")
       | .snapshots.cache == ("a" * 64) and .snapshots.offsite == ("b" * 64))' "$RUN/catalog/index.json" >/dev/null 2>&1 \
    && ok "add_entry: a second call fills the other tier, no duplicate" || bad "add_entry update"
H '_catalog_add_entry 8001 2026_03_04-05_06_07 lxc ../evil.tar 1 a b' >/dev/null 2>&1; rc=$?
[[ $rc != 0 ]] && jq -e '.entries | length == 5' "$RUN/catalog/index.json" >/dev/null && ok "add_entry: bad archive name refused" || bad "add_entry evil"
rm -f "$RUN/catalog/index.json"
H '_catalog_add_entry 8001 2026_03_04-05_06_07 lxc vzdump-lxc-8001-2026_03_04-05_06_07.tar 1 a ""' >/dev/null 2>&1; rc=$?
[[ $rc != 0 && ! -e "$RUN/catalog/index.json" ]] && ok "add_entry: no index → nothing written (never a one-entry index)" || bad "add_entry wrote a partial index"

# --- refresh hooks: run-schedule and prune refresh the index only with the integration on ---
rm -f "$RUN/catalog/index.json"
$BIN run-schedule >/dev/null 2>&1; $BIN prune >/dev/null 2>&1
[[ ! -e "$RUN/catalog/index.json" ]] && ok "standalone: run-schedule and prune do not touch the catalogue" || bad "standalone wrote the catalogue"
mkcfg "$RUN/config-both" "PBO_INTEGRATION=both"
PBO_CONFIG="$RUN/config-both" $BIN run-schedule > "$RUN/rs.out" 2>&1; rc=$?
newest="$(R "$RUN/repo-cache" snapshots --json --tag vmid=8001 2>/dev/null | jq -r 'sort_by(.time) | .[-1].id')"
[[ $rc == 0 ]] && jq -e --arg id "$newest" 'any(.entries[]; .snapshots.cache == $id)' "$RUN/catalog/index.json" >/dev/null 2>&1 \
    && grep -q 'run-schedule: catalogue refreshed' "$RUN/rs.out" && ok "both: run-schedule refreshes the catalogue (the new 8001 is in it)" || bad "run-schedule hook rc=$rc $(tail -3 "$RUN/rs.out")"
gen="$(jq .generated "$RUN/catalog/index.json")"; sleep 1.1
PBO_CONFIG="$RUN/config-both" $BIN --json prune > "$RUN/pr.out" 2>"$RUN/pr.err"; rc=$?
[[ $rc == 0 && "$(jq .generated "$RUN/catalog/index.json")" -gt "$gen" ]] && jq -e '.ok' "$RUN/pr.out" >/dev/null 2>&1 \
    && [[ "$(grep -c . "$RUN/pr.out")" == 1 ]] && ok "both: prune refreshes the catalogue, still one JSON object" || bad "prune hook rc=$rc $(cat "$RUN/pr.out")"
mkcfg "$RUN/config-blocked" "PBO_INTEGRATION=both" "PBO_CATALOG=$RUN/blocked/index.json"; : > "$RUN/blocked"
PBO_CONFIG="$RUN/config-blocked" $BIN prune > "$RUN/pr.out" 2>&1; rc=$?
[[ $rc == 0 ]] && grep -q 'prune: catalogue refresh failed' "$RUN/pr.out" && ok "refresh failure after prune is a warning, prune still exit 0" || bad "hook failure rc=$rc $(tail -3 "$RUN/pr.out")"

# --- dispatcher ---
$BIN catalog >/dev/null 2>&1; [[ $? == 64 ]] && ok "catalog without a subcommand → EX_USAGE" || bad "catalog usage"
$BIN --json help 2>/dev/null | jq -e '.usage | test("catalog refresh") and test("catalog materialize")' >/dev/null && ok "help lists the catalog commands" || bad "help"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
