# shellcheck shell=bash
# lib/cluster.sh — cluster / node awareness (ADR 0002, Phase 2).
#
# The model (like PVE+PBS): each node backs up the guests that live ON IT, into
# the SAME shared repo. Restic tags per vmid → migration-safe; dedup is
# cluster-wide. Nothing here is node-specific — everything is derived at runtime,
# so the SAME config can sit on every node.
#
# On a single node (or with no cluster/quorum) every filter is a no-op: the tool
# behaves exactly as it did before clusters were a concern.

# _local_node → this node's pmxcfs name (fallback: short hostname).
_local_node() {
    local n=""
    [[ -r /etc/pve/.members ]] && command -v jq >/dev/null 2>&1 \
        && n="$(jq -r '.nodename // empty' /etc/pve/.members 2>/dev/null)"
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

# _backup_set → the ordered vmids to back up on THIS node (one per line).
#   BACKUP_ORDER=auto | empty  → all local guests (auto-discovered, numeric order)
#   BACKUP_ORDER=<csv>         → the listed vmids that live here, in the given order
# When no cluster view is available (single node / no quorum / test sandbox) an
# explicit list is trusted as-is (we cannot — and need not — filter by node).
_backup_set() {
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
    pvesm status --content "$content" 2>/dev/null | awk 'NR>1 && $3=="active"{print $1; exit}'
}
