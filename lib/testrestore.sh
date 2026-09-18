# shellcheck shell=bash
# lib/testrestore.sh: test-restore helpers + dispatcher. The full chain (restore
# a throwaway copy → boot → wait for it to respond → destroy) lives in the restic
# engine (lib/restic.sh, rdo_test_restore); the reusable _tr_* helpers are here.
#
# This is the only command that truly proves an offsite backup can be restored
# AND booted; the rest just verify bytes.

# Best-effort teardown, the throwaway may be either an LXC or a VM, so try both.
_tr_destroy() {
    local id="$1"
    [[ -n "$id" ]] || return 0
    pct stop "$id" >/dev/null 2>&1 || true; pct destroy "$id" --purge >/dev/null 2>&1 || true
    qm  stop "$id" >/dev/null 2>&1 || true; qm  destroy "$id" --purge >/dev/null 2>&1 || true
}

# Wait until the guest responds (or timeout). qemu → guest-agent ping (via _g_alive,
# which accepts `running` when no agent is configured); lxc → a command runs inside.
_tr_wait() {
    local id="$1" gtype="${2:-lxc}" i
    for (( i=0; i < ${TR_WAIT_TRIES:-30}; i++ )); do
        _g_alive "$gtype" "$id" && return 0
        sleep "${TR_WAIT_SLEEP:-2}"
    done
    return 1
}

# Strip networking from the throwaway BEFORE booting it. The restored copy carries
# the source guest's net config (same MAC + IP), so booting it on the bridge would
# clash with the still-running original. Liveness is proven via `pct exec` / the
# qemu guest-agent (namespace/virtio, not the network), so a net-less boot still
# proves the guest came up.
_tr_isolate_net() {
    local t="$1" id="$2" k
    if [[ "$t" == qemu ]]; then
        for k in $(qm config "$id" 2>/dev/null | sed -n 's/^\(net[0-9]\+\):.*/\1/p'); do
            qm set "$id" --delete "$k" >/dev/null 2>&1 || true
        done
    else
        for k in $(pct config "$id" 2>/dev/null | sed -n 's/^\(net[0-9]\+\):.*/\1/p'); do
            pct set "$id" --delete "$k" >/dev/null 2>&1 || true
        done
    fi
}

# Pick the highest free throwaway vmid in 9000-9099 (free = neither an LXC nor a VM).
_tr_pick_target() {
    local n
    for (( n=9099; n >= 9000; n-- )); do
        _g_exists "$n" || { printf '%s' "$n"; return 0; }
    done
    return 1
}

# do_test_restore <vmid>, dispatch to the restic engine.
do_test_restore() { rdo_test_restore "$1"; }
