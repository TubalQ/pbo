# shellcheck shell=bash
# lib/metrics.sh: Prometheus metrics and the JSON audit log.
#
# Metrics are a node_exporter textfile (METRICS_FILE, default
# STATE_DIR/pbo.prom; point it into node_exporter's --collector.textfile.directory
# to have it scraped). Two sources:
#  - events (run-schedule, verify, prune, test-restore, ingest) recorded in STATE_DIR/metrics-state.json
#    as they happen;
#  - per guest, read from the repo: restic keeps a summary in every snapshot
#    (start/end, bytes added, bytes processed), so nothing extra is measured
#    during a backup.
# The file is rewritten after run-schedule, verify, prune, test-restore, a manual
# backup (or one run as a job) and by `pbo metrics`.
#
# Audit: AUDIT_JSON (default LOG_DIR/audit.jsonl), one JSON object per line: a
# "command" entry per invocation (who, what, args, node, exit code, duration)
# and "event" entries for the details audit_log already records (restore etc.).

_metrics_state() { printf '%s/metrics-state.json' "$STATE_DIR"; }

# _metrics_event <name> <key> <value> [<key> <value> ...]: numbers only.
_metrics_event() {
    local name="$1"; shift
    local f; f="$(_metrics_state)"
    local cur='{}'; [[ -r "$f" ]] && cur="$(cat "$f" 2>/dev/null)"; jq -e 'type=="object"' >/dev/null 2>&1 <<<"$cur" || cur='{}'
    local args=(--arg n "$name") upd='.[$n] = (.[$n] // {})' i=0
    while [[ $# -ge 2 ]]; do
        [[ "$2" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || { shift 2; continue; }
        args+=(--arg "k$i" "$1" --argjson "v$i" "$2"); upd+=" | .[\$n][\$k$i] = \$v$i"; i=$((i+1)); shift 2
    done
    jq -c "${args[@]}" "$upd" <<<"$cur" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
    return 0
}

# _metrics_render → the textfile on stdout. Reads the repo once.
_metrics_render() {
    local state='{}' f; f="$(_metrics_state)"
    [[ -r "$f" ]] && state="$(cat "$f")"; jq -e 'type=="object"' >/dev/null 2>&1 <<<"$state" || state='{}'
    local repo snaps; repo="$(_restic_read_repo)"
    snaps="$(_restic "$repo" --no-lock snapshots --json 2>/dev/null)" || snaps=""
    local repo_ok=1; jq -e 'type=="array"' >/dev/null 2>&1 <<<"$snaps" || { snaps='[]'; repo_ok=0; }
    local tier=offsite; [[ "$repo" == "${RESTIC_CACHE_REPO:-}" ]] && tier=cache
    # snapshots on stdin: a production repo's list is far too big for argv
    local tr='{}'; declare -F _tr_last_by_vmid >/dev/null && tr="$(_tr_last_by_vmid)"
    jq -e 'type=="object"' >/dev/null 2>&1 <<<"$tr" || tr='{}'
    local trf; trf="$(mktemp)"; printf '%s' "$tr" > "$trf"
    printf '%s' "$snaps" | jq -r --argjson st "$state" --slurpfile trs "$trf" --arg node "$(_local_node)" --arg ver "${VERSION:-}" \
          --arg role "${PBO_ROLE:-host}" --arg tier "$tier" --argjson repo_ok "$repo_ok" '
        . as $s | ($trs[0] // {}) as $tr |
        def ts: capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2}))$")
            | ((.d + "Z") | fromdateiso8601)
              - (if .z == "Z" then 0 else ((if .s == "+" then 1 else -1 end) * ((.h|tonumber)*3600 + (.m|tonumber)*60)) end);
        def lbl($o): if ($o|length) == 0 then "" else
            "{" + ([$o | to_entries[] | "\(.key)=\"\(.value|tostring|gsub("\\\\";"\\\\\\\\")|gsub("\"";"\\\\\"")|gsub("\n";"\\\\n"))\""] | join(",")) + "}" end;
        def m($name; $help; $type; $rows): "# HELP \($name) \($help)\n# TYPE \($name) \($type)\n" + ([$rows[] | "\($name)\(lbl(.l)) \(.v)"] | join("\n"));
        ( [ $s[]
            | { vmid: ((.tags // []) | map(select(startswith("vmid="))) | .[0] // "" | sub("vmid=";"")),
                type: ((.tags // []) | map(select(startswith("type="))) | .[0] // "type=lxc" | sub("type=";"")
                       | if test("^(lxc|qemu|host)$") then . else "unknown" end),
                t: ((.time | ts?) // 0), sm: (.summary // {}) }
            | select(.vmid | test("^([0-9]{1,9}|host-[A-Za-z0-9.-]{1,63})$")) ]
          | group_by(.vmid) | map(max_by(.t) as $l | {vmid: .[0].vmid, type: $l.type, n: length, last: $l}) ) as $g
        | [ m("pbo_info"; "pbo version and role"; "gauge"; [{l:{version:$ver, role:$role, node:$node}, v:1}]),
            m("pbo_repo_up"; "1 if the repo answered the snapshot listing"; "gauge"; [{l:{tier:$tier}, v:$repo_ok}]),
            m("pbo_repo_snapshots"; "snapshots in the repo"; "gauge"; [{l:{tier:$tier}, v:($s|length)}]),
            m("pbo_guest_snapshots"; "snapshots per guest"; "gauge"; [$g[] | {l:{vmid, type}, v:.n}]),
            m("pbo_guest_last_backup_timestamp_seconds"; "time of the newest snapshot per guest"; "gauge"; [$g[] | {l:{vmid, type}, v:.last.t}]),
            m("pbo_guest_last_backup_duration_seconds"; "duration of the newest backup (restic part)"; "gauge";
              [$g[] | select(.last.sm.backup_start and .last.sm.backup_end)
                    | {l:{vmid, type}, v:(((.last.sm.backup_end|ts?) // 0) - ((.last.sm.backup_start|ts?) // 0))}]),
            m("pbo_guest_last_backup_added_bytes"; "new data added by the newest backup (before compression)"; "gauge";
              [$g[] | select(.last.sm.data_added != null) | {l:{vmid, type}, v:.last.sm.data_added}]),
            m("pbo_guest_last_backup_processed_bytes"; "size of the guest archive in the newest backup"; "gauge";
              [$g[] | select(.last.sm.total_bytes_processed != null) | {l:{vmid, type}, v:.last.sm.total_bytes_processed}]),
            ( [ $tr | to_entries[] | .value
                | select((.vmid|type) == "string" and (.vmid | test("^[0-9]{1,9}$")))
                | {vmid, type: (.type // "" | if test("^(lxc|qemu)$") then . else "unknown" end),
                   epoch: (.epoch // 0), ok: (if .ok == true then 1 else 0 end), dur: (.duration_s // 0)} ] as $t
              | m("pbo_guest_last_test_restore_timestamp_seconds"; "time of the newest restore test per guest"; "gauge"; [$t[] | {l:{vmid, type}, v:.epoch}]) + "\n"
              + m("pbo_guest_last_test_restore_success"; "1 if the newest restore test of the guest booted"; "gauge"; [$t[] | {l:{vmid, type}, v:.ok}]) + "\n"
              + m("pbo_guest_last_test_restore_duration_seconds"; "duration of the newest restore test"; "gauge"; [$t[] | {l:{vmid, type}, v:.dur}]) ),
            ( ["run_schedule","verify","prune","test_restore","ingest"] | map(. as $e | ($st[$e] // {}) as $x
                | select($x | length > 0)
                | m("pbo_\($e)_last_timestamp_seconds"; "when \($e) last finished"; "gauge"; [{l:{}, v:($x.time // 0)}]) + "\n"
                + m("pbo_\($e)_last_success"; "1 if the last \($e) succeeded"; "gauge"; [{l:{}, v:($x.ok // 0)}])
                + (if $x.duration then "\n" + m("pbo_\($e)_last_duration_seconds"; "duration of the last \($e)"; "gauge"; [{l:{}, v:$x.duration}]) else "" end)
                + (if $x.failed != null then "\n" + m("pbo_\($e)_last_failed"; "guests that failed in the last \($e)"; "gauge"; [{l:{}, v:$x.failed}]) else "" end)
              ) | .[] )
          ] | join("\n") + "\n"'
    local rc=$?; rm -f "$trf"; return "$rc"
}

# _metrics_write: render to METRICS_FILE atomically (Prometheus may read any time).
_metrics_write() {
    [[ "${METRICS_ENABLED:-true}" == "true" ]] || return 0
    local f="${METRICS_FILE:-$STATE_DIR/pbo.prom}" out
    out="$(_metrics_render 2>/dev/null)" || return 0
    [[ -n "$out" ]] || return 0
    local dir; dir="$(dirname "$f")"; mkdir -p "$dir" 2>/dev/null
    # a directory someone else can write (e.g. a shared node-exporter textfile
    # dir) must not get a predictable temp name from root: mktemp, fchmod via umask
    if [[ "$(id -u)" == 0 && "$(stat -c %u "$dir" 2>/dev/null)" != 0 ]]; then
        log_warn "metrics: $dir is not owned by root, not writing $f"; return 0
    fi
    local tmp; tmp="$(umask 022; mktemp "$dir/.pbo.prom.XXXXXX")" || return 0
    printf '%s' "$out" > "$tmp" 2>/dev/null && chmod 0644 "$tmp" && mv -f "$tmp" "$f" || rm -f "$tmp"
    return 0
}

# metrics [--no-write]: print the metrics (and refresh the textfile).
rdo_metrics() {
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        # one JSON object like every command: the Prometheus text as a string
        local t; t="$(_metrics_render)" || die "$EX_SOFTWARE" "metrics: could not render"
        json_emit "$(jq -cn --arg t "$t" '{status:"ok", ok:true, format:"prometheus-text", text:$t}')"
    else
        _metrics_render
    fi
    [[ "${1:-}" == "--no-write" ]] || _metrics_write
}

# --- JSON audit log ---------------------------------------------------------
_audit_json() {                       # <json-object>
    local f="${AUDIT_JSON:-}"
    [[ -n "$f" ]] || return 0
    ( umask 077; printf '%s\n' "$1" >> "$f" ) 2>/dev/null || true
}
# PBO_AUDIT_USER: set by the job runner or a wrapper to the person who asked for the
# action (e.g. alice@pve). Only root can run pbo, so this is a label, not a boundary.
_audit_who() { printf '%s' "${PBO_AUDIT_USER:-${SUDO_USER:-$(id -un 2>/dev/null || echo "uid$(id -u)")}}"; }

# Read-only commands are logged too (who looked at what is part of an audit),
# flagged so a reader can filter them. `config` is not in the list: `config
# set|unset` change the config; its read-only subcommands (show, list, get,
# template, check) set AUDIT_RO_OVERRIDE (rdo_config, lib/config.sh). `timers apply`
# writes drop-ins: AUDIT_RW_OVERRIDE (lib/timers.sh), like `doctor --fix`.
readonly AUDIT_READONLY="status list usage doctor metrics help preflight restore-report guests timers version"

audit_command_start() {
    AUDIT_T0="$(date +%s)"
}
audit_command_end() {                 # <exit code>
    [[ -n "${PBO_COMMAND:-}" && -n "${AUDIT_T0:-}" ]] || return 0
    [[ "${PBO_AUDIT_DONE:-0}" == 1 ]] && return 0; PBO_AUDIT_DONE=1
    local ro=false; [[ " $AUDIT_READONLY " == *" $PBO_COMMAND "* || "${AUDIT_RO_OVERRIDE:-0}" == 1 ]] && ro=true
    # a read-only command can change things with a flag (doctor --fix)
    [[ "${AUDIT_RW_OVERRIDE:-0}" == 1 ]] && ro=false
    [[ "${DRY_RUN:-0}" == 1 ]] && ro=true
    # AUDIT_ARGS: the arguments with secret values masked (config set), when set
    local -a _aud_args=("${PBO_ORIG_ARGS[@]+"${PBO_ORIG_ARGS[@]}"}")
    declare -p AUDIT_ARGS >/dev/null 2>&1 && _aud_args=("${AUDIT_ARGS[@]+"${AUDIT_ARGS[@]}"}")
    _audit_json "$(jq -cn --arg time "$(date --iso-8601=seconds)" --arg user "$(_audit_who)" \
        --arg node "$(_local_node 2>/dev/null)" --arg role "${PBO_ROLE:-host}" --arg cmd "$PBO_COMMAND" \
        --arg ver "${VERSION:-}" --argjson rc "$1" --argjson dur "$(( $(date +%s) - AUDIT_T0 ))" \
        --argjson ro "$ro" --argjson dry "$( [[ "${DRY_RUN:-0}" == 1 ]] && echo true || echo false )" \
        --argjson pid "$$" --arg via "${PBO_AUDIT_VIA:-cli}" --arg job "${PBO_JOB_ID:-}" \
        --arg client "$( [[ "${PBO_AUDIT_CLIENT:-}" =~ ^[0-9A-Fa-f:.]{2,45}(/64)?$ ]] && printf '%s' "$PBO_AUDIT_CLIENT" )" '$ARGS.positional as $a
        | {time:$time, kind:"command", user:$user, node:$node, role:$role, command:$cmd,
           args:$a, exit:$rc, ok:($rc==0), duration_s:$dur, read_only:$ro, dry_run:$dry, pid:$pid, version:$ver,
           via:$via, job:(if $job == "" then null else ($job | tonumber) end),
           client:(if $client == "" then null else $client end)}' \
        --args -- "${_aud_args[@]+"${_aud_args[@]}"}" 2>/dev/null)"
}
