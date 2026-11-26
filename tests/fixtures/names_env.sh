# shellcheck shell=bash
# tests/fixtures/names_env.sh: the world of tests/names.sh and
# tests/names_retention.sh, sourced with ROOT (the checkout) and RUN (the
# suite's run directory, removed and made again here) set. pbo runs as a copy
# of the entry point that sources tests/fixtures/run_dir_guard.sh, with every
# path it resolves below RUN (W is its world), Proxmox mocked, restic through
# a wrapper that records each call's argv in ARGV_LOG.
[[ -n "${ROOT:-}" && "${RUN:-}" == "$ROOT"/run-* ]] || { echo "names_env: ROOT and RUN (below it, run-*) must be set" >&2; exit 99; }
rm -rf "$RUN"
W="$RUN/w"
mkdir -p "$RUN"/{bin,tree,tmp,none} "$W"/{cache/spool/dump,state,log,lock,pve/lxc,pve/qemu-server,pve/nodes/pve2/lxc,hostetc,staging}
if [[ "$(tail -n 1 pbo)" != 'main "$@"' ]]; then
    echo "  FAIL the entry point no longer ends in main \"\$@\": the harness needs a new hook"; exit 1
fi
{ sed '$d' pbo; printf '%s\n' 'source "$SELF_DIR/../../tests/fixtures/run_dir_guard.sh"'; tail -n 1 pbo; } > "$RUN/tree/pbo"
chmod 755 "$RUN/tree/pbo"; ln -s "$ROOT/lib" "$RUN/tree/lib"
for m in pct qm pvesh pvesm vzdump systemctl zfs zpool dpkg-query; do install -m 0755 "tests/mocks/$m" "$RUN/bin/"; done
# backup-host collects metadata with these: stubs, nothing of the machine's is read
for m in pveversion apt-mark dpkg lsblk pvs vgs lvs ip; do printf '#!/bin/sh\necho "stub %s"\n' "$m" > "$RUN/bin/$m"; chmod 755 "$RUN/bin/$m"; done
# restic: every call's argv (shell-quoted) in $ARGV_LOG, then the real one
export ARGV_LOG="$RUN/argv" REAL_RESTIC; REAL_RESTIC="$(command -v restic)"; : > "$ARGV_LOG"
printf '#!/usr/bin/env bash\n{ printf "%%q " "$@"; printf "\\n"; } >> "$ARGV_LOG"\nexec "$REAL_RESTIC" "$@"\n' > "$RUN/bin/restic-wrap"
chmod 755 "$RUN/bin/restic-wrap"
export PATH="$RUN/bin:$PATH" TMPDIR="$RUN/tmp" HOME="$RUN/none" TEST_RUN="$RUN" MOCK_LOG="$RUN/calls"
export MOCK_CONF_DIR="$W/pve/lxc" MOCK_QM_CONF_DIR="$W/pve/qemu-server" MOCK_SPOOL="$W/cache/spool" MOCK_SYSTEMCTL_DIR="$RUN/none"
# the schema defaults that are the machine's own files: here, at paths nothing creates
export RESTIC_ENV_FILE="$RUN/none/restic.env" NTFY_CREDS_FILE="$RUN/none/ntfy.env" PBO_SYSTEMD_DIR="$RUN/none/systemd" \
    PBO_PVE_TEMPLATE_DIR="$RUN/none/templates" TEST_GUARD_CACHE_DEFAULT="$RUN/none/dcache"
: > "$MOCK_LOG"
# a cluster of two nodes; this one is pve1
printf '{"nodename":"pve1","version":3,"cluster":{"name":"lab","version":2,"nodes":2,"quorate":1},"nodelist":{"pve1":{"id":1,"online":1,"ip":"192.0.2.11"},"pve2":{"id":2,"online":1,"ip":"192.0.2.12"}}}\n' > "$W/pve/.members"
printf 'dir: local\n\tpath %s/none/vz\n\npbo: pbo\n\tpath %s\n\tcontent backup\n' "$RUN" "$W/cache/spool" > "$W/pve/storage.cfg"
: > "$W/vzdump.conf"; : > "$W/vzdump.lock"
printf 'testpass\n' > "$W/pass"; chmod 600 "$W/pass"
echo "iface eth0 inet manual" > "$W/hostetc/interfaces"

# cfg <file> [KEY=value...]: every path below run-names/; a given key replaces
# the base line (one line per key)
cfg() {
    local f="$1"; shift
    local -A over=(); local l
    for l in "$@"; do over["${l%%=*}"]=1; done
    { while IFS= read -r l; do [[ -n "${over[${l%%=*}]:-}" ]] || printf '%s\n' "$l"; done < <(_cfg_base)
      printf '%s\n' "$@"; } > "$f"
    chmod 600 "$f"
}
_cfg_base() {
    printf '%s\n' "CACHE_DIR=$W/cache" "LOG_DIR=$W/log" "STATE_DIR=$W/state" "LOCK_DIR=$W/lock" \
        "RESTIC_BIN=$RUN/bin/restic-wrap" "RESTIC_PASSWORD_FILE=$W/pass" "RESTIC_CACHE_DIR=$W/rcache" \
        "RESTIC_CACHE_REPO=$W/repo-cache" "RESTIC_OFFSITE_REPO=$W/repo-offsite" "LOCAL_REPO=true" \
        "STORAGE_BOX_SNAPSHOTS_CONFIRMED=true" "NTFY_URL=" "NOTIFY_PVE=false" \
        "PBO_PVE_CFS_DIR=$W/pve" "PBO_PVE_LXC_DIR=$W/pve/lxc" "PBO_PVE_QEMU_DIR=$W/pve/qemu-server" \
        "PVE_STORAGE_CFG=$W/pve/storage.cfg" "PBO_PVE_STORAGE_CFG=$W/pve/storage.cfg" \
        "VZDUMP_CONF=$W/vzdump.conf" "VZDUMP_LOCK=$W/vzdump.lock" "PBO_CATALOG=$W/catalog/index.json" \
        "PVE_SPOOL_DIR=$W/cache/spool" "PVE_STAGING_DIR=$W/staging" "PVE_CATALOG_MOUNT_DIR=$RUN/none/mnt" \
        "PBO_PERMS_CONFIG_DIR=$RUN/none" "HOST_BACKUP_PATHS=$W/hostetc" "HOST_BACKUP_EXCLUDES=$W/hostetc/secret" \
        "KEEP_LOCAL=50" "BACKUP_ORDER=8001"
}
cfg "$RUN/config"; export PBO_CONFIG="$RUN/config"
BIN="$RUN/tree/pbo"
# G [args...]: the guarded pbo, output in $out, status in $rc; a stop of the
# guard (99) is recorded and fails the suite at the end
G()  { out="$("$BIN" "$@" 2>&1)"; rc=$?; (( rc != 99 )) || printf '%s\n' "$*: $out" >> "$RUN/guard-hits"; }
GJ() { out="$("$BIN" --json "$@" 2>"$RUN/err")"; rc=$?; (( rc != 99 )) || printf '%s\n' "$*: $(cat "$RUN/err")" >> "$RUN/guard-hits"; }
R() { RESTIC_PASSWORD_FILE="$W/pass" RESTIC_CACHE_DIR="$W/rcache" "$REAL_RESTIC" -r "$1" "${@:2}"; }
# tagsof <repo> <vmid> <ts>: the tags of that snapshot, one line
tagsof() { R "$1" snapshots --json --tag "vmid=$2,ts=$3" 2>/dev/null | jq -c '.[0].tags // []'; }
# nametags <repo> <vmid>: every name=/nameb64= tag of that guest's snapshots, sorted
nametags() { R "$1" snapshots --json --tag "vmid=$2" 2>/dev/null | jq -r '[.[].tags[] | select(startswith("name") )] | sort | join(" ")'; }
# bargv <vmid>: the recorded restic backup calls of that guest
bargv() { grep -E "(^| )backup( |$)" "$ARGV_LOG" | grep -F -- "vmid=$1 " ; }
# ct <vmid> <hostname line or empty> [extra lines]: a CT config (pct mock and PBO_PVE_LXC_DIR)
ct() {
    { printf 'arch: amd64\n'; [[ -n "$2" ]] && printf 'hostname: %s\n' "$2"
      printf 'rootfs: teststore:%s/vm-%s-disk-0.raw,size=1G\nunprivileged: 1\n' "$1" "$1"; printf '%s\n' "${@:3}"; } > "$W/pve/lxc/$1.conf"
}
tsof() { [[ "$1" =~ ([0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}) ]] && printf '%s' "${BASH_REMATCH[1]}"; }
