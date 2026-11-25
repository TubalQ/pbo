# shellcheck shell=bash
# lib/policy.sh: per-guest policy from Proxmox tags.
#
# Set on the guest in Proxmox (GUI or `pct set <id> --tags ...`), so it follows
# the guest across nodes without editing pbo's config:
#   pbo-skip              not backed up by run-schedule (a manual backup still works)
#   pbo-stop              vzdump --mode stop for this guest
#   pbo-keep-daily-N      offsite retention for this guest, overriding KEEP_OFFSITE_*
#   pbo-keep-weekly-N     (any subset; the rest come from the config)
#   pbo-keep-monthly-N
#   pbo-keep-yearly-N
#
# Retention overrides are written into each snapshot as a restic tag
# (keep=d30.w8.m12.y2, dots because restic splits tags on commas). Prune reads
# them back from the repo, so the policy holds on a janitor that can't see
# Proxmox, and still holds after the guest is gone. The newest snapshot of a
# guest decides, so changing the tag takes effect from the next backup.

# _guest_tags <vmid> → the guest's Proxmox tags, one per line (lower case).
# Guest metadata cache: one `pvesh get /cluster/resources` per process instead of
# a pct/qm config call (a perl start, ~0.7 s) per question per guest. Falls back
# to the config when pvesh has no answer (no cluster view, tests). Cleared by
# anything that changes tags (policy set).
# _GM_POOL is the guest's resource pool (PVE backup jobs can select by pool,
# lib/ownership.sh). _GM_OK=1 when the resource view was a readable array.
declare -A _GM_TAGS=() _GM_NAME=() _GM_TYPE=() _GM_POOL=()
_GM_LOADED=0 _GM_OK=0
_guest_meta_load() {
    (( _GM_LOADED )) && return 0
    _GM_LOADED=1
    local json line id
    json="$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null)" || return 0
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$json" && _GM_OK=1
    # \x1f, not a tab: read collapses runs of IFS whitespace, so an empty field
    # (a guest without tags) would shift the pool into the tags
    while IFS=$'\x1f' read -r id t n tg pl; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        _GM_TYPE[$id]="$t"; _GM_NAME[$id]="$n"; _GM_TAGS[$id]="$tg"; _GM_POOL[$id]="$pl"
    done < <(jq -r --arg node "$(_local_node)" '.[]? | select(.node == $node) | [(.vmid|tostring), (.type // ""), (.name // ""), (.tags // ""), (.pool // "")] | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' <<<"$json" 2>/dev/null)
    return 0
}
_guest_meta_reset() { _GM_TAGS=(); _GM_NAME=(); _GM_TYPE=(); _GM_POOL=(); _GM_LOADED=0; _GM_OK=0; }

_guest_tags() {
    local line
    _guest_meta_load
    if [[ -n "${_GM_TYPE[$1]+x}" ]]; then line="${_GM_TAGS[$1]}"
    else line="$( { pct config "$1" 2>/dev/null || qm config "$1" 2>/dev/null; } | sed -n 's/^tags:[[:space:]]*//p' | head -1)"; fi
    [[ -n "$line" ]] || return 0
    printf '%s\n' "$line" | tr ';, ' '\n\n\n' | tr '[:upper:]' '[:lower:]' | sed '/^$/d'
}

_guest_has_tag() { _guest_tags "$1" | grep -qx "$2"; }
_guest_skipped() { _guest_has_tag "$1" pbo-skip; }
_guest_force_stop() { _guest_has_tag "$1" pbo-stop; }

# _guest_keep_tag <vmid> → "d30.m12" style override string, empty if none.
_guest_keep_tag() {
    local t out=() n
    while read -r t; do
        case "$t" in
            pbo-keep-daily-*)   n="${t#pbo-keep-daily-}";   [[ "$n" =~ ^[0-9]+$ ]] && out+=("d$n") ;;
            pbo-keep-weekly-*)  n="${t#pbo-keep-weekly-}";  [[ "$n" =~ ^[0-9]+$ ]] && out+=("w$n") ;;
            pbo-keep-monthly-*) n="${t#pbo-keep-monthly-}"; [[ "$n" =~ ^[0-9]+$ ]] && out+=("m$n") ;;
            pbo-keep-yearly-*)  n="${t#pbo-keep-yearly-}";  [[ "$n" =~ ^[0-9]+$ ]] && out+=("y$n") ;;
        esac
    done < <(_guest_tags "$1")
    local IFS=.; printf '%s' "${out[*]:-}"
}

# _keep_args <override> → restic forget flags: config defaults, overridden by
# the d/w/m/y parts of the override string. Zero means "not kept by that bucket".
_keep_args() {
    local d="${KEEP_OFFSITE_DAILY:-7}" w="${KEEP_OFFSITE_WEEKLY:-4}" m="${KEEP_OFFSITE_MONTHLY:-6}" y="${KEEP_OFFSITE_YEARLY:-0}" p
    # The override comes from a tag in the repo, i.e. from whoever can write the
    # repo. On a janitor that is a host it doesn't trust, so nothing from it may
    # reach bash arithmetic unvalidated: exactly <letter><1-6 digits>, base 10.
    local IFS=.
    for p in $1; do
        if [[ "$p" =~ ^([dwmy])([0-9]{1,6})$ ]]; then
            local n=$((10#${BASH_REMATCH[2]}))
            case "${BASH_REMATCH[1]}" in d) d=$n ;; w) w=$n ;; m) m=$n ;; y) y=$n ;; esac
        fi
    done
    unset IFS
    # config values too (they are root's, but a typo shouldn't become arithmetic)
    local v; for v in d w m y; do [[ "${!v}" =~ ^[0-9]{1,6}$ ]] || printf -v "$v" 0; done
    # On a janitor the tag comes from a host it must not trust: a host could
    # otherwise write keep=d0 and have the janitor delete its history. There a
    # tag may only RAISE retention above the janitor's own KEEP_OFFSITE_*.
    if _is_janitor; then
        local base; base=("${KEEP_OFFSITE_DAILY:-7}" "${KEEP_OFFSITE_WEEKLY:-4}" "${KEEP_OFFSITE_MONTHLY:-6}" "${KEEP_OFFSITE_YEARLY:-0}")
        local i=0; for v in d w m y; do
            [[ "${base[$i]}" =~ ^[0-9]{1,6}$ ]] && (( ${!v} < base[i] )) && printf -v "$v" '%s' "${base[$i]}"
            i=$((i+1))
        done
    fi
    local a=()
    (( d > 0 )) && a+=(--keep-daily "$d")
    (( w > 0 )) && a+=(--keep-weekly "$w")
    (( m > 0 )) && a+=(--keep-monthly "$m")
    (( y > 0 )) && a+=(--keep-yearly "$y")
    # never let a policy of all zeros mean "delete everything"
    (( ${#a[@]} )) || a=(--keep-last 1)
    # A per-guest override comes from Proxmox tags, which anyone with
    # VM.Config.Options on the guest can edit. It may lower retention, but never
    # below the newest KEEP_OVERRIDE_MIN_LAST snapshots (restic keeps the union).
    if [[ -n "${1:-}" ]]; then
        local floor="${KEEP_OVERRIDE_MIN_LAST:-3}"; [[ "$floor" =~ ^[0-9]{1,4}$ ]] || floor=3
        (( 10#$floor > 0 )) && a+=(--keep-last "$((10#$floor))")
    fi
    printf '%s\n' "${a[@]}"
}

# _policy_groups <snapshots-json> → one line per forget run:
#   <override>\t<vmid> <vmid> ...
# Override "" = the config default. A guest's policy is the keep= tag on its
# newest snapshot. With no overrides at all there is exactly one line with an
# empty vmid list, meaning "everything" (the single forget call from before per-guest policy).
_policy_groups() {
    printf '%s' "$1" | jq -r '
        # Only well-formed values leave jq: they are word-split into restic args
        # and parsed in bash. A malformed keep= counts as no override.
        [ .[]
          | { vmid: ((.tags // []) | map(select(startswith("vmid="))) | .[0] // "" | sub("vmid=";"")),
              keep: ((.tags // []) | map(select(startswith("keep="))) | .[0] // "" | sub("keep=";"")),
              time: .time }
          | select(.vmid | test("^([0-9]{1,9}|host-[A-Za-z0-9.-]{1,63})$"))
          | .keep |= (if test("^[dwmy][0-9]{1,6}(\\.[dwmy][0-9]{1,6}){0,3}$") then . else "" end) ]
        | group_by(.vmid) | map(max_by(.time))
        | if all(.keep == "") then "\t"
          else (group_by(.keep) | map("\(.[0].keep)\t\(map(.vmid) | join(" "))") | .[])
          end' 2>/dev/null
}

# _forget_policy_runs <repo> <cb> : call <cb> <repo> <forget-args...> once per
# policy group, with --tag vmid=... filters when the repo has overrides.
_forget_policy_runs() {
    local repo="$1" cb="$2" snaps line keep ids id
    # Fail closed: without a readable snapshot list we don't know the policies,
    # and a default-policy forget over everything would be the wrong guess.
    if ! snaps="$(_restic "$repo" snapshots --json 2>/dev/null)" || ! jq -e 'type=="array"' >/dev/null 2>&1 <<<"$snaps"; then
        log_warn "retention: cannot list snapshots in $repo, nothing forgotten"
        return 1
    fi
    # Snapshot times are whatever the writer claimed. On a janitor, a snapshot
    # from the future could take over the GFS buckets and push real ones out,
    # so refuse to prune at all while one exists (doctor reports it).
    if _is_janitor; then
        local fut; fut="$(_future_snapshots "$snaps")"
        if [[ -n "$fut" ]]; then
            log_error "retention: refusing to prune $repo, snapshots dated in the future: $fut (a writer is lying about time)"
            return 1
        fi
        local back brc=0; back="$(_backdated_snapshots "$snaps" "$repo")" || brc=$?
        if (( brc != 0 )); then
            log_error "retention: refusing to prune $repo, the janitor baseline $(_janitor_seen_file "$repo") is unreadable or malformed"
            return 1
        fi
        if [[ -n "$back" ]]; then
            log_error "retention: refusing to prune $repo, snapshots that arrived after the last janitor run but claim an earlier time: $back"
            return 1
        fi
        # Bind the forgets to exactly this checked set (see _janitor_bound_forget).
        _CHECKED_IDS_FILE="$(mktemp)"
        jq -r '.[].id' <<<"$snaps" > "$_CHECKED_IDS_FILE"
    fi
    local checked_at; checked_at="$(date +%s)"
    local rc=0
    while IFS= read -r line; do
        keep="${line%%$'\t'*}"; ids="${line#*$'\t'}"
        local args=(); mapfile -t args < <(_keep_args "$keep")
        if [[ -n "$ids" ]]; then for id in $ids; do args+=(--tag "vmid=$id"); done; fi
        "$cb" "$repo" "${args[@]}" || rc=1
    done < <(_policy_groups "$snaps")
    if _is_janitor; then
        # Baseline only after every forget succeeded, stamped with the time of
        # the CHECK, so a snapshot that arrived mid-run is judged next time.
        # a read (list --reasons, dry runs) never moves the janitor's baseline
        (( rc == 0 )) && [[ "${DRY_RUN:-0}" != 1 && "${_FORGET_READONLY:-0}" != 1 ]] && { _janitor_seen_update "$snaps" "$repo" "$checked_at" || rc=1; }
        rm -f "$_CHECKED_IDS_FILE"; _CHECKED_IDS_FILE=""
    fi
    return "$rc"
}

# _janitor_bound_forget <repo> <policy args...> → removed short_ids (JSON array).
# restic's forget lists the repo again by itself, so a snapshot that lands
# between our checks and that listing would be judged unchecked. On a janitor,
# ask for the plan first (--dry-run), insist every snapshot in it was in the
# checked set, then forget exactly the planned ids and nothing else.
_CHECKED_IDS_FILE=""
_janitor_bound_forget() {
    local repo="$1"; shift
    local plan
    plan="$(_restic "$repo" forget --group-by paths "$@" --dry-run --json 2>/dev/null)" || { log_warn "retention: forget plan failed for $repo"; return 1; }
    jq -e 'type=="array"' >/dev/null 2>&1 <<<"$plan" || { log_warn "retention: forget plan for $repo is not JSON"; return 1; }
    local extra
    extra="$(jq -r '[.[] | ((.keep // []) + (.remove // []))[] | .id] | .[]' <<<"$plan" | grep -vxF -f "$_CHECKED_IDS_FILE" | head -5 | tr '\n' ' ')"
    if [[ -n "${extra// /}" ]]; then
        log_error "retention: snapshots appeared in $repo after the checks ($extra), nothing forgotten this run"
        return 1
    fi
    local rm_ids=(); mapfile -t rm_ids < <(jq -r '[.[] | (.remove // [])[] | .id] | .[]' <<<"$plan")
    if (( ${#rm_ids[@]} )) && [[ "${DRY_RUN:-0}" != 1 ]]; then
        _restic_w "$repo" forget "${rm_ids[@]}" >/dev/null 2>&1 || { log_warn "retention: forget of the planned ids failed in $repo"; return 1; }
    fi
    jq -c '[.[] | (.remove // [])[] | .short_id]' <<<"$plan"
}

# _future_snapshots <snapshots-json> → short ids of snapshots dated more than
# FUTURE_SKEW (default 1h) ahead of this machine's clock, space-separated.
_future_snapshots() {
    local lim=$(( $(date +%s) + ${FUTURE_SKEW:-3600} ))
    printf '%s' "$1" | jq -r --argjson lim "$lim" '
        def epoch: capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2}))$")
            | ((.d + "Z") | fromdateiso8601)
              - (if .z == "Z" then 0 else ((if .s == "+" then 1 else -1 end) * ((.h|tonumber)*3600 + (.m|tonumber)*60)) end);
        [ .[] | select(((.time | epoch?) // 99999999999) > $lim) | .short_id ] | join(" ")' 2>/dev/null
}

# Backdated inserts (janitor). A host could slip a snapshot into a past day so
# that day's GFS bucket keeps the fake and the real one is forgotten. The
# janitor remembers which snapshot ids it has seen and when it last ran
# (STATE_DIR/janitor-seen-<repo hash>.json, its own disk, the host can't touch it). A NEW id
# claiming a time before that run arrived late and lies about it. Days before
# the last janitor run are thereby sealed; only the time since then is open.
# First run (no state): everything present is accepted as the baseline.
_janitor_seen_file() {             # <repo>: one baseline per repo (a janitor may serve several)
    printf '%s/janitor-seen-%s.json' "${STATE_DIR}" "$(printf '%s' "$1" | sha256sum | cut -c1-16)"
}
# Exit 0 with the suspicious ids (maybe none), 2 when the baseline exists but
# can't be trusted (unreadable, malformed): the caller must then not prune.
# The FUTURE_SKEW tolerance below the last run is deliberate: an honest backup
# that STARTED shortly before the janitor listed the repo but finished after
# carries a time just before last_run. With the janitor at midday the window
# can't reach into the previous day's bucket.
_backdated_snapshots() {           # <snapshots-json> <repo>
    local f; f="$(_janitor_seen_file "$2")"
    [[ -e "$f" ]] || return 0      # first run: no baseline yet
    jq -e '(.last_run|type)=="number" and (.ids|type)=="array"' "$f" >/dev/null 2>&1 || return 2
    local last; last="$(jq -r '.last_run' "$f")"; [[ "$last" =~ ^[0-9]+$ ]] || return 2
    local lim=$(( last - ${FUTURE_SKEW:-3600} ))
    printf '%s' "$1" | jq -r --slurpfile st "$f" --argjson lim "$lim" '
        def epoch: capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2}))$")
            | ((.d + "Z") | fromdateiso8601)
              - (if .z == "Z" then 0 else ((if .s == "+" then 1 else -1 end) * ((.h|tonumber)*3600 + (.m|tonumber)*60)) end);
        (($st[0].ids // []) | map({key:., value:true}) | from_entries) as $seen
        | [ .[] | select(($seen[.id] // false) | not) | select(((.time | epoch?) // -1) < $lim) | .short_id ] | join(" ")' 2>/dev/null || return 2
}
_janitor_seen_update() {           # <snapshots-json> <repo> [checked-at epoch]
    local f; f="$(_janitor_seen_file "$2")"
    if printf '%s' "$1" | jq -c --argjson now "${3:-$(date +%s)}" '{last_run:$now, ids:[.[].id]}' > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"; then
        return 0
    fi
    rm -f "$f.tmp"; log_error "retention: could not write the janitor baseline $f"; return 1
}

# --- policy get/set -----------------------------------------------------------
# The policy lives in the guest's Proxmox tags. These two commands are the only
# code pbo uses to write them (scripts too). Tags can also be edited in the Proxmox
# GUI by hand. Tags that are not pbo-* are left exactly as they were.

# _policy_json <vmid> → {vmid, type, skip, stop, keep, keep_effective, pbo_tags}
_policy_json() {
    local id="$1" t; t="$(_guest_type "$id")" || die "$EX_DATAERR" "policy: no guest $id on this node"
    local keep; keep="$(_guest_keep_tag "$id")"
    jq -cn --arg id "$id" --arg t "$t" --arg keep "$keep" \
        --argjson skip "$(_guest_skipped "$id" && echo true || echo false)" \
        --argjson stop "$(_guest_force_stop "$id" && echo true || echo false)" \
        --arg tags "$(_guest_tags "$id" | grep '^pbo-' || true)" \
        --arg eff "$(_keep_args "$keep" | tr '\n' ' ')" \
        '{vmid:$id, type:$t, skip:$skip, stop:$stop, keep:(if $keep == "" then null else $keep end),
          keep_effective:($eff | gsub("\\s+$";"")), pbo_tags:($tags | split("\n") | map(select(length > 0)))}'
}

rdo_policy_get() {
    local id="${1:-}"; is_vmid "$id" || die "$EX_USAGE" "policy get <vmid>"
    local j; j="$(_policy_json "$id")"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_emit "$(jq -c '{status:"ok", ok:true} + .' <<<"$j")"; return "$EX_OK"; fi
    jq -r '"vmid \(.vmid) (\(.type))\n  skip: \(if .skip then "yes, left out of scheduled backups" else "no" end)\n  stop: \(if .stop then "yes, backed up in stop mode" else "no" end)\n  keep: \(.keep // "default") → \(.keep_effective)"' <<<"$j"
}

# _keep_spec_valid <spec>: d/w/m/y each at most once, 1-6 digits.
_keep_spec_valid() {
    [[ "$1" =~ ^[dwmy][0-9]{1,6}(\.[dwmy][0-9]{1,6}){0,3}$ ]] || return 1
    local letters; letters="$(tr -cd 'dwmy' <<<"$1")"
    [[ "$(fold -w1 <<<"$letters" | sort | uniq -d)" == "" ]]
}

# policy set <vmid> [--skip on|off] [--stop on|off] [--keep <d30.w8.m12.y2>|default]
rdo_policy_set() {
    local id="${1:-}"; shift || true
    is_vmid "$id" || die "$EX_USAGE" "policy set <vmid> [--skip on|off] [--stop on|off] [--keep d30.w8.m12.y2|default]"
    local skip="" stop="" keep="" keep_given=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip) [[ "${2:-}" =~ ^(on|off)$ ]] || die "$EX_USAGE" "--skip on|off"; skip="$2"; shift 2 ;;
            --stop) [[ "${2:-}" =~ ^(on|off)$ ]] || die "$EX_USAGE" "--stop on|off"; stop="$2"; shift 2 ;;
            --keep) keep="${2:-}"; keep_given=1
                    [[ "$keep" == default ]] || _keep_spec_valid "$keep" \
                        || die "$EX_USAGE" "--keep: d/w/m/y with a count, each at most once, dot-separated (e.g. d30.m12), or 'default'"
                    shift 2 ;;
            *) die "$EX_USAGE" "unknown policy set flag: $1" ;;
        esac
    done
    [[ -n "$skip$stop" || $keep_given == 1 ]] || die "$EX_USAGE" "policy set: nothing to change (--skip, --stop or --keep)"
    local t; t="$(_guest_type "$id")" || die "$EX_DATAERR" "policy: no guest $id on this node"
    local before; before="$(_policy_json "$id")"

    # current tags, raw order; drop the pbo ones we are about to decide on
    local cur new=() tg; cur="$( { pct config "$id" 2>/dev/null || qm config "$id" 2>/dev/null; } | sed -n 's/^tags:[[:space:]]*//p' | head -1)"
    local -a tags; IFS=';, ' read -r -a tags <<<"$cur"
    for tg in "${tags[@]+"${tags[@]}"}"; do
        [[ -n "$tg" ]] || continue
        case "${tg,,}" in
            pbo-skip) [[ -n "$skip" ]] && continue ;;
            pbo-stop) [[ -n "$stop" ]] && continue ;;
            pbo-keep-daily-*|pbo-keep-weekly-*|pbo-keep-monthly-*|pbo-keep-yearly-*) (( keep_given )) && continue ;;
        esac
        new+=("$tg")
    done
    [[ "$skip" == on ]] && new+=(pbo-skip)
    [[ "$stop" == on ]] && new+=(pbo-stop)
    if (( keep_given )) && [[ "$keep" != default ]]; then
        local p IFS=.
        for p in $keep; do
            case "${p:0:1}" in d) new+=("pbo-keep-daily-$((10#${p:1}))") ;; w) new+=("pbo-keep-weekly-$((10#${p:1}))") ;;
                               m) new+=("pbo-keep-monthly-$((10#${p:1}))") ;; y) new+=("pbo-keep-yearly-$((10#${p:1}))") ;; esac
        done
        unset IFS
    fi
    local line; line="$(IFS=';'; printf '%s' "${new[*]+"${new[*]}"}")"
    _guest_meta_reset
    audit_log "policy set vmid=$id skip=${skip:-same} stop=${stop:-same} keep=$( ((keep_given)) && echo "$keep" || echo same) tags='$line'"
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        log_info "[dry-run] policy set $id: tags would be '${line}'"
    else
        local tool=pct; [[ "$t" == qemu ]] && tool=qm
        if [[ -n "$line" ]]; then "$tool" set "$id" --tags "$line" >/dev/null 2>&1 || die "$EX_SOFTWARE" "policy set: $tool set $id --tags failed"
        else "$tool" set "$id" --delete tags >/dev/null 2>&1 || die "$EX_SOFTWARE" "policy set: $tool set $id --delete tags failed"; fi
    fi
    local after; after="$( [[ "${DRY_RUN:-0}" == 1 ]] && printf '%s' "$before" || _policy_json "$id")"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_emit "$(jq -cn --argjson b "$before" --argjson a "$after" --arg tags "$line" '{status:"ok", ok:true, before:$b, after:$a, tags:$tags}')"
    else
        log_info "policy set $id: done ($(jq -r '"skip \(.skip), stop \(.stop), keep \(.keep // "default")"' <<<"$after"))"
    fi
}
