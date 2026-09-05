# shellcheck shell=bash
# lib/testrestore.sh — step 8: test-restore. Full chain against a THROWAWAY vmid:
# fetch FROM OFFSITE (not cache) → verify → pct restore → start → wait for
# the container to respond → stop → destroy. Report via ntfy (silent on success
# unless NTFY_ON_SUCCESS=true; alerts on failure).
#
# This is the only command that truly proves an offsite backup can be
# restored AND booted — the rest just verify bytes.

# Best-effort teardown — the throwaway may be either an LXC or a VM, so try both.
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

# Pick the highest free throwaway vmid in 9000–9099 (free = neither an LXC nor a VM).
_tr_pick_target() {
    local n
    for (( n=9099; n >= 9000; n-- )); do
        _g_exists "$n" || { printf '%s' "$n"; return 0; }
    done
    return 1
}

# do_test_restore <vmid>
do_test_restore() {
    local vmid="$1"
    if [[ "${ENGINE:-tar}" == "restic" ]]; then rdo_test_restore "$vmid"; return $?; fi
    local remote="${RCLONE_REMOTE}:${REMOTE_PATH}/${vmid}"

    # The latest offsite archive for the vmid.
    local base ts
    base="$(rclone lsf "$remote" 2>/dev/null | grep -E '\.tar\.zst$' | sort -r | head -1 || true)"
    [[ -n "$base" ]] || die "$EX_DATAERR" "test-restore: no offsite archives for vmid $vmid"
    ts="$(_archive_ts "$base")"

    local target; target="$(_tr_pick_target)" \
        || die "$EX_UNAVAILABLE" "test-restore: no free vmid in 9000–9099"
    local jobfile="${JOBS_DIR}/testrestore-${vmid}-$(date +%Y%m%d-%H%M%S).log"
    mkdir -p "$JOBS_DIR"
    audit_log "test-restore vmid=$vmid ts=$ts throwaway=$target"
    log_info "test-restore: vmid $vmid ($ts) → throwaway vmid $target"

    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] would fetch $vmid ($ts), restore→$target, boot, destroy"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "dry_run" "true" "vmid" "$vmid" "throwaway" "$target"
        return "$EX_OK"
    fi

    # 1. fetch FROM OFFSITE (+ sha256). die cleans up nothing — target not created yet.
    _fetch_core "$vmid" "$ts"
    local archive="$FETCHED_ARCHIVE"

    # unprivileged + storage from sidecar/meta.
    local unpriv=1
    if [[ -f "${archive}.conf" ]]; then
        unpriv="$(awk -F': ' '/^unprivileged:/{print $2; exit}' "${archive}.conf")"
        [[ "$unpriv" =~ ^[01]$ ]] || unpriv=1
    fi
    local storage
    storage="$(jq -r '.source_volumes[0] // empty' "${archive}.meta.json" 2>/dev/null | cut -d'|' -f1)"
    [[ -n "$storage" && "$storage" != "null" ]] || storage="nvmepool"

    # 2–4. restore → start → respond. From now on: clean up target on every failure.
    local ok=1 stage=""
    if ! run_stream "$jobfile" "pct-restore[$target]" -- \
            pct restore "$target" "$archive" --storage "$storage" --unprivileged "$unpriv"; then
        ok=0; stage="restore"
    fi
    if (( ok )) && ! run_stream "$jobfile" "pct-start[$target]" -- pct start "$target"; then
        ok=0; stage="start"
    fi
    if (( ok )); then
        log_info "test-restore: waiting for CT $target to respond…"
        _tr_wait "$target" || { ok=0; stage="respond"; }
    fi

    # 5. always clean up.
    _tr_destroy "$target"

    if (( ok )); then
        notify_success "test-restore OK: vmid $vmid ($ts) restored and booted on throwaway-$target"
        if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
            json_result "test_ok" "true" "vmid" "$vmid" "ts" "$ts" "throwaway" "$target"
        else
            log_info "test-restore: ✅ vmid $vmid booted from offsite (throwaway-$target, cleaned up)"
        fi
        return "$EX_OK"
    fi
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_result "test_failed" "false" "vmid" "$vmid" "stage" "$stage" "throwaway" "$target"
    die "$EX_SOFTWARE" "test-restore FAILED at step '$stage' for vmid $vmid (throwaway-$target cleaned up)"
}
