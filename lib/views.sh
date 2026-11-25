# shellcheck shell=bash
# lib/views.sh: read-only views for scripts and monitoring:
# guests, timers, version (config: lib/config.sh). Human output by default, the contract with --json.

# --- guests -----------------------------------------------------------------
# One entry per guest: identity, policy, newest snapshot, last restore test.
# Host: every guest on this node (pbo-skip ones included, flagged). Janitor: every
# vmid seen in the repo. The repo is read once.

# _guest_meta <vmid> → {vmid,name,type,exists,policy:{skip,stop,keep}}
_guest_meta() {
    local id="$1" t name="" c
    _guest_meta_load
    if [[ -n "${_GM_TYPE[$id]+x}" ]]; then
        t="${_GM_TYPE[$id]}"; name="${_GM_NAME[$id]}"
        [[ "$t" == qemu || "$t" == lxc ]] || t=lxc
        jq -cn --arg id "$id" --arg t "$t" --arg n "$name" \
            --argjson skip "$(_guest_skipped "$id" && echo true || echo false)" \
            --argjson stop "$(_guest_force_stop "$id" && echo true || echo false)" \
            --arg keep "$(_guest_keep_tag "$id")" \
            '{vmid:$id, name:(if $n == "" then null else $n end), type:$t, exists:true,
              policy:{skip:$skip, stop:$stop, keep:(if $keep == "" then null else $keep end)}}'
    elif t="$(_guest_type "$id")"; then
        c="$(_g_config "$t" "$id" 2>/dev/null)" || c=""
        name="$(sed -nE 's/^(hostname|name):[[:space:]]*//p' <<<"$c" | head -1)"
        jq -cn --arg id "$id" --arg t "$t" --arg n "$name" \
            --argjson skip "$(_guest_skipped "$id" && echo true || echo false)" \
            --argjson stop "$(_guest_force_stop "$id" && echo true || echo false)" \
            --arg keep "$(_guest_keep_tag "$id")" \
            '{vmid:$id, name:(if $n == "" then null else $n end), type:$t, exists:true,
              policy:{skip:$skip, stop:$stop, keep:(if $keep == "" then null else $keep end)}}'
    else
        jq -cn --arg id "$id" '{vmid:$id, name:null, type:null, exists:false, policy:{skip:false, stop:false, keep:null}}'
    fi
}

rdo_guests() {
    local repo snaps repo_ok=true ids
    repo="$(_restic_read_repo)"
    snaps="$(_restic "$repo" --no-lock snapshots --json 2>/dev/null)" || snaps=""
    jq -e 'type=="array"' >/dev/null 2>&1 <<<"$snaps" || { snaps='[]'; repo_ok=false; }
    if _is_janitor; then
        ids="$(printf '%s' "$snaps" | jq -r '[.[].tags[]? | select(test("^vmid=[0-9]{1,9}$")) | sub("^vmid=";"")] | unique | .[]')"
    else
        _guest_meta_load    # here, not in the $(...) below: a subshell's cache dies with it
        _pve_jobs_load      # the same for guest ownership (lib/ownership.sh)
        # plus guests a PVE job owns that BACKUP_ORDER leaves out (none in standalone)
        if _integration_standalone; then ids="$(_backup_set_all || true)"
        else ids="$( { _backup_set_all; _pve_owned_guests; } | awk 'NF && !seen[$0]++' || true)"; fi
    fi
    local meta='' id
    _guest_meta_load
    local owner
    while read -r id; do
        [[ "$id" =~ ^[0-9]{1,9}$ ]] || continue
        if _is_janitor; then meta+="$(jq -cn --arg id "$id" '{vmid:$id, name:null, type:null, exists:null, policy:null, owner:null, owner_job:null}')"$'\n'
        else
            owner="$(_guest_owner "$id")"
            meta+="$(_guest_meta "$id" | jq -c --arg o "$owner" '. + {owner: ($o | sub(":.*$"; "")),
                owner_job: (if ($o | startswith("pve:")) then ($o | sub("^pve:"; "")) else null end)}')"$'\n'
        fi
    done <<<"$ids"
    local tr='{}'; tr="$(_tr_last_by_vmid 2>/dev/null)" || tr='{}'
    jq -e 'type=="object"' >/dev/null 2>&1 <<<"$tr" || tr='{}'
    local out
    local trf; trf="$(mktemp)"; printf '%s' "$tr" > "$trf"
    out="$(printf '%s' "$snaps" | jq -c --arg meta "$meta" --slurpfile trs "$trf" --argjson now "$(date +%s)" \
        --argjson max "${DOCTOR_MAX_AGE:-172800}" --argjson repo_ok "$repo_ok" \
        --arg node "$(_local_node)" --arg role "${PBO_ROLE:-host}" --arg tier "$( [[ "$repo" == "${RESTIC_CACHE_REPO:-}" ]] && echo cache || echo offsite )" '
        def ts: (capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2}))$")
                 | ((.d + "Z") | fromdateiso8601)
                   - (if .z == "Z" then 0 else ((if .s == "+" then 1 else -1 end) * ((.h|tonumber)*3600 + (.m|tonumber)*60)) end))? // null;
        . as $s | ($trs[0] // {}) as $tr
        | ($meta | split("\n") | map(select(length > 0) | fromjson)) as $guests
        | { status: (if $repo_ok then "ok" else "repo_unreachable" end), ok: $repo_ok,
            node: $node, role: $role, repo_tier: $tier, max_age_s: $max,
            guests: [ $guests[] | . as $g
              | [ $s[] | select((.tags // []) | index("vmid=\($g.vmid)")) ] as $mine
              | ($mine | max_by(.time | ts) // null) as $n
              | ($tr[$g.vmid] // null) as $t
              | $g + {
                  in_backup_set: (if $g.policy == null then null else (($g.policy.skip | not) or $g.owner == "pve") end),
                  snapshots: ($mine | length),
                  newest: (if $n == null then null else
                    { id: $n.id, short_id: $n.short_id, time: $n.time,
                      age_s: (($n.time | ts) as $e | if $e then $now - $e else null end),
                      added_bytes: ($n.summary.data_added // null),
                      processed_bytes: ($n.summary.total_bytes_processed // null),
                      duration_s: ((($n.summary.backup_end // "") | ts) as $b | (($n.summary.backup_start // "") | ts) as $a
                                   | if $a and $b then $b - $a else null end) } end),
                  stale: ($repo_ok and ($g.policy == null or ($g.policy.skip | not) or $g.owner == "pve")
                          and ($n == null or ((($n.time | ts) // 0) < $now - $max))),
                  last_restore_test: (if $t == null then null else
                    { time: $t.time, ok: $t.ok, failed_stage: $t.failed_stage, duration_s: $t.duration_s,
                      trigger: $t.trigger } end) } ] }')" || { rm -f "$trf"; die "$EX_SOFTWARE" "guests: could not build the view"; }
    rm -f "$trf"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_emit "$out"; return "$EX_OK"; fi
    { printf 'VMID\tNAME\tTYPE\tPOLICY\tSNAPS\tNEWEST\tRESTORE TEST\n'
      jq -r '.guests[] | [ .vmid, (.name // "-"), (.type // "-"),
            (if .policy == null then "-" else ([ (if .policy.skip then "skip" else empty end), (if .policy.stop then "stop" else empty end),
              (.policy.keep // empty) ] | if length == 0 then "-" else join(",") end) end),
            (.snapshots | tostring),
            (if .newest == null then "none" else "\(.newest.time[0:16] | sub("T";" "))\(if .stale then " STALE" else "" end)" end),
            (if .last_restore_test == null then "never" elif .last_restore_test.ok then "OK \(.last_restore_test.time[0:10])"
             else "FAILED at \(.last_restore_test.failed_stage) \(.last_restore_test.time[0:10])" end) ] | @tsv' <<<"$out"
    } | { column -t -s $'\t' 2>/dev/null || cat; }
    [[ "$(jq -r .ok <<<"$out")" == true ]] || log_warn "guests: repo $repo not reachable, snapshot columns are empty"
}

# --- timers -----------------------------------------------------------------
# `pbo timers [apply]` and the schedules as config keys: lib/timers.sh.

# --- config -----------------------------------------------------------------
# `pbo config`: lib/config.sh.

# --- version ----------------------------------------------------------------
rdo_version() {
    # as restic prints it (a -dev suffix kept); doctor compares _restic_version
    local rv; rv="$(_restic_bin version 2>/dev/null | awk '{print $2; exit}')" || rv=""
    local out; out="$(jq -cn --arg v "${VERSION:-}" --argjson s "$PBO_JSON_SCHEMA" --argjson cs "${PBO_CONFIG_SCHEMA:-1}" \
        --arg role "${PBO_ROLE:-host}" --arg node "$(_local_node)" --arg rv "$rv" \
        '{status:"ok", ok:true, version:$v, json_schema:$s, config_schema:$cs, role:$role, node:$node,
          restic:(if $rv == "" then null else $rv end)}')"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_emit "$out"; else jq -r '"pbo \(.version) (\(.role) on \(.node), restic \(.restic // "?"), json schema \(.json_schema))"' <<<"$out"; fi
}
