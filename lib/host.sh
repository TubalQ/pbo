# shellcheck shell=bash
# lib/host.sh: back up the Proxmox HOST itself (config + rebuild metadata), not a
# guest. Manual only (`pbo backup-host` / menu), never part of run-schedule.
#
# It reuses the restic engine's plumbing: same repo, same cache→offsite copy, same
# prune retention. A host snapshot is tagged like a guest but with a synthetic
# vmid ("host-<node>") and type=host, so it shows up in list/status/menu and is
# pruned automatically, while restore branches on type=host to a FILE restore
# (never pct/qmrestore — you don't blindly overwrite /etc/pve on a live host).
#
# SECURITY: SSH keys and the restic DR key are excluded (HOST_BACKUP_EXCLUDES).
# The host must keep its own offline copy of those; they are NOT in this backup.

# _host_id → the synthetic vmid tag for this node's host snapshots.
_host_id() { printf 'host-%s' "$(_local_node)"; }

# _host_collect_meta <dir>: dump rebuild-relevant state that is not a file
# (versions, package list, storage/network layout). Best-effort; never fails the
# backup. Each command's output (or its error) is captured so the file exists.
_host_collect_meta() {
    local d="$1"; mkdir -p "$d"
    { pveversion -v 2>&1; }                                            > "$d/pveversion.txt"      || true
    { apt-mark showmanual 2>&1; }                                      > "$d/packages-manual.txt" || true
    { dpkg --get-selections 2>&1; }                                   > "$d/dpkg-selections.txt" || true
    { lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>&1; echo
      pvs 2>&1; vgs 2>&1; lvs 2>&1; echo
      zpool status 2>&1; zfs list 2>&1; }                             > "$d/storage.txt"         || true
    { ip -o addr 2>&1; echo; ip route 2>&1; }                        > "$d/network.txt"         || true
    { pvesh get /cluster/resources --output-format json 2>/dev/null; } > "$d/cluster-resources.json" || true
    printf 'pbo host backup metadata\nnode: %s\ncollected: %s\n' \
        "$(_local_node)" "$(date --iso-8601=seconds)"                 > "$d/README.txt"
}

# rdo_backup_host: restic backup of HOST_BACKUP_PATHS + collected metadata,
# tagged vmid=host-<node>,type=host. Same cache→offsite copy as guest backups.
rdo_backup_host() {
    local node; node="$(_local_node)"
    local id; id="$(_host_id)"
    local ts; ts="$(date +%Y_%m_%d-%H_%M_%S)"
    local stage="${CACHE_DIR}/${id}/meta"
    local jobfile; jobfile="${JOBS_DIR}/backup-${id}-$(date +%Y%m%d-%H%M%S).log"

    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] host backup of node $node (paths: ${HOST_BACKUP_PATHS})"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$id" "type" "host" "engine" "restic"
        return "$EX_OK"
    fi

    # Say it every run: this backup does NOT contain the keys needed to log in.
    log_warn "host backup: SSH keys and other private-key material are deliberately excluded for security — keep your own offline copy; they will NOT be in this backup to restore."

    restic_init
    _restic_stale_unlock "$(_restic_write_repo)"
    [[ "${LOCAL_REPO:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]] && _restic_stale_unlock "$RESTIC_OFFSITE_REPO"

    rm -rf "$stage"; mkdir -p "$stage" "$JOBS_DIR"
    log_info "host backup $node: collecting rebuild metadata → $stage"
    _host_collect_meta "$stage"

    # Split the space-separated lists without glob expansion (read -ra), then keep
    # only paths that exist (a missing source makes restic exit 3/warn).
    local allpaths=() paths=() p
    read -ra allpaths <<<"$HOST_BACKUP_PATHS"
    for p in "${allpaths[@]}"; do [[ -e "$p" ]] && paths+=("$p"); done
    paths+=("$stage")
    local expat=() excludes=() e
    read -ra expat <<<"$HOST_BACKUP_EXCLUDES"
    for e in "${expat[@]}"; do [[ -n "$e" ]] && excludes+=(--exclude "$e"); done

    local wrepo; wrepo="$(_restic_write_repo)"
    log_info "host backup $node: restic backup → $wrepo (tags vmid=$id,type=host,ts=$ts)"
    local rc=0
    run_stream "$jobfile" "restic-host[$node]" -- \
        _restic "$wrepo" backup "${excludes[@]}" \
            --tag "vmid=$id" --tag "ts=$ts" --tag "type=host" --host "$node" \
            "${paths[@]}" || rc=$?
    if (( rc == 3 )); then
        log_warn "host backup $node: some files could not be read (restic warning), snapshot still created"
    elif (( rc != 0 )); then
        notify_failure "host backup FAILED on $node (see $jobfile)"
        die "$EX_SOFTWARE" "host backup failed (see $jobfile)"
    fi

    if [[ "${LOCAL_REPO:-true}" == "true" && "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]]; then
        log_info "host backup $node: restic copy cache → offsite"
        if ! run_stream "$jobfile" "restic-copy[$node]" -- \
                _restic "$RESTIC_OFFSITE_REPO" copy --from-repo "$RESTIC_CACHE_REPO" --tag "vmid=$id,ts=$ts"; then
            die "$EX_UNAVAILABLE" "restic copy → offsite failed for host $node"
        fi
    fi

    rm -rf "$stage"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "uploaded" "true" "vmid" "$id" "ts" "$ts" "type" "host" "engine" "restic" "job" "$jobfile"
    else
        log_info "host backup $node: DONE (restic), ts=$ts"
    fi
    notify_success "host backup OK on $node (ts=$ts)"
    return "$EX_OK"
}

# rdo_restore_host <node|host-id> <ts> <target-dir> [path]
# Extracts the snapshot's files to <target-dir> (optionally a single <path>). It
# never writes to live host paths; you review and copy back by hand.
rdo_restore_host() {
    local who="$1" ts="$2" target="$3" path="${4:-}"
    local id="$who"; [[ "$id" == host-* ]] || id="host-$who"
    local repo; repo="$(_restic_read_repo)"
    command -v jq >/dev/null 2>&1 || die "$EX_UNAVAILABLE" "jq required for restore-host"

    local snap
    snap="$(_restic "$repo" snapshots --json --tag "vmid=$id,ts=$ts" 2>/dev/null | jq -r '.[-1].short_id // empty')"
    [[ -n "$snap" ]] || die "$EX_DATAERR" "restore-host: no snapshot for $id at ts=$ts"

    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] restic restore $snap → $target ${path:+(include $path)}"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$id" "target" "$target"
        return "$EX_OK"
    fi

    mkdir -p "$target"
    local args=(restore "$snap" --target "$target")
    [[ -n "$path" ]] && args+=(--include "$path")
    if ! _restic "$repo" "${args[@]}" >/dev/null 2>&1; then
        die "$EX_SOFTWARE" "restore-host failed ($id, $ts)"
    fi

    log_warn "restore-host: files extracted to $target — review and copy back BY HAND (e.g. /etc/pve); nothing was written to live system paths."
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_result "restored" "true" "vmid" "$id" "ts" "$ts" "target" "$target" "type" "host" "engine" "restic"
    else
        log_info "restore-host: DONE → $target"
    fi
    return "$EX_OK"
}
