# shellcheck shell=bash
# lib/policy.sh: per-guest policy from Proxmox tags (issue #9).
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
_guest_tags() {
    local line
    line="$( { pct config "$1" 2>/dev/null || qm config "$1" 2>/dev/null; } | sed -n 's/^tags:[[:space:]]*//p' | head -1)"
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
    printf '%s\n' "${a[@]}"
}

# _policy_groups <snapshots-json> → one line per forget run:
#   <override>\t<vmid> <vmid> ...
# Override "" = the config default. A guest's policy is the keep= tag on its
# newest snapshot. With no overrides at all there is exactly one line with an
# empty vmid list, meaning "everything" (the pre-#9 single forget call).
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
        local back; back="$(_backdated_snapshots "$snaps" "$repo")"
        if [[ -n "$back" ]]; then
            log_error "retention: refusing to prune $repo, snapshots that arrived after the last janitor run but claim an earlier time: $back"
            return 1
        fi
        [[ "${DRY_RUN:-0}" == 1 ]] || _janitor_seen_update "$snaps" "$repo"
    fi
    local rc=0
    while IFS= read -r line; do
        keep="${line%%$'\t'*}"; ids="${line#*$'\t'}"
        local args=(); mapfile -t args < <(_keep_args "$keep")
        if [[ -n "$ids" ]]; then for id in $ids; do args+=(--tag "vmid=$id"); done; fi
        "$cb" "$repo" "${args[@]}" || rc=1
    done < <(_policy_groups "$snaps")
    return "$rc"
}

# _future_snapshots <snapshots-json> → short ids of snapshots dated more than
# FUTURE_SKEW (default 1h) ahead of this machine's clock, space-separated.
_future_snapshots() {
    local lim=$(( $(date +%s) + ${FUTURE_SKEW:-3600} ))
    printf '%s' "$1" | jq -r --argjson lim "$lim" '
        def epoch: capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2}))$")
            | ((.d + "Z") | fromdateiso8601)
              - (if .z == "Z" then 0 else ((if .s == "+" then 1 else -1 end) * ((.h|tonumber)*3600 + (.m|tonumber)*60)) end);
        [ .[] | select((.time | epoch) > $lim) | .short_id ] | join(" ")' 2>/dev/null
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
_backdated_snapshots() {           # <snapshots-json> <repo>
    local f; f="$(_janitor_seen_file "$2")"
    [[ -r "$f" ]] || return 0
    local last; last="$(jq -r '.last_run // 0' "$f" 2>/dev/null)"; [[ "$last" =~ ^[0-9]+$ ]] || last=0
    local lim=$(( last - ${FUTURE_SKEW:-3600} ))
    printf '%s' "$1" | jq -r --slurpfile st "$f" --argjson lim "$lim" '
        def epoch: capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|(?<s>[+-])(?<h>[0-9]{2}):(?<m>[0-9]{2}))$")
            | ((.d + "Z") | fromdateiso8601)
              - (if .z == "Z" then 0 else ((if .s == "+" then 1 else -1 end) * ((.h|tonumber)*3600 + (.m|tonumber)*60)) end);
        (($st[0].ids // []) | map({key:., value:true}) | from_entries) as $seen
        | [ .[] | select(($seen[.id] // false) | not) | select((.time | epoch) < $lim) | .short_id ] | join(" ")' 2>/dev/null
}
_janitor_seen_update() {           # <snapshots-json> <repo>
    local f; f="$(_janitor_seen_file "$2")"
    printf '%s' "$1" | jq -c --argjson now "$(date +%s)" '{last_run:$now, ids:[.[].id]}' > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
}
