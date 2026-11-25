# shellcheck shell=bash
# lib/testrestore.sh: test-restore helpers + dispatcher. The full chain (restore
# a throwaway copy → boot → wait for it to respond → destroy) lives in the restic
# engine (lib/restic.sh, rdo_test_restore); the reusable _tr_* helpers are here.
#
# This is the only command that truly proves an offsite backup can be restored
# AND booted; the rest just verify bytes.

# Teardown of a throwaway THIS run restored (the caller only calls it then: the
# vmid was free when picked, but a fetch takes minutes and someone may have
# created a guest with that id meanwhile). Only the restored type is touched.
_tr_destroy() {
    local id="$1" t="${2:-lxc}"
    [[ -n "$id" ]] || return 0
    # protection: 1 (carried over from a protected source) would make destroy refuse
    if [[ "$t" == qemu ]]; then qm set "$id" --delete protection >/dev/null 2>&1 || true
        qm stop "$id" >/dev/null 2>&1 || true; qm destroy "$id" --purge >/dev/null 2>&1 || true
    else pct set "$id" --delete protection >/dev/null 2>&1 || true
        pct stop "$id" >/dev/null 2>&1 || true; pct destroy "$id" --purge >/dev/null 2>&1 || true; fi
}

# Wait until the guest responds (or timeout). qemu → guest-agent ping (via _g_alive,
# which accepts `running` when no agent is configured); lxc → a command runs inside.
# TR_RESPOND_HOW: how the answer was proven: "exec" (a command ran in the CT),
# "agent" (the qemu guest agent answered) or "running" (a VM without an agent:
# only that it is running, not that the OS came up). Recorded in the evidence.
_tr_wait() {
    local id="$1" gtype="${2:-lxc}" i
    TR_RESPOND_HOW=""
    for (( i=0; i < ${TR_WAIT_TRIES:-30}; i++ )); do
        if [[ "$gtype" == qemu ]]; then
            if qm agent "$id" ping >/dev/null 2>&1; then TR_RESPOND_HOW=agent; return 0; fi
            if ! qm config "$id" 2>/dev/null | grep -Eq '^agent:.*1' && [[ "$(qm status "$id" 2>/dev/null)" == *running* ]]; then
                TR_RESPOND_HOW=running; return 0
            fi
        elif pct exec "$id" -- true >/dev/null 2>&1; then TR_RESPOND_HOW="exec"; return 0
        fi
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
            qm set "$id" --delete "$k" >/dev/null 2>&1 || return 1
        done
    else
        for k in $(pct config "$id" 2>/dev/null | sed -n 's/^\(net[0-9]\+\):.*/\1/p'); do
            pct set "$id" --delete "$k" >/dev/null 2>&1 || return 1
        done
    fi
    return 0
}

# Isolation of the throwaway is an ALLOWLIST. As root, pct restore / qmrestore keep
# the source's host bindings (bind/device mount points, devN, raw lxc.* lines,
# hostpci/usb/serial passthrough, virtiofs, host-path disks, hookscripts...).
# Booting a second copy that shares a host directory or device with the running
# original can corrupt the original's data, and a denylist always misses one. So
# every config key must be known-safe; volume-backed disks and mount points only
# when their value is a storage volume. Everything else is removed before boot
# (_tr_strip_host), and _tr_isolated refuses the boot if anything unsafe remains.
# raw lxc keys: only uid/gid maps, resource limits and dropping capabilities;
# device access (lxc.cgroup2.devices.*), apparmor profiles and the rest are not safe.
_TR_LXC_SAFE='^(arch|parent|cmode|console|cores|cpulimit|cpuunits|digest|features|hostname|lock|memory|nameserver|onboot|ostype|protection|rootfs|searchdomain|startup|swap|tags|template|timezone|tty|unprivileged|unused[0-9]+|mp[0-9]+|lxc\.idmap|lxc\.cgroup2?\.(cpu|cpuset|memory|pids|io|blkio)\.[a-z0-9_.]+|lxc\.cap\.drop)$'
_TR_QEMU_SAFE='^(acpi|parent|agent|balloon|bios|boot|bootdisk|cores|cpu|cpulimit|cpuunits|digest|efidisk[0-9]+|hotplug|kvm|localtime|lock|machine|memory|meta|name|numa|onboot|ostype|protection|scsihw|smbios1|sockets|startup|tablet|tags|template|tpmstate[0-9]+|vcpus|vga|vmgenid|unused[0-9]+|(ide|sata|scsi|virtio)[0-9]+)$'

_tr_conf_file() { [[ "$1" == qemu ]] && printf '%s/%s.conf' "${PBO_PVE_QEMU_DIR:-/etc/pve/qemu-server}" "$2" || printf '%s/%s.conf' "${PBO_PVE_LXC_DIR:-/etc/pve/lxc}" "$2"; }

# _tr_unsafe_keys <type> <vmid> → keys of the main config section that are not
# known-safe (one per line). Read from the file: comments (the description) are
# skipped, raw lxc.* keys are included. Unreadable config → "<unreadable>".
_tr_unsafe_keys() {
    local t="$1" id="$2" f safe; f="$(_tr_conf_file "$t" "$id")"
    [[ -r "$f" ]] || { printf '<unreadable>\n'; return 0; }
    [[ "$t" == qemu ]] && safe="$_TR_QEMU_SAFE" || safe="$_TR_LXC_SAFE"
    SAFE="$safe" TARGET="$id" ALLOWNET="${TR_ALLOW_LINKDOWN_NET:-0}" awk '
        # any section: pending changes ([PENDING], [pve:pending]) apply at the next
        # start and snapshots do not belong in a fresh restore. Only cloud-init metadata is fine.
        /^\[/ { main = 0; if ($0 !~ /^\[special:cloudinit\][[:space:]]*$/) print "<section " $0 ">"; next }
        BEGIN { main = 1 }
        !main || /^[[:space:]]*(#|$)/ { next }
        {
            k = $0; sub(/[[:space:]]*[:=].*/, "", k)
            v = $0; sub(/^[^:=]*[:=][[:space:]]*/, "", v)
            # restore --start keeps its NICs, but only disconnected (link_down=1)
            if (ENVIRON["ALLOWNET"] == "1" && k ~ /^net[0-9]+$/ && v ~ /(^|,)link_down=1(,|$)/) next
            if (k !~ ENVIRON["SAFE"]) { print k; next }
            # features: only nesting, keyctl, fuse (mount=, force_rw_sys= etc. reach the host)
            if (k == "features") { n = split(v, f, ","); for (i = 1; i <= n; i++) if (f[i] !~ /^(nesting|keyctl|fuse)=[01]$/) { print k; next } }
            # disks / mount points / unused: only volumes OWNED by the throwaway
            # (vm|subvol|base-<target>-...), an empty drive, or an ISO as cdrom.
            if (k ~ /^(rootfs|mp[0-9]+|unused[0-9]+|(ide|sata|scsi|virtio)[0-9]+|efidisk[0-9]+|tpmstate[0-9]+)$/) {
                split(v, p, ","); src = p[1]; sub(/^(volume|file)=/, "", src)
                if (src == "none") next
                if (src !~ /^[A-Za-z0-9][A-Za-z0-9._-]*:[^\/]/) { print k; next }
                vol = src; sub(/^[^:]*:/, "", vol); n = split(vol, seg, "/"); last = seg[n]
                if (last ~ ("^(vm|subvol|base)-" ENVIRON["TARGET"] "-")) next
                if (vol ~ /^iso\// && v ~ /(^|,)media=cdrom(,|$)/) next
                print k
            }
        }' "$f" | sort -u
}

# _tr_strip_host <type> <vmid>: remove every unsafe key. Sets TR_STRIPPED.
_tr_strip_host() {
    local t="$1" id="$2" k keys=() raw=() failed=0 f
    TR_STRIPPED=()
    mapfile -t keys < <(_tr_unsafe_keys "$t" "$id")
    for k in "${keys[@]}"; do
        case "$k" in
            '<unreadable>'|'<section '*|rootfs) failed=1 ;;
            lxc.*) raw+=("$k") ;;
            *) if [[ "$t" == qemu ]]; then qm set "$id" --delete "$k" >/dev/null 2>&1 && TR_STRIPPED+=("$k") || failed=1
               else pct set "$id" --delete "$k" >/dev/null 2>&1 && TR_STRIPPED+=("$k") || failed=1; fi ;;
        esac
    done
    # raw lxc.* keys cannot be removed with pct set: rewrite the main section
    if (( ${#raw[@]} )); then
        f="$(_tr_conf_file "$t" "$id")"
        local body; body="$(RAW=" ${raw[*]} " awk '
            BEGIN { main = 1 } /^\[/ { main = 0 }
            { k = $0; sub(/[[:space:]]*[:=].*/, "", k) }
            !(main && index(ENVIRON["RAW"], " " k " ") > 0)' "$f")" || body=""
        if [[ -n "$body" ]] && printf '%s\n' "$body" > "$f"; then TR_STRIPPED+=("${raw[@]}"); else failed=1; fi
    fi
    return "$failed"
}

# _tr_isolated <type> <vmid>: 0 only when nothing unsafe is left (network included:
# netN is not on the allowlist) and autostart is off. Checked before boot.
_tr_isolated() {
    local t="$1" id="$2"
    [[ -z "$(_tr_unsafe_keys "$t" "$id")" ]] || return 1
    ! grep -qE '^onboot:[[:space:]]*1' "$(_tr_conf_file "$t" "$id")"
}

# Pick the highest free throwaway vmid in 9000-9099 (free = neither an LXC nor a VM).
# _tr_pick_target → TR_TARGET: a free throwaway vmid in 9000-9099, free cluster-wide (not
# only on this node), and holds its lock (TR_TARGET_LOCK_FD) so a concurrent
# test-restore or restore cannot pick the same one.
_tr_pick_target() {
    local n taken="" j
    j="$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null)" || j=""
    jq -e 'type=="array"' >/dev/null 2>&1 <<<"$j" && taken=" $(jq -r '.[].vmid' <<<"$j" | tr '\n' ' ') "
    for (( n=9099; n >= 9000; n-- )); do
        [[ "$taken" == *" $n "* ]] && continue
        _g_exists "$n" && continue
        exec {TR_TARGET_LOCK_FD}>"${LOCK_DIR}/pbo.vmid-${n}.lock" || continue
        if flock -n "$TR_TARGET_LOCK_FD"; then TR_TARGET="$n"; return 0; fi
        exec {TR_TARGET_LOCK_FD}>&-
    done
    return 1
}

# do_test_restore <vmid>, dispatch to the restic engine.
do_test_restore() { rdo_test_restore "$1"; }

# --- scheduled restore tests + evidence ----------------------------------------
# Every test-restore (manual or scheduled) appends one JSON record to the history
# (TR_HISTORY, default STATE_DIR/restore-tests.jsonl; STATE_DIR is not rotated,
# the history is the evidence). The scheduled run picks the guest that has gone
# longest without a test and refreshes STATE_DIR/restore-report.{json,txt}, the
# file to hand an auditor. `pbo restore-report` prints the same on demand.

_tr_history() { printf '%s' "${TR_HISTORY:-$STATE_DIR/restore-tests.jsonl}"; }

# _tr_stage <name> <ok:true|false> <seconds>: collect one stage into TR_STAGES.
_tr_stage() { TR_STAGES+=("$(jq -cn --arg n "$1" --argjson ok "$2" --argjson s "$3" '{name:$n, ok:$ok, seconds:$s}')"); }

# _tr_records: the history as a JSON array; unreadable lines are skipped.
_tr_records() {
    local f; f="$(_tr_history)"
    [[ -r "$f" ]] || { printf '[]'; return 0; }
    jq -cR 'fromjson? // empty | select(type=="object" and (.vmid|type)=="string" and (.epoch|type)=="number")' "$f" 2>/dev/null \
        | jq -cs '.' 2>/dev/null || printf '[]'
}

# _tr_last_by_vmid → {"<vmid>": <newest record>, ...}
_tr_last_by_vmid() {
    _tr_records | jq -c 'group_by(.vmid) | map(max_by(.epoch)) | map({key:.vmid, value:.}) | from_entries' 2>/dev/null || printf '{}'
}

# _tr_record <json>: append to the history and refresh the report files.
_tr_record() {
    local f; f="$(_tr_history)"
    [[ -n "$1" ]] || { log_warn "test-restore: could not build the evidence record"; return 0; }
    mkdir -p "$(dirname "$f")" 2>/dev/null
    printf '%s\n' "$1" >> "$f" 2>/dev/null || log_warn "test-restore: could not write the evidence record to $f"
    _tr_write_report
}

# _tr_candidates → vmids to rotate through: guests in this node's backup set
# (pbo-skip excluded unless a PVE job owns the guest) that have at least one snapshot in the read repo.
_tr_candidates() {
    local repo snaps; repo="$(_restic_read_repo)"
    snaps="$(_restic "$repo" --no-lock snapshots --json 2>/dev/null)" || return 1
    local inrepo; inrepo="$(printf '%s' "$snaps" | jq -r '.[] | (.tags // [])[] | select(test("^vmid=[0-9]+$")) | sub("vmid=";"")' 2>/dev/null | sort -u)" || return 1
    local id
    while read -r id; do
        [[ -n "$id" ]] && grep -qx "$id" <<<"$inrepo" && printf '%s\n' "$id"
    done < <(_backup_set)
    return 0
}

# _tr_next_guest <candidates (lines)> <already picked (space separated)>
# → the next guest to test: a guest whose latest test FAILED comes first
# (oldest failure first), then never-tested guests, then the oldest-tested
# (ties: lowest vmid). At most one failed guest is retried per run, so a guest
# that keeps failing cannot block the rotation when TR_PER_RUN > 1.
_tr_next_guest() {
    local last c out rank ep ok failed_picked=0 p
    last="$(_tr_last_by_vmid)"
    # note: `false // x` is x in jq, so the result is read with an explicit null check
    for p in $2; do [[ "$(jq -r --arg v "$p" '.[$v] | if . == null then "" else (.ok | tostring) end' <<<"$last")" == false ]] && failed_picked=1; done
    out="$(while read -r c; do
        [[ -n "$c" && " $2 " != *" $c "* ]] || continue
        ep="$(jq -r --arg v "$c" '.[$v].epoch // 0' <<<"$last")"
        ok="$(jq -r --arg v "$c" '.[$v] | if . == null then "" else (.ok | tostring) end' <<<"$last")"
        if [[ "$ok" == false ]] && (( ! failed_picked )); then rank=0
        elif [[ -z "$ok" ]]; then rank=1
        else rank=2; fi
        printf '%s %s %s\n' "$rank" "$ep" "$c"
    done <<<"$1" | sort -k1,1n -k2,2n -k3,3n | head -1 | awk '{print $3}')"
    [[ -n "$out" ]] || return 1
    printf '%s' "$out"
}

# test-restore --scheduled: TR_PER_RUN guests (default 1), each in its own
# subshell so one failure does not stop the rest. Every outcome is recorded.
rdo_test_restore_scheduled() {
    _guest_meta_load
    _pve_jobs_load      # PVE-owned guests count too (lib/ownership.sh); no-op in standalone
    local n="${TR_PER_RUN:-1}"; [[ "$n" =~ ^[0-9]{1,3}$ ]] && (( 10#$n >= 1 )) || n=1; n=$((10#$n))
    local cands; cands="$(_tr_candidates)" || die "$EX_UNAVAILABLE" "test-restore --scheduled: repo not readable"
    if [[ -z "$cands" ]]; then
        log_warn "test-restore --scheduled: no guest in the backup set has a snapshot yet, nothing to test"
        [[ "${JSON_OUTPUT:-0}" == 1 ]] && json_emit '{"status":"nothing_to_test","ok":true,"tested":[],"failed":[]}'
        return "$EX_OK"
    fi
    local picked=() failed=() id i
    for (( i=0; i<n; i++ )); do
        id="$(_tr_next_guest "$cands" "${picked[*]:-}")" || break
        picked+=("$id")
        log_info "test-restore --scheduled: testing vmid $id ($((i+1))/$n)"
        ( TR_TRIGGER=scheduled; JSON_OUTPUT=0; do_test_restore "$id" ) || failed+=("$id")
    done
    TR_FAILED="${#failed[@]}"
    # one JSON object for the run (the per-guest results are in the evidence)
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_emit "$(jq -cn --arg t "${picked[*]:-}" --arg f "${failed[*]:-}" --arg rep "${STATE_DIR}/restore-report.json" \
            '($f | split(" ") | map(select(length>0))) as $fl
             | {status:(if ($fl|length) == 0 then "ok" else "failed" end), ok:(($fl|length) == 0),
                tested:($t | split(" ") | map(select(length>0))), failed:$fl, report:$rep}')"
    fi
    if (( ${#failed[@]} )); then
        # each failure already alerted with its stage; this is the run summary
        log_warn "test-restore --scheduled: ${#failed[@]} of ${#picked[@]} failed (${failed[*]}), report: ${STATE_DIR}/restore-report.txt"
        PBO_ERROR_LOGGED=1   # no second "stopped unexpectedly" alert
        exit "$EX_SOFTWARE"
    fi
    log_info "test-restore --scheduled: ${#picked[@]} OK (${picked[*]}), report: ${STATE_DIR}/restore-report.txt"
    return "$EX_OK"
}

# _tr_report_json [days] → the evidence report as JSON.
_tr_report_json() {
    local days="${1:-${TR_REPORT_DAYS:-90}}"; [[ "$days" =~ ^[0-9]{1,5}$ ]] || days=90
    local set; set="$(_backup_set | jq -R . | jq -cs . 2>/dev/null)" || set='[]'; [[ -n "$set" ]] || set='[]'
    _tr_records | jq -c --argjson set "$set" --argjson days "$((10#$days))" --argjson now "$(date +%s)" \
        --arg node "$(_local_node 2>/dev/null)" --arg ver "${VERSION:-}" '
        . as $h | ($now - $days*86400) as $since
        | ($h | group_by(.vmid) | map(max_by(.epoch)) | map({key:.vmid, value:.}) | from_entries) as $last
        | { generated: ($now | todate), node: $node, version: $ver, window_days: $days,
            tests: ([$h[] | select(.epoch >= $since)] | sort_by(.epoch) | reverse),
            coverage: {
              guests: ($set | length),
              tested_ok: [$set[] | select($last[.].ok == true and $last[.].epoch >= $since)],
              not_in_window: [$set[] | select($last[.].ok == true and $last[.].epoch < $since)],
              failed: [$set[] | select($last[.] != null and $last[.].ok != true)],
              never: [$set[] | select($last[.] == null)] } }'
}

# _tr_report_text: the JSON report (stdin) rendered for humans.
_tr_report_text() {
    jq -r '
        def dur: (. // 0 | floor) as $s | if $s >= 3600 then "\($s/3600|floor)h\(($s%3600)/60|floor)m"
                 elif $s >= 60 then "\($s/60|floor)m\($s%60)s" else "\($s)s" end;
        def ids: if length == 0 then "none" else join(" ") end;
        "pbo restore tests on \(.node), last \(.window_days) days (generated \(.generated), pbo \(.version))",
        "",
        (if (.tests | length) == 0 then "  no restore tests in this window" else
          (.tests[] |
            "  \(.time[0:16] | sub("T";" "))  \(.vmid)  \(.name // "" | if . == "" then "-" else . end)  \(.type)  "
            + (if .ok then "OK    " else "FAILED at \(.failed_stage)  " end) + "\(.duration_s | dur)  "
            + "snapshot \((.snapshot.time // "")[0:16] | sub("T";" ")) (\(.snapshot.age_s | dur) old, \(.repo.tier))  "
            + ([.stages[] | "\(.name) \(.seconds | dur)\(if .ok then "" else " FAIL" end)"] | join(", "))
            + (if .trigger == "scheduled" then "" else "  [\(.trigger)]" end)) end),
        "",
        "coverage: \(.coverage.guests) guests in the backup set",
        "  tested OK in window: \(.coverage.tested_ok | length) (\(.coverage.tested_ok | ids))",
        "  latest test FAILED:  \(.coverage.failed | length) (\(.coverage.failed | ids))",
        "  OK, but not in window: \(.coverage.not_in_window | length) (\(.coverage.not_in_window | ids))",
        "  never tested:        \(.coverage.never | length) (\(.coverage.never | ids))"'
}

# _tr_write_report: refresh STATE_DIR/restore-report.{json,txt}.
_tr_write_report() {
    local j; j="$(_tr_report_json 2>/dev/null)" || return 0
    [[ -n "$j" ]] || return 0
    local b="${STATE_DIR}/restore-report"
    printf '%s\n' "$j" > "$b.json.$$" 2>/dev/null && mv -f "$b.json.$$" "$b.json"
    printf '%s' "$j" | _tr_report_text > "$b.txt.$$" 2>/dev/null && mv -f "$b.txt.$$" "$b.txt"
    rm -f "$b.json.$$" "$b.txt.$$" 2>/dev/null
    return 0
}

# restore-report [--days N]: print the report (--json for the JSON form).
rdo_restore_report() {
    _guest_meta_load
    _pve_jobs_load      # PVE-owned guests count too (lib/ownership.sh); no-op in standalone
    local days="${TR_REPORT_DAYS:-90}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days) [[ "${2:-}" =~ ^[0-9]{1,5}$ ]] || die "$EX_USAGE" "--days needs a number"; days="$2"; shift 2 ;;
            *) die "$EX_USAGE" "unknown restore-report flag: $1" ;;
        esac
    done
    local j; j="$(_tr_report_json "$days")" || die "$EX_SOFTWARE" "could not build the restore report"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_emit "$(jq -c '{status:"ok", ok:true} + .' <<<"$j")"; else printf '%s' "$j" | _tr_report_text; fi
}

# _tr_leftovers → throwaway guests still around (tagged pbo-throwaway), e.g. after
# a crash mid-test. One cluster query instead of probing 9000-9099.
_tr_leftovers() {
    pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
        | jq -r --arg n "$(_local_node 2>/dev/null)" '.[] | select((.tags // "") | split(";") | index("pbo-throwaway"))
                 | select(.node == $n) | .vmid' 2>/dev/null | sort -n | tr '\n' ' ' | sed 's/ $//'
}

# _doctor_testrestore <ok> <bad> <warn> → TRD_LINES, TRD_PROBLEMS, TRD_WARNS
_doctor_testrestore() {
    local ok="$1" bad="$2" warn="$3"; TRD_LINES=(); TRD_PROBLEMS=0; TRD_WARNS=0
    local j; j="$(_tr_report_json "${TR_REPORT_DAYS:-90}" 2>/dev/null)" || j='{}'
    local newest; newest="$(_tr_records | jq -c 'max_by(.epoch) // empty' 2>/dev/null)" || newest=""
    if [[ -z "$newest" ]]; then
        TRD_LINES+=("$warn  no restore test recorded yet (pbo test-restore <vmid>, or enable pbo-test-restore.timer)"); TRD_WARNS=1
    else
        local ep days max="${TR_MAX_AGE:-1814400}"   # 21 days
        ep="$(jq -r '.epoch' <<<"$newest")"; days=$(( ( $(date +%s) - ep ) / 86400 ))
        local f; for f in $(jq -r '.coverage.failed[]?' <<<"$j" 2>/dev/null); do
            TRD_LINES+=("$bad  $(_tr_last_by_vmid | jq -r --arg v "$f" '.[$v] | "restore test of vmid \(.vmid) FAILED at \(.failed_stage) on \(.time[0:10])"') (re-test: pbo test-restore $f)")
            TRD_PROBLEMS=$((TRD_PROBLEMS+1))
        done
        if (( $(date +%s) - ep > max )); then TRD_LINES+=("$warn  last restore test ${days}d ago (> $(( max/86400 ))d)"); TRD_WARNS=$((TRD_WARNS+1))
        else TRD_LINES+=("$ok  last restore test ${days}d ago (vmid $(jq -r '.vmid' <<<"$newest") $(jq -r 'if .ok then "OK" else "FAILED" end' <<<"$newest")); $(jq -r '"\(.coverage.tested_ok|length)/\(.coverage.guests) guests tested OK in \(.window_days)d"' <<<"$j")"); fi
    fi
    local lo; lo="$(_tr_leftovers)" || lo=""
    if [[ -n "$lo" ]]; then TRD_LINES+=("$warn  leftover test-restore throwaway guest(s): $lo (destroy them if no test is running)"); TRD_WARNS=$((TRD_WARNS+1)); fi
    return 0
}

# _tr_mark_throwaway <type> <vmid>: no autostart, tagged pbo-throwaway.
_tr_mark_throwaway() {
    if [[ "$1" == qemu ]]; then qm set "$2" --onboot 0 --protection 0 --tags pbo-throwaway >/dev/null 2>&1
    else pct set "$2" --onboot 0 --protection 0 --tags pbo-throwaway >/dev/null 2>&1; fi
}
