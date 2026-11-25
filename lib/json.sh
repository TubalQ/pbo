# shellcheck shell=bash
# lib/json.sh: the machine-readable contract.
#
# With --json every command writes exactly one JSON object per line to stdout;
# logs go to stderr. Every object carries:
#   schema   the contract version (PBO_JSON_SCHEMA); a breaking change bumps it
#   command  the pbo command
#   status   a short word ("ok", "failed", "problems", "error", ...)
#   ok       true/false
#   dry_run  true/false
# A command that fails before it printed its own object prints an error object
# ({status:"error", ok:false, exit:<code>, error:"..."}) with the same exit code.
# Read commands (doctor, status, guests, timers, config, list, usage, version,
# restore-report) use real types: numbers, booleans, arrays, null. Action results
# built with json_result keep string values unless the key is marked (:n, :b).
# tests/json.sh pins the contract.

readonly PBO_JSON_SCHEMA=1
# jq def that drops credentials from URL-like strings: userinfo, query strings,
# and the user in sftp:user@host (what _mask_url does in lib/common.sh).
readonly PBO_JQ_MASK='def mask: gsub("(?<a>://)[^/@\\s]+@"; "\(.a)***@") | gsub("(?<a>://[^\\s?\"]*)\\?[^\\s\"]*"; "\(.a)?***")
                       | gsub("(?<a>(^|[\\s=]))sftp:[^@/:\\s]+@"; "\(.a)sftp:***@");'
JSON_EMITTED=0
# The result goes to the stdout pbo started with (PBO_JSON_FD), not to whatever
# stdout is current: a die inside $(...) would otherwise print its error object
# into the captured variable and the caller would see nothing. Whether an object
# was printed is kept in a file (PBO_JSON_MARK), because subshells can print too.
json_open() {
    [[ "${JSON_OUTPUT:-0}" == 1 ]] || return 0
    exec {PBO_JSON_FD}>&1
    PBO_JSON_MARK="$(mktemp "${TMPDIR:-/tmp}/pbo-json.XXXXXX" 2>/dev/null)" || PBO_JSON_MARK=""
}
json_close() { [[ -n "${PBO_JSON_MARK:-}" ]] && rm -f "$PBO_JSON_MARK"; return 0; }
_json_emitted() { [[ "${JSON_EMITTED:-0}" == 1 ]] || [[ -n "${PBO_JSON_MARK:-}" && -s "$PBO_JSON_MARK" ]]; }

# json_emit [object]: print <object> (or stdin) with the envelope fields added
# in front. Fields the object sets itself win.
json_emit() {
    local obj
    if [[ $# -gt 0 ]]; then obj="$1"; else obj="$(cat)"; fi
    [[ -n "$obj" ]] || obj='{"status":"error","ok":false,"error":"internal: empty result"}'
    local dry=false; [[ "${DRY_RUN:-0}" == 1 ]] && dry=true
    if ! jq -c --argjson schema "$PBO_JSON_SCHEMA" --arg cmd "${PBO_COMMAND:-}" --argjson dry "$dry" \
            "$PBO_JQ_MASK"'
             if type == "object" then {schema:$schema, command:$cmd, dry_run:$dry} + . | walk(if type == "string" then mask else . end)
             else error("not an object") end' \
            <<<"$obj" 1>&"${PBO_JSON_FD:-1}" 2>/dev/null; then
        jq -cn --argjson schema "$PBO_JSON_SCHEMA" --arg cmd "${PBO_COMMAND:-}" \
            '{schema:$schema, command:$cmd, status:"error", ok:false, error:"internal: invalid JSON result"}' >&"${PBO_JSON_FD:-1}"
    fi
    JSON_EMITTED=1
    [[ -n "${PBO_JSON_MARK:-}" ]] && printf 1 > "$PBO_JSON_MARK" 2>/dev/null
    return 0
}

# json_result <status> <ok:true|false> [key value ...]
# A flat result object. Values are strings; a key ending in ":n" is a number,
# ":b" a boolean (the suffix is dropped), e.g. json_result ok true backups_ok:n 3
json_result() {
    local status="$1" ok="$2"; shift 2
    [[ "$ok" == true ]] || ok=false
    local args=(--arg status "$status" --argjson ok "$ok") filter='{status:$status, ok:$ok}' i=0 k v
    while [[ $# -ge 2 ]]; do
        k="$1"; v="$2"; shift 2
        case "$k" in
            *:n) k="${k%:n}"; [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || v=null; args+=(--arg "k$i" "$k" --argjson "v$i" "$v") ;;
            *:b) k="${k%:b}"; [[ "$v" == true ]] || v=false; args+=(--arg "k$i" "$k" --argjson "v$i" "$v") ;;
            *)   args+=(--arg "k$i" "$k" --arg "v$i" "$v") ;;
        esac
        filter+=" + {(\$k$i): \$v$i}"; i=$((i+1))
    done
    json_emit "$(jq -cn "${args[@]}" "$filter")"
}

# json_error <exit-code> <message>: the error object, unless this run already
# printed its own result.
json_error() {
    [[ "${JSON_OUTPUT:-0}" == 1 ]] && ! _json_emitted || return 0
    json_emit "$(jq -cn --arg e "$2" --argjson x "${1:-1}" '{status:"error", ok:false, exit:$x, error:$e}')"
}
