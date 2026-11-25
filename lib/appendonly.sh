# shellcheck shell=bash
# lib/appendonly.sh: append-only offsite + the janitor role (ADR 0004).
#
# A PVE host that can delete its own offsite backups loses them together with the
# host. With OFFSITE_APPEND_ONLY=true the offsite repo sits behind a restic
# rest-server started with --append-only: the host can add snapshots but never
# forget, prune or remove keys there. Retention runs on a second machine, the
# janitor (PBO_ROLE=janitor), which has the repo on local disk and is the only
# thing that can delete.
#
# restic exits 0 when a forget is refused with 403 (the snapshot just stays), so a
# host can't find out after the fact that its prune did nothing. The host has to
# know up front, hence the explicit setting, and `doctor` probes the server to
# prove the setting matches reality.

# Commands that make sense on a janitor: no guests, no vzdump, just the repo.
readonly JANITOR_COMMANDS="init doctor list usage verify prune unlock rotate-key status notify-test metrics help guests timers config version"

# _role_check <command>: refuse guest operations on a janitor, and a config that
# claims both roles. Called from main() after load_config.
_role_check() {
    local cmd="$1"
    case "${PBO_ROLE:-host}" in
        host) : ;;
        janitor)
            # Never run the janitor as root. Its state and log dirs belong to the
            # server user, so root writing there could be steered by a symlink;
            # and a root prune leaves repo files rest-server can't read. Re-exec
            # as JANITOR_USER before anything is written.
            # PBO_JANITOR_ALLOW_ROOT=1 exists for the test suite only.
            if [[ "$(id -u)" == 0 && "${PBO_JANITOR_ALLOW_ROOT:-0}" != 1 ]]; then
                local ju="${JANITOR_USER:-restic}"
                id "$ju" >/dev/null 2>&1 || die "$EX_CONFIG" "JANITOR_USER '$ju' does not exist"
                [[ "$(id -u "$ju")" != 0 ]] || die "$EX_CONFIG" "JANITOR_USER must not be root"
                exec "${PBO_RUNUSER_BIN:-runuser}" -u "$ju" -- "${SELF_DIR}/pbo" "${PBO_ORIG_ARGS[@]+"${PBO_ORIG_ARGS[@]}"}"
            fi
            if [[ "${PBO_INTEGRATION:-standalone}" != standalone ]]; then
                die "$EX_CONFIG" "PBO_ROLE=janitor with PBO_INTEGRATION=${PBO_INTEGRATION}: a janitor has no Proxmox, only standalone is allowed"
            fi
            if [[ "${OFFSITE_APPEND_ONLY:-false}" == "true" ]]; then
                die "$EX_CONFIG" "PBO_ROLE=janitor with OFFSITE_APPEND_ONLY=true: the janitor is the one that prunes, it needs write access to the repo"
            fi
            if [[ " $JANITOR_COMMANDS " != *" $cmd "* ]]; then
                die "$EX_USAGE" "'$cmd' is not available on a janitor (PBO_ROLE=janitor); allowed: $JANITOR_COMMANDS"
            fi ;;
        *) die "$EX_CONFIG" "PBO_ROLE must be 'host' or 'janitor', got '${PBO_ROLE}'" ;;
    esac
}

_is_janitor() { [[ "${PBO_ROLE:-host}" == "janitor" ]]; }

# Offsite is append-only from THIS machine's point of view: the host must leave
# retention to the janitor.
_offsite_append_only() {
    [[ "${OFFSITE_APPEND_ONLY:-false}" == "true" ]] && ! _is_janitor
}

# _rest_password: the rest-server HTTP password, read from its file. Empty if
# no file is configured (the URL may carry credentials, or there is no auth).
_rest_password() {
    [[ -n "${RESTIC_REST_PASSWORD_FILE:-}" ]] || return 0
    [[ -r "$RESTIC_REST_PASSWORD_FILE" ]] || die "$EX_CONFIG" "RESTIC_REST_PASSWORD_FILE $RESTIC_REST_PASSWORD_FILE unreadable"
    tr -d '\n' < "$RESTIC_REST_PASSWORD_FILE"
}

# _rest_base_url <repo>: https://host:port/path for a rest: repo, credentials in
# the URL stripped (curl gets them via -u). Empty for anything that isn't rest:.
_rest_base_url() {
    local repo="$1"
    [[ "$repo" == rest:* ]] || return 0
    local url="${repo#rest:}"
    # drop user[:pass]@ if someone put it in the URL
    url="$(printf '%s' "$url" | sed -E 's#^(https?://)[^/@]+@#\1#')"
    printf '%s' "${url%/}"
}

# _rest_probe_append_only <repo> → prints the HTTP code of a DELETE against a key
# id that cannot exist. Harmless either way: there is nothing to delete.
#   403 = server refuses deletes (append-only enforced)
#   200/404 = server would delete (NOT append-only)
#   401 = wrong credentials, 000 = unreachable/TLS failure
_rest_probe_append_only() {
    local base; base="$(_rest_base_url "$1")"
    [[ -n "$base" ]] || { printf 'n/a'; return 0; }
    local zero; zero="$(printf '0%.0s' {1..64})"
    local args=(-s -o /dev/null -w '%{http_code}' -m 15 -X DELETE)
    [[ -n "${RESTIC_CACERT:-}" ]] && args+=(--cacert "$RESTIC_CACERT")
    if [[ -n "${RESTIC_REST_USERNAME:-}" ]]; then
        local pw; pw="$(_rest_password)"
        # credentials on stdin via a config line, never on the command line
        args+=(-K -)
        printf 'user = "%s:%s"\n' "$RESTIC_REST_USERNAME" "$pw" | curl "${args[@]}" "$base/keys/$zero" 2>/dev/null
        return 0
    fi
    curl "${args[@]}" "$base/keys/$zero" 2>/dev/null
}

# _doctor_append_only: lines for `doctor` on a host. Sets AO_PROBLEMS/AO_WARNS
# and fills AO_LINES. A host that SAYS append-only but whose server accepts
# deletes is a hard failure: it believes it is protected and isn't.
_doctor_append_only() {
    local ok="$1" bad="$2" warn="$3"
    AO_LINES=(); AO_PROBLEMS=0; AO_WARNS=0; AO_VERIFIED=0
    [[ "${OFFSITE_ENABLED:-true}" == "true" && -n "${RESTIC_OFFSITE_REPO:-}" ]] || return 0
    local repo="$RESTIC_OFFSITE_REPO" code
    if ! _offsite_append_only; then
        # Not claimed. If it's a rest-server that happens to enforce it, say so.
        [[ "$repo" == rest:* ]] || return 0
        code="$(_rest_probe_append_only "$repo")"
        if [[ "$code" == 403 ]]; then
            AO_LINES+=("$warn  offsite server is append-only but OFFSITE_APPEND_ONLY=false: host prune will silently do nothing there, set it to true")
            AO_WARNS=1
        fi
        return 0
    fi
    if [[ "$repo" != rest:* ]]; then
        AO_LINES+=("$warn  OFFSITE_APPEND_ONLY=true on a non-rest repo ($repo): pbo can't verify it, make sure the target really refuses deletes")
        AO_WARNS=1; return 0
    fi
    code="$(_rest_probe_append_only "$repo")"
    case "$code" in
        403) AO_LINES+=("$ok  offsite append-only enforced (server refused a test delete)"); AO_VERIFIED=1 ;;
        200|204|404) AO_LINES+=("$bad  offsite server ACCEPTS deletes (HTTP $code): it is not running --append-only"); AO_PROBLEMS=1 ;;
        401) AO_LINES+=("$bad  offsite append-only probe: authentication failed (HTTP 401), check RESTIC_REST_USERNAME/RESTIC_REST_PASSWORD_FILE"); AO_PROBLEMS=1 ;;
        *)   AO_LINES+=("$bad  offsite append-only probe failed (HTTP ${code:-none}): unreachable or TLS error, check RESTIC_CACERT"); AO_PROBLEMS=1 ;;
    esac
}

# _doctor_janitor_ownership <repo-dir>: on a janitor the repo is served by
# rest-server as its own user. A prune run as root leaves root-owned packs and
# index files the server can't read, and the next backup fails. Catch it here.
_doctor_janitor_ownership() {
    local dir="$1" owner stray
    [[ -d "$dir" && -f "$dir/config" ]] || return 0
    owner="$(stat -c '%U' "$dir/config")"
    stray="$(find "$dir" ! -user "$owner" -print -quit 2>/dev/null)"
    if [[ -n "$stray" ]]; then
        printf 'files in %s not owned by %s (e.g. %s): run the janitor as %s' "$dir" "$owner" "$stray" "$owner"
        return 1
    fi
    return 0
}
