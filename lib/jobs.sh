# shellcheck shell=bash
# lib/jobs.sh: the job model.
#
# A job is one pbo action run in the background, observable from anywhere (CLI,
# menu, scripts) and independent of whoever started it:
#   pbo job start <command> [args]   → returns the job id at once
#   pbo job list | show <id> | log <id> [--from N] [--follow] | cancel <id>
#
# Each job has a directory RUNS_DIR/<id>/ (RUNS_DIR = STATE_DIR/runs):
#   meta.json    id, command, args (JSON array), started_by, via, created, runner
#   log          everything the command wrote to stderr (pbo's log lines)
#   out.jsonl    what it wrote to stdout (with --json: its result object)
#   pid          the runner's pid; child.pid the pbo process it started
#   result.json  written when it ended: exit code, end time, the result object
# With systemd the job runs as a transient unit pbo-job-<id> (survives the
# caller, cancel stops the whole cgroup); otherwise (JOB_RUNNER=direct, tests,
# containers) in its own session via setsid.
#
# The command takes its locks itself, exactly as on the CLI. backup and prune
# are started with --queue, so a job waits for a running backup instead of
# failing; `show` reports it as "queued" meanwhile.

# Commands that may run as a job. Read-only views are not jobs (just call them).
readonly JOB_COMMANDS="backup run-schedule verify prune restore test-restore fetch unlock backup-host notify-test init"
readonly JOB_SINGLE="prune verify run-schedule test-restore"

_runs_dir() { printf '%s/runs' "$STATE_DIR"; }
_job_dir()  { printf '%s/%s' "$(_runs_dir)" "$1"; }
_job_id_ok() { [[ "$1" =~ ^[0-9]{1,9}$ ]]; }

# _job_next_id: a monotonically increasing integer (flock'ed counter).
_job_next_id() {
    local d; d="$(_runs_dir)"; mkdir -p "$d" && chmod 0750 "$d" 2>/dev/null || true
    (
        flock -x 9
        local n=0; [[ -r "$d/.seq" ]] && n="$(tr -cd '0-9' < "$d/.seq")"
        n=$(( 10#${n:-0} + 1 ))
        printf '%s\n' "$n" > "$d/.seq.tmp" && mv -f "$d/.seq.tmp" "$d/.seq"
        printf '%s' "$n"
    ) 9>"$d/.seq.lock"
}

_job_runner() {
    case "${JOB_RUNNER:-auto}" in
        direct) printf direct ;;
        systemd) printf systemd ;;
        *) if command -v systemd-run >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then printf systemd; else printf direct; fi ;;
    esac
}

# _pid_is <pid> <needle>: pid alive and its command line contains needle (pid reuse guard)
# _pid_is <pid> <needle>: the needle must match whole arguments ("_job-run 1"
# must not match "_job-run 12")
_pid_is() {
    [[ "$1" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null || return 1
    local args; args=" $(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)"
    [[ "$args" == *" $2 "* || "$args" == *" $2" ]]
}

# _job_json <id> → the job as one object (state derived from the files)
_job_json() {
    local id="$1" d; d="$(_job_dir "$id")"
    [[ -r "$d/meta.json" ]] || return 1
    local state pid res='null' now; now="$(date +%s)"
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    if [[ -r "$d/result.json" ]]; then
        res="$(cat "$d/result.json")"; jq -e 'type=="object"' >/dev/null 2>&1 <<<"$res" || res='{"exit":null}'
        state="$(jq -r 'if .cancelled then "cancelled" elif .exit == 0 then "ok" else "failed" end' <<<"$res")"
    elif _pid_is "$pid" "_job-run $id"; then
        state=running
        # still waiting for the global/schedule lock (its last lock message is a wait) → queued
        grep -E 'waiting for (global lock|.* to finish \(schedule lock)|global lock acquired|schedule lock acquired' "$d/log" 2>/dev/null \
            | tail -1 | grep -q 'waiting for' && state=queued
    elif [[ ! -e "$d/pid" ]] && (( now - $(stat -c %Y "$d/meta.json" 2>/dev/null || echo "$now") < 30 )); then
        state=starting
    else
        state=lost
    fi
    jq -c --arg state "$state" --argjson res "$res" --argjson now "$now" '
        . + { state: $state,
              exit: $res.exit, ended: $res.ended, cancelled: ($res.cancelled // false),
              duration_s: (if $res.ended_epoch then $res.ended_epoch - .created_epoch else $now - .created_epoch end),
              result: $res.result }' "$d/meta.json"
}

# job start <command> [args...]
rdo_job_start() {
    local cmd="${1:-}"; shift || true
    [[ -n "$cmd" && " $JOB_COMMANDS " == *" $cmd "* ]] \
        || die "$EX_USAGE" "job start: '$cmd' cannot run as a job (allowed: $JOB_COMMANDS)"
    local a; for a in "$@"; do
        (( ${#a} <= 256 )) || die "$EX_USAGE" "job start: argument too long"
        [[ "$a" != *$'\n'* ]] || die "$EX_USAGE" "job start: newline in an argument"
    done
    local args=("$@")
    # backup/prune queue behind a running backup instead of failing at once
    if [[ "$cmd" == backup || "$cmd" == prune ]] && [[ " ${args[*]:-} " != *" --queue "* ]]; then args=(--queue "${args[@]}"); fi

    # Admission, under the id lock so two starts cannot both pass:
    #  - one at a time for the repo-wide runs (keyed on command + dry run, so a
    #    read-only plan never blocks the real thing);
    #  - no second active job for the same command and guest;
    #  - at most JOB_MAX_ACTIVE active jobs in all and JOB_MAX_PER_USER per user.
    local dry; dry="$( [[ "${DRY_RUN:-0}" == 1 ]] && echo true || echo false )"
    local first="" a2; for a2 in "${args[@]+"${args[@]}"}"; do [[ "$a2" =~ ^[0-9]+$ ]] && { first="$a2"; break; }; done
    mkdir -p "$(_runs_dir)" && chmod 0750 "$(_runs_dir)" 2>/dev/null || true
    exec {JOB_ADMIT_FD}>"$(_runs_dir)/.admit.lock" && flock -x "$JOB_ADMIT_FD"   # until meta.json exists
    _job_admit "$cmd" "$dry" "$first" "$(_audit_who)" || die "$EX_TEMPFAIL" "job start: $JOB_ADMIT_WHY"
    local id d runner; id="$(_job_next_id)" || die "$EX_SOFTWARE" "job start: could not allocate a job id"
    d="$(_job_dir "$id")"; mkdir -p "$d" && chmod 0750 "$d"
    runner="$(_job_runner)"
    jq -cn --argjson id "$id" --arg cmd "$cmd" --arg by "$(_audit_who)" --arg via "${PBO_AUDIT_VIA:-cli}" \
        --arg created "$(date --iso-8601=seconds)" --argjson ce "$(date +%s)" --arg runner "$runner" \
        --argjson dry "$( [[ "${DRY_RUN:-0}" == 1 ]] && echo true || echo false )" \
        '{id:$id, command:$cmd, args:$ARGS.positional, started_by:$by, via:$via, created:$created,
          created_epoch:$ce, runner:$runner, unit:(if $runner == "systemd" then "pbo-job-\($id)" else null end), dry_run:$dry}' \
        --args -- "${args[@]+"${args[@]}"}" > "$d/meta.json.tmp" && mv -f "$d/meta.json.tmp" "$d/meta.json"
    exec {JOB_ADMIT_FD}>&-
    : > "$d/log"; : > "$d/out.jsonl"
    audit_log "job start id=$id cmd=$cmd args=${args[*]:-} runner=$runner"
    _job_prune_old

    local self="${SELF_DIR}/pbo"
    if [[ "$runner" == systemd ]]; then
        systemd-run --unit "pbo-job-$id" --collect --quiet \
            --description "pbo job $id: $cmd" \
            ${PBO_CONFIG_EXPLICIT:+--setenv=PBO_CONFIG="$PBO_CONFIG_EXPLICIT"} --setenv=PBO_AUDIT_USER="$(_audit_who)" \
            --setenv=PBO_AUDIT_VIA="${PBO_AUDIT_VIA:-cli}" --setenv=PBO_JOB_ID="$id" \
            ${PBO_NO_NOTIFY:+--setenv=PBO_NO_NOTIFY="$PBO_NO_NOTIFY"} \
            -- "$self" _job-run "$id" >/dev/null 2>"$d/start.err" \
            || die "$EX_SOFTWARE" "job start: systemd-run failed: $(head -c 300 "$d/start.err")"
    else
        # PBO_CONFIG only when it was set explicitly: otherwise the job loads the
        # cluster config (/etc/pve/pbo/config) + local config exactly like the CLI
        if [[ -n "${PBO_CONFIG_EXPLICIT:-}" ]]; then export PBO_CONFIG="$PBO_CONFIG_EXPLICIT"; else unset PBO_CONFIG; fi
        ( _close_lock_fds; PBO_AUDIT_USER="$(_audit_who)" PBO_JOB_ID="$id" \
            exec setsid "$self" _job-run "$id" </dev/null >/dev/null 2>&1 ) &
        disown 2>/dev/null || true
    fi
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_emit "$(jq -c '{status:"started", ok:true, job:.}' "$d/meta.json")"
    else
        log_info "job $id started: pbo $cmd ${args[*]:-} (follow: pbo job log $id --follow)"
    fi
}

# _job-run <id>: the runner (internal). Runs the command, records the result.
rdo_job_run() {
    local id="${1:-}"; _job_id_ok "$id" || exit "$EX_USAGE"
    local d; d="$(_job_dir "$id")"; [[ -r "$d/meta.json" ]] || exit "$EX_USAGE"
    PBO_AUDIT_DONE=1          # the command it runs writes the audit line
    printf '%s\n' "$$" > "$d/pid"
    local cmd dry; cmd="$(jq -r .command "$d/meta.json")"; dry="$(jq -r .dry_run "$d/meta.json")"
    [[ " $JOB_COMMANDS " == *" $cmd "* ]] || exit "$EX_USAGE"
    local -a args; mapfile -t args < <(jq -r '.args[]' "$d/meta.json")
    local -a flags=(--json); [[ "$dry" == true ]] && flags+=(--dry-run)
    local rc=0
    "${SELF_DIR}/pbo" "${flags[@]}" "$cmd" "${args[@]+"${args[@]}"}" >"$d/out.jsonl" 2>>"$d/log" &
    local child=$!; printf '%s\n' "$child" > "$d/child.pid"
    wait "$child" || rc=$?
    [[ -e "$d/result.json" ]] && exit 0        # cancelled meanwhile: keep that record
    local last; last="$(grep -E '^\{' "$d/out.jsonl" 2>/dev/null | tail -1)"
    jq -e 'type=="object"' >/dev/null 2>&1 <<<"$last" || last='null'
    jq -cn --argjson rc "$rc" --arg ended "$(date --iso-8601=seconds)" --argjson ee "$(date +%s)" --argjson r "$last" \
        '{exit:$rc, ended:$ended, ended_epoch:$ee, cancelled:false, result:$r}' > "$d/result.json.tmp" \
        && mv -f "$d/result.json.tmp" "$d/result.json"
    exit 0
}

# _job_admit <cmd> <dry> <vmid|""> <user>: 0 = may start; else JOB_ADMIT_WHY.
_job_admit() {
    local cmd="$1" dry="$2" vm="$3" who="$4" id m total=0 mine=0
    while read -r id; do
        [[ -n "$id" && ! -e "$(_job_dir "$id")/result.json" ]] || continue
        [[ "$(_job_json "$id" 2>/dev/null | jq -r .state)" =~ ^(running|queued|starting)$ ]] || continue
        m="$(cat "$(_job_dir "$id")/meta.json" 2>/dev/null)" || continue
        total=$((total+1))
        [[ "$(jq -r .started_by <<<"$m")" == "$who" ]] && mine=$((mine+1))
        if [[ "$(jq -r .command <<<"$m")" == "$cmd" ]]; then
            if [[ " $JOB_SINGLE " == *" $cmd "* && "$(jq -r .dry_run <<<"$m")" == "$dry" ]]; then
                JOB_ADMIT_WHY="a $cmd job is already active (job $id)"; return 1; fi
            if [[ -n "$vm" ]] && jq -e --arg v "$vm" '.args | index($v) != null' >/dev/null <<<"$m"; then
                JOB_ADMIT_WHY="a $cmd job for $vm is already active (job $id)"; return 1; fi
        fi
    done < <(find "$(_runs_dir)" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' -printf '%f
' 2>/dev/null | sort -n)
    (( total < ${JOB_MAX_ACTIVE:-20} )) || { JOB_ADMIT_WHY="$total jobs are already active (JOB_MAX_ACTIVE)"; return 1; }
    (( mine < ${JOB_MAX_PER_USER:-5} )) || { JOB_ADMIT_WHY="$who already has $mine active jobs (JOB_MAX_PER_USER)"; return 1; }
    return 0
}

# rdo_job_active_of <command> [dry_run true|false] → id of an active job running it (rc 1 if none)
rdo_job_active_of() {
    local id
    while read -r id; do
        [[ -n "$id" && ! -e "$(_job_dir "$id")/result.json" ]] || continue
        if [[ "$(jq -r .command "$(_job_dir "$id")/meta.json" 2>/dev/null)" == "$1" ]] \
           && { [[ -z "${2:-}" ]] || [[ "$(jq -r .dry_run "$(_job_dir "$id")/meta.json" 2>/dev/null)" == "$2" ]]; } \
           && [[ "$(_job_json "$id" | jq -r .state)" =~ ^(running|queued|starting)$ ]]; then
            printf '%s' "$id"; return 0
        fi
    done < <(find "$(_runs_dir)" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' -printf '%f\n' 2>/dev/null | sort -n)
    return 1
}

# job list [--limit N]
rdo_job_list() {
    local limit=50
    while [[ $# -gt 0 ]]; do
        case "$1" in --limit) [[ "${2:-}" =~ ^[0-9]{1,4}$ ]] || die "$EX_USAGE" "--limit N"; limit="$2"; shift 2 ;;
                     *) die "$EX_USAGE" "unknown job list flag: $1" ;; esac
    done
    local ids lines='' id
    ids="$(find "$(_runs_dir)" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' -printf '%f\n' 2>/dev/null | sort -rn | head -n "$limit")" || ids=""
    while read -r id; do [[ -n "$id" ]] && lines+="$(_job_json "$id" || true)"$'\n'; done <<<"$ids"
    local out; out="$(printf '%s' "$lines" | jq -cs '{status:"ok", ok:true, jobs:map(select(. != null))}')"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_emit "$out"; return "$EX_OK"; fi
    { printf 'ID\tSTATE\tCOMMAND\tBY\tCREATED\tDURATION\tEXIT\n'
      jq -r '.jobs[] | [ (.id|tostring), .state, ("pbo " + .command + " " + (.args | join(" "))), .started_by,
              (.created[0:19] | sub("T";" ")), "\(.duration_s)s", (if .exit == null then "-" else (.exit|tostring) end) ] | @tsv' <<<"$out"
    } | { column -t -s $'\t' 2>/dev/null || cat; }
}

rdo_job_show() {
    local id="${1:-}"; _job_id_ok "$id" || die "$EX_USAGE" "job show <id>"
    local j; j="$(_job_json "$id")" || die "$EX_DATAERR" "no job $id"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_emit "$(jq -c '{status:"ok", ok:true, job:.}' <<<"$j")"; return "$EX_OK"; fi
    jq -r '"job \(.id): pbo \(.command) \(.args | join(" "))\n  state:   \(.state)\(if .exit != null then " (exit \(.exit))" else "" end)\n  by:      \(.started_by) via \(.via)\n  created: \(.created)\n  ended:   \(.ended // "-")\n  took:    \(.duration_s)s\(if .unit then "\n  unit:    \(.unit)" else "" end)"' <<<"$j"
}

# job log <id> [--from N] [--follow]: lines from N (0-based). JSON: {lines, from, next, done}
rdo_job_log() {
    local id="${1:-}"; shift || true; _job_id_ok "$id" || die "$EX_USAGE" "job log <id> [--from N] [--follow]"
    local from=0 follow=0
    while [[ $# -gt 0 ]]; do
        case "$1" in --from) [[ "${2:-}" =~ ^[0-9]{1,9}$ ]] || die "$EX_USAGE" "--from N"; from="$2"; shift 2 ;;
                     --follow) follow=1; shift ;;
                     *) die "$EX_USAGE" "unknown job log flag: $1" ;; esac
    done
    local d; d="$(_job_dir "$id")"; [[ -r "$d/meta.json" ]] || die "$EX_DATAERR" "no job $id"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        from=$((10#$from))
        local total fin=false; total="$(wc -l < "$d/log")"
        [[ -e "$d/result.json" ]] && fin=true
        json_emit "$(tail -n +"$((from+1))" "$d/log" | head -n 5000 | jq -Rcs --argjson from "$from" --argjson fin "$fin" --argjson total "$total" \
            'split("\n") | map(select(length > 0)) as $l | {status:"ok", ok:true, from:$from, next:([$from + ($l|length), $total] | min), done:$fin, lines:$l}')"
        return "$EX_OK"
    fi
    tail -n +"$((10#$from+1))" "$d/log"
    if (( follow )); then
        local n; n="$(wc -l < "$d/log")"
        while [[ ! -e "$d/result.json" ]]; do
            sleep 1
            local m; m="$(wc -l < "$d/log")"
            (( m > n )) && { tail -n +"$((n+1))" "$d/log" | head -n "$((m-n))"; n=$m; }
            [[ "$(_job_json "$id" | jq -r .state)" == lost ]] && break
        done
        tail -n +"$((n+1))" "$d/log"
        rdo_job_show "$id"
    fi
}

rdo_job_cancel() {
    local id="${1:-}"; _job_id_ok "$id" || die "$EX_USAGE" "job cancel <id>"
    local d; d="$(_job_dir "$id")"; [[ -r "$d/meta.json" ]] || die "$EX_DATAERR" "no job $id"
    local st; st="$(_job_json "$id" | jq -r .state)"
    [[ "$st" == running || "$st" == queued || "$st" == starting ]] || die "$EX_USAGE" "job $id is $st, nothing to cancel"
    # record first, so the runner keeps the cancelled result when its child dies
    jq -cn --arg ended "$(date --iso-8601=seconds)" --argjson ee "$(date +%s)" --arg by "$(_audit_who)" \
        '{exit:null, ended:$ended, ended_epoch:$ee, cancelled:true, cancelled_by:$by, result:null}' > "$d/result.json.tmp" \
        && mv -f "$d/result.json.tmp" "$d/result.json"
    audit_log "job cancel id=$id"
    if [[ "$(jq -r .runner "$d/meta.json")" == systemd ]]; then
        systemctl stop "pbo-job-$id" >/dev/null 2>&1 || true
    else
        local pid; pid="$(cat "$d/pid" 2>/dev/null || true)"
        _pid_is "$pid" "_job-run $id" && kill -TERM -- "-$pid" 2>/dev/null || true   # its session/process group
    fi
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_emit "$(jq -c '{status:"cancelled", ok:true, job:.}' <<<"$(_job_json "$id")")"
    else log_info "job $id cancelled"; fi
}

# keep the newest JOB_KEEP finished jobs (default 200); running ones always stay
_job_prune_old() {
    local keep="${JOB_KEEP:-200}" id n=0; [[ "$keep" =~ ^[0-9]+$ ]] || keep=200
    while read -r id; do
        [[ -n "$id" ]] || continue
        [[ -e "$(_job_dir "$id")/result.json" ]] || continue
        n=$((n+1)); (( n > keep )) && rm -rf -- "$(_job_dir "$id")"
    done < <(find "$(_runs_dir)" -mindepth 1 -maxdepth 1 -type d -regex '.*/[0-9]+' -printf '%f\n' 2>/dev/null | sort -rn)
    return 0
}

rdo_job() {
    local sub="${1:-}"; shift || true
    [[ "$sub" == list || "$sub" == show || "$sub" == log ]] && AUDIT_RO_OVERRIDE=1
    case "$sub" in
        start)  rdo_job_start "$@" ;;
        list)   rdo_job_list "$@" ;;
        show)   rdo_job_show "$@" ;;
        log)    rdo_job_log "$@" ;;
        cancel) rdo_job_cancel "$@" ;;
        *) die "$EX_USAGE" "job start <command> [args] | list | show <id> | log <id> [--from N] [--follow] | cancel <id>" ;;
    esac
}
