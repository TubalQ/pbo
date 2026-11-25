# shellcheck shell=bash
# lib/cluster.sh: cluster / node awareness (ADR 0002, Phase 2).
#
# The model (like PVE+PBS): each node backs up the guests that live ON IT, into
# the SAME shared repo. Restic tags per vmid → migration-safe; dedup is
# cluster-wide. Nothing here is node-specific, everything is derived at runtime,
# so the SAME config can sit on every node.
#
# On a single node (or with no cluster/quorum) every filter is a no-op: the tool
# behaves exactly as it did before clusters were a concern.

# _local_node → this node's pmxcfs name (fallback: short hostname).
_local_node() {
    local n="" m="${PBO_PVE_CFS_DIR:-/etc/pve}/.members"
    [[ -r "$m" ]] && command -v jq >/dev/null 2>&1 \
        && n="$(jq -r '.nodename // empty' "$m" 2>/dev/null)"
    [[ -n "$n" ]] || n="$(hostname -s 2>/dev/null || hostname)"
    printf '%s' "$n"
}

# _cluster_local_vmids → vmids on THIS node per the cluster resource view, or
# EMPTY if there is no cluster/quorum/pvesh (caller then treats guests as local).
_cluster_local_vmids() {
    local node; node="$(_local_node)"
    command -v pvesh >/dev/null 2>&1 || return 0
    pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
        | jq -r --arg n "$node" '.[] | select(.node==$n) | .vmid' 2>/dev/null
}

# _all_local_vmids → every guest on this node (LXC + VM), from the local tools.
# The no-cluster fallback for auto-discovery.
_all_local_vmids() {
    { pct list 2>/dev/null | awk 'NR>1{print $1}'
      qm  list 2>/dev/null | awk 'NR>1{print $1}'; } | grep -E '^[0-9]+$' | sort -n
}

# _backup_set → the guests that must have a fresh backup on THIS node:
# _backup_set_all minus guests tagged pbo-skip, plus (integration on) the guests
# a PVE backup job owns (lib/ownership.sh), appended in numeric order. Doctor's
# freshness check and test-restore use it. Standalone: exactly the old set.
_backup_set() {
    local id
    if _integration_standalone; then
        while read -r id; do
            [[ -n "$id" ]] || continue
            _guest_skipped "$id" || printf '%s\n' "$id"
        done < <(_backup_set_all)
        return 0
    fi
    _pve_jobs_load
    local -A seen=()
    while read -r id; do
        [[ -n "$id" && -z "${seen[$id]:-}" ]] || continue
        _guest_skipped "$id" && continue
        seen[$id]=1; printf '%s\n' "$id"
    done < <(_backup_set_all)
    while read -r id; do
        [[ -n "$id" && -z "${seen[$id]:-}" ]] || continue
        seen[$id]=1; printf '%s\n' "$id"
    done < <(_pve_owned_guests)
    return 0
}
# _backup_set_skipped → the guests left out because of pbo-skip that no PVE job
# backs up either.
_backup_set_skipped() {
    local id
    if _integration_standalone; then
        while read -r id; do [[ -n "$id" ]] && _guest_skipped "$id" && printf '%s\n' "$id"; done < <(_backup_set_all)
        return 0
    fi
    _pve_jobs_load
    while read -r id; do
        [[ -n "$id" ]] && _guest_skipped "$id" && [[ -z "$(_pve_owner_job "$id")" ]] && printf '%s\n' "$id"
    done < <(_backup_set_all)
    return 0
}
# _timer_set → what pbo.timer (run-schedule) backs up:
#   standalone  _backup_set
#   both        _backup_set minus the guests a PVE job owns
#   integrated  nothing (PVE jobs back up every guest)
# When ownership is unknown it fails open to _backup_set in every mode.
_timer_set() {
    local id
    if _integration_standalone; then _backup_set; return 0; fi
    _pve_jobs_load
    if ! _pve_owner_known; then _backup_set; return 0; fi
    [[ "$(_integration_mode)" == integrated ]] && return 0
    while read -r id; do
        [[ -n "$id" && -z "$(_pve_owner_job "$id")" ]] && printf '%s\n' "$id"
    done < <(_backup_set)
    return 0
}
# _backup_set_unowned → integrated only: guests in _backup_set_all that are
# neither tagged pbo-skip nor owned by a PVE job, i.e. that nothing backs up.
# Empty in other modes and when ownership is unknown (the timer has them).
_backup_set_unowned() {
    local id
    [[ "$(_integration_mode)" == integrated ]] || return 0
    _pve_jobs_load
    _pve_owner_known || return 0
    while read -r id; do
        [[ -n "$id" ]] || continue
        _guest_skipped "$id" && continue
        [[ -z "$(_pve_owner_job "$id")" ]] && printf '%s\n' "$id"
    done < <(_backup_set_all)
    return 0
}

# _backup_set_all → the ordered vmids to back up on THIS node (one per line).
#   BACKUP_ORDER=auto | empty  → all local guests (auto-discovered, numeric order)
#   BACKUP_ORDER=<csv>         → the listed vmids that live here, in the given order
# When no cluster view is available (single node / no quorum / test sandbox) an
# explicit list is trusted as-is (we cannot, and need not, filter by node).
_backup_set_all() {
    local order="${BACKUP_ORDER:-auto}" id
    local cluster_ids; cluster_ids="$(_cluster_local_vmids)"
    if [[ "$order" == "auto" || -z "$order" ]]; then
        if [[ -n "$cluster_ids" ]]; then printf '%s\n' "$cluster_ids" | sort -n
        else _all_local_vmids; fi
    else
        if [[ -n "$cluster_ids" ]]; then
            local -A here=(); while read -r id; do [[ -n "$id" ]] && here[$id]=1; done <<<"$cluster_ids"
            for id in ${order//,/ }; do [[ -n "${here[$id]:-}" ]] && printf '%s\n' "$id"; done
        else
            for id in ${order//,/ }; do [[ -n "$id" ]] && printf '%s\n' "$id"; done
        fi
    fi
    return 0   # a filtered-out last id must not make this generator "fail" under set -e
}

# _is_prune_owner → may THIS node run prune? Prune needs an exclusive repo lock,
# so in a cluster run it from one node. Default: yes (restic's lock makes a
# concurrent attempt fail safely, not corrupt). Set PRUNE_OWNER=<nodename> to
# restrict prune to a single node.
_is_prune_owner() {
    [[ -z "${PRUNE_OWNER:-}" || "${PRUNE_OWNER}" == "$(_local_node)" ]]
}

# _default_storage <type> → first ACTIVE storage that can hold this guest type's
# disks (qemu→images, lxc→rootdir), from PVE itself. Replaces a hardcoded pool so
# the tool is portable. Empty if none (caller must then require --storage).
_default_storage() {
    local content; [[ "$1" == qemu ]] && content=images || content=rootdir
    # pvesm missing or failing (no quorum) must not end the run silently under
    # pipefail: an empty answer, and the caller asks for --storage
    { pvesm status --content "$content" 2>/dev/null || true; } | awk 'NR>1 && $3=="active"{print $1; exit}'
}
