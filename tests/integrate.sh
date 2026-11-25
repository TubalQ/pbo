#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/integrate.sh: `pbo integrate status|enable|disable` and doctor's
# integration checks (lib/integrate.sh, ADR 0006/0007). A REAL local restic repo;
# PVE (pvesm, pvesh, pveum, dpkg-query) and systemctl are mocked. storage.cfg and
# vzdump.conf are files under run/, the plugin is a stand-in file whose load
# test is PBO_PVE_PLUGIN_CHECK. Nothing on the host is touched.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE and NTFY_CREDS_FILE are the machine's
# own files: point them into the checkout, at paths nothing creates (a config
# line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.creds"
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
skip() { printf '  SKIP %s\n' "$1"; }
command -v restic >/dev/null 2>&1 || { echo "restic not installed, skipping integrate tests"; exit 0; }

printf 'pbo: integrate tests\n'
RUN="$ROOT/run/integrate"; rm -rf "$RUN"
mkdir -p "$RUN"/{cache,state,log,lock,conf,bin,sysd,plugin}
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm \
    tests/mocks/systemctl tests/mocks/dpkg-query tests/mocks/pveum "$RUN/bin/"
export PATH="$RUN/bin:$PATH" MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/calls"
export MOCK_SYSTEMCTL_DIR="$RUN/sysd" MOCK_SYSTEMCTL_ENABLED="" MOCK_STORAGE_CFG="$RUN/storage.cfg"
export PBO_INTEGRATE_ALLOW_NONROOT=1   # enable/disable without root (the suite may run unprivileged)
# the plugin stand-in and its load test: env, not config (a config value beats the env)
export PBO_PVE_PLUGIN_PATH="$RUN/plugin/PboPlugin.pm" PBO_PVE_PLUGIN_CHECK=true
: > "$MOCK_LOG"
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
printf '# stand-in for PboPlugin.pm\n' > "$RUN/plugin/PboPlugin.pm"
HOOK="$ROOT/lib/vzdump-hook"   # what pbo names from a repo checkout (no vzdump-hook next to ./pbo)
MARK="# pbo: added by 'pbo integrate enable' (remove with 'pbo integrate disable')"

# the PVE side as it is before pbo: one dir storage, a vzdump.conf with defaults
printf 'dir: local\n\tpath /var/lib/vz\n\tcontent iso,vztmpl,backup\n' > "$RUN/storage.cfg.orig"
printf '# vzdump default settings\n\n#tmpdir: DIR\nmode: snapshot\n' > "$RUN/vzdump.conf.orig"
reset_pve() { cp "$RUN/storage.cfg.orig" "$RUN/storage.cfg"; cp "$RUN/vzdump.conf.orig" "$RUN/vzdump.conf"; rm -f "$RUN"/sysd/*; }
reset_pve

mkcfg() { { cat <<EOF
CACHE_DIR=$RUN/cache
LOG_DIR=$RUN/log
STATE_DIR=$RUN/state
LOCK_DIR=$RUN/lock
BACKUP_ORDER=auto
LOCAL_REPO=true
OFFSITE_ENABLED=false
RESTIC_CACHE_REPO=$RUN/cache/repo
RESTIC_PASSWORD_FILE=$RUN/pass
RESTIC_CACHE_DIR=$RUN/rcache
NTFY_URL=
NTFY_CREDS_FILE=/nonexistent
NOTIFY_PVE=false
PBO_CATALOG=$RUN/catalog/index.json
PVE_STORAGE_CFG=$RUN/storage.cfg
VZDUMP_CONF=$RUN/vzdump.conf
VZDUMP_LOCK=$RUN/vzdump.lock
EOF
    for l in "$@"; do echo "$l"; done; } > "$RUN/config"; chmod 600 "$RUN/config"; }
mkcfg
export PBO_CONFIG="$RUN/config"
RESTIC_PASSWORD_FILE="$RUN/pass" restic init --repo "$RUN/cache/repo" >/dev/null 2>&1 || { echo "restic init failed"; exit 1; }

# P <args...>: run pbo, stdout → $out, stderr → $RUN/err, exit → $rc
P()  { out="$($BIN "$@" 2>"$RUN/err")"; rc=$?; }
PJ() { out="$($BIN --json "$@" 2>"$RUN/err")"; rc=$?; }
has() { if jq -e "$2" >/dev/null 2>&1 <<<"$out"; then ok "$1"; else bad "$1: rc=$rc $(head -c 500 <<<"$out") $(tail -3 "$RUN/err")"; fi; }
same() { cmp -s "$2" "$3" && ok "$1" || bad "$1: $(diff "$2" "$3" | head -5)"; }
mode_in_cfg() { sed -nE 's/^PBO_INTEGRATION=(.*)$/\1/p' "$RUN/config" | tail -1; }
n_calls() { grep -c -- "$1" "$MOCK_LOG"; }
snap() { cp "$RUN/storage.cfg" "$RUN/s.before"; cp "$RUN/vzdump.conf" "$RUN/v.before"; cp "$RUN/config" "$RUN/c.before"; }
unchanged() {   # <name>: storage.cfg, vzdump.conf and the config are as in the last snap
    if cmp -s "$RUN/storage.cfg" "$RUN/s.before" && cmp -s "$RUN/vzdump.conf" "$RUN/v.before" && cmp -s "$RUN/config" "$RUN/c.before"; then ok "$1"
    else bad "$1: $(diff "$RUN/s.before" "$RUN/storage.cfg"; diff "$RUN/v.before" "$RUN/vzdump.conf"; diff "$RUN/c.before" "$RUN/config")"; fi
}
doctor_has() {  # <name> <level> <regex>
    if jq -e --arg l "$2" --arg r "$3" 'any(.findings[]; .level == $l and (.message | test($r)))' >/dev/null 2>&1 <<<"$out"; then ok "$1"
    else bad "$1: $(jq -c '[.findings[] | select(.level != "ok") | .message]' <<<"$out" 2>/dev/null | head -c 700)"; fi
}
doctor_lacks() { # <name> <regex>
    if jq -e --arg r "$2" 'any(.findings[]; .level != "ok" and (.message | test($r))) | not' >/dev/null 2>&1 <<<"$out"; then ok "$1"
    else bad "$1: $(jq -c '[.findings[] | select(.level != "ok") | .message]' <<<"$out" 2>/dev/null | head -c 700)"; fi
}

# --- the tested PVE set is the plugin's ---------------------------------------------
want="$(sed -nE "s/^[[:space:]]*'([a-z0-9-]+)' => '([^']+)',.*/\1=\2/p" pve-plugin/PboPlugin.pm | paste -sd' ' -)"
got="$(bash -c 'source lib/integrate.sh; echo "$INTEG_TESTED"' 2>/dev/null)"
[[ -n "$want" && "$want" == "$got" ]] && ok "INTEG_TESTED matches %TESTED in PboPlugin.pm" || bad "tested set: plugin '$want', integrate '$got'"

# --- status (standalone) ------------------------------------------------------------
PJ integrate status
has "status: standalone, versions ok, plugin present+loaded, no storage, no hook" \
    '.ok and .mode == "standalone" and .versions_ok and .plugin.present and .plugin.loaded and (.storage.present | not)
     and (.hook.configured | not) and .spool.files == 0 and (.catalog.present | not) and .jobs == [] and .recipe.source == "planned"'
jq -e --arg h "$HOOK" --arg s "$RUN/cache/spool" '.recipe.vzdump_conf == "script: \($h)" and (.recipe.storage_cfg | test("^pbo: pbo\n\tcontent backup\n\tnodes .+\n\tpath \($s)$"))' >/dev/null 2>&1 <<<"$out" \
    && ok "status: recipe stanza and hook line" || bad "status recipe: $(jq -c .recipe <<<"$out")"
out="$($BIN integrate status --json 2>/dev/null)"
jq -e '.schema == 1 and .command == "integrate" and .mode == "standalone"' >/dev/null 2>&1 <<<"$out" && ok "status --json after the subcommand works too" || bad "status --json: $(head -c 300 <<<"$out")"
P integrate status
grep -q '^mode: *standalone' <<<"$out" && grep -q 'recipe (planned)' <<<"$out" && ok "status: human view" || bad "status human: $out"

# --- dry-run changes nothing -----------------------------------------------------------
snap; : > "$MOCK_LOG"
PJ --dry-run integrate enable both
has "dry-run enable: plans storage, hook, timer and mode" \
    '.ok and .dry_run and .changed and any(.steps[]; test("^run: pvesm add pbo pbo --content backup --nodes .+ --path .+/cache/spool$"))
     and any(.steps[]; test("^edit: .+/vzdump.conf$")) and any(.steps[]; test("systemctl enable --now pbo-catalog.timer"))
     and any(.steps[]; test("PBO_INTEGRATION=both")) and (.diffs[0] | test("\\+script: "))'
unchanged "dry-run enable: storage.cfg, vzdump.conf and config untouched"
[[ "$(n_calls '^pvesm add')" == 0 && "$(n_calls '^systemctl enable')" == 0 && ! -e "$RUN/catalog/index.json" && ! -d "$RUN/cache/spool" ]] \
    && ok "dry-run enable: no pvesm/systemctl change, no catalogue, no spool" || bad "dry-run calls: $(cat "$MOCK_LOG")"
P --dry-run integrate enable both
grep -q '^+script: ' <<<"$out" && grep -q "^+$MARK" <<<"$out" && ok "dry-run enable: prints the vzdump.conf diff" || bad "dry-run diff: $out"

# --- refusals (nothing changed) ------------------------------------------------------------
snap
P integrate enable both
[[ $rc == 64 ]] && grep -q 'not a terminal, add --yes' "$RUN/err" && ok "enable without --yes off a terminal: refused" || bad "no --yes: rc=$rc $(tail -2 "$RUN/err")"
MOCK_DPKG_VERSIONS="pve-manager=9.2.20 libpve-storage-perl=9.1.17 qemu-server=9.2.20 pve-container=6.1.24" P integrate enable both --yes
[[ $rc == 69 ]] && grep -q 'Proxmox integration needs pve-manager >= 9.2.29 and libpve-storage-perl >= 9.1.18 (installed: 9.2.20, 9.1.17)' "$RUN/err" \
    && grep -q 'nothing was changed' "$RUN/err" && ok "version refusal (EX_UNAVAILABLE, both versions named)" || bad "version refusal: rc=$rc $(tail -2 "$RUN/err")"
MOCK_DPKG_VERSIONS="pve-container=6.1.24" P integrate enable both --yes
[[ $rc == 69 ]] && grep -q '(installed: not installed, not installed)' "$RUN/err" && ok "version refusal: packages missing" || bad "missing pkgs: rc=$rc $(tail -1 "$RUN/err")"
PBO_PVE_PLUGIN_PATH="$RUN/plugin/nope.pm" P integrate enable both --yes
[[ $rc == 69 ]] && grep -q 'nope.pm is not installed (./install.sh --integration both' "$RUN/err" && ok "plugin missing: refused" || bad "plugin missing: rc=$rc $(tail -1 "$RUN/err")"
PBO_PVE_PLUGIN_CHECK=false P integrate enable both --yes
[[ $rc == 69 ]] && grep -q 'does not load into PVE::Storage' "$RUN/err" && ok "plugin not loadable: refused" || bad "plugin load: rc=$rc $(tail -1 "$RUN/err")"
PBO_VZDUMP_HOOK="$RUN/nohook" P integrate enable both --yes
[[ $rc == 69 ]] && grep -q "the vzdump hook $RUN/nohook is missing or not executable" "$RUN/err" && ok "hook missing: refused (a script: line to nothing fails every vzdump)" || bad "hook missing: rc=$rc $(tail -1 "$RUN/err")"
PVE_SPOOL_DIR=/proc/pbo-spool P integrate enable both --yes
[[ $rc == 69 ]] && grep -q 'PVE_SPOOL_DIR /proc/pbo-spool is not on the filesystem of CACHE_DIR' "$RUN/err" && ok "spool on another filesystem: refused" || bad "spool fs: rc=$rc $(tail -1 "$RUN/err")"
cp "$RUN/config" "$RUN/config.good"; sed -i "s#^RESTIC_CACHE_REPO=.*#RESTIC_CACHE_REPO=$RUN/norepo#" "$RUN/config"
P integrate enable both --yes
cp "$RUN/config.good" "$RUN/config"
[[ $rc == 69 ]] && grep -q 'cache repo .*norepo is not readable' "$RUN/err" && ok "unreadable repo: refused" || bad "repo: rc=$rc $(tail -1 "$RUN/err")"
printf '\nnfs: pbo\n\tpath /mnt/pve/pbo\n\tcontent backup\n' >> "$RUN/storage.cfg"; snap
P integrate enable both --yes
[[ $rc == 69 ]] && grep -q "PVE already has a storage 'pbo' of type nfs" "$RUN/err" && ok "storage id taken by another type: refused" || bad "id taken: rc=$rc $(tail -1 "$RUN/err")"
unchanged "id taken: nothing changed"
cp "$RUN/storage.cfg.orig" "$RUN/storage.cfg"
printf 'script: /usr/local/bin/my-hook\n' >> "$RUN/vzdump.conf"; cp "$RUN/vzdump.conf" "$RUN/vz.foreign"; snap
P integrate enable integrated --yes
[[ $rc == 69 ]] && grep -q 'already runs a hook script (script: /usr/local/bin/my-hook)' "$RUN/err" && ok "foreign script: refused" || bad "foreign: rc=$rc $(tail -1 "$RUN/err")"
unchanged "foreign script: nothing changed"
P integrate enable integrated --catalog-only --yes
[[ $rc == 64 ]] && ok "integrated --catalog-only: refused (no backup target)" || bad "integrated catalog-only: rc=$rc"
: > "$MOCK_LOG"
PJ integrate enable both --catalog-only --yes
has "catalog-only with a foreign script: accepted" '.ok and .catalog_only and .changed'
same "catalog-only: vzdump.conf untouched (foreign script kept)" "$RUN/vz.foreign" "$RUN/vzdump.conf"
grep -qE "^pvesm add pbo pbo --content backup --nodes [^ ]+$" "$MOCK_LOG" && ok "catalog-only: storage added without --path" || bad "catalog-only add: $(grep pvesm "$MOCK_LOG")"
[[ "$(mode_in_cfg)" == both && -s "$RUN/catalog/index.json" ]] && ok "catalog-only: mode both written, catalogue refreshed" || bad "catalog-only mode: $(mode_in_cfg)"
[[ ! -d "$RUN/cache/spool" && -d "$RUN/cache/staging" && "$(stat -c %a "$RUN/cache/staging")" == 700 ]] && ok "catalog-only: staging 0700, no spool" || bad "catalog-only dirs: $(ls -la "$RUN/cache")"
cp "$RUN/vzdump.conf.orig" "$RUN/vzdump.conf"

# --- enable both (from catalog-only: the path converges), idempotent --------------------------------
: > "$MOCK_LOG"
P integrate enable both --yes
[[ $rc == 0 ]] && ok "enable both: exit 0" || bad "enable both: rc=$rc $(tail -3 "$RUN/err")"
grep -qE "^pvesm set pbo --path $RUN/cache/spool$" "$MOCK_LOG" && ! grep -q '^pvesm add' "$MOCK_LOG" && ok "enable both on a catalogue-only storage: pvesm set --path" || bad "converge: $(grep pvesm "$MOCK_LOG")"
grep -qx $'\tpath '"$RUN/cache/spool" "$RUN/storage.cfg" && ok "storage.cfg: the pbo storage has the spool path" || bad "storage.cfg: $(cat "$RUN/storage.cfg")"
{ cat "$RUN/vzdump.conf.orig"; printf '%s\nscript: %s\n' "$MARK" "$HOOK"; } > "$RUN/vz.want"
same "vzdump.conf: marker + script line appended, the rest byte for byte" "$RUN/vz.want" "$RUN/vzdump.conf"
[[ "$(stat -c %a "$RUN/cache/spool/dump")" == 755 && -e "$RUN/sysd/pbo-catalog.timer.enabled" && -e "$RUN/sysd/pbo-catalog.timer.active" ]] \
    && ok "spool/dump 0755, pbo-catalog.timer enabled and started" || bad "dirs/timer: $(ls "$RUN/sysd") $(stat -c %a "$RUN/cache/spool/dump" 2>&1)"
grep -q 'integrate enable mode=both' "$RUN/log/audit.log" && ok "enable: audit event" || bad "audit: $(tail -2 "$RUN/log/audit.log")"
: > "$MOCK_LOG"; cp "$RUN/storage.cfg" "$RUN/s.1"; cp "$RUN/vzdump.conf" "$RUN/v.1"
PJ integrate enable both --yes
has "second enable: unchanged" '.ok and .status == "unchanged" and (.changed | not) and .steps == []'
[[ "$(n_calls '^pvesm \(add\|set\)')" == 0 && "$(n_calls '^systemctl enable')" == 0 ]] && ok "second enable: no pvesm add/set, no systemctl enable" || bad "second enable calls: $(cat "$MOCK_LOG")"
same "second enable: storage.cfg unchanged" "$RUN/s.1" "$RUN/storage.cfg"
same "second enable: vzdump.conf unchanged (no duplicate line)" "$RUN/v.1" "$RUN/vzdump.conf"
[[ "$(grep -c '^pbo: pbo$' "$RUN/storage.cfg")" == 1 && "$(grep -c '^script:' "$RUN/vzdump.conf")" == 1 ]] && ok "one storage stanza, one script line" || bad "dupes"

# --- status after enable ---------------------------------------------------------------------
PJ integrate status
has "status: both, storage pbo with path, our hook, catalogue present, recipe from storage.cfg" \
    '.mode == "both" and .storage.present and .storage.type == "pbo" and (.storage.path | endswith("/cache/spool"))
     and .hook.configured and .hook.ours and .hook.current and .hook.executable and .hook.foreign_script == null
     and .spool.same_fs_as_cache and .catalog.present and .catalog.entries == 0 and .catalog_timer_enabled
     and .recipe.source == "storage.cfg" and (.recipe.storage_cfg | startswith("pbo: pbo\n"))'

# --- catalog-only downgrade removes our line (byte for byte), and back ----------------------------
: > "$MOCK_LOG"
P integrate enable both --catalog-only </dev/null
grep -q "pbo's hook line is removed from $RUN/vzdump.conf" "$RUN/err" && ! grep -q 'is not touched' "$RUN/err" \
    && ok "catalog-only downgrade: the question says the hook line goes" || bad "downgrade prompt: $(cat "$RUN/err")"
P integrate enable both --catalog-only --yes
same "catalog-only downgrade: our hook line removed, vzdump.conf as before" "$RUN/vzdump.conf.orig" "$RUN/vzdump.conf"
P integrate enable both --catalog-only </dev/null
grep -q "$RUN/vzdump.conf is not touched" "$RUN/err" && ok "catalog-only again: the question says vzdump.conf is not touched" || bad "co prompt: $(cat "$RUN/err")"
grep -q '^pvesm set pbo --delete path$' "$MOCK_LOG" && ! grep -q $'^\tpath' <(sed -n '/^pbo: pbo/,/^$/p' "$RUN/storage.cfg") && ok "catalog-only downgrade: path deleted" || bad "downgrade: $(grep pvesm "$MOCK_LOG")"
P integrate enable both --yes
same "back to a backup target: the line is back" "$RUN/vz.want" "$RUN/vzdump.conf"

# --- doctor ------------------------------------------------------------------------------------
for id in 101 102 103; do printf 'arch: amd64\nhostname: g%s\nrootfs: teststore:vm-%s-disk-0,size=1G\nunprivileged: 1\n' "$id" "$id" > "$MOCK_CONF_DIR/$id.conf"; done
node="$(jq -r '.nodename // empty' /etc/pve/.members 2>/dev/null)"; [[ -n "$node" ]] || node="$(hostname -s)"
printf '[{"vmid":101,"node":"%s","type":"lxc","name":"g101"},{"vmid":102,"node":"%s","type":"lxc","name":"g102"},
 {"vmid":103,"node":"%s","type":"lxc","name":"g103"}]\n' "$node" "$node" "$node" > "$RUN/res.json"
export MOCK_PVESH_JSON="$RUN/res.json"
printf 'features: fuse=1\n' >> "$MOCK_CONF_DIR/102.conf"
PJ doctor
doctor_has "doctor: storage OK line" ok "storage 'pbo' \\(pbo, backup target"
doctor_has "doctor: hook OK line" ok "vzdump hook .*vzdump-hook"
doctor_has "doctor: pbo-catalog.timer enabled" ok "pbo-catalog.timer enabled"
doctor_lacks "doctor: no integration problem after enable" "plugin|storage 'pbo'|hook|spool|PVE job"
printf '[{"id":"job-a","vmid":"101,102","storage":"pbo","compress":"zstd","script":"/x/hook","protected":1,"prune-backups":{"keep-last":3},"schedule":"04:30","notification-mode":"none"},
 {"id":"job-off","vmid":"103","storage":"pbo","enabled":0},
 {"id":"job-ka","vmid":"103","storage":"pbo","compress":"0","mode":"stop","prune-backups":{"keep-all":1}}]\n' > "$RUN/jobs.json"
export MOCK_PVESH_BACKUP_JSON="$RUN/jobs.json"
printf '[{"path":"/storage/pbo","roleid":"PVEDatastoreUser","type":"user","ugid":"alice@pve","propagate":1},
 {"path":"/","roleid":"NoAccess","type":"user","ugid":"bob@pve","propagate":1},
 {"path":"/","roleid":"Administrator","type":"user","ugid":"root@pam","propagate":1}]\n' > "$RUN/acl.json"
printf '[{"roleid":"PVEDatastoreUser","privs":"Datastore.AllocateSpace,Datastore.Audit"},{"roleid":"NoAccess","privs":""}]\n' > "$RUN/roles.json"
export MOCK_PVEUM_ACL_JSON="$RUN/acl.json" MOCK_PVEUM_ROLE_JSON="$RUN/roles.json"
touch -d '2 days ago' "$RUN/cache/spool/dump/vzdump-lxc-101-2026_01_01-01_00_00.tar"
mkdir -p "$RUN/state/ingest-copy"; : > "$RUN/state/ingest-copy/101_2026_01_01-01_00_00"; touch -d '2 days ago' "$RUN/state/ingest-copy/101_2026_01_01-01_00_00"
jq -c '.generated = 1000 | .entries += [{volname:"backup/vzdump-lxc-103-2026_01_01-01_00_00.tar",vmid:103,type:"lxc",ts:"2026_01_01-01_00_00",size:4000000000000000000,snapshots:{cache:"aaaaaaaa",offsite:null},offsite_only:false}]' "$RUN/catalog/index.json" > "$RUN/i.tmp" && mv "$RUN/i.tmp" "$RUN/catalog/index.json"
MOCK_DPKG_VERSIONS="pve-manager=9.3.1 libpve-storage-perl=9.1.18 qemu-server=9.2.20 pve-container=6.1.24" PJ doctor
doctor_has "doctor FAIL: job script replaces the hook" fail "PVE job job-a: its own hook script \\(script: /x/hook\\)"
doctor_has "doctor FAIL: job compression" fail "PVE job job-a: compression zstd"
doctor_has "doctor FAIL: job prune-backups (the API's object form)" fail "PVE job job-a: prune-backups keep-last=3"
doctor_lacks "doctor: prune-backups keep-all=1 (object form) is no problem" "PVE job job-ka: prune-backups"
doctor_has "doctor FAIL: job protected" fail "PVE job job-a: protected"
doctor_has "doctor FAIL: fuse guest in a snapshot-mode job" fail "PVE job job-a: guest\\(s\\) 102 must be backed up in stop mode"
doctor_has "doctor FAIL: spool archive older than 24 h" fail "1 archive\\(s\\) in the spool, the oldest 4[0-9]h old"
doctor_has "doctor FAIL: an ingested snapshot without its offsite copy for more than 24 h" fail "1 ingested snapshot\\(s\\) are in the cache repo but not offsite, 1 for more than 24h"
doctor_has "doctor WARN: disabled pbo job" warn "PVE job job-off: disabled"
doctor_has "doctor WARN: a stop-mode job needs more spool than is free" warn "PVE job job-ka runs in stop mode: its archives wait in the spool until job-end, about 4000000000000000000 bytes for guest\\(s\\) 103"
doctor_has "doctor WARN: notification-mode none" warn "PVE job job-a: notification-mode none"
doctor_has "doctor WARN: job within an hour of pbo.timer" warn "PVE job job-a: runs within an hour of pbo.timer \\(05:00\\)"
doctor_has "doctor WARN: ACL for a non-root user" warn "user alice@pve has role PVEDatastoreUser on /storage/pbo"
doctor_lacks "doctor: no ACL warning for NoAccess or root@pam" "bob@pve|root@pam has role"
doctor_has "doctor WARN: old catalogue" warn "catalogue is [0-9]+ min old"
doctor_has "doctor WARN: PVE newer than tested" warn "newer than the set the plugin was tested with: pve-manager 9.3.1"
rm -f "$RUN/cache/spool/dump/"vzdump-*; unset MOCK_PVESH_BACKUP_JSON MOCK_PVEUM_ACL_JSON
P catalog refresh
printf 'script: /usr/local/bin/other\n' > "$RUN/vzdump.conf"
MOCK_SYSTEMCTL_ENABLED="" PJ doctor
doctor_has "doctor FAIL: foreign hook" fail "runs a foreign hook \\(script: /usr/local/bin/other\\)"
: > "$RUN/vzdump.conf"
PJ doctor
doctor_has "doctor FAIL: no hook" fail "no hook in .*vzdump.conf"
printf 'script: %s\n' "$RUN/plugin/hook" > "$RUN/vzdump.conf"; : > "$RUN/plugin/hook"; chmod 0644 "$RUN/plugin/hook"
PBO_VZDUMP_HOOK="$RUN/plugin/hook" PJ doctor
doctor_has "doctor FAIL: the hook not executable" fail "the hook .*/plugin/hook is missing or not executable"
cp "$RUN/vz.want" "$RUN/vzdump.conf"
PBO_PVE_PLUGIN_PATH="$RUN/plugin/none.pm" PJ doctor
doctor_has "doctor FAIL: plugin missing" fail "storage plugin .*none.pm missing"
PBO_PVE_PLUGIN_CHECK=false PJ doctor
doctor_has "doctor FAIL: plugin not loadable" fail "does not load into PVE::Storage"
PVE_SPOOL_DIR=/proc/pbo-spool PJ doctor
doctor_has "doctor FAIL: storage path is not PVE_SPOOL_DIR" fail "has path .*/cache/spool, PVE_SPOOL_DIR is /proc/pbo-spool"
doctor_has "doctor FAIL: spool on another filesystem" fail "spool /proc/pbo-spool is not on CACHE_DIR's filesystem"
rm -f "$RUN/sysd/pbo-catalog.timer.enabled"
PJ doctor
doctor_has "doctor WARN: pbo-catalog.timer not enabled" warn "pbo-catalog.timer not enabled"
: > "$RUN/sysd/pbo-catalog.timer.enabled"
cp "$RUN/storage.cfg" "$RUN/s.keep"; cp "$RUN/storage.cfg.orig" "$RUN/storage.cfg"
PJ doctor
doctor_has "doctor FAIL: storage missing" fail "storage 'pbo' is not in .*storage.cfg"
printf '\nnfs: pbo\n\tpath /x\n' >> "$RUN/storage.cfg"
PJ doctor
doctor_has "doctor FAIL: storage of another type" fail "storage 'pbo' is of type nfs, not pbo"
cp "$RUN/s.keep" "$RUN/storage.cfg"
mkcfg; : > "$MOCK_LOG"
PJ doctor
doctor_has "doctor WARN: standalone with a pbo storage in storage.cfg" warn "storage.cfg has a pbo storage \\(pbo\\) but PBO_INTEGRATION=standalone"
! grep -qE '^pvesh get (/cluster/backup|/storage)|^dpkg-query|^pveum' "$MOCK_LOG" && ok "doctor standalone: no pvesh jobs/storage, dpkg-query or pveum call" || bad "standalone doctor calls: $(grep -E 'pvesh|dpkg|pveum' "$MOCK_LOG" | head -3)"
mkcfg "PBO_INTEGRATION=both"

# --- disable ------------------------------------------------------------------------------------
printf '[{"id":"job-on","vmid":"101","storage":"pbo"}]\n' > "$RUN/jobs.json"; export MOCK_PVESH_BACKUP_JSON="$RUN/jobs.json"
snap
P integrate disable --yes
[[ $rc == 69 ]] && grep -q 'enabled PVE backup job(s) still write to a pbo storage: job-on (storage pbo, guests 101)' "$RUN/err" \
    && grep -q 'Datacenter -> Backup' "$RUN/err" && ok "disable refused while an enabled job targets pbo" || bad "disable with job: rc=$rc $(tail -1 "$RUN/err")"
unchanged "disable refused: nothing changed (mode still both)"
MOCK_PVESH_FAIL_PATH=/cluster/backup P integrate disable --yes
[[ $rc == 69 ]] && grep -q 'cannot tell whether a PVE backup job still uses' "$RUN/err" && ok "disable refused when the jobs cannot be read" || bad "disable pvesh fail: rc=$rc $(tail -1 "$RUN/err")"
printf '[{"id":"job-on","vmid":"101","storage":"pbo","enabled":0}]\n' > "$RUN/jobs.json"
touch "$RUN/cache/spool/dump/vzdump-lxc-101-2026_01_02-01_00_00.tar"   # young: ingest --pending leaves it
P integrate disable --yes
[[ $rc == 75 ]] && grep -q '1 archive(s) are still in the spool' "$RUN/err" && ok "disable refused with spool leftovers (EX_TEMPFAIL)" || bad "spool leftovers: rc=$rc $(tail -1 "$RUN/err")"
[[ "$(mode_in_cfg)" == standalone ]] && grep -q '^pbo: pbo' "$RUN/storage.cfg" && grep -q '^script:' "$RUN/vzdump.conf" \
    && ok "disable: mode standalone written FIRST, storage and hook still there" || bad "disable order: mode=$(mode_in_cfg)"
rm -f "$RUN/cache/spool/dump/"vzdump-*
mkcfg "PBO_INTEGRATION=both"
: > "$RUN/cache/staging/vzdump-lxc-101-2026_01_01-01_00_00.tar"
: > "$MOCK_LOG"
MOCK_PVESM_FAIL=remove P integrate disable --yes
[[ $rc == 69 && "$(mode_in_cfg)" == standalone ]] && same "pvesm remove fails: mode already standalone, hook line already gone" "$RUN/vzdump.conf.orig" "$RUN/vzdump.conf" \
    || bad "disable failing late: rc=$rc mode=$(mode_in_cfg)"
grep -q '^pbo ingest\|ingest --pending' "$RUN/err" "$RUN/log/pbo.log" 2>/dev/null && ok "disable: ran ingest --pending" || bad "no ingest --pending: $(tail -3 "$RUN/err")"
: > "$MOCK_LOG"
P integrate disable --yes
[[ $rc == 0 ]] && ok "disable: exit 0" || bad "disable: rc=$rc $(tail -3 "$RUN/err")"
same "disable: vzdump.conf restored byte for byte" "$RUN/vzdump.conf.orig" "$RUN/vzdump.conf"
same "disable: storage.cfg back to the original" "$RUN/storage.cfg.orig" "$RUN/storage.cfg"
[[ ! -e "$RUN/sysd/pbo-catalog.timer.enabled" && ! -e "$RUN/sysd/pbo-catalog.timer.active" ]] && ok "disable: pbo-catalog.timer disabled and stopped" || bad "timer: $(ls "$RUN/sysd")"
[[ -z "$(ls -A "$RUN/cache/staging")" ]] && ok "disable: staging emptied" || bad "staging: $(ls "$RUN/cache/staging")"
grep -q 'job-on.*still name a pbo storage' "$RUN/err" && ok "disable: warns about the disabled job that names pbo" || bad "disabled job warning: $(tail -3 "$RUN/err")"
grep -q 'apt remove pbo-pve-storage' <<<"$out" && ok "disable: plugin-removal hint" || bad "hint: $out"
: > "$MOCK_LOG"
PJ integrate disable --yes
has "second disable: unchanged" '.ok and .status == "unchanged" and .steps == []'
unset MOCK_PVESH_BACKUP_JSON

# --- byte-for-byte with a vzdump.conf that does not end in a newline --------------------------------
printf 'mode: stop\nbwlimit: 1000' > "$RUN/vzdump.conf"; cp "$RUN/vzdump.conf" "$RUN/vz.nonl"
P integrate enable both --yes
[[ $rc == 0 && "$(head -1 "$RUN/vzdump.conf")" == "$MARK" ]] && ok "no trailing newline: our lines go first" || bad "nonl enable: rc=$rc $(head -3 "$RUN/vzdump.conf")"
P integrate disable --yes
same "no trailing newline: disable restores the bytes" "$RUN/vz.nonl" "$RUN/vzdump.conf"
cp "$RUN/vzdump.conf.orig" "$RUN/vzdump.conf"

# --- enable writes the mode LAST -------------------------------------------------------------------
mkcfg
MOCK_SYSTEMCTL_FAIL=enable P integrate enable both --yes
[[ $rc != 0 && -z "$(mode_in_cfg)" ]] && grep -q '^pbo: pbo' "$RUN/storage.cfg" && ok "enable: a failing timer step leaves the mode unwritten (written last)" || bad "enable order: rc=$rc mode=$(mode_in_cfg)"
P integrate enable both --yes
log="$(cat "$RUN/log/pbo.log")"
t1="$(grep -n 'systemctl enable --now pbo-catalog.timer' <<<"$log" | tail -1 | cut -d: -f1)"; t2="$(grep -n 'PBO_INTEGRATION=both written' <<<"$log" | tail -1 | cut -d: -f1)"
[[ -n "$t1" && -n "$t2" ]] && (( t2 > t1 )) && ok "enable: the mode is written after the timer step" || bad "enable log order: '$t1' '$t2'"
P integrate disable --yes

# --- roles and rights ---------------------------------------------------------------------------------
mkcfg "PBO_ROLE=janitor"
PBO_JANITOR_ALLOW_ROOT=1 P integrate status
[[ $rc == 64 ]] && grep -q "'integrate' is not available on a janitor" "$RUN/err" && ok "janitor: integrate refused" || bad "janitor: rc=$rc $(tail -1 "$RUN/err")"
mkcfg
if [[ "$(id -u)" != 0 ]]; then
    PBO_INTEGRATE_ALLOW_NONROOT=0 P integrate enable both --yes
    [[ $rc == 64 ]] && grep -q 'run it as root' "$RUN/err" && ok "non-root: enable refused" || bad "non-root: rc=$rc"
    PBO_INTEGRATE_ALLOW_NONROOT=0 PJ integrate status
    has "non-root: status still works" '.ok'
else
    skip "non-root refusal (running as root)"
fi
P integrate bogus
[[ $rc == 64 ]] && ok "unknown subcommand: usage" || bad "bogus: rc=$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
