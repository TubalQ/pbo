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
    snaps="$(_restic "$repo" snapshots --json 2>/dev/null || echo '[]')"; [[ -n "$snaps" ]] || snaps='[]'
    local rc=0
    while IFS= read -r line; do
        keep="${line%%$'\t'*}"; ids="${line#*$'\t'}"
        local args=(); mapfile -t args < <(_keep_args "$keep")
        if [[ -n "$ids" ]]; then for id in $ids; do args+=(--tag "vmid=$id"); done; fi
        "$cb" "$repo" "${args[@]}" || rc=1
    done < <(_policy_groups "$snaps")
    return "$rc"
}
