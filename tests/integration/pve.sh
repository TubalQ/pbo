#!/usr/bin/env bash
# tests/integration/pve.sh: end-to-end test against a REAL Proxmox host.
#
# Not part of tests/all.sh: it creates and destroys guests. Run it on a PVE node:
#
#   sudo tests/integration/pve.sh
#
# What it does, with its own config/cache/repos (the installed pbo and its config
# are never touched):
#   1. creates a throwaway LXC (and a small VM unless PBO_IT_VM=0), writes a marker
#   2. backup → list → restore to a new vmid → boot (LXC) → marker compared
#   3. test-restore, prune, verify --scheduled, doctor
#   4. with PBO_IT_JANITOR_CT=<ctid>: the same against an append-only rest-server in
#      that container, including a delete attempt from the host and a janitor prune
#   5. destroys everything it created, also on failure
#
# Settings (env):
#   PBO_IT_VMID=9990        first of four vmids used (vmid..vmid+3), must all be free
#   PBO_IT_TEMPLATE=…       LXC template (default: newest debian-*-standard on local)
#   PBO_IT_STORAGE=…        storage for the throwaway guests (default: first zfspool)
#   PBO_IT_VM=1             also test a QEMU VM (disk-only, not booted)
#   PBO_IT_JANITOR_CT=      ctid running rest-server --append-only + pbo janitor
#   PBO_IT_JANITOR_URL=     https://<ip>:8000 of that rest-server
#   PBO_IT_KEEP=0           1 = leave guests and files for inspection
set -uo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"; BIN="$SRC/pbo"
pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
step() { printf '\n== %s\n' "$1"; }
die()  { printf 'pve.sh: %s\n' "$*" >&2; exit 2; }

[[ "$(id -u)" == 0 ]] || die "must run as root on a Proxmox host"
command -v pct >/dev/null && command -v qm >/dev/null && command -v vzdump >/dev/null || die "pct/qm/vzdump missing: not a Proxmox host"

V="${PBO_IT_VMID:-9990}"; CT=$V; CTR=$((V+1)); VM=$((V+2)); VMR=$((V+3))
TAG="pbo-it-$$"
TPL="${PBO_IT_TEMPLATE:-$(pveam list local 2>/dev/null | awk '/debian-[0-9]+-standard/{print $1}' | sort -V | tail -1)}"
STO="${PBO_IT_STORAGE:-$(pvesm status 2>/dev/null | awk '$2=="zfspool" && $3=="active"{print $1; exit}')}"
[[ -n "$TPL" ]] || die "no LXC template found, set PBO_IT_TEMPLATE"
[[ -n "$STO" ]] || die "no storage found, set PBO_IT_STORAGE"
for id in $CT $CTR $VM $VMR; do
    { pct status "$id" >/dev/null 2>&1 || qm status "$id" >/dev/null 2>&1; } && die "vmid $id is in use, set PBO_IT_VMID to a free range"
done

# Everything lives under one dir; the cache must be traversable by the mapped root
# of an unprivileged CT (vzdump runs tar as uid 100000), so not under /root.
_n=0
W="$(mktemp -d /var/tmp/pbo-it.XXXXXX)"; chmod 0755 "$W"
mkdir -p "$W"/{cache,state,log,lock}
chmod 0700 "$W/lock"   # the permission rules want LOCK_DIR closed (doctor warns otherwise)
created=()
cleanup() {
    local rc=$?
    if [[ "${PBO_IT_KEEP:-0}" == 1 ]]; then printf '\nPBO_IT_KEEP=1: left %s and vmids %s\n' "$W" "${created[*]:-none}"; exit "$rc"; fi
    for id in "${created[@]}"; do
        # only destroy what carries our tag (never a guest someone else made meanwhile)
        if pct config "$id" 2>/dev/null | grep -q "$TAG"; then pct stop "$id" >/dev/null 2>&1; pct destroy "$id" --purge >/dev/null 2>&1
        elif qm config "$id" 2>/dev/null | grep -q "$TAG"; then qm stop "$id" >/dev/null 2>&1; qm destroy "$id" --purge >/dev/null 2>&1; fi
    done
    if [[ -n "${PBO_IT_JANITOR_CT:-}" ]]; then
        jx "rm -rf /srv/restic/pbo-it /etc/pbo/config.it /etc/pbo/restic-pass.it; htpasswd -D /etc/rest-server/htpasswd pbo-it >/dev/null 2>&1" || true
    fi
    rm -rf "$W"
    exit "$rc"
}
trap cleanup EXIT
# commands inside the janitor CT, with a clean env (pct exec leaks the caller's)
jx() { pct exec "$PBO_IT_JANITOR_CT" -- env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C bash -c "$1"; }
P() { PBO_CONFIG="$W/config" PBO_NO_NOTIFY=1 "$BIN" "$@"; }
# run a step, keep its output; on failure show the tail so the FAIL has a reason
PL() { local log="$W/step-$((++_n)).log"; if P "$@" >"$log" 2>&1; then return 0; fi
       sed 's/^/      | /' "$log" | tail -6 >&2; return 1; }

umask 077; openssl rand -base64 32 | tr -d '\n' > "$W/repo-pass"; umask 022
OFFSITE="$W/offsite-repo"; AO=false
if [[ -n "${PBO_IT_JANITOR_CT:-}" ]]; then
    [[ -n "${PBO_IT_JANITOR_URL:-}" ]] || die "PBO_IT_JANITOR_URL is required with PBO_IT_JANITOR_CT"
    step "janitor CT $PBO_IT_JANITOR_CT: test user + repo"
    umask 077; openssl rand -base64 32 | tr -d '\n' > "$W/rest-pass"; umask 022
    pct push "$PBO_IT_JANITOR_CT" "$W/rest-pass" /root/pbo-it.pass
    jx "htpasswd -B -i /etc/rest-server/htpasswd pbo-it < /root/pbo-it.pass >/dev/null 2>&1; rm -f /root/pbo-it.pass" && ok "htpasswd user pbo-it added" || bad "htpasswd"
    pct pull "$PBO_IT_JANITOR_CT" /etc/rest-server/tls/cert.pem "$W/ca.pem"
    pct push "$PBO_IT_JANITOR_CT" "$W/repo-pass" /etc/pbo/restic-pass.it
    jx "chown restic:restic /etc/pbo/restic-pass.it; chmod 0400 /etc/pbo/restic-pass.it
        sed -e 's#^RESTIC_OFFSITE_REPO=.*#RESTIC_OFFSITE_REPO=/srv/restic/pbo-it/repo#' \
            -e 's#^RESTIC_PASSWORD_FILE=.*#RESTIC_PASSWORD_FILE=/etc/pbo/restic-pass.it#' \
            -e 's#^KEEP_OFFSITE_DAILY=.*#KEEP_OFFSITE_DAILY=1#' -e 's#^KEEP_OFFSITE_WEEKLY=.*#KEEP_OFFSITE_WEEKLY=0#' \
            -e 's#^KEEP_OFFSITE_MONTHLY=.*#KEEP_OFFSITE_MONTHLY=0#' /etc/pbo/config > /etc/pbo/config.it
        chown root:restic /etc/pbo/config.it; chmod 0640 /etc/pbo/config.it"
    OFFSITE="rest:${PBO_IT_JANITOR_URL%/}/pbo-it/repo"; AO=true
fi

cat > "$W/config" <<EOF
CACHE_DIR=$W/cache
LOG_DIR=$W/log
STATE_DIR=$W/state
LOCK_DIR=$W/lock
BACKUP_ORDER=$CT
LOCAL_REPO=true
OFFSITE_ENABLED=true
RESTIC_CACHE_REPO=$W/cache/repo
RESTIC_OFFSITE_REPO=$OFFSITE
RESTIC_PASSWORD_FILE=$W/repo-pass
RESTIC_CACHE_DIR=$W/rcache
KEEP_LOCAL=1
KEEP_OFFSITE_DAILY=1
KEEP_OFFSITE_WEEKLY=0
KEEP_OFFSITE_MONTHLY=0
TR_STORAGE=$STO
VERIFY_ROTATE=2
STORAGE_BOX_SNAPSHOTS_CONFIRMED=true
EOF
if [[ "$AO" == true ]]; then
    cat >> "$W/config" <<EOF
OFFSITE_APPEND_ONLY=true
RESTIC_REST_USERNAME=pbo-it
RESTIC_REST_PASSWORD_FILE=$W/rest-pass
RESTIC_CACERT=$W/ca.pem
EOF
fi
chmod 0600 "$W/config"

step "$(P --version 2>/dev/null) against PVE $(pveversion 2>/dev/null | cut -d/ -f2) — template $TPL, storage $STO, offsite $( [[ $AO == true ]] && echo "append-only $OFFSITE" || echo "local dir")"
P init >/dev/null 2>&1 && ok "init both tiers" || { bad "init"; exit 1; }

step "LXC $CT"
# a NIC without an address (ip=manual): no traffic, but restore --start must take it down
BR="${PBO_IT_BRIDGE:-}"; if [[ -z "$BR" ]]; then for _b in /sys/class/net/vmbr*; do BR="${_b##*/}"; break; done; fi
pct create "$CT" "$TPL" --hostname pbo-it --rootfs "$STO:2" --unprivileged 1 --memory 256 \
    --net0 "name=eth0,bridge=$BR,ip=manual,ip6=manual" \
    --features nesting=1 --description "$TAG" >/dev/null 2>&1 && created+=("$CT") || { bad "pct create"; exit 1; }
# host bindings test-restore must strip before booting its throwaway copy
mkdir -p "$W/bind" && pct set "$CT" --mp0 "$W/bind,mp=/mnt/itbind" >/dev/null 2>&1 \
    && printf 'lxc.mount.entry: %s mnt/itbind2 none bind,optional,create=dir\n' "$W/bind" >> "/etc/pve/lxc/$CT.conf" \
    && ok "bind mount + raw lxc.mount.entry on CT $CT" || bad "bind mount setup"
pct start "$CT" >/dev/null 2>&1; sleep 3
MARK="pbo-it $(date +%s) $RANDOM"
pct exec "$CT" -- bash -c "echo '$MARK' > /root/marker" && ok "marker written in CT $CT" || bad "marker"

for i in 1 2; do PL backup "$CT" && ok "backup $i (running CT, snapshot mode)" || bad "backup $i"; sleep 2; done
n="$(P --json list "$CT" 2>/dev/null | jq '.archives|length')"
[[ "$n" == 2 ]] && ok "list shows 2 snapshots" || bad "list shows $n"

TS="$(P --json list "$CT" 2>/dev/null | jq -r '.archives|sort_by(.modtime)|last|.archive' | sed -E "s/^vzdump-lxc-$CT-(.*)\.tar$/\1/")"
PL restore "$CT" "$TS" --to "$CTR" --storage "$STO" --yes --start && created+=("$CTR") && ok "restore --start → $CTR" || bad "restore"
# --start boots the copy with every interface link_down=1 (same MAC/IP as the source)
nets="$(pct config "$CTR" 2>/dev/null | grep -E '^net[0-9]+:' || true)"
if [[ -n "$nets" ]] && ! grep -vq 'link_down=1' <<<"$nets" && [[ "$(pct status "$CTR" 2>/dev/null)" == "status: running" ]]; then
    ok "restored copy running with its network disconnected"
    if ! pct config "$CTR" | grep -qE '^mp0: /|^lxc\.mount\.entry' && ! grep -q 'lxc.mount.entry' "/etc/pve/lxc/$CTR.conf"; then
        ok "restored copy started without the source's bind mount and raw mount entry"
    else bad "restore --start kept host bindings: $(pct config "$CTR" | grep -E '^mp|^lxc')"; fi
else bad "restore --start: $(pct status "$CTR" 2>&1) / $nets"; fi
pct set "$CTR" --description "$TAG" >/dev/null 2>&1
sleep 3
got="$(pct exec "$CTR" -- cat /root/marker 2>/dev/null)"
[[ "$got" == "$MARK" ]] && ok "restored CT boots, marker identical" || bad "marker after restore: '$got'"
[[ "$(pct config "$CTR" | awk '/^unprivileged/{print $2}')" == 1 ]] && ok "restored CT still unprivileged" || bad "unprivileged lost"

# job model with the real runner: a transient systemd unit
jid="$(P --json job start verify 2>/dev/null | jq -r '.job.id // empty')"
for _ in $(seq 1 120); do [[ -n "$jid" && -e "$W/state/runs/$jid/result.json" ]] && break; sleep 1; done
jshow="$(P --json job show "$jid" 2>/dev/null)"
if jq -e '.job.runner == "systemd" and .job.state == "ok" and .job.result.ok == true' >/dev/null 2>&1 <<<"$jshow" \
   && ! systemctl is-active --quiet "pbo-job-$jid" 2>/dev/null; then ok "job via systemd-run: verify ran as pbo-job-$jid, result recorded, unit gone"
else bad "job via systemd: $jshow"; fi
PL test-restore "$CT" && ok "test-restore (restore, boot, destroy)" || bad "test-restore"
tr="$(jq -cR 'fromjson? // empty' "$W/state/restore-tests.jsonl" 2>/dev/null | tail -1)"
_tid="$(jq -r '.throwaway // empty' <<<"$tr" 2>/dev/null)"
if jq -e --arg v "$CT" '.vmid==$v and .ok==true and ([.stages[].name]==["fetch","restore","isolate","start","respond","cleanup"]) and .cleanup_ok==true and (.stripped|index("mp0")) != null and (.stripped|index("lxc.mount.entry")) != null' >/dev/null 2>&1 <<<"$tr" \
   && [[ -n "$_tid" ]] && ! pct config "$_tid" >/dev/null 2>&1 && ! qm config "$_tid" >/dev/null 2>&1; then
    ok "test-restore evidence recorded, host bindings stripped, throwaway gone"
else bad "test-restore evidence: $tr"; fi

if [[ "${PBO_IT_VM:-1}" == 1 ]]; then
    step "VM $VM (disk only)"
    qm create "$VM" --name pbo-it-vm --memory 128 --scsi0 "$STO:1" --description "$TAG" >/dev/null 2>&1 && created+=("$VM") || bad "qm create"
    dev="$(pvesm path "$(qm config "$VM" | awk -F'[ ,]' '/^scsi0:/{print $2}')" 2>/dev/null)"
    VMARK="pbo-it-vm $(date +%s) $RANDOM"
    printf '%s' "$VMARK" | dd of="$dev" bs=512 conv=notrunc,fsync status=none && ok "marker written to VM disk" || bad "vm marker"
    PL backup "$VM" && ok "VM backup (.vma)" || bad "vm backup"
    VTS="$(P --json list "$VM" 2>/dev/null | jq -r '.archives|sort_by(.modtime)|last|.archive' | sed -E "s/^vzdump-qemu-$VM-(.*)\.vma$/\1/")"
    PL restore "$VM" "$VTS" --to "$VMR" --storage "$STO" --yes && created+=("$VMR") && ok "VM restore → $VMR" || bad "vm restore"
    qm set "$VMR" --description "$TAG" >/dev/null 2>&1
    rdev="$(pvesm path "$(qm config "$VMR" | awk -F'[ ,]' '/^scsi0:/{print $2}')" 2>/dev/null)"
    got="$(dd if="$rdev" bs=${#VMARK} count=1 status=none 2>/dev/null)"
    [[ "$got" == "$VMARK" ]] && ok "restored VM disk carries the marker" || bad "vm marker after restore: '$got'"
fi

step "retention + integrity"
out="$(P --json prune 2>/dev/null)"
[[ "$(jq -r .ok <<<"$out")" == true ]] && ok "prune ok" || bad "prune: $out"
if [[ "$AO" == true ]]; then
    [[ "$(jq -r .offsite_skipped <<<"$out")" == append_only ]] && ok "host prune leaves append-only offsite alone" || bad "offsite_skipped: $out"
else
    [[ "$(P --json list "$CT" 2>/dev/null | jq '.archives|length')" == 1 ]] && ok "offsite pruned to policy" || bad "offsite after prune"
fi
for s in 1/2 2/2; do
    o="$(P --json verify --scheduled 2>/dev/null)"
    [[ "$(jq -r .subset <<<"$o")" == "$s" && "$(jq -r .ok <<<"$o")" == true ]] && ok "verify --scheduled slice $s" || bad "verify $s: $o"
done
P doctor >"$W/doctor.out" 2>&1 && ok "doctor clean" || bad "doctor: $(grep -E 'FAIL|WARN' "$W/doctor.out" | head -3)"

if [[ "$AO" == true ]]; then
    step "append-only, from the host's side"
    grep -q 'append-only enforced' "$W/doctor.out" && ok "doctor proved the server refuses deletes" || bad "no append-only proof in doctor"
    RR() { RESTIC_REST_USERNAME=pbo-it RESTIC_REST_PASSWORD="$(cat "$W/rest-pass")" RESTIC_PASSWORD_FILE="$W/repo-pass" \
           RESTIC_CACHE_DIR="$W/rcache" restic -r "$OFFSITE" --cacert "$W/ca.pem" "$@"; }
    before="$(RR snapshots --json 2>/dev/null | jq length)"
    RR forget --keep-last 1 --prune >/dev/null 2>&1
    after="$(RR snapshots --json 2>/dev/null | jq length)"
    [[ "$before" -ge 2 && "$after" == "$before" ]] && ok "host forget --prune refused ($before snapshots before and after)" || bad "forget from host: $before → $after"
    code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$W/ca.pem" -u "pbo-it:$(cat "$W/rest-pass")" -X DELETE "${OFFSITE#rest:}/config")"
    [[ "$code" == 403 ]] && ok "DELETE of the repo config refused (403)" || bad "DELETE config → $code"

    step "append-only, janitor side"
    out="$(jx "cd /tmp; PBO_CONFIG=/etc/pbo/config.it pbo --json prune 2>/dev/null")"
    [[ "$(jq -r .ok <<<"$out")" == true && "$(jq '.offsite_deleted|length' <<<"$out")" -ge 1 ]] && ok "janitor prune applied retention" || bad "janitor prune: $out"
    stray="$(jx "find /srv/restic/pbo-it ! -user restic | head -1")"
    [[ -z "$stray" ]] && ok "repo files still owned by the server user" || bad "root-owned file after janitor prune: $stray"
    PL backup "$CT" && ok "host backup after janitor prune" || bad "backup after janitor prune"
    jx "cd /tmp; PBO_CONFIG=/etc/pbo/config.it pbo verify --scheduled >/dev/null 2>&1" && ok "janitor verify" || bad "janitor verify"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
