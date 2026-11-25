# shellcheck shell=bash
# lib/timers.sh: pbo's systemd timers, their schedules as config keys (ADR
# 0009, "Portability", MP part 2), and `pbo timers [apply]`.
#
# Each timer's OnCalendar= (and its RandomizedDelaySec=, where the unit has
# one) is a schema key (SCHEDULE_*, lib/config_schema.sh) whose default is the
# value in systemd/<timer>; tests/schedule_config.sh checks that the two agree.
# The unit files are never edited (a reinstall or a package upgrade replaces
# them): a timer whose keys differ from their defaults gets a drop-in,
# <PBO_SYSTEMD_DIR>/<timer>.d/schedule.conf, whose `OnCalendar=` line first
# clears the unit's calendar (OnCalendar= adds to a list) and then sets the
# configured one. A timer whose keys are all at their defaults has no drop-in:
# an old one is removed, and its directory when that leaves it empty (another
# drop-in an admin put there stays; schedule.conf sorts after override.conf,
# so the config wins over `systemctl edit`). Who writes them:
#   - the apply-schedule on_change hook (`pbo config set|unset`, lib/config.sh),
#     for the timers whose keys changed;
#   - `pbo timers apply` (install.sh, the .deb's postinst) and `pbo doctor
#     --fix`, for every timer of the role: a reinstall, or a config edited by
#     hand or in the cluster-shared file, ends with drop-ins that match it.
# After a change systemd reloads its units (daemon-reload). A schedule change
# resets the timer's persistent state: every pbo timer has Persistent=true, and
# systemd computes a calendar timer's next run from its last trigger (the
# stamp file), not from the restart, so a plain restart with a time earlier in
# the day (or week) than the last run would start the job at once. An enabled
# timer whose drop-in changes is therefore stopped before the drop-in is
# written (a stopped timer is not re-armed by the reload), its stamp is cleared
# after the reload (`systemctl clean --what=state`), and it is started again
# when it was running: its next run is the first one of the new calendar from
# now on, and a run missed under the old schedule is not caught up. A disabled
# timer stays disabled, an enabled one that was not running stays stopped (pbo
# never enables or starts a timer of its own accord). Every systemctl call
# goes through _sched_systemctl. A value pbo refuses (the calendar and
# timespan types, _cs_validate) is never written: that timer's drop-in stays as
# it is and the run fails with 78.

# unit|calendar key|delay key (empty: the unit has no RandomizedDelaySec)|role
SCHED_TIMERS='pbo.timer|SCHEDULE_BACKUP||host
pbo-prune.timer|SCHEDULE_PRUNE|SCHEDULE_PRUNE_DELAY|host
pbo-verify.timer|SCHEDULE_VERIFY|SCHEDULE_VERIFY_DELAY|host
pbo-test-restore.timer|SCHEDULE_TEST_RESTORE|SCHEDULE_TEST_RESTORE_DELAY|host
pbo-catalog.timer|SCHEDULE_CATALOG|SCHEDULE_CATALOG_DELAY|host
pbo-janitor.timer|SCHEDULE_JANITOR|SCHEDULE_JANITOR_DELAY|janitor'
SCHED_DROPIN=schedule.conf
# the values a config change is about to give (the apply-schedule hook: the
# shell still holds the ones load_config read)
declare -gA _SCHED_OVR=()

# _sched_systemctl <args...>: the one way this file calls systemctl.
_sched_systemctl() { systemctl "$@"; }

# _sched_rows [ROLE] → the table rows of ROLE (default PBO_ROLE), one per line.
_sched_rows() {
    local role="${1:-${PBO_ROLE:-host}}" r
    while IFS= read -r r; do [[ "${r##*|}" == "$role" ]] && printf '%s\n' "$r"; done <<<"$SCHED_TIMERS"
    return 0
}

# _sched_units_of KEY... → the timers (of any role) whose schedule the KEYs are.
_sched_units_of() {
    local r u c d k
    while IFS='|' read -r u c d _; do
        for k in "$@"; do [[ "$k" == "$c" || ( -n "$d" && "$k" == "$d" ) ]] && { printf '%s\n' "$u"; break; }; done
    done <<<"$SCHED_TIMERS"
    return 0
}

# _sched_val_r KEY → _CS_R: KEY's effective value (_SCHED_OVR first).
_sched_val_r() {
    if [[ -n "${_SCHED_OVR[$1]+x}" ]]; then
        _CS_R="${_SCHED_OVR[$1]}"; [[ -n "$_CS_R" ]] || _cs_default_r "$1"
    else
        _cs_value_r "$1"
    fi
}

# _sched_dropin UNIT → the drop-in's path.
_sched_dropin() {
    local d="${PBO_SYSTEMD_DIR:-}"
    [[ -n "$d" ]] || { _cs_default_r PBO_SYSTEMD_DIR; d="$_CS_R"; }
    while [[ "$d" == */ && "$d" != / ]]; do d="${d%/}"; done
    printf '%s/%s.d/%s' "$d" "$1" "$SCHED_DROPIN"
}

# _sched_want_r CALKEY DELAYKEY → _SCHED_WANT: the drop-in the timer needs
# (empty: none, its keys are at their defaults); _SCHED_BAD: why a value is
# refused (then nothing may be written).
_sched_want_r() {
    local ck="$1" dk="$2" cal cdef dly='' ddef='' body='' why
    _SCHED_WANT='' _SCHED_BAD=''
    _sched_val_r "$ck"; cal="$_CS_R"; _cs_default_r "$ck"; cdef="$_CS_R"
    if [[ -n "$dk" ]]; then _sched_val_r "$dk"; dly="$_CS_R"; _cs_default_r "$dk"; ddef="$_CS_R"; fi
    if [[ "$cal" != "$cdef" ]] && ! why="$(_cs_validate "$ck" "$cal")"; then _SCHED_BAD="$why"; fi
    if [[ -n "$dk" && "$dly" != "$ddef" ]] && ! why="$(_cs_validate "$dk" "$dly")"; then _SCHED_BAD+="${_SCHED_BAD:+; }$why"; fi
    [[ -z "$_SCHED_BAD" ]] || return 0
    # OnCalendar= is a list: the empty assignment drops the unit's own entry
    [[ "$cal" == "$cdef" ]] || body+=$'OnCalendar=\nOnCalendar='"$cal"$'\n'
    [[ -z "$dk" || "$dly" == "$ddef" ]] || body+="RandomizedDelaySec=$dly"$'\n'
    [[ -n "$body" ]] || return 0
    _SCHED_WANT="# Written by pbo from its config (${ck}${dk:+, $dk}). pbo rewrites or removes
# this file ('pbo config set', 'pbo timers apply', 'pbo doctor --fix'): change
# the keys, not this file.
[Timer]
$body"
}

# _sched_file_is FILE CONTENT: FILE holds exactly CONTENT.
_sched_file_is() {
    [[ -f "$1" && ! -L "$1" ]] || return 1
    local cur
    { IFS= read -r -d '' cur < "$1"; } 2>/dev/null || true
    [[ "$cur" == "$2" ]]
}

# _sched_write FILE CONTENT: replace FILE atomically (a temp file next to it,
# 0644 as systemd's own files, renamed over it); its directory is created
# 0755. A symlink in either place is refused: root writes here, and a link
# would let the write land somewhere else. → _SCHED_ERR on failure.
_sched_write() {
    local f="$1" dir tmp
    dir="${f%/*}"; _SCHED_ERR=''
    if [[ -L "$dir" || -L "$f" ]]; then _SCHED_ERR="$( [[ -L "$dir" ]] && echo "$dir" || echo "$f") is a symlink: not written"; return 1; fi
    [[ -d "${dir%/*}" ]] || { _SCHED_ERR="${dir%/*} does not exist (are the units installed?)"; return 1; }
    ( umask 022; mkdir -p -- "$dir" ) 2>/dev/null || { _SCHED_ERR="cannot create $dir"; return 1; }
    tmp="$(mktemp "$dir/.${f##*/}.pbo.XXXXXX" 2>/dev/null)" || { _SCHED_ERR="cannot write in $dir"; return 1; }
    if printf '%s' "$2" > "$tmp" && chmod 0644 -- "$tmp" && mv -f -- "$tmp" "$f"; then return 0; fi
    rm -f -- "$tmp"; _SCHED_ERR="cannot replace $f"; return 1
}

# _sched_remove FILE: the drop-in goes, and its directory when it is empty then.
_sched_remove() {
    local f="$1"; _SCHED_ERR=''
    [[ ! -L "${f%/*}" ]] || { _SCHED_ERR="${f%/*} is a symlink: not changed"; return 1; }
    rm -f -- "$f" 2>/dev/null || { _SCHED_ERR="cannot remove $f"; return 1; }
    rmdir -- "${f%/*}" 2>/dev/null || true
    return 0
}

# _sched_res UNIT STATUS PATH MESSAGE: one result (SCHED_RES).
_sched_res() { SCHED_RES+=("$1"$'\x1f'"$2"$'\x1f'"$3"$'\x1f'"$4"); }

# _sched_apply [--check] [UNIT...]: bring the drop-ins of the UNITs (default:
# every timer of the role) in line with the config. --check changes nothing
# (doctor); DRY_RUN=1 says what it would change. Results:
#   SCHED_RES    "unit<US>status<US>path<US>message" per timer, status one of
#                ok (as the config wants), written, removed, would-write,
#                would-remove, drift, stale (--check: a drop-in that differs
#                from the config, or one the config no longer wants), bad (a
#                value pbo refuses), failed
#   SCHED_RELOAD none (nothing changed), ok, would, skipped (no systemctl),
#                failed; SCHED_RELOAD_MSG the reason
#   SCHED_RESTARTED  the timers started again (enabled and running ones whose
#                drop-in changed: stopped, stamp cleared, started)
#   SCHED_NFAIL, SCHED_NBAD  counts
# Returns 0, 78 when a value is refused, 69 when a change failed.
_sched_apply() {
    local check=0 dry="${DRY_RUN:-0}" r u ck dk f want have cal changed=() rc=0 sd=0
    # held: enabled timers stopped (or found stopped) before their drop-in
    # changed, in order; up: those that were running and are started again
    local held=() noclean=() idle=()
    local -A up=()
    [[ "${1:-}" == --check ]] && { check=1; shift; }
    declare -ga SCHED_RES=() SCHED_RESTARTED=()
    SCHED_RELOAD=none SCHED_RELOAD_MSG='' SCHED_NFAIL=0 SCHED_NBAD=0
    command -v systemctl >/dev/null 2>&1 && sd=1
    _cs_load
    while IFS='|' read -r u ck dk _; do
        [[ -n "$u" ]] || continue
        if (( $# )) && [[ " $* " != *" $u "* ]]; then continue; fi
        f="$(_sched_dropin "$u")"
        _sched_want_r "$ck" "$dk"; want="$_SCHED_WANT"
        _sched_val_r "$ck"; cal="$_CS_R"
        have=0; [[ -e "$f" || -L "$f" ]] && have=1
        if [[ -n "$_SCHED_BAD" ]]; then
            SCHED_NBAD=$((SCHED_NBAD+1))
            _sched_res "$u" bad "$f" "$_SCHED_BAD: not applied, $u keeps its $( (( have )) && echo "drop-in" || echo "unit's schedule")"
            continue
        fi
        if [[ -n "$want" ]] && _sched_file_is "$f" "$want"; then _sched_res "$u" ok "$f" "$cal (drop-in)"; continue; fi
        if [[ -z "$want" ]] && (( ! have )); then _sched_res "$u" ok "$f" "$cal (default)"; continue; fi
        if (( check )); then
            if [[ -n "$want" ]]; then _sched_res "$u" drift "$f" "$( (( have )) && echo "its drop-in does not match" || echo "has no drop-in for") ${ck}=$cal"
            else _sched_res "$u" stale "$f" "its drop-in is left from another schedule; the config has the default ($cal)"; fi
            continue
        fi
        if [[ "$dry" == 1 ]]; then
            if [[ -n "$want" ]]; then _sched_res "$u" would-write "$f" "would write $f (${ck}=$cal)"
            else _sched_res "$u" would-remove "$f" "would remove $f (back to the default $cal)"; fi
            changed+=("$u"); continue
        fi
        # an enabled timer stops before its drop-in changes: the reload would
        # re-arm a running one from its old stamp (see the top of this file)
        if (( sd )) && _sched_systemctl is-enabled --quiet "$u" >/dev/null 2>&1; then
            if _sched_systemctl is-active --quiet "$u" >/dev/null 2>&1; then
                if ! _sched_systemctl stop "$u" >/dev/null 2>&1; then
                    _sched_res "$u" failed "$f" "could not stop $u before its schedule changes (systemctl stop $u): its drop-in is not changed"
                    SCHED_NFAIL=$((SCHED_NFAIL+1)); continue
                fi
                up[$u]=1
            fi
            held+=("$u")
        fi
        if [[ -n "$want" ]]; then
            if _sched_write "$f" "$want"; then _sched_res "$u" written "$f" "$f written (${ck}=$cal)"; changed+=("$u")
            else _sched_res "$u" failed "$f" "$_SCHED_ERR"; SCHED_NFAIL=$((SCHED_NFAIL+1)); fi
        else
            if _sched_remove "$f"; then _sched_res "$u" removed "$f" "$f removed (back to the default $cal)"; changed+=("$u")
            else _sched_res "$u" failed "$f" "$_SCHED_ERR"; SCHED_NFAIL=$((SCHED_NFAIL+1)); fi
        fi
    done < <(_sched_rows "${PBO_ROLE:-host}")
    if (( ${#changed[@]} )); then
        if [[ "$dry" == 1 ]]; then
            SCHED_RELOAD=would SCHED_RELOAD_MSG="would run systemctl daemon-reload, and stop, reset (clean --what=state) and start again the running enabled ones of: ${changed[*]}"
        elif (( ! sd )); then
            SCHED_RELOAD=skipped SCHED_RELOAD_MSG="no systemctl here: systemd reads the drop-ins when it starts"
        elif _sched_systemctl daemon-reload >/dev/null 2>&1; then
            SCHED_RELOAD=ok SCHED_RELOAD_MSG="systemctl daemon-reload"
            # the stamp goes (last trigger unknown): the next run counts from
            # the start below, not from the last run under the old schedule.
            # Needs systemd 247 or later and a stopped unit.
            for u in "${held[@]+"${held[@]}"}"; do
                [[ " ${changed[*]} " == *" $u "* ]] || continue
                _sched_systemctl clean --what=state "$u" >/dev/null 2>&1 || noclean+=("$u")
            done
        else
            SCHED_RELOAD=failed SCHED_RELOAD_MSG="systemctl daemon-reload failed: the timers keep their old schedule until systemd reloads"
            SCHED_NFAIL=$((SCHED_NFAIL+1))
        fi
    fi
    # what was stopped runs again, also when its write or the reload failed
    for u in "${held[@]+"${held[@]}"}"; do
        if [[ -z "${up[$u]+x}" ]]; then idle+=("$u"); continue; fi
        if _sched_systemctl start "$u" >/dev/null 2>&1; then SCHED_RESTARTED+=("$u")
        else SCHED_NFAIL=$((SCHED_NFAIL+1)); _sched_res "$u" failed "$(_sched_dropin "$u")" "could not start $u again (systemctl start $u)"; fi
    done
    if [[ "$SCHED_RELOAD" == ok ]]; then
        if (( ${#SCHED_RESTARTED[@]} )); then
            SCHED_RELOAD_MSG+=", restarted ${SCHED_RESTARTED[*]} (next run computed from now; a run missed under the old schedule is not caught up)"
        elif (( ${#idle[@]} )); then
            SCHED_RELOAD_MSG+=" (no timer restarted: ${idle[*]} enabled but not running, left stopped)"
        else
            SCHED_RELOAD_MSG+=" (no timer restarted: none of them is enabled)"
        fi
        (( ${#noclean[@]} == 0 )) || SCHED_RELOAD_MSG+="; could not clear the last-trigger stamp of ${noclean[*]} (systemctl clean --what=state needs systemd 247 or later): it starts at once if its new schedule had a run since its last one"
    fi
    (( SCHED_NBAD == 0 )) || rc="$EX_CONFIG"
    (( SCHED_NFAIL == 0 )) || rc="$EX_UNAVAILABLE"
    return "$rc"
}

# _sched_audit: audit-log each drop-in change of the last _sched_apply.
_sched_audit() {
    [[ "${DRY_RUN:-0}" == 1 ]] && return 0
    local r u st f m
    for r in "${SCHED_RES[@]+"${SCHED_RES[@]}"}"; do
        IFS=$'\x1f' read -r u st f m <<<"$r"
        case "$st" in written|removed) audit_log "timers: $u schedule drop-in $st ($f)" ;; esac
    done
    return 0
}

# --- the PVE job window (doctor) -------------------------------------------------
# _sched_minutes_r SPEC → _SM_R: the minutes of the local day at which a
# calendar expression elapses, space-separated; empty when that is not known
# (every minute, or a form only systemd can expand while systemd-analyze is
# missing). Plain HH:MM[:SS] (lists allowed) is read here; wildcards, ranges,
# repetitions and a time zone go to `systemd-analyze calendar --iterations`,
# which prints the next elapses in local time, like a PVE job's next run.
_sched_minutes_r() {
    local s="$1" t='' tz=0 i h m hl ml line
    local -a p=() seenm=()
    _SM_R=''
    case "$s" in
        minutely|'') return 0 ;;
        hourly) for (( i = 0; i < 24; i++ )); do _SM_R+="${_SM_R:+ }$(( i * 60 ))"; done; return 0 ;;
        daily|weekly|monthly|yearly|annually|quarterly|semiannually) _SM_R=0; return 0 ;;
    esac
    read -r -a p <<<"$s"
    for i in "${!p[@]}"; do
        if [[ "${p[i]}" == *:* ]]; then t="${p[i]}"
        elif [[ -n "$t" ]]; then tz=1; fi
    done
    if (( ! tz )) && [[ -z "$t" ]]; then _SM_R=0; return 0; fi   # a date alone: midnight
    if (( ! tz )) && [[ "$t" =~ ^([0-9]{1,2}(,[0-9]{1,2})*):([0-9]{1,2}(,[0-9]{1,2})*)(:[0-9]{1,2}(\.[0-9]+)?)?$ ]]; then
        hl="${BASH_REMATCH[1]}" ml="${BASH_REMATCH[3]}"
        for h in ${hl//,/ }; do
            for m in ${ml//,/ }; do
                (( 10#$h < 24 && 10#$m < 60 )) && _SM_R+="${_SM_R:+ }$(( 10#$h * 60 + 10#$m ))"
            done
        done
        return 0
    fi
    _cs_sd_analyze || return 0
    local tmo=(); command -v timeout >/dev/null 2>&1 && tmo=(timeout 10)
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*(Next\ elapse|Iter[a-z.]*\ \#[0-9]+):[[:space:]]+[A-Za-z]+\ [0-9-]+\ ([0-9]{2}):([0-9]{2}) ]] || continue
        m=$(( 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]} ))
        [[ -n "${seenm[m]:-}" ]] && continue
        seenm[m]=1; _SM_R+="${_SM_R:+ }$m"
    done < <(LC_ALL=C "${tmo[@]}" systemd-analyze calendar --iterations=96 -- "$s" 2>/dev/null)
    return 0
}

# _sched_hm MINUTE → HH:MM
_sched_hm() { printf '%02d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# --- pbo timers [apply] ----------------------------------------------------------
# _pbo_timer_units → the timers of this role; with the Proxmox integration on
# (PBO_INTEGRATION both|integrated) also pbo-catalog.timer.
_pbo_timer_units() {
    if _is_janitor; then printf '%s\n' pbo-janitor.timer; return 0; fi
    printf '%s\n' pbo.timer pbo-prune.timer pbo-verify.timer pbo-test-restore.timer
    _integration_standalone || printf '%s\n' pbo-catalog.timer
}

# _sd_prop <unit> <property> → the value (systemctl show), empty if none
_sd_prop() { systemctl show -p "$2" --value "$1" 2>/dev/null || true; }
# _sd_time <systemd timestamp> → ISO 8601, or empty for none ("n/a", "0", "")
_sd_time() { [[ -n "$1" && "$1" != n/a && "$1" != 0 ]] && date -d "$1" --iso-8601=seconds 2>/dev/null || true; }

# _sched_effective_r UNIT → _SE_R: the calendar systemd runs UNIT on, its
# OnCalendar= entries from TimersCalendar ("; " between several), in systemd's
# normalized form; empty when that is not known (no systemctl, the unit not
# loaded). It can differ from the config: another drop-in in <timer>.d (an
# override.conf from `systemctl edit`, the way to change a time before 0.6), or
# a daemon-reload that did not happen or failed.
_sched_effective_r() {
    local raw e
    _SE_R=''
    command -v systemctl >/dev/null 2>&1 || return 0
    [[ "$(_sd_prop "$1" LoadState)" == loaded ]] || return 0
    raw="$(_sd_prop "$1" TimersCalendar)"
    while [[ "$raw" == *OnCalendar=* ]]; do
        raw="${raw#*OnCalendar=}"; e="${raw%%;*}"
        e="${e%"${e##*[![:space:]]}"}"; e="${e%\}}"; e="${e%"${e##*[![:space:]]}"}"
        [[ -n "$e" ]] && _SE_R+="${_SE_R:+; }$e"
    done
    return 0
}

# _sched_norm_r SPEC → _SN_R: SPEC in systemd's normalized form (what
# TimersCalendar shows: 'Sun 06:30' is 'Sun *-*-* 06:30:00'); empty when
# systemd-analyze cannot be used to tell (then nothing is compared: a plain
# string compare would call '*:0/15' different from its own normal form).
_sched_norm_r() {
    local line t=()
    _SN_R=''
    _cs_sd_analyze || return 0
    command -v timeout >/dev/null 2>&1 && t=(timeout 10)
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*Normalized\ form:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] && { _SN_R="${BASH_REMATCH[1]}"; break; }
    done < <(LC_ALL=C "${t[@]}" systemd-analyze calendar -- "$1" </dev/null 2>/dev/null)
    return 0
}

# _sched_differs_r UNIT CALKEY → _SD_R: what systemd runs UNIT on when that is
# known and is not the config's value (normalized on both sides), else empty.
_sched_differs_r() {
    local eff
    _SD_R=''
    _sched_effective_r "$1"; eff="$_SE_R"
    [[ -n "$eff" ]] || return 0
    _sched_val_r "$2"; _sched_norm_r "$_CS_R"
    [[ -n "$_SN_R" && "$eff" != "$_SN_R" ]] && _SD_R="$eff"
    return 0
}

# _sched_row_of UNIT → its table row (empty when UNIT has no schedule key)
_sched_row_of() {
    local r
    while IFS= read -r r; do [[ "${r%%|*}" == "$1" ]] && { printf '%s' "$r"; return 0; }; done <<<"$SCHED_TIMERS"
    return 0
}

# _sched_json UNIT → {key, value, default, source, delay_key, delay, delay_default,
# delay_source, dropin, dropin_present, dropin_current}: the schedule the config
# gives UNIT (null when it has no key).
_sched_json() {
    local row u ck dk v d dv='' dd='' f cur=false pres=false
    row="$(_sched_row_of "$1")"
    [[ -n "$row" ]] || { printf 'null'; return 0; }
    IFS='|' read -r u ck dk _ <<<"$row"
    _cs_load
    _sched_val_r "$ck"; v="$_CS_R"; _cs_default_r "$ck"; d="$_CS_R"
    if [[ -n "$dk" ]]; then _sched_val_r "$dk"; dv="$_CS_R"; _cs_default_r "$dk"; dd="$_CS_R"; fi
    f="$(_sched_dropin "$u")"
    [[ -e "$f" ]] && pres=true
    _sched_want_r "$ck" "$dk"
    if [[ -z "$_SCHED_BAD" ]]; then
        if [[ -n "$_SCHED_WANT" ]]; then _sched_file_is "$f" "$_SCHED_WANT" && cur=true
        elif [[ "$pres" == false ]]; then cur=true; fi
    fi
    jq -cn --arg k "$ck" --arg v "$v" --arg d "$d" --arg s "$(_cfg_key_source "$ck")" \
        --arg dk "$dk" --arg dv "$dv" --arg dd "$dd" --arg ds "$( [[ -n "$dk" ]] && _cfg_key_source "$dk")" \
        --arg f "$f" --argjson pres "$pres" --argjson cur "$cur" '
        def nz: if . == "" then null else . end;
        {key:$k, value:$v, default:$d, source:$s, delay_key:($dk|nz), delay:($dv|nz), delay_default:($dd|nz),
         delay_source:($ds|nz), dropin:$f, dropin_present:$pres, dropin_current:$cur}'
}

rdo_timers() {
    case "${1:-}" in
        "") ;;
        apply) shift; _timers_apply_cmd "$@"; return ;;
        *) die "$EX_USAGE" "timers [apply] (got '$1')" ;;
    esac
    local u svc out='' row ck diff
    while read -r u; do
        svc="${u%.timer}.service"
        # the calendar systemd runs, and whether it is the config's (null: not known)
        _sched_effective_r "$u"; diff=null
        row="$(_sched_row_of "$u")"
        if [[ -n "$row" && -n "$_SE_R" ]]; then
            ck="${row#*|}"; ck="${ck%%|*}"
            _sched_val_r "$ck"; _sched_norm_r "$_CS_R"
            if [[ -n "$_SN_R" ]]; then diff=false; [[ "$_SE_R" == "$_SN_R" ]] || diff=true; fi
        fi
        out+="$(jq -cn --arg unit "$u" --arg svc "$svc" \
            --arg load "$(_sd_prop "$u" LoadState)" --arg file "$(_sd_prop "$u" UnitFileState)" \
            --arg act "$(_sd_prop "$u" ActiveState)" --arg cal "$_SE_R" --argjson diff "$diff" \
            --arg next "$(_sd_time "$(_sd_prop "$u" NextElapseUSecRealtime)")" \
            --arg last "$(_sd_time "$(_sd_prop "$u" LastTriggerUSec)")" \
            --arg sload "$(_sd_prop "$svc" LoadState)" --arg res "$(_sd_prop "$svc" Result)" \
            --arg ex "$(_sd_prop "$svc" ExecMainStatus)" --arg sact "$(_sd_prop "$svc" ActiveState)" \
            --argjson sched "$(_sched_json "$u")" '
            def nz: if . == "" then null else . end;
            ($load == "loaded") as $inst
            | { unit: $unit, service: $svc, installed: $inst,
                enabled: ($file == "enabled"), active: ($act == "active"),
                calendar: ($cal | nz), calendar_differs: $diff,
                schedule: $sched,
                next: ($next | nz), last: ($last | nz),
                last_result: (if $inst and $sload == "loaded" and ($last != "") then ($res | nz) else null end),
                last_exit: (if $inst and ($last != "") and ($ex | test("^[0-9]+$")) then ($ex | tonumber) else null end),
                running: ($sact == "activating" or $sact == "active") }')" || die "$EX_SOFTWARE" "timers: could not read $u"
        out+=$'\n'
    done < <(_pbo_timer_units)
    out="$(printf '%s' "$out" | jq -cs '{status:"ok", ok:true, timers:.}')"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_emit "$out"; return "$EX_OK"; fi
    { printf 'TIMER\tSTATE\tSCHEDULE\tSOURCE\tNEXT\tLAST\tRESULT\n'
      jq -r '.timers[] | [ .unit, (if .installed | not then "not installed" elif .enabled then "enabled" else "disabled" end),
              (.calendar // .schedule.value // "-"), (.schedule.source // "-"),
              ((.next // "-") | .[0:16] | sub("T";" ")), ((.last // "-") | .[0:16] | sub("T";" ")),
              (.last_result // "-") ] | @tsv' <<<"$out"; } | { column -t -s $'\t' 2>/dev/null || cat; }
    jq -r '.timers[] | select(.schedule != null and (.schedule.dropin_current | not))
        | "note: \(.unit): \(.schedule.dropin) does not match the config (pbo timers apply, or pbo doctor --fix, rewrites it)"' <<<"$out"
    # SCHEDULE is what systemd runs: say so where the config says otherwise
    jq -r '.timers[] | select(.installed and .schedule != null and .schedule.dropin_current and .calendar_differs == true)
        | "note: \(.unit): systemd runs \(.calendar), the config says \(.schedule.value) (another drop-in in \(.unit).d, e.g. an override.conf from systemctl edit, sets OnCalendar=, or a daemon-reload is pending)"' <<<"$out"
}

# pbo timers apply: the drop-ins of every timer of the role from the config
# (install.sh runs it after installing the units, so a reinstall keeps a
# custom schedule). On a janitor it stays root (lib/appendonly.sh _role_check):
# the drop-ins are root's, in the systemd directory.
_timers_apply_cmd() {
    (( $# == 0 )) || die "$EX_USAGE" "timers apply (got '$1')"
    # `timers` is a read-only command in the audit record; apply changes files
    AUDIT_RW_OVERRIDE=1
    local rc=0 r u st f m res=''
    _sched_apply || rc=$?
    _sched_audit
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        for r in "${SCHED_RES[@]+"${SCHED_RES[@]}"}"; do res+="$r"$'\x1e'; done
        json_emit "$(jq -cn --arg r "$res" --arg rl "$SCHED_RELOAD" --arg rm "$SCHED_RELOAD_MSG" \
            --arg rs "${SCHED_RESTARTED[*]-}" --argjson rc "$rc" --argjson dry "${DRY_RUN:-0}" '
            [ $r | split("\u001e")[] | select(length > 0) | split("\u001f") | {unit:.[0], status:.[1], dropin:.[2], message:.[3]} ] as $t
            | {status:(if $rc == 0 then "ok" else "failed" end), ok:($rc == 0), dry_run:($dry == 1),
               changed:any($t[]; .status | IN("written","removed","would-write","would-remove")),
               timers:$t, reload:$rl, reload_message:(if $rm == "" then null else $rm end),
               restarted:($rs | split(" ") | map(select(length > 0)))}')"
    else
        for r in "${SCHED_RES[@]+"${SCHED_RES[@]}"}"; do
            IFS=$'\x1f' read -r u st f m <<<"$r"
            case "$st" in
                ok) printf '%s: %s\n' "$u" "$m" ;;
                bad|failed) printf '%s: FAILED: %s\n' "$u" "$m" ;;
                *) printf '%s: %s\n' "$u" "$m" ;;
            esac
        done
        [[ "$SCHED_RELOAD" == none ]] || printf '%s\n' "$SCHED_RELOAD_MSG"
        (( ${#SCHED_RESTARTED[@]} == 0 )) || printf 'restarted: %s\n' "${SCHED_RESTARTED[*]}"
    fi
    if (( rc )); then PBO_ERROR_LOGGED=1; log_error "timers apply: ${SCHED_NBAD} refused value(s), ${SCHED_NFAIL} failed step(s) (see above)"; fi
    return "$rc"
}

# --- doctor --------------------------------------------------------------------------
# _sched_root_pass: a janitor started as root drops to JANITOR_USER before it
# writes anything (_role_check), and the drop-ins are root's: `doctor --fix`
# applies them here, right before the re-exec, and hands the result to the
# doctor that runs as JANITOR_USER (PBO_SCHED_FIX_REPORT, PBO_SCHED_FIXED=1),
# as the permission pass does (lib/perms.sh _perm_root_pass).
_sched_root_pass() {
    [[ "${PBO_SCHED_FIXED:-0}" == 1 ]] && return 0
    local a seen=0 args=() dry="${DRY_RUN:-0}" r rep=''
    for a in "${PBO_ORIG_ARGS[@]+"${PBO_ORIG_ARGS[@]}"}"; do
        if (( seen )); then args+=("$a"); elif [[ "$a" == doctor ]]; then seen=1; fi
    done
    _doctor_args "${args[@]+"${args[@]}"}" || { DRY_RUN="$dry"; return 0; }
    (( DOCTOR_FIX && ! DOCTOR_PERMS_ONLY )) || { DRY_RUN="$dry"; return 0; }
    _sched_apply || true
    for r in "${SCHED_RES[@]+"${SCHED_RES[@]}"}"; do rep+="${r//$'\n'/ }"$'\n'; done
    [[ "$SCHED_RELOAD" == none ]] || rep+="reload"$'\x1f'"$SCHED_RELOAD"$'\x1f'$'\x1f'"$SCHED_RELOAD_MSG"$'\n'
    export PBO_SCHED_FIXED=1 PBO_SCHED_FIX_REPORT="$rep"
    DRY_RUN="$dry"
}

# _doctor_schedule <ok> <bad> <warn> → DSC_LINES, DSC_PROBLEMS, DSC_WARNS: the
# timer schedules. With --fix the drop-ins are applied first (FIXED / WOULD
# FIX; on a janitor started as root that ran before the re-exec). Then: a
# drop-in that does not match the config (drift) or that the config no longer
# wants (stale) is a WARN (the timer runs, on another schedule than the config
# says), a value pbo refuses a WARN (config check names it too), a timer whose
# unit files systemd has not reloaded yet (NeedDaemonReload) a WARN, one whose
# calendar in systemd (TimersCalendar) is not the config's a WARN; else one OK
# line. A janitor's root pass is audit-logged here, by the re-exec'd doctor.
_doctor_schedule() {
    local ok="$1" bad="$2" warn="$3" r u st f m custom=() n=0 by='' row ck
    DSC_LINES=() DSC_PROBLEMS=0 DSC_WARNS=0
    if (( DOCTOR_FIX )); then
        local -a fixres=()
        if _is_janitor && [[ "${PBO_SCHED_FIXED:-0}" == 1 ]]; then
            # root applied them before the re-exec and wrote no audit line (it
            # writes nothing into the janitor user's LOG_DIR): this doctor,
            # running as JANITOR_USER, records them, as the permission pass's
            by=" (as root, before dropping to ${JANITOR_USER:-restic})"
            while IFS= read -r r; do [[ -n "$r" ]] && fixres+=("$r"); done <<<"${PBO_SCHED_FIX_REPORT:-}"
        elif ! _is_janitor || [[ "$EUID" == 0 ]]; then
            _sched_apply || true
            _sched_audit
            fixres=("${SCHED_RES[@]+"${SCHED_RES[@]}"}")
            [[ "$SCHED_RELOAD" == none ]] || fixres+=("reload"$'\x1f'"$SCHED_RELOAD"$'\x1f'$'\x1f'"$SCHED_RELOAD_MSG")
        fi
        for r in "${fixres[@]+"${fixres[@]}"}"; do
            IFS=$'\x1f' read -r u st f m <<<"$r"
            if [[ "$u" == reload ]]; then   # the daemon-reload record (st: SCHED_RELOAD)
                case "$st" in
                    ok) DSC_LINES+=("  ${C_G:-}FIXED${C_0:-} $m") ;;
                    would) DSC_LINES+=("  ${C_Y:-}WOULD FIX${C_0:-} $m") ;;
                    *) DSC_LINES+=("$warn  $m"); DSC_WARNS=$((DSC_WARNS+1)) ;;
                esac
                continue
            fi
            case "$st" in
                written|removed)
                    DSC_LINES+=("  ${C_G:-}FIXED${C_0:-} $u: $m")
                    # (the other branch audited them in _sched_audit; a dry run
                    # reports would-* only)
                    [[ -z "$by" ]] || audit_log "timers: $u schedule drop-in $st ($f)$by" ;;
                would-write|would-remove) DSC_LINES+=("  ${C_Y:-}WOULD FIX${C_0:-} $u: $m") ;;
                failed) DSC_LINES+=("$warn  $u: $m"); DSC_WARNS=$((DSC_WARNS+1)) ;;
            esac
            # doctor --json lists the changes (`changes`, next to the permission
            # fixes): {name: the timer, path: its drop-in, change, applied}
            case "$st" in
                written|removed|would-write|would-remove)
                    DP_CHANGES_JSON="$(jq -c --arg u "$u" --arg f "$f" --arg st "${st#would-}" --argjson ap "$( [[ "$st" == would-* ]] && echo false || echo true )" \
                        '(. // []) + [{name:$u, path:$f, change:("schedule drop-in " + (if $st == "remove" or $st == "removed" then "removed" else "written" end)), from:null, to:null, applied:$ap}]' <<<"$DP_CHANGES_JSON")" ;;
            esac
        done
    fi
    _sched_apply --check || true
    for r in "${SCHED_RES[@]+"${SCHED_RES[@]}"}"; do
        IFS=$'\x1f' read -r u st f m <<<"$r"
        case "$st" in
            ok)
                # the drop-in is as the config says; whether systemd runs it is
                # its own question: a reload that did not happen (also after a
                # drop-in was removed), or another drop-in that sets OnCalendar=
                row="$(_sched_row_of "$u")"; ck="${row#*|}"; ck="${ck%%|*}"
                if [[ "$(_sd_prop "$u" NeedDaemonReload)" == yes ]]; then
                    DSC_LINES+=("$warn  $u: systemd has not reloaded its unit files since they changed, so its schedule may not be the config's yet (systemctl daemon-reload)"); DSC_WARNS=$((DSC_WARNS+1))
                    continue
                fi
                _sched_differs_r "$u" "$ck"
                if [[ -n "$_SD_R" ]]; then
                    _sched_val_r "$ck"
                    DSC_LINES+=("$warn  $u: systemd runs $_SD_R, the config says $_CS_R (another drop-in in $u.d such as override.conf from systemctl edit sets OnCalendar=, or a daemon-reload is pending)"); DSC_WARNS=$((DSC_WARNS+1))
                    continue
                fi
                n=$((n+1))
                [[ "$m" == *"(drop-in)" ]] && custom+=("$u ${m% (drop-in)}") ;;
            drift|stale) DSC_LINES+=("$warn  $u $m: 'pbo doctor --fix' (or 'pbo timers apply') $( [[ "$st" == drift ]] && echo writes || echo removes) $f"); DSC_WARNS=$((DSC_WARNS+1)) ;;
            bad) DSC_LINES+=("$warn  $u: $m"); DSC_WARNS=$((DSC_WARNS+1)) ;;
        esac
    done
    if (( n )); then
        if (( ${#custom[@]} )); then
            local c txt=''
            for c in "${custom[@]}"; do txt+="${txt:+; }$c"; done
            DSC_LINES+=("$ok  timer schedules as the config says (custom: $txt)")
        else
            DSC_LINES+=("$ok  timer schedules as the config says (all defaults)")
        fi
    fi
    return 0
}
