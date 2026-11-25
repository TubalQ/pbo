# shellcheck shell=bash
# lib/config.sh: `pbo config`, the configuration seen through the schema
# (lib/config_schema.sh, ADR 0009). Read-only so far: show, list, get, template
# and check. load_config (lib/common.sh) reads the config with the strict reader
# (lib/config_parse.sh, 0.6 M3); these commands show what it read (CFG_VAL,
# CFG_SRC, CFG_ENV) through the schema.
#
# Secrets are never printed, only whether they are set; credentials inside URLs
# are masked (here for the human output, in json_emit for --json).

# _config_known_keys: every schema key, in table order.
_config_known_keys() { _cs_load; printf '%s\n' "${CS_ORDER[@]}"; }

# _config_is_secret KEY: the value must not be printed. Schema keys say so with
# the secret flag (NTFY_URL/NTFY_TOPIC: on a public ntfy server the topic is the
# password; RESTIC_SFTP_COMMAND may carry e.g. "sshpass -p ..."). A key the
# schema does not know is never printed, whatever its name.
_config_is_secret() {
    _cs_has "$1" || return 0
    _cs_flag "$1" secret >/dev/null
}

# _config_secret_name KEY: the old name rule for secrets. Not used to decide
# anything at runtime any more (the schema flags them); tests/config.sh checks
# that every schema key with such a name carries the secret flag.
_config_secret_name() { [[ "$1" =~ (TOKEN|PASSWORD|SECRET|PASS|KEY|ACCESS|CREDENTIAL|CREDS|COMMAND|TOPIC)$ ]]; }

# _config_mask_url <value>: drop credentials from anything URL-like.
_config_mask_url() { _mask_url "$1"; }

# _config_shared_file: the cluster-shared base config load_config read, when it
# is not also the last file read (it is when no local config exists).
_config_shared_file() {
    local s="${PBO_CONFIG_SHARED_LOADED:-}"
    [[ -n "$s" && "$s" != "${PBO_CONFIG_LOADED:-}" ]] && printf '%s' "$s"
    return 0
}

# _config_rows <mode> [KEY...]: the keys as one JSON array (one jq call, not one
# per key). mode: all (show), list (no internal or other-role keys, unless a
# config file sets them), keys (just the KEYs given). The source of a value is
# where the reader found its last assignment (CFG_SRC): the cluster-shared file
# ("shared") or the local one ("config", which wins, read after it); else the
# environment ("env", the snapshot load_config took before assigning anything:
# a non-empty value there is what pbo uses); else the default.
_config_rows() {
    local mode="$1"; shift
    _cs_load
    local role="${PBO_ROLE:-host}" k v d src sec set known rec='' keys=()
    # (load_config filled these; a caller that did not run it gets the defaults)
    declare -p CFG_SRC >/dev/null 2>&1 || { declare -gA CFG_SRC=() CFG_VAL=() CFG_ENV=() CFG_EXPORT=(); declare -ga CFG_UNKNOWN=(); }
    if [[ "$mode" == keys ]]; then keys=("$@")
    else
        # then the keys only a file has (typos, keys of a newer pbo, the proxy
        # variables it exports), in the order the files set them
        keys=("${CS_ORDER[@]}" "${CFG_UNKNOWN[@]+"${CFG_UNKNOWN[@]}"}")
        # a proxy variable set bare and exported (http_proxy=x, export
        # http_proxy=y) is in both: one row
        for k in "${!CFG_EXPORT[@]}"; do
            [[ " ${CFG_UNKNOWN[*]} " == *" $k "* ]] || keys+=("$k")
        done
    fi
    for k in "${keys[@]}"; do
        known=0; _cs_has "$k" && known=1
        if [[ "$mode" == list && "$known" == 1 && -z "${CFG_SRC[$k]+x}" ]]; then
            _cs_flag "$k" internal >/dev/null && continue
            _cs_has_role "$k" "$role" || continue
        fi
        src=default
        if [[ -n "${CFG_SRC[$k]+x}" ]]; then
            if [[ "${CFG_SRC[$k]%%:*}" == shared ]]; then src=shared; else src=config; fi
        elif (( known )) && [[ -n "${CFG_ENV[$k]:-}" ]]; then src="env"
        fi
        # the effective value: what pbo reads through its :- fallbacks. A key
        # the schema does not know was never assigned: what the file says.
        if (( known )); then _cs_value_r "$k"; v="$_CS_R"; else v="${CFG_VAL[$k]-}"; fi
        set=0; [[ -n "$v" ]] && set=1
        sec=0; _config_is_secret "$k" && sec=1
        d=''; if (( known && ! sec )); then _cs_default_r "$k"; d="$_CS_R"; fi
        (( sec )) && v=''
        # the separators cannot occur in a config value worth showing
        v="${v//[$'\x1e\x1f']/}"; d="${d//[$'\x1e\x1f']/}"
        if (( known )); then
            rec+="$k"$'\x1f'"$v"$'\x1f'"$sec"$'\x1f'"$set"$'\x1f'"$src"$'\x1f'1$'\x1f'"${CS_TYPE[$k]}"$'\x1f'"${CS_SECTION[$k]}"$'\x1f'"$d"$'\x1f'"${CS_FLAGS[$k]}"$'\x1f'"${CS_ROLES[$k]}"$'\x1f'"${CS_DESC[$k]}"$'\x1e'
        else
            rec+="$k"$'\x1f'"$v"$'\x1f'"$sec"$'\x1f'"$set"$'\x1f'"$src"$'\x1f'0$'\x1f'$'\x1f'$'\x1f'$'\x1f'$'\x1f'$'\x1f'$'\x1e'
        fi
    done
    jq -cn --arg d "$rec" '
        def nz: if . == "" then null else . end;
        def flags: if . == "" then [] else split(",") end;
        [ $d | split("\u001e")[] | select(length > 0) | split("\u001f")
          | (.[2] == "1") as $sec | (.[5] == "1") as $known
          | { key: .[0], value: (if $sec then null else .[1] end), secret: $sec, set: (.[3] == "1"),
              source: .[4], known: $known,
              type: (if $known then .[6] else null end), section: (if $known then .[7] else null end),
              default: (if $known and ($sec | not) then .[8] else null end),
              flags: (.[9] | flags), roles: (.[10] | flags), description: (.[11] | nz),
              managed_by: ((.[9] | flags | map(select(startswith("managed=")) | ltrimstr("managed=")) | first) // null) } ]'
}

# _config_envelope <rows>: the `config` result object around the key rows.
# restic_env: RESTIC_ENV_FILE as load_config found it (lib/restic.sh): the
# names of its variables and the number of findings, never a value.
_config_envelope() {
    # file_schema: what the file declares (PBO_CONFIG_VERSION has a default now)
    jq -c --arg f "${PBO_CONFIG_LOADED:-}" --arg sf "$(_config_shared_file)" --arg ver "${CFG_VAL[PBO_CONFIG_VERSION]:-}" \
        --arg lf "${PBO_CONFIG_LOCAL:-}" --argjson schema "${PBO_CONFIG_SCHEMA:-1}" --arg role "${PBO_ROLE:-host}" \
        --arg ef "${RESTIC_ENV_FILE:-}" --arg ep "${RENV_PRESENT-0}" --arg ek "${RENV_KEYS[*]-}" --arg en "$( [[ -n "${RENV_ERRORS[0]+x}" ]] && echo "${#RENV_ERRORS[@]}" || echo 0 )" \
        '{status:"ok", ok:true, file:(if $f == "" then null else $f end), shared_file:(if $sf == "" then null else $sf end),
          local_file:(if $lf == "" then null else $lf end), config_schema:$schema,
          file_schema:(if $ver == "" then null else ($ver | tonumber? // $ver) end), role:$role,
          restic_env:{file:(if $ef == "" then null else $ef end), present:($ep == "1"),
                      variables:($ek | split(" ") | map(select(length > 0))), errors:($en | tonumber)},
          keys:.}' <<<"$1"
}

# config [show] | list [--all]
_config_view() {
    local mode="$1"; shift
    local all=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) [[ "$mode" == list ]] || die "$EX_USAGE" "config show takes no arguments (it shows every key; see config list)"; all=1; shift ;;
            *) die "$EX_USAGE" "config $mode: unknown argument '$1'" ;;
        esac
    done
    local rows out
    if [[ "$mode" == show ]] || (( all )); then rows="$(_config_rows all)"; else rows="$(_config_rows list)"; fi
    out="$(_config_envelope "$rows")" || die "$EX_SOFTWARE" "config: could not build the view"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_emit "$out"; return "$EX_OK"; fi
    if [[ "$mode" == show ]]; then
        # the 0.5 format: KEY=value, "# default" when the file does not set it
        jq -r "$PBO_JQ_MASK"' .keys[] | "\(.key)=\(if .secret then (if .set then "<set>" else "<unset>" end) else (.value | mask) end)\(if .source == "default" then "   # default" else "" end)"' <<<"$out"
        return "$EX_OK"
    fi
    { printf 'KEY\tVALUE\tSOURCE\tTYPE\n'
      # long values cut (config get prints them whole); types readable
      jq -r "$PBO_JQ_MASK"'
        def cut: if length > 60 then .[0:57] + "..." else . end;
        def pretty: if startswith("int:") then (ltrimstr("int:") | split(":") | "int \(.[0])..\(.[1] // "")")
                    elif startswith("enum:") then (ltrimstr("enum:") | split(",") | map(if . == "" then "\"\"" else . end) | join("|"))
                    else . end;
        .keys[] | [ .key,
            (if .secret then (if .set then "<set>" else "<unset>" end) elif .value == "" then "-" else (.value | mask | cut) end),
            .source, (if .known then (.type | pretty) else "unknown key" end) ] | @tsv' <<<"$out"
    } | { column -t -s $'\t' 2>/dev/null || cat; }
    # the variables RESTIC_ENV_FILE gives restic: their names only
    jq -r '.restic_env | select(.present) | "\nRESTIC_ENV_FILE \(.file): \(.variables | length) variable(s) for restic only\(if (.variables | length) > 0 then " (" + (.variables | join(" ")) + ")" else "" end)\(if .errors > 0 then "; pbo refuses the file (pbo config check)" else "" end)"' <<<"$out"
}

# config get KEY: the effective value (a secret: <set> or <unset>).
_config_get() {
    [[ $# -eq 1 && -n "$1" ]] || die "$EX_USAGE" "config get KEY (one key; 'pbo config list' shows them)"
    _cs_has "$1" || die "$EX_USAGE" "config get: '$1' is not a known config key ('pbo config list --all' shows them)"
    local row; row="$(_config_rows keys "$1" | jq -c '.[0]')" || die "$EX_SOFTWARE" "config get: could not read $1"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then json_emit "$(jq -c '{status:"ok", ok:true} + .' <<<"$row")"; return "$EX_OK"; fi
    jq -r "$PBO_JQ_MASK"' if .secret then (if .set then "<set>" else "<unset>" end) else (.value | mask) end' <<<"$row"
}

# _cs_quote VALUE: VALUE as the right-hand side of KEY=VALUE that bash reads
# back unchanged: bare when that is safe (plain characters and ${KEY}
# references: an assignment does not split words), else in double quotes, so a
# ${KEY} reference in a default still expands when the line is uncommented.
_cs_quote() {
    local v="$1" re='^([A-Za-z0-9_./:,@%+=-]|\$\{[A-Z][A-Z0-9_]*\})*$'
    if [[ "$v" =~ $re ]]; then printf '%s' "$v"; return 0; fi
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//\`/\\\`}"
    printf '"%s"' "$v"
}

# _cfg_comment: prose on stdin as "# " comment lines ("#" for an empty line).
_cfg_comment() {
    local l
    while IFS= read -r l; do if [[ -n "$l" ]]; then printf '# %s\n' "$l"; else printf '#\n'; fi; done
}

# _cfg_template_desc KEY: the description the example shows; a derived default
# names the keys it follows (the example writes it resolved, see
# _cs_template_value).
_cfg_template_desc() {
    local desc="${CS_DESC[$1]}" spec="${CS_DEFAULT[$1]}" refs=''
    while [[ "$spec" == *'${'*'}'* ]]; do
        spec="${spec#*\$\{}"; refs+="${refs:+, }${spec%%\}*}"; spec="${spec#*\}}"
    done
    [[ -n "$refs" && "$desc" != *follows* ]] && desc+="; the default follows $refs"
    printf '%s' "$desc"
}

# _config_template [role]: the example config for a role, generated from the
# schema: keys in table order under their section, active unless advanced (or
# flagged template_<role>, what that role must set), each with its description.
# Internal and deprecated keys are left out. Deterministic: it depends on nothing
# but the schema.
_config_template() {
    local role="${1:-host}" k s prev='' val line title desc
    _cs_load
    _cfg_template_header "$role" | _cfg_comment
    for k in "${CS_ORDER[@]}"; do
        _cs_has_role "$k" "$role" || continue
        _cs_flag "$k" internal >/dev/null && continue
        _cs_flag "$k" deprecated >/dev/null && continue
        s="${CS_SECTION[$k]}"
        if [[ "$s" != "$prev" ]]; then
            printf '\n'
            title="$(_cfg_section_title "$s")"
            [[ -n "$title" ]] && printf '# --- %s ---\n' "$title"
            _cfg_section_intro "$s" | _cfg_comment
            prev="$s"
        fi
        val="$(_cs_template_value "$k" "$role")"
        line="$k=$(_cs_quote "$val")"
        if [[ "$role" != host ]] && _cs_flag "$k" "template_$role" >/dev/null; then :
        elif _cs_flag "$k" advanced >/dev/null; then line="#$line"; fi
        desc="$(_cfg_template_desc "$k")"
        if (( ${#line} < 44 )); then printf '%-44s # %s\n' "$line" "$desc"
        else printf '%s  # %s\n' "$line" "$desc"; fi
    done
}

# config template [--role host|janitor]
_config_template_cmd() {
    local role=host
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --role) [[ $# -ge 2 ]] || die "$EX_USAGE" "config template --role host|janitor"; role="$2"; shift 2 ;;
            --role=*) role="${1#--role=}"; shift ;;
            *) die "$EX_USAGE" "config template: unknown argument '$1' (use --role host|janitor)" ;;
        esac
    done
    case "$role" in host|janitor) ;; *) die "$EX_USAGE" "config template: --role must be host or janitor, not '$role'" ;; esac
    local t; t="$(_config_template "$role")" || die "$EX_SOFTWARE" "config template: could not generate it"
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_emit "$(jq -cn --arg r "$role" --arg t "$t" '{status:"ok", ok:true, role:$r, template:($t + "\n")}')"; return "$EX_OK"
    fi
    printf '%s\n' "$t"
}

# --- config check: the strict reader (lib/config_parse.sh) ---------------------------

# _config_compare_show KEY VALUE SET: a value as `config check --compare-bash`
# shows it: quoted the way bash would read it back (a CR or a space stays
# visible), URL credentials masked, <unset> when that reading did not set it.
_config_compare_show() {
    [[ "$3" == 1 ]] || { printf '<unset>'; return 0; }
    printf '%q' "$(_mask_url "$2")"
}

# _config_entries <file>: the reader's errors and warnings for one file, sorted
# by line: "<line>\x1f<error|warning>\x1f<message>" per line.
_config_entries() {
    local f="$1" e rest out=''
    for e in "${CFG_ERRORS[@]}"; do
        [[ "$e" == "$f:"* ]] || continue
        rest="${e#"$f:"}"; out+="${rest%%:*}"$'\x1f'error$'\x1f'"${rest#*: }"$'\n'
    done
    for e in "${CFG_WARNINGS[@]}"; do
        [[ "$e" == "$f:"* ]] || continue
        rest="${e#"$f:"}"; out+="${rest%%:*}"$'\x1f'warning$'\x1f'"${rest#*: }"$'\n'
    done
    [[ -n "$out" ]] || return 0
    # URL credentials masked (the reader never quotes a secret's value; this
    # also covers a type message that repeats a URL value)
    _mask_url "$(printf '%s' "$out" | sort -t $'\x1f' -k1,1n -s)"
}

# _config_compare_lines: after _cfg_compare_bash, one line per key bash reads
# differently (a secret only as <differs>), in file and line order → CCB_LINES;
# CCB_OK is the line for "no difference".
_config_compare_lines() {
    CCB_LINES=(); CCB_OK=''
    local k f n src
    local -a order=()
    mapfile -t order < <(for k in "${CFG_DIFF[@]}"; do
        src="${CFG_SRC[$k]#*:}"; f="${src%:*}"
        for n in "${!PBO_CONFIG_FILES[@]}"; do [[ "${PBO_CONFIG_FILES[n]}" == "$f" ]] && break; done
        printf '%s\t%s\t%s\n' "$n" "${src##*:}" "$k"
    done | sort -t $'\t' -k1,1n -k2,2n | cut -f3)
    for k in "${order[@]}"; do
        [[ -n "$k" ]] || continue
        src="${CFG_SRC[$k]#*:}"; f="${src%:*}"; n="${src##*:}"
        if _config_is_secret "$k"; then
            CCB_LINES+=("config: $k reads differently when bash sources the file (<differs>), $f line $n")
        else
            CCB_LINES+=("config: $k reads differently when bash sources the file (bash: $(_config_compare_show "$k" "${CFG_BASH[$k]}" "${CFG_BASH_SET[$k]:-0}"), pbo: $(_config_compare_show "$k" "${CFG_VAL[$k]}" 1)), $f line $n")
        fi
    done
    (( ${#CCB_LINES[@]} )) || CCB_OK="config: bash reads every key the same (${#CFG_VAL[@]} keys)"
    return 0
}

# _config_doctor_lines: what the reader found that doctor reports (load_config
# already stopped on every error): CDL_FAIL, the lines pbo ignores (an exec or
# local-only key in the cluster-shared file: one node's pbo would run what
# another node's admin wrote); CDL_WARN, the reader's warnings that
# _config_check does not give already (a key set twice, a CR or a BOM, an export
# of a config key, a reference taken from the environment), at most 10, then a
# count. Unknown keys and environment switches are _config_check's, test hooks
# `pbo config check`'s.
_config_doctor_lines() {
    CDL_FAIL=(); CDL_WARN=()
    local e rest f more=0
    declare -p CFG_WARNINGS >/dev/null 2>&1 || return 0
    for e in "${CFG_IGNORED[@]}"; do
        f="${e%%:*}"; rest="${e#"$f:"}"
        CDL_FAIL+=("config $f line ${rest%%:*}: $(_mask_url "${rest#*: }")")
    done
    for e in "${CFG_WARNINGS[@]}"; do
        case "$e" in *": unknown key "*|*" is an environment switch, not a config key"*|*" is a test hook (internal)"*) continue ;; esac
        if (( ${#CDL_WARN[@]} >= 10 )); then more=$((more+1)); continue; fi
        f="${e%%:*}"; rest="${e#"$f:"}"
        CDL_WARN+=("config $f line ${rest%%:*}: $(_mask_url "${rest#*: }")")
    done
    (( more == 0 )) || CDL_WARN+=("config: $more more warning(s) ('pbo config check' lists them all)")
    return 0
}

# config check [--file F [--shared]] [--role host|janitor] [--compare-bash]: the
# config as pbo reads it (load_config's strict reader), every error and warning
# by file and line. --file F checks F alone; --shared checks it as the
# cluster-shared file. A line pbo ignores (an exec or local-only key in the
# shared file) counts as an error. Exit 78 when there is an error.
#
# --compare-bash: migration debugging (0.5 → 0.6). Also SOURCES the files the
# way pbo 0.5 did, in a subshell with a clean environment (_cfg_compare_bash),
# and names every key bash reads differently, and a file bash cannot parse or
# stops in. It runs the config as code: an explicit opt-in, never the default.
_config_check_cmd() {
    local file='' role='' shared=0 compare=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file) [[ $# -ge 2 && -n "$2" ]] || die "$EX_USAGE" "config check --file <config file>"; file="$2"; shift 2 ;;
            --file=*) file="${1#--file=}"; [[ -n "$file" ]] || die "$EX_USAGE" "config check --file <config file>"; shift ;;
            --shared) shared=1; shift ;;
            --role) [[ $# -ge 2 ]] || die "$EX_USAGE" "config check --role host|janitor"; role="$2"; shift 2 ;;
            --role=*) role="${1#--role=}"; shift ;;
            --compare-bash) compare=1; shift ;;
            *) die "$EX_USAGE" "config check: unknown argument '$1' (use --file F, --shared, --role host|janitor, --compare-bash)" ;;
        esac
    done
    [[ -z "$role" || "$role" == host || "$role" == janitor ]] || die "$EX_USAGE" "config check: --role must be host or janitor, not '$role'"
    (( shared == 0 )) || [[ -n "$file" ]] || die "$EX_USAGE" "config check: --shared needs --file"
    _cfg_parse_ensure
    local f e origin=file nerr nref nstop nwarn why
    if [[ -n "$file" ]]; then
        [[ -f "$file" ]] || die "$EX_USAGE" "config check: $file is not a file"
        (( shared )) && origin=shared
        # read only (CFG_ENV, the environment load_config saw, is kept for its
        # references)
        _cfg_reset; PBO_CONFIG_FILES=("$file")
        _cfg_parse_file "$file" "$origin" || true
    elif ! declare -p CFG_VAL >/dev/null 2>&1; then
        _cfg_env_snapshot; _cfg_parse_all || true   # called outside main
    fi
    # the reader's own refusals: what the 'pbo refuses' line and the migration
    # hint below are about
    nref="${#CFG_ERRORS[@]}"
    # On a janitor every other command runs as JANITOR_USER (_role_check),
    # which reads the files again: a file only root can read (an editor or
    # `install -m 0600` makes one) stops all of them. This check stays root, so
    # it asks the janitor user. Not for --file (one file, read directly), not
    # under PBO_JANITOR_ALLOW_ROOT (the commands run as root then).
    local ju src
    if [[ -z "$file" && "$EUID" == 0 && "${PBO_JANITOR_ALLOW_ROOT:-0}" != 1 \
          && "${CFG_VAL[PBO_ROLE]:-${PBO_ROLE:-host}}" == janitor ]]; then
        ju="${CFG_VAL[JANITOR_USER]:-${JANITOR_USER:-restic}}"
        if ! id "$ju" >/dev/null 2>&1; then
            src="${CFG_SRC[JANITOR_USER]:-}"; src="${src#*:}"   # <file>:<line>, or the first file
            CFG_ERRORS+=("${src:-${PBO_CONFIG_FILES[0]:-config}:0}: JANITOR_USER '$ju' does not exist: every other janitor command stops on it")
        else
            for f in "${PBO_CONFIG_FILES[@]}"; do
                "${PBO_RUNUSER_BIN:-runuser}" -u "$ju" -- test -r "$f" 2>/dev/null \
                    || CFG_ERRORS+=("$f:0: JANITOR_USER $ju cannot read the file: every other janitor command runs as $ju and stops here (keep it 0640 root:$ju)")
            done
        fi
    fi
    if (( compare )); then
        # it runs the files: the rules load_config applies before reading one
        for f in "${PBO_CONFIG_FILES[@]}"; do
            _config_file_check "$f" || { [[ $? == 1 ]] || die "$EX_CONFIG" "config check --compare-bash: $_CFC_MSG (not sourced)"; }
        done
        _cfg_compare_bash
        # bash's own message is not repeated: it can quote the line, a secret
        # included (${NTFY_TOKEN:?tk_...})
        for e in "${CFG_BASH_FAIL[@]+"${CFG_BASH_FAIL[@]}"}"; do
            why="${e##*$'\x1f'}"; f="${e%$'\x1f'*}"
            if [[ "$why" == stops ]]; then
                CFG_WARNINGS+=("$f:0: bash stops on this file (it exits while the file is sourced: a \${X:?} or an exit): pbo 0.5 stopped there too")
            else
                CFG_WARNINGS+=("$f:0: bash cannot parse this file (bash -n fails): pbo 0.5 stopped reading it at the error")
            fi
        done
        _config_compare_lines
    fi
    if [[ -z "$role" ]]; then
        role="${CFG_VAL[PBO_ROLE]:-${PBO_ROLE:-host}}"
        [[ "$role" == janitor ]] || role=host
    fi
    _cfg_check_values "$role"
    # RESTIC_ENV_FILE (lib/restic.sh): load_config checked it; its findings are
    # listed under its own name (key names and line numbers, never a value).
    # A finding there stops every command but this one, doctor and version.
    local -a show_files=("${PBO_CONFIG_FILES[@]+"${PBO_CONFIG_FILES[@]}"}")
    if [[ -z "$file" && "${RENV_PRESENT-0}" == 1 ]]; then
        show_files+=("$RESTIC_ENV_FILE")
        CFG_ERRORS+=("${RENV_ERRORS[@]+"${RENV_ERRORS[@]}"}")
        CFG_WARNINGS+=("${RENV_WARNINGS[@]+"${RENV_WARNINGS[@]}"}")
    fi
    # errors every command stops on that are not the reader's (the role checks,
    # the janitor user's access above, RESTIC_ENV_FILE)
    nstop=$(( ${#CFG_ERRORS[@]} - nref ))
    # the lines pbo ignores are errors here: nothing in a config should be dropped
    CFG_ERRORS+=("${CFG_IGNORED[@]+"${CFG_IGNORED[@]}"}")
    nerr="${#CFG_ERRORS[@]}"; nwarn="${#CFG_WARNINGS[@]}"
    # files the reader refuses that bash accepts: the migration hint. Only the
    # reader's refusals: a role error or an ignored key is not code.
    local -a bashok=()
    if (( nref )); then
        for f in "${PBO_CONFIG_FILES[@]}"; do
            for e in "${CFG_ERRORS[@]:0:nref}"; do
                [[ "$e" == "$f:"* ]] || continue
                "${BASH:-bash}" -n -- "$f" 2>/dev/null && bashok+=("$f")
                break
            done
        done
    fi

    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        local rec='' diffs='' fails='' k src
        for f in "${show_files[@]+"${show_files[@]}"}"; do
            rec+="$f"$'\x1e'"$(_config_entries "$f")"$'\x1d'
        done
        if (( compare )); then
            for k in "${CFG_DIFF[@]}"; do src="${CFG_SRC[$k]#*:}"; diffs+="$k"$'\x1f'"${src%:*}"$'\x1f'"${src##*:}"$'\n'; done
            for e in "${CFG_BASH_FAIL[@]+"${CFG_BASH_FAIL[@]}"}"; do fails+="$e"$'\n'; done
        fi
        json_emit "$(jq -cn --arg d "$rec" --arg diffs "$diffs" --arg fails "$fails" --argjson compare "$compare" --arg role "$role" \
            --argjson nerr "$nerr" --argjson nwarn "$nwarn" --argjson nkeys "${#CFG_VAL[@]}" \
            --argjson nign "${#CFG_IGNORED[@]}" --arg bashok "$(printf '%s\n' "${bashok[@]+"${bashok[@]}"}")" '
            def entries($k): split("\n") | map(select(length > 0) | split("\u001f") | select(.[1] == $k)
                                               | {line: (.[0] | tonumber), message: .[2]});
            def lines: split("\n") | map(select(length > 0));
            { status: (if $nerr > 0 then "invalid" else "ok" end), ok: ($nerr == 0), role: $role,
              errors: $nerr, warnings: $nwarn, ignored: $nign, keys: $nkeys,
              files: [ $d | split("\u001d")[] | select(length > 0) | split("\u001e")
                       | {file: .[0], errors: (.[1] | entries("error")), warnings: (.[1] | entries("warning")),
                          valid_bash: (.[0] as $f | (($bashok | lines) | index($f)) != null)} ],
              compare_bash: (if $compare == 1 then
                         ($diffs | lines | map(split("\u001f") | {key: .[0], file: .[1], line: (.[2] | tonumber)})) as $dl
                         | {agree: (($dl | length) == 0 and ($fails | length) == 0), keys: $nkeys, differences: $dl,
                            bash_failed: ($fails | lines | map(split("\u001f") | {file: .[0], why: .[1]}))}
                       else null end) }')"
    else
        local l kind msg
        (( ${#PBO_CONFIG_FILES[@]} )) || printf 'no config file: pbo uses the defaults\n'
        for f in "${show_files[@]+"${show_files[@]}"}"; do
            while IFS=$'\x1f' read -r l kind msg; do
                [[ -n "$kind" ]] && printf '%s:%s: %s: %s\n' "$f" "$l" "$kind" "$msg"
            done < <(_config_entries "$f")
        done
        if (( compare )); then
            for l in "${CCB_LINES[@]+"${CCB_LINES[@]}"}"; do printf '%s\n' "$l"; done
            [[ -z "$CCB_OK" ]] || printf '%s\n' "$CCB_OK"
        fi
        printf 'pbo config check: %d error(s), %d warning(s) in %d file(s)\n' "$nerr" "$nwarn" "${#show_files[@]}"
        if (( nref )); then
            printf "pbo refuses this config: fix the lines above (pbo 0.6 reads KEY=VALUE lines and does not run the config as shell code)\n"
        elif (( nstop )); then
            printf "pbo stops on this config: every command refuses the errors above\n"
        elif (( nerr )); then
            printf "pbo ignores the lines marked error above: fix them\n"
        fi
        for f in "${bashok[@]+"${bashok[@]}"}"; do
            printf '%s is valid bash, but pbo 0.6 no longer runs the config as code; see the 0.6.0 migration notes in CHANGELOG.md\n' "$f"
        done
    fi
    if (( nerr )); then PBO_ERROR_LOGGED=1; return "$EX_CONFIG"; fi
    return "$EX_OK"
}

# --- the writer: _cfg_write, pbo config set|unset (0.6 M4, ADR 0009 "Writer") ----------
#
# The only code that changes a config file. One call is one transaction (any
# number of sets and unsets) under the lock LOCK_DIR/pbo.config: the file is
# read, edited line by line, written to a temp file in the same directory with
# the old file's owner, group and mode, read back with the strict reader AND
# sourced by bash in a clean subshell (both must give every key the value
# intended, and every other key the value it had), fsynced and renamed over the
# old one. Comments, blank lines and the order of the lines stay; the file stays
# valid bash, so pbo 0.5 still reads it after a downgrade.

# _cfg_qval VALUE → _CFG_Q: VALUE as the right-hand side of KEY=VALUE that the
# strict reader and bash read back unchanged: bare when every character is plain
# (nothing to split, expand or refuse), else in double quotes with \ " $ `
# escaped. Unlike _cs_quote (the template's ${KEY} references) a $ stays literal:
# the value given is the value meant.
_cfg_qval() {
    local v="$1" LC_ALL=C
    if [[ "$v" != *[!A-Za-z0-9_./:,@%+=-]* ]]; then _CFG_Q="$v"; return 0; fi
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//\$/\\\$}"; v="${v//\`/\\\`}"
    _CFG_Q="\"$v\""
}

# _cfg_value_len TEXT → _CFG_VL: how many characters of TEXT (what follows
# KEY= on a line the reader accepted) the value takes: quoted segments are
# skipped whole, the value ends at the first blank outside quotes. What is left
# is blanks and an end-of-line comment.
_cfg_value_len() {
    local s="$1" i=0 n="${#1}" c rest sq="'"
    while (( i < n )); do
        c="${s:i:1}"
        case "$c" in
            ' '|$'\t') break ;;
            "$sq")
                rest="${s:i+1}"
                if [[ "$rest" != *"$sq"* ]]; then i=$n; break; fi
                rest="${rest%%"$sq"*}"; i=$(( i + ${#rest} + 2 )) ;;
            '"')
                i=$((i+1))
                while (( i < n )); do
                    c="${s:i:1}"
                    if [[ "$c" == '\' ]]; then i=$((i+2))
                    elif [[ "$c" == '"' ]]; then i=$((i+1)); break
                    else i=$((i+1)); fi
                done ;;
            '\') i=$((i+2)) ;;
            *) i=$((i+1)) ;;
        esac
    done
    (( i <= n )) || i=$n
    _CFG_VL="$i"
}

# _cfg_line_key LINE: an assignment line ([blanks][export ]KEY=...) → _CFG_LK
# (the key) and _CFG_LP (the length of the line up to and including the =).
# Returns 1 for anything else (blank, comment).
_cfg_line_key() {
    local l="$1" t p
    _CFG_LK='' _CFG_LP=0
    t="${l#"${l%%[![:blank:]]*}"}"
    if [[ "$t" == export[[:blank:]]* ]]; then t="${t:6}"; t="${t#"${t%%[![:blank:]]*}"}"; fi
    [[ "$t" == [A-Za-z_]*=* ]] || return 1
    p="${t%%=*}"
    [[ "$p" != *[!A-Za-z0-9_]* ]] || return 1
    _CFG_LK="$p"; _CFG_LP=$(( ${#l} - ${#t} + ${#p} + 1 ))
}

# _cfgw_newline LINE PREFIXLEN NEW → _CFGW_NL: NEW (the new [prefix]KEY=VALUE)
# in place of LINE, an assignment or a commented template line whose first
# PREFIXLEN characters end with KEY=. LINE's end-of-line comment is kept at its
# column (the template aligns them), or two blanks after a longer value.
_cfgw_newline() {
    local l="$1" lp="$2" rest tail c col
    rest="${l:lp}"
    _cfg_value_len "$rest"
    tail="${rest:_CFG_VL}"
    c="${tail#"${tail%%[![:blank:]]*}"}"
    _CFGW_NL="$3"
    [[ "$c" == '#'* ]] || return 0
    col=$(( lp + _CFG_VL + ${#tail} - ${#c} ))
    if (( ${#_CFGW_NL} < col )); then printf -v _CFGW_NL '%-*s%s' "$col" "$_CFGW_NL" "$c"
    else _CFGW_NL+="  $c"; fi
}

# _cfgw_set KEY VALUE: in _CFGW_L (the file's lines), KEY's last active line
# gets the new value in place (an earlier one, which never counted, goes); else
# a commented template line #KEY=... becomes it; else the line goes under the
# schema section's "# --- <title> ---" header, or at the end.
_cfgw_set() {
    local k="$1" i tpl=-1 last l line keep=() title h=-1 n p
    _cfg_qval "$2"
    for i in "${!_CFGW_L[@]}"; do
        l="${_CFGW_L[i]}"
        if [[ "$l" == "#$k="* ]]; then (( tpl >= 0 )) || tpl=$i; continue; fi
        if _cfg_line_key "$l" && [[ "$_CFG_LK" == "$k" ]]; then last=$i; keep+=("$i"); fi
    done
    if (( ${#keep[@]} )); then
        _cfg_line_key "${_CFGW_L[last]}"
        # the prefix (blanks, export) stays as written
        line="${_CFGW_L[last]}"; line="${line:0:_CFG_LP-${#k}-1}"
        _cfgw_newline "${_CFGW_L[last]}" "$_CFG_LP" "$line$k=$_CFG_Q"
        _CFGW_L[last]="$_CFGW_NL"
        unset 'keep[-1]'
        for i in "${keep[@]+"${keep[@]}"}"; do unset "_CFGW_L[$i]"; done
        _CFGW_L=("${_CFGW_L[@]+"${_CFGW_L[@]}"}")
        return 0
    fi
    if (( tpl >= 0 )); then
        _cfgw_newline "${_CFGW_L[tpl]}" $(( ${#k} + 2 )) "$k=$_CFG_Q"
        _CFGW_L[tpl]="$_CFGW_NL"
        return 0
    fi
    line="$k=$_CFG_Q"
    # a proxy variable only takes effect exported (lib/config_parse.sh)
    _cs_has "$k" || ! _cfg_export_allowed "$k" || line="export $line"
    if _cs_has "$k"; then title="$(_cfg_section_title "${CS_SECTION[$k]}")"; else title=''; fi
    n="${#_CFGW_L[@]}"
    if [[ -n "$title" ]]; then
        for i in "${!_CFGW_L[@]}"; do [[ "${_CFGW_L[i]}" == "# --- $title ---" ]] && { h=$i; break; }; done
    fi
    if (( h < 0 )); then _CFGW_L+=("$line"); return 0; fi
    for (( i = h + 1; i < ${#_CFGW_L[@]}; i++ )); do
        [[ "${_CFGW_L[i]}" == '# --- '*' ---' ]] && { n=$i; break; }
    done
    p=$h
    for (( i = h + 1; i < n; i++ )); do [[ "${_CFGW_L[i]}" == *[![:blank:]]* ]] && p=$i; done
    _CFGW_L=("${_CFGW_L[@]:0:p+1}" "$line" "${_CFGW_L[@]:p+1}")
    return 0
}

# _cfgw_unset KEY: every active line of KEY goes (an earlier one would count
# once the last is gone); comments and a #KEY= template line stay.
_cfgw_unset() {
    local k="$1" i
    for i in "${!_CFGW_L[@]}"; do
        _cfg_line_key "${_CFGW_L[i]}" && [[ "$_CFG_LK" == "$k" ]] && unset "_CFGW_L[$i]"
    done
    _CFGW_L=("${_CFGW_L[@]+"${_CFGW_L[@]}"}")
}

# _cfg_file_value FILE KEY: KEY's value in FILE alone, as the strict reader reads
# it (empty when FILE does not set it or cannot be read). A subshell: the
# reader's results of load_config stay as they are.
_cfg_file_value() {
    [[ -r "$1" ]] || return 0
    ( _cfg_reset; _cfg_parse_file "$1" local >/dev/null 2>&1 || true; printf '%s' "${CFG_VAL[$2]-}" )
}

# _cfgw_strip TEXT: TEXT without the record separators the writer's results use.
_cfgw_strip() { _CFGW_S="${1//[$'\x1e\x1f']/}"; }

# _cfgv_effective → _CFGV_E[KEY]: every schema key's effective value from what
# the reader holds now (CFG_VAL), the way load_config gives it: the environment
# snapshot, then the files, then the defaults. Run in a subshell only: it
# reassigns the schema keys.
_cfgv_effective() {
    local k
    for k in "${CS_ORDER[@]}"; do
        if [[ -n "${CFG_ENV[$k]+x}" ]]; then printf -v "$k" '%s' "${CFG_ENV[$k]}"; else unset -v "$k"; fi
    done
    _cfg_apply
    set_defaults
    declare -gA _CFGV_E=()
    for k in "${CS_ORDER[@]}"; do _CFGV_E[$k]="${!k-}"; done
}

# _cfg_verify TARGET CANDIDATE: read the config files the way load_config does,
# once as they are and once with CANDIDATE in place of TARGET, and check the
# candidate before it replaces TARGET: the strict reader accepts it, every set
# key (CFGW_OPS / CFGW_KEYS / CFGW_VALS) reads as the value given, every unset
# key is no longer set by it, every other key reads as before, and bash, sourcing
# the files up to it in a clean subshell (_cfg_compare_bash), agrees with the
# reader on every key the change gives or whose bash reading it changes (a
# difference the files had before, such as a CRLF line, is reported, not
# refused). Run in $(...): it changes the reader's results and the schema keys.
# Prints records (US-separated fields, RS-terminated):
#   ERR msg                           a reason to refuse the candidate (exit 1)
#   WARN msg                          a bash difference the files had before
#   FILE key had before has after     the key's value in TARGET itself
#   EFF key before after              an effective value that changes (or an op key)
#   OVR key file                      a set key a file read after TARGET overrides
_cfg_verify() {
    local target="$1" cand="$2" i i2 f k t tpos=-1 ok=1 e fb fa
    local -a files=() origins=() pre=()
    local -A av=() as=() eb=() isop=() skip=() bd=() bb=() bbs=() bf=()
    _cfg_config_files
    for i in "${!_CFG_FPATH[@]}"; do
        f="${_CFG_FPATH[i]}"
        if [[ "$f" == "$target" ]]; then tpos=${#files[@]}
        else
            [[ -f "$f" ]] || continue
            [[ "${_CFG_FORIGIN[i]}" != shared || "$EUID" == 0 || -r "$f" ]] || continue
        fi
        files+=("$f"); origins+=("${_CFG_FORIGIN[i]}")
    done
    if (( tpos < 0 )); then printf 'ERR\x1f%s is not a file pbo reads\x1e' "$target"; return 1; fi
    for i in "${!CFGW_KEYS[@]}"; do isop[${CFGW_KEYS[i]}]=1; done
    # a new file starts with PBO_CONFIG_VERSION (_cfg_write_locked)
    (( ${CFGW_CREATED:-0} == 0 )) || skip[PBO_CONFIG_VERSION]=1
    # as it is: the values up to TARGET, the effective ones after every file
    _cfg_reset
    for i in "${!files[@]}"; do
        if (( i != tpos )) || [[ -f "$target" ]]; then _cfg_parse_file "${files[i]}" "${origins[i]}" || true; fi
        if (( i == tpos )); then
            for k in "${!CFG_VAL[@]}"; do av[$k]="${CFG_VAL[$k]}"; t="${CFG_SRC[$k]#*:}"; as[$k]="${t%:*}"; done
            # what bash makes of the files as they are: a difference already
            # there (a CRLF line, which load_config only warns about, in this
            # file or one read before it) must not block every change; only
            # what the candidate changes is refused below
            PBO_CONFIG_FILES=()
            for (( i2 = 0; i2 <= tpos; i2++ )); do
                (( i2 != tpos )) || [[ -f "$target" ]] || continue
                PBO_CONFIG_FILES+=("${files[i2]}")
            done
            _cfg_compare_bash
            for k in "${CFG_DIFF[@]+"${CFG_DIFF[@]}"}"; do bd[$k]=1; done
            for k in "${!CFG_BASH[@]}"; do bb[$k]="${CFG_BASH[$k]}"; done
            for k in "${!CFG_BASH_SET[@]}"; do bbs[$k]="${CFG_BASH_SET[$k]}"; done
            for e in "${CFG_BASH_FAIL[@]+"${CFG_BASH_FAIL[@]}"}"; do bf[${e%%$'\x1f'*}]=1; done
        fi
    done
    _cfgv_effective
    for k in "${CS_ORDER[@]}"; do eb[$k]="${_CFGV_E[$k]}"; done
    # with the candidate
    _cfg_reset
    for i in "${!files[@]}"; do
        f="${files[i]}"; (( i == tpos )) && f="$cand"
        pre+=("$f")
        _cfg_parse_file "$f" "${origins[i]}" || true
        (( i == tpos )) || continue
        for e in "${CFG_ERRORS[@]+"${CFG_ERRORS[@]}"}"; do
            _cfgw_strip "${e//"$cand"/$target}"; printf 'ERR\x1f%s\x1e' "$_CFGW_S"; ok=0
        done
        (( ok )) || return 1
        for i2 in "${!CFGW_KEYS[@]}"; do
            k="${CFGW_KEYS[i2]}"; t="${CFG_SRC[$k]-}"; t="${t#*:}"; t="${t%:*}"
            if [[ "${CFGW_OPS[i2]}" == set ]]; then
                if [[ "$t" != "$cand" || "${CFG_VAL[$k]-}" != "${CFGW_VALS[i2]}" ]]; then
                    printf 'ERR\x1f%s would not read back as the value given\x1e' "$k"; ok=0
                fi
            elif [[ "$t" == "$cand" ]]; then
                printf 'ERR\x1f%s would still be set in %s\x1e' "$k" "$target"; ok=0
            fi
            fb=0; [[ "${as[$k]-}" == "$target" ]] && fb=1
            fa=0; [[ "$t" == "$cand" ]] && fa=1
            _cfgw_strip "${av[$k]-}"; e="$_CFGW_S"; _cfgw_strip "${CFG_VAL[$k]-}"
            (( fb )) || e=''; (( fa )) || _CFGW_S=''
            printf 'FILE\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1e' "$k" "$fb" "$e" "$fa" "$_CFGW_S"
        done
        # nothing else may change: every other key as before
        for k in "${!av[@]}" "${!CFG_VAL[@]}"; do
            [[ -z "${isop[$k]+x}" && -z "${skip[$k]+x}" ]] || continue
            if [[ "${av[$k]+x}" != "${CFG_VAL[$k]+x}" || "${av[$k]-}" != "${CFG_VAL[$k]-}" ]]; then
                printf 'ERR\x1f%s would read differently after the change\x1e' "$k"; ok=0
            fi
        done
        (( ok )) || return 1
        # bash sources the files up to the candidate as pbo 0.5 did: the same values
        PBO_CONFIG_FILES=("${pre[@]}")
        _cfg_compare_bash
        # refused: the candidate itself, or a file bash read as it is before;
        # one that failed before already (another file) is left as it is
        for e in "${CFG_BASH_FAIL[@]+"${CFG_BASH_FAIL[@]}"}"; do
            f="${e%%$'\x1f'*}"
            if [[ "$f" == "$cand" || -z "${bf[$f]+x}" ]]; then
                printf 'ERR\x1fbash cannot read the new file the way pbo does (%s)\x1e' "${e##*$'\x1f'}"; ok=0
            else
                _cfgw_strip "$f"; printf 'WARN\x1fbash cannot read %s the way pbo does (%s), as before the change\x1e' "$_CFGW_S" "${e##*$'\x1f'}"
            fi
        done
        # refused: a key given, or one whose bash reading the candidate changes
        for k in "${CFG_DIFF[@]+"${CFG_DIFF[@]}"}"; do
            if [[ -n "${isop[$k]+x}" || -z "${bd[$k]+x}" || "${CFG_BASH[$k]-}" != "${bb[$k]-}" || "${CFG_BASH_SET[$k]-}" != "${bbs[$k]-}" ]]; then
                printf 'ERR\x1f%s would read differently when bash sources the file\x1e' "$k"; ok=0
            else
                printf 'WARN\x1f%s reads differently when bash sources the files, as before the change (pbo config check --compare-bash)\x1e' "$k"
            fi
        done
        (( ok )) || return 1
    done
    for k in "${CFGW_KEYS[@]}"; do
        t="${CFG_SRC[$k]-}"; t="${t#*:}"; t="${t%:*}"
        [[ -z "$t" || "$t" == "$cand" ]] || printf 'OVR\x1f%s\x1f%s\x1e' "$k" "$t"
    done
    _cfgv_effective
    for k in "${CS_ORDER[@]}"; do
        [[ "${eb[$k]}" != "${_CFGV_E[$k]}" || -n "${isop[$k]+x}" ]] || continue
        _cfgw_strip "${eb[$k]}"; e="$_CFGW_S"; _cfgw_strip "${_CFGV_E[$k]}"
        printf 'EFF\x1f%s\x1f%s\x1f%s\x1e' "$k" "$e" "$_CFGW_S"
    done
    return 0
}

# _cfg_diff_mask: a unified diff of a config on stdin, on stdout with the values
# of secret and unknown keys replaced by <hidden> (commented lines too) and
# credentials in URLs masked.
_cfg_diff_mask() {
    local l c body t n=0 lp
    while IFS= read -r l; do
        n=$((n+1))
        if (( n <= 2 )) || [[ "$l" == '@@'* || "$l" == '\'* ]]; then printf '%s\n' "$l"; continue; fi
        c="${l:0:1}" body="${l:1}" t="$body" lp=0
        [[ "$t" == '#'* ]] && { t="${t:1}"; lp=1; }
        if _cfg_line_key "$t" && _config_is_secret "$_CFG_LK"; then
            printf '%s%s<hidden>\n' "$c" "${body:0:lp+_CFG_LP}"
        else
            printf '%s\n' "$(_mask_url "$l")"
        fi
    done
    return 0
}

# _cfg_lock / _cfg_unlock: LOCK_DIR/pbo.config, one writer at a time; busy is
# exit 75 at once (a config change is short; waiting would hide a stuck one).
# On a janitor run as root, the config's own directory instead: LOCK_DIR there
# belongs to JANITOR_USER, who could swap the lock file for a symlink (root
# would create or open any path) or a FIFO (root's open would block) between
# any check and the open. Only root takes this lock on a janitor (config
# set|unset stay root, every other command runs as JANITOR_USER), and the
# config's directory is root's: a read fd on it creates nothing and follows
# no link another user planted.
_cfg_lock() {
    [[ "${CFG_LOCK_HELD:-0}" == 1 ]] && return 0
    local f="${LOCK_DIR%/}/pbo.config" d u m
    if [[ "${PBO_ROLE:-host}" == janitor && "$EUID" == 0 ]]; then
        d="$(dirname -- "${PBO_CONFIG_LOCAL:-/etc/pbo/config}")"
        if [[ -L "$d" || ! -d "$d" ]]; then CFGW_ERR="cannot lock the config: $d is not a directory"; return "$EX_CANTCREAT"; fi
        read -r u m < <(stat -c '%u %a' -- "$d" 2>/dev/null) || u=''
        if [[ "$u" != 0 || ! "$m" =~ ^[0-7]+$ ]] || (( 8#$m & 8#022 )); then
            CFGW_ERR="cannot lock the config: $d is not root's alone (owner uid ${u:-?}, mode ${m:-?}): it must be owned by root and not group- or world-writable"
            return "$EX_CANTCREAT"
        fi
        { exec {CFG_LOCK_FD}<"$d"; } 2>/dev/null || { CFGW_ERR="cannot open $d to lock the config"; return "$EX_CANTCREAT"; }
        if ! flock -n "$CFG_LOCK_FD"; then
            exec {CFG_LOCK_FD}>&-; CFG_LOCK_FD=''
            CFGW_ERR="another config change is running (lock on $d busy): try again"; return "$EX_TEMPFAIL"
        fi
        CFG_LOCK_HELD=1; return 0
    fi
    [[ -d "$LOCK_DIR" ]] || { mkdir -p -- "$LOCK_DIR" && chmod 0700 -- "$LOCK_DIR"; } 2>/dev/null || true
    # root writes it; a symlink there could point anywhere
    if [[ -L "$f" ]]; then CFGW_ERR="the config lock $f is a symlink: remove it"; return "$EX_CANTCREAT"; fi
    # (in braces: on a bare exec, 2>/dev/null would silence stderr for good)
    { exec {CFG_LOCK_FD}>>"$f"; } 2>/dev/null || { CFGW_ERR="cannot open the config lock $f"; return "$EX_CANTCREAT"; }
    if ! flock -n "$CFG_LOCK_FD"; then
        exec {CFG_LOCK_FD}>&-; CFG_LOCK_FD=''
        CFGW_ERR="another config change is running (lock $f busy): try again"; return "$EX_TEMPFAIL"
    fi
    CFG_LOCK_HELD=1
}
_cfg_unlock() {
    [[ "${CFG_LOCK_HELD:-0}" == 1 ]] || return 0
    [[ -z "${CFG_LOCK_FD:-}" ]] || exec {CFG_LOCK_FD}>&-
    CFG_LOCK_FD='' CFG_LOCK_HELD=0
}

# _cfgw_new_perms: owner, group and mode a new local config file and its
# directory get, from the permission table (lib/perms.sh: host 0600 root:root in
# a 0700 directory; janitor 0640 root:<JANITOR_USER> in 0750) → _CFGW_PF
# ("owner group mode") and _CFGW_PD.
_cfgw_new_perms() {
    local n k ow gr ms rest
    _CFGW_PF='root - 0600' _CFGW_PD='root - 0700'
    _perm_ensure
    while IFS='|' read -r n k ow gr ms rest; do
        ms="${ms#<}"; ms="${ms%%/*}"; ow="${ow%\?}"
        case "$n:$k" in
            config:file) _CFGW_PF="$ow $gr $ms" ;;
            config/..:dir) _CFGW_PD="$ow $gr $ms" ;;
        esac
    done < <(_perm_rules "${PBO_ROLE:-host}")
    return 0
}

# _cfgw_apply_perms <path> "<owner> <group> <mode>": what _cfgw_new_perms gives,
# owners only as root; a group that does not exist is named, not invented.
_cfgw_apply_perms() {
    local p="$1" ow gr ms
    read -r ow gr ms <<<"$2"
    chmod "$ms" -- "$p" || return 1
    (( EUID == 0 )) || return 0
    [[ "$ow" == - ]] || chown "$ow" -- "$p" || return 1
    if [[ "$gr" != - ]]; then
        if getent group "$gr" >/dev/null 2>&1; then chgrp "$gr" -- "$p" || return 1
        else log_warn "config: group $gr does not exist: $p keeps group root (the janitor user cannot read it)"; fi
    fi
    return 0
}

# _cfgw_copy_acl OLD NEW: OLD's extended ACL (entries beyond owner, group and
# other, e.g. a monitoring user's read access) onto NEW, which replaces it. The
# whole ACL is set, so NEW's group bits become the mask again (stat %a, which
# the mode copy used, shows the mask there). Returns 1 when OLD has one that
# cannot be copied: dropped without a word, that reader would lose access.
_cfgw_copy_acl() {
    local old="$1" new="$2" l
    if command -v getfacl >/dev/null 2>&1; then
        [[ -n "$(getfacl -cp --skip-base -- "$old" 2>/dev/null)" ]] || return 0
        command -v setfacl >/dev/null 2>&1 || return 1
        getfacl -cp -- "$old" 2>/dev/null | setfacl --set-file=- -- "$new" 2>/dev/null
        return
    fi
    # without getfacl: ls marks a file that has one with a trailing +
    l="$(ls -ld -- "$old" 2>/dev/null)"; l="${l%% *}"
    [[ "$l" != *+ ]]
}

# _cfgw_unchanged FILE LINESVAR: FILE still holds the lines in the array named
# LINESVAR (as _cfg_write_locked read it), or still does not exist when the
# change creates it.
_cfgw_unchanged() {
    local f="$1" i
    local -n _cfgw_ref="$2"
    local -a cur=()
    if (( CFGW_CREATED )); then [[ ! -e "$f" ]]; return; fi
    [[ -f "$f" ]] || return 1
    { mapfile -t cur < "$f"; } 2>/dev/null || return 1
    (( ${#cur[@]} == ${#_cfgw_ref[@]} )) || return 1
    for i in "${!cur[@]}"; do [[ "${cur[i]}" == "${_cfgw_ref[i]}" ]] || return 1; done
    return 0
}

# _cfg_shared_check TARGET: --shared needs the cluster filesystem. Never on a
# janitor (no Proxmox: /etc/pve there is a plain directory, and the "shared"
# file would be a stray layer only that host reads), and the shared file must
# lie on the mounted pmxcfs (PBO_PVE_CFS_DIR, /etc/pve, which has .members or
# .version): with pve-cluster stopped a file written there lands in the
# directory under the mount point, hidden once pmxcfs mounts, and no other node
# sees it. → _CFG_SHERR and _CFG_SHRC (the exit code); returns 1 when refused.
_cfg_shared_check() {
    local target="$1" cfs="${PBO_PVE_CFS_DIR:-/etc/pve}"
    while [[ "$cfs" == */ && "$cfs" != / ]]; do cfs="${cfs%/}"; done
    _CFG_SHERR='' _CFG_SHRC=0
    if [[ "${PBO_ROLE:-host}" == janitor ]]; then
        _CFG_SHERR="a janitor has no Proxmox cluster filesystem: set it in the local config (without --shared); nothing was written"
        _CFG_SHRC="$EX_USAGE"; return 1
    fi
    if [[ "$target" != "$cfs"/* ]]; then
        _CFG_SHERR="$target is not on the cluster filesystem $cfs: nothing was written"; _CFG_SHRC="$EX_UNAVAILABLE"; return 1
    fi
    if [[ ! -e "$cfs/.members" && ! -e "$cfs/.version" ]]; then
        _CFG_SHERR="$cfs is not the mounted cluster filesystem (is pve-cluster running?): nothing was written"; _CFG_SHRC="$EX_UNAVAILABLE"; return 1
    fi
    return 0
}

# _cfg_write [--shared] [--hooks] (set KEY VALUE | unset KEY)...: one
# transaction on the local config (PBO_CONFIG_LOCAL), or with --shared on the
# cluster-shared one. The caller has validated the keys and values. --hooks runs
# the hooks that must pass before the file is replaced (move-cache). DRY_RUN=1:
# everything but the replace (the candidate is checked in a temp file).
# Results: CFGW_FILE, CFGW_CHANGED (the file's text changes), CFGW_WRITTEN,
# CFGW_CREATED, CFGW_DIFF (masked), CFGW_KEYS/OPS/VALS (the ops),
# CFGW_FB/CFGW_FA[key] ("1<US>value" when TARGET sets it, before and after),
# CFGW_EB/CFGW_EA[key] (effective values that change, and those of the op keys),
# CFGW_OVR[key] (a later file that overrides a set key), CFGW_WARNS (bash
# differences the files had before, logged as warnings). Returns 0, or an exit
# code with the reason in CFGW_ERR; nothing is changed then.
_cfg_write() {
    local shared=0 hooks=0
    while [[ "${1:-}" == --* ]]; do
        case "$1" in --shared) shared=1 ;; --hooks) hooks=1 ;; *) CFGW_ERR="internal: _cfg_write $1"; return "$EX_SOFTWARE" ;; esac
        shift
    done
    CFGW_ERR='' CFGW_FILE='' CFGW_CHANGED=0 CFGW_WRITTEN=0 CFGW_CREATED=0 CFGW_DIFF=''
    declare -ga CFGW_KEYS=() CFGW_OPS=() CFGW_VALS=() CFGW_WARNS=()
    declare -gA CFGW_FB=() CFGW_FA=() CFGW_EB=() CFGW_EA=() CFGW_OVR=()
    while (( $# )); do
        case "$1" in
            set)   [[ $# -ge 3 ]] || { CFGW_ERR='internal: set KEY VALUE'; return "$EX_SOFTWARE"; }
                   CFGW_OPS+=(set); CFGW_KEYS+=("$2"); CFGW_VALS+=("$3"); shift 3 ;;
            unset) [[ $# -ge 2 ]] || { CFGW_ERR='internal: unset KEY'; return "$EX_SOFTWARE"; }
                   CFGW_OPS+=(unset); CFGW_KEYS+=("$2"); CFGW_VALS+=(''); shift 2 ;;
            *) CFGW_ERR="internal: _cfg_write op '$1'"; return "$EX_SOFTWARE" ;;
        esac
    done
    # load_config's state: the files, their order, the environment snapshot
    if [[ -z "${LOCK_DIR:-}" ]] || ! declare -p CFG_ENV >/dev/null 2>&1; then
        CFGW_ERR='internal: _cfg_write needs load_config first'; return "$EX_SOFTWARE"
    fi
    _cs_load
    local target='' i origin=local cfs="${PBO_PVE_CFS_DIR:-/etc/pve}"
    _cfg_config_files
    for i in "${!_CFG_FPATH[@]}"; do
        if (( shared )); then [[ "${_CFG_FORIGIN[i]}" == shared ]] && { target="${_CFG_FPATH[i]}"; origin=shared; }
        else [[ "${_CFG_FORIGIN[i]}" == local ]] && target="${_CFG_FPATH[i]}"; fi
    done
    if [[ -z "$target" ]]; then
        if (( shared )); then CFGW_ERR="there is no cluster-shared config: with PBO_CONFIG set pbo reads that file alone"; return "$EX_USAGE"; fi
        CFGW_ERR='internal: no local config file'; return "$EX_SOFTWARE"
    fi
    CFGW_FILE="$target"
    if (( shared )); then _cfg_shared_check "$target" || { CFGW_ERR="$_CFG_SHERR"; return "$_CFG_SHRC"; }; fi
    if [[ -L "$target" ]]; then
        CFGW_ERR="$target is a symlink: pbo replaces the file and would replace the link; point PBO_CONFIG at the file itself"; return "$EX_CANTCREAT"
    fi
    if [[ -e "$target" && ! -f "$target" ]]; then CFGW_ERR="$target is not a regular file"; return "$EX_CANTCREAT"; fi
    local dry="${DRY_RUN:-0}" rc=0
    if [[ "$dry" != 1 ]]; then _cfg_lock || return $?; fi
    _cfg_write_locked "$target" "$origin" "$hooks" "$cfs" || rc=$?
    _cfg_unlock
    return "$rc"
}

# _cfg_write_locked TARGET ORIGIN HOOKS CFS: _cfg_write's work under the lock.
_cfg_write_locked() {
    local target="$1" origin="$2" hooks="$3" cfs="$4" dry="${DRY_RUN:-0}" dir tmp st u g m i k out rec rc=0
    local -a orig=()
    _CFGW_L=()
    if [[ -f "$target" ]]; then
        { mapfile -t _CFGW_L < "$target"; } 2>/dev/null || { CFGW_ERR="cannot read $target"; return "$EX_CANTCREAT"; }
    else
        CFGW_CREATED=1
        _CFGW_L=("# pbo config: KEY=VALUE lines, read by pbo (never run as code); 'pbo config list' shows every key" "PBO_CONFIG_VERSION=${PBO_CONFIG_SCHEMA:-1}")
    fi
    orig=("${_CFGW_L[@]+"${_CFGW_L[@]}"}")
    for i in "${!CFGW_KEYS[@]}"; do
        if [[ "${CFGW_OPS[i]}" == set ]]; then _cfgw_set "${CFGW_KEYS[i]}" "${CFGW_VALS[i]}"
        else _cfgw_unset "${CFGW_KEYS[i]}"; fi
    done
    if (( ! CFGW_CREATED )) && [[ "${#orig[@]}" == "${#_CFGW_L[@]}" ]]; then
        CFGW_CHANGED=0
        for i in "${!orig[@]}"; do [[ "${orig[i]}" == "${_CFGW_L[i]}" ]] || { CFGW_CHANGED=1; break; }; done
    else
        CFGW_CHANGED=1
    fi
    # an unset of a key a new file would not have: nothing to create
    if (( CFGW_CREATED )) && [[ " ${CFGW_OPS[*]} " != *" set "* ]]; then CFGW_CHANGED=0; fi
    (( CFGW_CHANGED )) || return 0

    dir="$(dirname -- "$target")"
    if [[ "$dry" == 1 ]]; then
        # nothing next to the config, not even a temp file
        tmp="$(mktemp "${TMPDIR:-/tmp}/pbo-config.XXXXXX")" || { CFGW_ERR="cannot create a temp file"; return "$EX_CANTCREAT"; }
    else
        if [[ ! -d "$dir" ]]; then
            # the local config's directory as the permission table says; pmxcfs
            # (the cluster-shared file) has fixed modes of its own
            if [[ "$origin" == local && "$dir" != "$cfs" && "$dir" != "$cfs"/* ]]; then
                _cfgw_new_perms
                mkdir -p -- "$dir" && _cfgw_apply_perms "$dir" "$_CFGW_PD" || { CFGW_ERR="cannot create $dir"; return "$EX_CANTCREAT"; }
            else
                mkdir -p -- "$dir" || { CFGW_ERR="cannot create $dir"; return "$EX_CANTCREAT"; }
            fi
        fi
        tmp="$(mktemp "$dir/.${target##*/}.pbo.XXXXXX")" || { CFGW_ERR="cannot write in $dir"; return "$EX_CANTCREAT"; }
    fi
    CFGW_TMP="$tmp"
    if (( ${#_CFGW_L[@]} )); then printf '%s\n' "${_CFGW_L[@]}" > "$tmp" || rc=1; else : > "$tmp" || rc=1; fi
    if (( rc )); then rm -f -- "$tmp"; CFGW_TMP=''; CFGW_ERR="cannot write $tmp"; return "$EX_CANTCREAT"; fi
    # owner, group and mode: the old file's (a janitor's 0640 root:<user> stays),
    # a new one's from the permission table; pmxcfs keeps its own
    if [[ "$dry" != 1 && "$target" != "$cfs"/* ]]; then
        if (( ! CFGW_CREATED )); then
            st="$(stat -c '%u %g %a' -- "$target")" && read -r u g m <<<"$st" \
                && chmod "$m" -- "$tmp" && chown "$u:$g" -- "$tmp" 2>/dev/null \
                && [[ "$(stat -c '%u %g' -- "$tmp")" == "$u $g" ]] || rc=1
            if (( ! rc )) && ! _cfgw_copy_acl "$target" "$tmp"; then
                rm -f -- "$tmp"; CFGW_TMP=''
                CFGW_ERR="$target has an extended ACL that pbo cannot copy to the new file (getfacl/setfacl missing or failing): install the acl package, or remove the ACL (setfacl -b); nothing was changed"
                return "$EX_CANTCREAT"
            fi
        elif [[ "$origin" == local ]]; then
            _cfgw_new_perms; _cfgw_apply_perms "$tmp" "$_CFGW_PF" || rc=1
        fi
        if (( rc )); then rm -f -- "$tmp"; CFGW_TMP=''; CFGW_ERR="cannot give the new file the owner and mode of $target; nothing was changed"; return "$EX_CANTCREAT"; fi
    fi
    local old="$target"; [[ -f "$target" ]] || old=/dev/null
    # (diff exits 1 when the files differ, which they do)
    CFGW_DIFF="$(diff -u --label "$target" --label "$target (new)" -- "$old" "$tmp" 2>/dev/null | _cfg_diff_mask)" || true

    # read it back: the strict reader and bash, as load_config would read it
    out="$(_cfg_verify "$target" "$tmp")" || rc=1
    local -a errs=()
    while [[ "$out" == *$'\x1e'* ]]; do
        rec="${out%%$'\x1e'*}"; out="${out#*$'\x1e'}"
        local f1 f2 f3 f4 f5
        IFS=$'\x1f' read -r _ f1 f2 f3 f4 f5 <<<"$rec"
        case "${rec%%$'\x1f'*}" in
            ERR)  errs+=("$f1") ;;
            WARN) CFGW_WARNS+=("$f1") ;;
            FILE) [[ "$f2" == 1 ]] && CFGW_FB[$f1]="$f3"; [[ "$f4" == 1 ]] && CFGW_FA[$f1]="$f5" ;;
            EFF)  CFGW_EB[$f1]="$f2"; CFGW_EA[$f1]="$f3" ;;
            OVR)  CFGW_OVR[$f1]="$f2" ;;
        esac
    done
    if (( rc )) || (( ${#errs[@]} )); then
        rm -f -- "$tmp"; CFGW_TMP=''
        CFGW_ERR="the new $target would not read as intended, nothing was changed: ${errs[0]:-the check failed}"
        (( ${#errs[@]} <= 1 )) || CFGW_ERR+=" (and $(( ${#errs[@]} - 1 )) more)"
        return "$EX_CONFIG"
    fi
    for i in "${CFGW_WARNS[@]+"${CFGW_WARNS[@]}"}"; do log_warn "config: $i"; done
    if (( hooks )); then
        _cfg_hooks_pre || { rc=$?; rm -f -- "$tmp"; CFGW_TMP=''; return "$rc"; }
    fi
    if [[ "$dry" == 1 ]]; then rm -f -- "$tmp"; CFGW_TMP=''; return 0; fi
    # the config lock is per node, the cluster-shared file is not: another
    # node may have replaced it since it was read. Its change would be lost
    # under this rename, so this one is not made (the window left is the
    # instant between this read and the rename)
    if [[ "$origin" == shared ]] && ! _cfgw_unchanged "$target" orig; then
        rm -f -- "$tmp"; CFGW_TMP=''
        CFGW_ERR="$target was changed on another node while this change was prepared; nothing was changed: try again"; return "$EX_TEMPFAIL"
    fi
    # durable before it is visible, the rename itself durable after
    sync -- "$tmp" 2>/dev/null || sync
    if ! mv -f -- "$tmp" "$target"; then
        rm -f -- "$tmp"; CFGW_TMP=''; CFGW_ERR="cannot replace $target; nothing was changed"; return "$EX_CANTCREAT"
    fi
    CFGW_TMP=''
    sync -- "$dir" 2>/dev/null || true
    CFGW_WRITTEN=1
    # this process's own change is no reason for it to start again when it
    # takes a lock later (lib/lock.sh _lock_config_changed)
    PBO_START_US="${EPOCHREALTIME//[!0-9]/}"
    [[ "$target" != "${PBO_CONFIG_LOCAL:-}" ]] || PBO_START_ID="$(stat -c '%d:%i' -- "$target" 2>/dev/null)" || PBO_START_ID=''
    return 0
}

# --- on_change hooks (lib/config_schema.sh) ----------------------------------------------
# A key's on_change flag names what changing its effective value implies. Two
# run before the file is replaced and can stop the change: confirm-repo (in
# _config_change_cmd, before the lock: a question) and move-cache (in
# _cfg_write, under the lock). Two run after a successful write:
# restart-mount and apply-schedule (the timer drop-ins). (PBO_INTEGRATION has none: it is managed, written only by
# `pbo integrate`, which converges PVE's side itself.) A key whose value
# changes because one it follows changed (RESTIC_CACHE_REPO under CACHE_DIR)
# counts, except for confirm-repo, which asks about the keys given. Results:
# CFGH ("hook<US>status<US>message"; status ok, skipped, would, failed).

_cfgh() { CFGH+=("$1"$'\x1f'"$2"$'\x1f'"$3"); }

# _cfg_hooks_for KEY → _CFG_HOOK: KEY's on_change hook, or empty.
_cfg_hooks_for() { _CFG_HOOK="$(_cs_flag "$1" on_change)" || _CFG_HOOK=''; }

# _cfg_hooks_pre: the hooks that must pass before the file is replaced.
_cfg_hooks_pre() {
    local k
    for k in "${!CFGW_EA[@]}"; do
        [[ "${CFGW_EB[$k]}" != "${CFGW_EA[$k]}" ]] || continue
        _cfg_hooks_for "$k"
        case "$_CFG_HOOK" in
            move-cache) _cfg_hook_move_cache "${CFGW_EB[$k]}" "${CFGW_EA[$k]}" || return $? ;;
        esac
    done
    return 0
}

# _cfg_hooks_post: after a successful write (or a dry run), each hook once.
# Returns 1 when one failed (the config is written all the same).
_cfg_hooks_post() {
    local k done=' ' rc=0
    for k in "${CS_ORDER[@]}"; do
        [[ -n "${CFGW_EA[$k]+x}" && "${CFGW_EB[$k]}" != "${CFGW_EA[$k]}" ]] || continue
        _cfg_hooks_for "$k"
        [[ -n "$_CFG_HOOK" && "$done" != *" $_CFG_HOOK "* ]] || continue
        case "$_CFG_HOOK" in
            restart-mount) done+="$_CFG_HOOK "; _cfg_hook_restart_mount || rc=1 ;;
            apply-schedule) done+="$_CFG_HOOK "; _cfg_hook_apply_schedule || rc=1 ;;
        esac
    done
    return "$rc"
}

# _cfg_hook_apply_schedule: a timer schedule (SCHEDULE_*) changed: the drop-ins
# of the timers whose keys changed, from the values just written (this shell
# still holds the old ones), then daemon-reload and a restart of each such
# timer that is enabled (lib/timers.sh _sched_apply). The value was checked
# against its type before anything was written (_cfg_check_change: 78). With
# --shared only this node's drop-ins change: the other nodes read the shared
# file on their next start, and their doctor names the drift until `pbo
# timers apply` or `pbo doctor --fix` runs there.
_cfg_hook_apply_schedule() {
    local k r u st f m units=() rc=0
    _sched_ensure
    _SCHED_OVR=()
    for k in "${!CFGW_EA[@]}"; do
        [[ "$(_cs_flag "$k" on_change 2>/dev/null)" == apply-schedule ]] || continue
        _SCHED_OVR[$k]="${CFGW_EA[$k]}"
        [[ "${CFGW_EB[$k]}" != "${CFGW_EA[$k]}" ]] && mapfile -t -O "${#units[@]}" units < <(_sched_units_of "$k")
    done
    (( ${#units[@]} )) || { _SCHED_OVR=(); return 0; }
    # one entry per timer (a calendar and its delay changed together)
    mapfile -t units < <(printf '%s\n' "${units[@]}" | awk '!seen[$0]++')
    _sched_apply "${units[@]}" || rc=$?
    _SCHED_OVR=()
    _sched_audit
    for r in "${SCHED_RES[@]+"${SCHED_RES[@]}"}"; do
        IFS=$'\x1f' read -r u st f m <<<"$r"
        case "$st" in
            written|removed) _cfgh apply-schedule ok "$u: $m" ;;
            would-write|would-remove) _cfgh apply-schedule would "$u: $m" ;;
            ok) _cfgh apply-schedule skipped "$u: already $m" ;;
            *) _cfgh apply-schedule failed "$u: $m" ;;
        esac
    done
    case "$SCHED_RELOAD" in
        ok) _cfgh apply-schedule ok "$SCHED_RELOAD_MSG" ;;
        would) _cfgh apply-schedule would "$SCHED_RELOAD_MSG" ;;
        skipped) _cfgh apply-schedule skipped "$SCHED_RELOAD_MSG" ;;
        failed) _cfgh apply-schedule failed "$SCHED_RELOAD_MSG" ;;
    esac
    (( rc == 0 ))
}

# _cfg_confirm_repo: confirm-repo for the keys given (_CC_KEYS/_CC_OPS/_CC_VALS):
# a new repo URL or path points pbo at another repo, it moves no snapshot. Needs
# --yes (_CC_YES) or a yes on a terminal; a dry run only says it.
_cfg_confirm_repo() {
    local i k new cur msg='' a
    for i in "${!_CC_KEYS[@]}"; do
        k="${_CC_KEYS[i]}"
        # not a key given: one _cfg_follows moved along with CACHE_DIR
        [[ -z "${_CC_IMPLICIT[$k]+x}" ]] || continue
        _cfg_hooks_for "$k"; [[ "$_CFG_HOOK" == confirm-repo ]] || continue
        cur="${!k-}"
        new="${_CC_VALS[i]}"; if [[ "${_CC_OPS[i]}" == unset || -z "$new" ]]; then _cs_default_r "$k"; new="$_CS_R"; fi
        [[ "$new" != "$cur" ]] || continue
        msg+="${msg:+; }$k: $(_mask_url "${cur:-<empty>}") -> $(_mask_url "${new:-<empty>}")"
    done
    [[ -n "$msg" ]] || return 0
    msg="$msg. pbo moves no data: the snapshots stay in the repo they are in, and pbo uses the new one from now on ('pbo init' creates it if it does not exist)"
    if [[ "${_CC_YES:-0}" == 1 || "${DRY_RUN:-0}" == 1 ]]; then
        _cfgh confirm-repo ok "$msg"; printf 'config: %s\n' "$msg" >&2; return 0
    fi
    [[ -t 0 ]] || die "$EX_USAGE" "config: $msg. Not a terminal: add --yes to confirm"
    read -r -p "config: $msg. Continue? [y/N] " a
    [[ "$a" == [yYjJ]* ]] || die "$EX_USAGE" "config: cancelled, nothing was changed"
    _cfgh confirm-repo ok "$msg"
}

# _cfg_hook_move_cache OLD NEW: CACHE_DIR changes from OLD to NEW (effective
# values), under the config lock, before the file is replaced. The one place
# that decides how: a cache with data, one whose spool the PVE storage names
# (the integration is on) and any change while a move is unfinished go to the
# cache move (lib/cachemove.sh _cm_hook: preflight, journal, the data moved
# before the file is replaced, the rest after it). An empty cache (the old
# directory does not exist or holds only directories: no repo, nothing in the
# spool or staging, no dump) needs no move: NEW, which does not exist or is
# empty, is created and the permission table applied to it (lib/perms.sh:
# closed to others, an ACL entry per unprivileged CT; with --fix-parents also
# the directories above it), and the config is written.
_cfg_hook_move_cache() {
    local old="$1" new="$2" hit e
    # /x and /x/ are the same directory: nothing moves
    while [[ "$old" == */ && "$old" != / ]]; do old="${old%/}"; done
    while [[ "$new" == */ && "$new" != / ]]; do new="${new%/}"; done
    if [[ "$old" == "$new" ]]; then _cfgh move-cache skipped "CACHE_DIR stays $new: nothing to move"; return 0; fi
    if _cm_needed "$old"; then _cm_hook "$old" "$new"; return $?; fi
    _perm_ensure
    [[ "$new" == /* ]] || { CFGW_ERR="CACHE_DIR must be an absolute path, not '$new'"; return "$EX_CONFIG"; }
    if [[ "$PERM_SYSTEM_DIRS" == *" $new "* ]]; then
        CFGW_ERR="CACHE_DIR=$new is a system directory: give pbo a directory of its own (e.g. $new/pbo)"; return "$EX_CONFIG"
    fi
    [[ ! -L "$new" ]] || { CFGW_ERR="CACHE_DIR=$new is a symlink: give the real path"; return "$EX_CONFIG"; }
    [[ ! -e "$new" || -d "$new" ]] || { CFGW_ERR="CACHE_DIR=$new exists and is not a directory"; return "$EX_CONFIG"; }
    if [[ -d "$new" ]]; then
        hit="$(find "$new" -mindepth 1 -maxdepth 1 ! -name lost+found ! -name .zfs ! -name .snapshot -print -quit 2>/dev/null)" || hit="$new (cannot be read)"
        if [[ -n "$hit" ]]; then
            CFGW_ERR="CACHE_DIR $new is not empty (${hit#"$new"/}): pbo does not take over a directory that holds other files; choose an empty or a new one"
            return "$EX_UNAVAILABLE"
        fi
    fi
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        if [[ -d "$new" ]]; then _cfgh move-cache would "the cache is empty: $new would get the permissions of the CACHE_DIR rule"
        else _cfgh move-cache would "the cache is empty: $new would be created with the permissions of the CACHE_DIR rule"; fi
        return 0
    fi
    # 0755 first: the rule adds the ACL entries, then closes it (never closed
    # while an unprivileged CT would be locked out, as _cache_dir_protect)
    if [[ ! -d "$new" ]]; then
        ( umask 022; mkdir -p -- "$new" ) || { CFGW_ERR="cannot create $new"; return "$EX_CANTCREAT"; }
    fi
    local CACHE_DIR="$new" PERM_EXTRA_VMIDS=() fp=()
    (( ${CM_FIX_PARENTS:-0} )) && fp=(--fix-parents --only CACHE_DIR:parents)
    _perm_apply --fix "${fp[@]}" --only CACHE_DIR || true
    for e in "${PERM_FIX_ERRORS[@]+"${PERM_FIX_ERRORS[@]}"}"; do log_warn "config: $e"; done
    for e in "${PERM_FINDINGS[@]+"${PERM_FINDINGS[@]}"}"; do
        [[ "${e%%$'\t'*}" == ok ]] || log_warn "config: ${e##*$'\t'}"
    done
    _cfgh move-cache ok "the cache was empty: $new created, mode $(stat -c %a -- "$new" 2>/dev/null)"
    # the journal of an earlier move learns of it once the file is written
    # (_config_change_cmd): it must not keep NEW banned as a place a move left
    CM_EMPTY_CHANGE="$old"$'\t'"$new"
    return 0
}

# _cfg_hook_restart_mount: pbo-mount.service reads the mount settings when it
# starts: restart it if (and only if) it is running, and not under a restore
# that reads through it.
_cfg_hook_restart_mount() {
    local unit="${PBO_MOUNT_UNIT:-pbo-mount.service}"
    if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-active --quiet "$unit" 2>/dev/null; then
        _cfgh restart-mount skipped "$unit is not running: it uses the new setting when it starts"; return 0
    fi
    if declare -F _catalog_mount_busy >/dev/null && _catalog_mount_busy; then
        _cfgh restart-mount failed "$unit is in use (a restore reads through it): restart it when the restore is done (systemctl restart $unit)"; return 1
    fi
    if [[ "${DRY_RUN:-0}" == 1 ]]; then _cfgh restart-mount would "would restart $unit"; return 0; fi
    if systemctl restart "$unit" >/dev/null 2>&1; then _cfgh restart-mount ok "$unit restarted"; return 0; fi
    _cfgh restart-mount failed "could not restart $unit (systemctl restart $unit)"; return 1
}

# --- pbo config set|unset -------------------------------------------------------------------

# Names a config must not set even with --force: bash would apply them when
# pbo 0.5 sources the file (a downgrade), or stop on a readonly one.
readonly CFG_FORBIDDEN_NAMES=' PATH IFS ENV BASH_ENV SHELLOPTS BASHOPTS CDPATH GLOBIGNORE PS4 PROMPT_COMMAND HOME SHELL TMOUT LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT PERL5LIB PERL5OPT PYTHONPATH '

# _cfg_managed_hint CMD: where a managed key is changed instead.
_cfg_managed_hint() {
    case "$1" in
        integrate) printf "'pbo integrate enable both|integrated' or 'pbo integrate disable'" ;;
        install)   printf 'install.sh (install.sh --janitor sets PBO_ROLE=janitor)' ;;
        *)         printf "'pbo %s'" "$1" ;;
    esac
}

# _cfg_check_change OP KEY VALUE SHARED FORCE: may this change be written? Dies
# with the reason (64 usage, 78 a value or key the config may not have).
_cfg_check_change() {
    local op="$1" k="$2" v="$3" shared="$4" force="$5" role="${PBO_ROLE:-host}" m msg LC_ALL=C
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$EX_USAGE" "config $op: '$k' is not a key name"
    if ! _cs_has "$k"; then
        _cs_env_switch "$k" && die "$EX_USAGE" "config $op: $k is an environment switch, not a config key: set it in pbo's environment"
        [[ "$op" == unset ]] && return 0   # removing a typo is always fine
        (( force )) || die "$EX_USAGE" "config set: '$k' is not a known config key ('pbo config list --all' shows them; --force writes it anyway, pbo ignores it)"
        if [[ "$CFG_FORBIDDEN_NAMES" == *" $k "* || "$k" == BASH* || "$k" == LD_* ]] || declare -p "$k" 2>/dev/null | grep -q '^declare -[a-zA-Z]*r'; then
            die "$EX_USAGE" "config set: $k may not be set in a config, not even with --force: bash would apply it when pbo 0.5 reads the file"
        fi
    fi
    if m="$(_cs_flag "$k" managed)"; then
        die "$EX_USAGE" "config $op: $k is managed by $(_cfg_managed_hint "$m"), not by config $op"
    fi
    # where each node keeps its cache, unset too: the move-cache check sees only
    # this node's cache, and pmxcfs copies the cluster-shared file to every
    # node, where no check runs (their repo and spool would be left behind)
    if (( shared )) && _cs_has "$k" \
       && [[ "$(_cs_flag "$k" on_change 2>/dev/null)" == move-cache || "$(_cs_flag "$k" follows 2>/dev/null)" == CACHE_DIR ]]; then
        die "$EX_CONFIG" "config $op --shared: $k decides where each node keeps its cache, and pmxcfs copies the cluster-shared file to every node, where no move-cache check runs: set it in the local config of each node (pbo config $op $k ...)"
    fi
    [[ "$op" == unset ]] && return 0
    [[ "${v//$'\t'/}" != *[[:cntrl:]]* ]] \
        || die "$EX_CONFIG" "config set: the value of $k holds a control character (a newline?): a value is one line of text"
    _cs_has "$k" || return 0
    if (( shared )); then
        local fl=",${CS_FLAGS[$k]},"
        [[ "$fl" != *,secret,* ]] || die "$EX_CONFIG" "config set --shared: $k is a secret, and pmxcfs copies the cluster-shared file to every node: set it in the local config of each node"
        [[ "$fl" != *,exec,* && "$fl" != *,local-only,* ]] || die "$EX_CONFIG" "config set --shared: $k runs a program or is per node, so pbo ignores it in the cluster-shared file: set it in the local config of each node"
    fi
    _cs_has_role "$k" "$role" || die "$EX_CONFIG" "config set: $k is not used on a $role (it is a ${CS_ROLES[$k]//,/ and } key)"
    msg="$(_cs_validate "$k" "$v")" || die "$EX_CONFIG" "config set: $msg"
    if [[ -n "$v" && ( "${CS_TYPE[$k]}" == path || "${CS_TYPE[$k]}" == dir ) && "$v" != /* ]]; then
        die "$EX_CONFIG" "config set: $k must be an absolute path"
    fi
    return 0
}

# _cfg_follow_default_r KEY BASE VALUE: KEY's derived default when the key it
# follows (BASE) has VALUE → _CS_R.
_cfg_follow_default_r() { local "$2=$3"; _cs_default_r "$1"; }

# _cfg_target_value KEY TARGET: KEY's value in TARGET when the reader found it
# there last (CFG_SRC) → _CFG_TV; returns 1 when TARGET does not set it.
_cfg_target_value() {
    local s="${CFG_SRC[$1]-}"
    s="${s#*:}"; s="${s%:*}"
    [[ -n "$s" && "$s" == "$2" ]] || return 1
    _CFG_TV="${CFG_VAL[$1]}"
}

# _cfg_key_elsewhere KEY TARGET: a source other than TARGET gives KEY a value:
# another config file pbo reads (each file read alone, as the reader takes it:
# a key the shared file may not set does not count) or the environment
# (CFG_ENV). Removing KEY from TARGET then does not let it fall back to its
# derived default: that other value would win. In subshells, so the reader's
# results of load_config stay as they are.
_cfg_key_elsewhere() {
    local k="$1" target="$2" i f
    [[ -z "${CFG_ENV[$k]+x}" ]] || return 0
    _cfg_config_files
    for i in "${!_CFG_FPATH[@]}"; do
        f="${_CFG_FPATH[i]}"
        [[ "$f" != "$target" && -f "$f" && -r "$f" ]] || continue
        ( _cfg_reset; _cfg_parse_file "$f" "${_CFG_FORIGIN[i]}" >/dev/null 2>&1 || true; [[ -n "${CFG_VAL[$k]+x}" ]] ) && return 0
    done
    return 1
}

# _cfg_follows: a key that follows another one (follows=CACHE_DIR) is not
# pinned at its derived default: set to the value it would derive, it is unset
# instead; and when the key it follows changes, a value the file holds that was
# the old derived default goes too, so it moves along (_CC_* arrays, notes in
# _CC_NOTES[key], the ops added here in _CC_IMPLICIT). Both only when no other
# file and not the environment sets the key (_cfg_key_elsewhere): removing the
# line would hand the key to that value instead of the derived default. Then a
# set stays a set (it pins the override), and a line at the old default is
# rewritten to the new one.
_cfg_follows() {
    local k base i j have cur newb target="$1"
    for k in "${CS_ORDER[@]}"; do
        base="$(_cs_flag "$k" follows)" || continue
        cur="${!base-}" newb="${!base-}" have=-1
        for i in "${!_CC_KEYS[@]}"; do
            [[ "${_CC_KEYS[i]}" == "$base" ]] || continue
            newb="${_CC_VALS[i]}"
            if [[ "${_CC_OPS[i]}" == unset || -z "$newb" ]]; then _cfg_follow_default_r "$base" "$base" ''; newb="$_CS_R"; fi
        done
        for j in "${!_CC_KEYS[@]}"; do [[ "${_CC_KEYS[j]}" == "$k" ]] && have=$j; done
        if (( have >= 0 )); then
            [[ "${_CC_OPS[have]}" == set && -n "${_CC_VALS[have]}" ]] || continue
            _cfg_follow_default_r "$k" "$base" "$newb"
            if [[ "${_CC_VALS[have]%/}" == "${_CS_R%/}" ]] && ! _cfg_key_elsewhere "$k" "$target"; then
                _CC_OPS[have]=unset _CC_VALS[have]=''
                _CC_NOTES[$k]="not pinned: it follows $base ($_CS_R)"
            fi
        elif [[ "${newb%/}" != "${cur%/}" ]] && _cfg_target_value "$k" "$target"; then
            _cfg_follow_default_r "$k" "$base" "$cur"
            if [[ "${_CFG_TV%/}" == "${_CS_R%/}" ]]; then
                _CC_IMPLICIT[$k]=1
                if ! _cfg_key_elsewhere "$k" "$target"; then
                    _CC_KEYS+=("$k"); _CC_OPS+=(unset); _CC_VALS+=('')
                    _CC_NOTES[$k]="removed: it was the default under the old $base, it follows $base"
                else
                    _cfg_follow_default_r "$k" "$base" "$newb"
                    _CC_KEYS+=("$k"); _CC_OPS+=(set); _CC_VALS+=("$_CS_R")
                    _CC_NOTES[$k]="moved to the default under the new $base (another source sets it, so the line stays)"
                fi
            fi
        fi
    done
    return 0
}

# _cfg_show KEY VALUE: a value as config set reports it (a secret or an unknown
# key: <set> or <unset>).
_cfg_show() {
    if _config_is_secret "$1"; then if [[ -n "$2" ]]; then printf '<set>'; else printf '<unset>'; fi
    else _mask_url "$2"; fi
}

# config set KEY VALUE [KEY VALUE...] [--shared] [--yes] [--force]
# config unset KEY... [--shared] [--yes]
# One transaction (_cfg_write) on the local config, or with --shared the
# cluster-shared one. Flags are read where a KEY may stand; `--` ends them. A
# global --dry-run (or one here) prints the diff and changes nothing.
_config_change_cmd() {
    local sub="$1"; shift
    local shared=0 force=0 literal=0 want=key i k n kp
    _CC_YES=0; declare -ga _CC_KEYS=() _CC_OPS=() _CC_VALS=() CFGH=(); declare -gA _CC_NOTES=() _CC_IMPLICIT=()
    # the cache move's flags (lib/cachemove.sh): only with CACHE_DIR
    local cmflags=''
    CM_RESUME=0 CM_ABORT=0 CM_KEEP_OLD=0 CM_FIX_PARENTS=0 CM_VERIFY_DATA=0
    # the audit record's copy of the arguments, a secret's (or an unknown key's)
    # value masked: kept up to date token by token, so a usage error stops
    # with it masked too
    declare -ga AUDIT_ARGS=()
    for k in "${PBO_ORIG_ARGS[@]+"${PBO_ORIG_ARGS[@]}"}"; do [[ "$k" == config ]] && break; AUDIT_ARGS+=("$k"); done
    AUDIT_ARGS+=(config "$sub")
    _cs_core
    while (( $# )); do
        # KEY=VALUE typed as one argument where a key belongs (no flag has an
        # =): what follows the = may be a secret. It is cut off before the
        # token reaches the audit record or any message (die logs to the log
        # file and notifies), masked unless the key is a known non-secret one.
        if [[ "$want" == key && "$1" == *=* ]]; then
            kp="${1%%=*}"
            if [[ "$kp" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && ! _config_is_secret "$kp"; then AUDIT_ARGS+=("$(_mask_url "$1")")
            else AUDIT_ARGS+=("$kp=<secret>"); fi
            if (( ! literal )) && [[ "$kp" == -* ]]; then
                die "$EX_USAGE" "config $sub: unknown flag '$kp=...' (use --shared, --yes, --force, --dry-run, and for CACHE_DIR --resume, --abort, --keep-old, --fix-parents, --verify-data; -- before a key that starts with -)"
            fi
            if [[ "$sub" == set ]]; then die "$EX_USAGE" "config set: '$kp=...' is one argument: write config set $kp VALUE (two arguments)"; fi
            die "$EX_USAGE" "config unset: '$kp=...' is not a key name: write config unset $kp"
        fi
        if [[ "$sub" == set && "$want" == val ]] && _config_is_secret "${_CC_KEYS[-1]}"; then AUDIT_ARGS+=('<secret>')
        else AUDIT_ARGS+=("$1"); fi
        if (( ! literal )) && [[ "$want" == key ]]; then
            case "$1" in
                --shared) shared=1; shift; continue ;;
                --yes|-y) _CC_YES=1; shift; continue ;;
                --force) force=1; shift; continue ;;
                --dry-run) DRY_RUN=1; shift; continue ;;
                --resume) CM_RESUME=1; cmflags+=" $1"; shift; continue ;;
                --abort) CM_ABORT=1; cmflags+=" $1"; shift; continue ;;
                --keep-old) CM_KEEP_OLD=1; cmflags+=" $1"; shift; continue ;;
                --fix-parents) CM_FIX_PARENTS=1; cmflags+=" $1"; shift; continue ;;
                --verify-data) CM_VERIFY_DATA=1; cmflags+=" $1"; shift; continue ;;
                --) literal=1; shift; continue ;;
                -*) die "$EX_USAGE" "config $sub: unknown flag '$1' (use --shared, --yes, --force, --dry-run, and for CACHE_DIR --resume, --abort, --keep-old, --fix-parents, --verify-data; -- before a key that starts with -)" ;;
            esac
        fi
        if [[ "$sub" == unset ]]; then _CC_KEYS+=("$1"); _CC_OPS+=(unset); _CC_VALS+=('')
        elif [[ "$want" == key ]]; then _CC_KEYS+=("$1"); _CC_OPS+=(set); want='val'
        else _CC_VALS+=("$1"); want=key; fi
        shift
    done
    if [[ "$sub" == set ]]; then
        (( ${#_CC_KEYS[@]} )) || die "$EX_USAGE" "config set KEY VALUE [KEY VALUE...] [--shared] [--yes] [--force]"
        [[ "$want" == key ]] || die "$EX_USAGE" "config set: ${_CC_KEYS[-1]} has no value (config set KEY VALUE; \"\" sets it empty, which means the default)"
    else
        (( ${#_CC_KEYS[@]} )) || die "$EX_USAGE" "config unset KEY... [--shared] [--yes]"
    fi
    _cs_load
    for i in "${!_CC_KEYS[@]}"; do
        k="${_CC_KEYS[i]}"
        for (( n = 0; n < i; n++ )); do [[ "${_CC_KEYS[n]}" != "$k" ]] || die "$EX_USAGE" "config $sub: $k is given twice"; done
        _cfg_check_change "$sub" "$k" "${_CC_VALS[i]}" "$shared" "$force"
        _cs_flag "$k" internal >/dev/null && log_warn "config: $k is a test hook (internal): it does not belong in a production config"
        if [[ "$sub" == set && ",${CS_FLAGS[$k]-}" == *,deprecated=* ]]; then log_warn "config: $k is replaced by $(_cs_flag "$k" deprecated)"; fi
    done
    # CACHE_DIR: a move with data (lib/cachemove.sh). An unfinished one is
    # finished (--resume) or undone (--abort) here when that needs no config
    # write; everything else goes through the writer and its move-cache hook.
    local cmi=-1
    for i in "${!_CC_KEYS[@]}"; do [[ "${_CC_KEYS[i]}" == CACHE_DIR ]] && cmi=$i; done
    if (( cmi < 0 )) && [[ -n "$cmflags" ]]; then die "$EX_USAGE" "config $sub:$cmflags: only with CACHE_DIR (the cache move)"; fi
    (( CM_RESUME + CM_ABORT < 2 )) || die "$EX_USAGE" "config $sub CACHE_DIR: --resume or --abort, not both"
    CM_YES="$_CC_YES" CM_FORCE="$force"
    if (( cmi >= 0 )); then
        local cmnew="${_CC_VALS[cmi]}"
        if [[ "${_CC_OPS[cmi]}" == unset || -z "$cmnew" ]]; then _cs_default_r CACHE_DIR; cmnew="$_CS_R"; fi
        if ! _cm_before_write "$sub" "$cmnew"; then
            _config_cm_report "$sub" "$CM_RC"
            return "$CM_RC"
        fi
    fi
    # the file the change goes to, as _cfg_write picks it
    local target=''
    _cfg_config_files
    for i in "${!_CFG_FPATH[@]}"; do
        if (( shared )); then [[ "${_CFG_FORIGIN[i]}" != shared ]] || target="${_CFG_FPATH[i]}"
        else [[ "${_CFG_FORIGIN[i]}" != local ]] || target="${_CFG_FPATH[i]}"; fi
    done
    [[ -n "$target" ]] || die "$EX_USAGE" "config $sub --shared: there is no cluster-shared config: with PBO_CONFIG set pbo reads that file alone"
    # before anything is asked or written (_cfg_write checks it again)
    if (( shared )); then _cfg_shared_check "$target" || die "$_CFG_SHRC" "config $sub --shared: $_CFG_SHERR"; fi
    _cfg_follows "$target"
    (( cmi < 0 )) || _cm_follow_ops "$target"
    _cfg_confirm_repo
    local -a ops=() wflags=(--hooks)
    for i in "${!_CC_KEYS[@]}"; do
        if [[ "${_CC_OPS[i]}" == set ]]; then ops+=(set "${_CC_KEYS[i]}" "${_CC_VALS[i]}"); else ops+=(unset "${_CC_KEYS[i]}"); fi
    done
    local rc=0
    (( shared == 0 )) || wflags+=(--shared)
    CM_PENDING=0 CM_EMPTY_CHANGE=''
    _cfg_write "${wflags[@]}" "${ops[@]}" || rc=$?
    local hookrc=0
    if (( CM_PENDING )); then
        # the move's data is in place: the config write finishes the pre-write
        # half; a failed write undoes the move
        if (( rc == 0 && CFGW_WRITTEN )); then
            _cm_after_write || hookrc=1
        else
            _cm_rollback "the config could not be written: ${CFGW_ERR:-exit $rc}" || CFGW_ERR+="; $CM_ERR"
            (( rc != 0 )) || rc="$EX_SOFTWARE"
        fi
        CM_PENDING=0
    fi
    if [[ -n "$CM_EMPTY_CHANGE" ]] && (( rc == 0 && CFGW_WRITTEN )); then
        _cm_journal_empty_change "${CM_EMPTY_CHANGE%%$'\t'*}" "${CM_EMPTY_CHANGE#*$'\t'}"
    fi
    CM_EMPTY_CHANGE=''
    (( rc == 0 )) || die "$rc" "config $sub: $CFGW_ERR"
    if (( CFGW_CHANGED )); then
        if (( CFGW_WRITTEN )); then
            local what=''
            for i in "${!CFGW_KEYS[@]}"; do
                k="${CFGW_KEYS[i]}"
                if [[ "${CFGW_OPS[i]}" == unset ]]; then what+=" unset=$k"
                elif _config_is_secret "$k"; then what+=" $k=<secret>"
                else what+=" $k=$(printf '%q' "$(_mask_url "${CFGW_VALS[i]}")")"; fi
            done
            audit_log "config $sub file=$CFGW_FILE$what"
        fi
        _cfg_hooks_post || hookrc=1
    fi
    _config_change_report "$sub" "$shared" "$hookrc"
    if (( hookrc )); then
        PBO_ERROR_LOGGED=1
        log_error "config $sub: $CFGW_FILE was written, but a follow-up step failed (see above)"
        return "$EX_UNAVAILABLE"
    fi
    return "$EX_OK"
}

# _config_cm_report SUB RC: what config set|unset CACHE_DIR --resume|--abort did
# when it needed no config write (the cache move's hooks only).
_config_cm_report() {
    local sub="$1" rc="$2" line hk='' f1 f2 f3
    for line in "${CFGH[@]+"${CFGH[@]}"}"; do hk+="$line"$'\x1e'; done
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_emit "$(jq -cn --arg h "$hk" --arg sub "$sub" --argjson rc "$rc" --arg f "${PBO_CONFIG_LOCAL:-}" '
            def recs: split("\u001e") | map(select(length > 0) | split("\u001f"));
            { status: (if $rc == 0 then "ok" else "hook_failed" end), ok: ($rc == 0), action: $sub, file: $f,
              changed: false, written: false, changes: [], effective: [],
              hooks: [ $h | recs[] | { hook: .[0], status: .[1], message: .[2] } ] }')"
        return 0
    fi
    while IFS=$'\x1f' read -r -d $'\x1e' f1 f2 f3; do printf '%s: %s\n' "$f1" "$f3"; done < <(printf '%s' "$hk")
    if (( rc )); then PBO_ERROR_LOGGED=1; log_error "config $sub CACHE_DIR: the cache move did not finish (see above)"; fi
    return 0
}

# _config_change_report SUB SHARED HOOKRC: what config set|unset did, as text or JSON.
_config_change_report() {
    local sub="$1" shared="$2" hookrc="$3" i k sec b a fb fa rec='' eff='' hk='' line
    for i in "${!CFGW_KEYS[@]}"; do
        k="${CFGW_KEYS[i]}"; sec=0; _config_is_secret "$k" && sec=1
        if (( ! CFGW_CHANGED )); then
            # nothing written, nothing read back: the values as loaded
            if _cfg_target_value "$k" "$CFGW_FILE"; then CFGW_FB[$k]="$_CFG_TV" CFGW_FA[$k]="$_CFG_TV"; fi
            if _cs_has "$k"; then _cs_value_r "$k"; CFGW_EB[$k]="$_CS_R" CFGW_EA[$k]="$_CS_R"; fi
        fi
        if [[ -n "${CFGW_EA[$k]+x}" ]]; then b="${CFGW_EB[$k]}" a="${CFGW_EA[$k]}"
        else b="${CFGW_FB[$k]-}" a="${CFGW_FA[$k]-}"; fi
        fb="${CFGW_FB[$k]+1}" fa="${CFGW_FA[$k]+1}"
        rec+="$k"$'\x1f'"${CFGW_OPS[i]}"$'\x1f'"$sec"$'\x1f'"$(_cfg_show "$k" "$b")"$'\x1f'"$(_cfg_show "$k" "$a")"$'\x1f'"${fb:-0}"$'\x1f'"$(_cfg_show "$k" "${CFGW_FB[$k]-}")"$'\x1f'"${fa:-0}"$'\x1f'"$(_cfg_show "$k" "${CFGW_FA[$k]-}")"$'\x1f'"${_CC_NOTES[$k]-}"$'\x1f'"${CFGW_OVR[$k]-}"$'\x1e'
    done
    for k in "${CS_ORDER[@]}"; do
        [[ -n "${CFGW_EA[$k]+x}" && " ${CFGW_KEYS[*]} " != *" $k "* ]] || continue
        eff+="$k"$'\x1f'"$(_cfg_show "$k" "${CFGW_EB[$k]}")"$'\x1f'"$(_cfg_show "$k" "${CFGW_EA[$k]}")"$'\x1e'
    done
    for line in "${CFGH[@]+"${CFGH[@]}"}"; do hk+="$line"$'\x1e'; done
    if [[ "${JSON_OUTPUT:-0}" == 1 ]]; then
        json_emit "$(jq -cn --arg d "$rec" --arg e "$eff" --arg h "$hk" --arg f "$CFGW_FILE" --arg sub "$sub" \
            --argjson shared "$shared" --argjson changed "$CFGW_CHANGED" --argjson written "$CFGW_WRITTEN" \
            --argjson created "$CFGW_CREATED" --argjson hookrc "$hookrc" --arg diff "$CFGW_DIFF" --argjson dry "${DRY_RUN:-0}" '
            def recs: split("\u001e") | map(select(length > 0) | split("\u001f"));
            def nz: if . == "" then null else . end;
            { status: (if $hookrc == 1 then "hook_failed" else "ok" end), ok: ($hookrc == 0), action: $sub,
              file: $f, shared: ($shared == 1), changed: ($changed == 1), written: ($written == 1), created: ($created == 1 and $written == 1),
              changes: [ $d | recs[] | { key: .[0], action: .[1], secret: (.[2] == "1"), before: .[3], after: .[4],
                         file_before: (if .[5] == "1" then .[6] else null end), file_after: (if .[7] == "1" then .[8] else null end),
                         note: (.[9] | nz), overridden_by: (.[10] | nz) } ],
              effective: [ $e | recs[] | { key: .[0], before: .[1], after: .[2] } ],
              hooks: [ $h | recs[] | { hook: .[0], status: .[1], message: .[2] } ],
              diff: (if $dry == 1 and $changed == 1 then $diff else null end) }')"
        return 0
    fi
    local f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11
    while IFS=$'\x1f' read -r -d $'\x1e' f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11; do
        if [[ -n "$f10" && "$f4" != "$f5" ]]; then printf '%s: %s -> %s (%s)\n' "$f1" "${f4:-<empty>}" "${f5:-<empty>}" "$f10"
        elif [[ -n "$f10" ]]; then printf '%s: %s\n' "$f1" "$f10"
        elif [[ "$f4" != "$f5" ]]; then printf '%s: %s -> %s\n' "$f1" "${f4:-<empty>}" "${f5:-<empty>}"
        elif [[ "$f6$f7" != "$f8$f9" ]]; then
            if [[ "$f8" == 1 ]]; then printf '%s=%s (the value pbo uses does not change)\n' "$f1" "$f9"
            else printf '%s removed (the value pbo uses does not change: %s)\n' "$f1" "${f5:-<empty>}"; fi
        else printf '%s: already %s\n' "$f1" "${f5:-<empty>}"; fi
        [[ -z "$f11" ]] || printf '  note: %s also sets %s and wins on this node\n' "$f11" "$f1"
    done < <(printf '%s' "$rec")
    while IFS=$'\x1f' read -r -d $'\x1e' f1 f2 f3; do
        printf '%s: %s -> %s (follows)\n' "$f1" "${f2:-<empty>}" "${f3:-<empty>}"
    done < <(printf '%s' "$eff")
    while IFS=$'\x1f' read -r -d $'\x1e' f1 f2 f3; do
        [[ "$f1" == confirm-repo ]] && continue   # said before the change
        printf '%s: %s\n' "$f1" "$f3"
    done < <(printf '%s' "$hk")
    if (( ! CFGW_CHANGED )); then printf 'nothing to change in %s\n' "$CFGW_FILE"
    elif [[ "${DRY_RUN:-0}" == 1 ]]; then printf '%s\n' "$CFGW_DIFF"; printf 'dry run: %s not changed\n' "$CFGW_FILE"
    elif (( CFGW_CREATED )); then printf 'created %s\n' "$CFGW_FILE"
    else printf 'written: %s\n' "$CFGW_FILE"; fi
    (( shared == 0 || CFGW_WRITTEN == 0 )) || printf 'note: pmxcfs copies %s to every node; their pbo reads it on its next start (no hook runs there)\n' "$CFGW_FILE"
    return 0
}

readonly CONFIG_SUBCOMMANDS="show, list [--all], get KEY, set KEY VALUE... [--shared] [--yes] [--force] (CACHE_DIR also [--resume|--abort] [--keep-old] [--fix-parents] [--verify-data]), unset KEY... [--shared], template [--role host|janitor], check [--file F] [--role host|janitor] [--compare-bash]"

rdo_config() {
    local sub="${1:-show}"; [[ $# -gt 0 ]] && shift
    # only set and unset change anything: the others keep the audit record read-only
    case "$sub" in set|unset) ;; *) AUDIT_RO_OVERRIDE=1 ;; esac
    case "$sub" in
        show|list) _config_view "$sub" "$@" ;;
        get)       _config_get "$@" ;;
        template)  _config_template_cmd "$@" ;;
        check)     _config_check_cmd "$@" ;;
        set|unset) _config_change_cmd "$sub" "$@" ;;
        *) die "$EX_USAGE" "config: unknown subcommand '$sub' (valid: $CONFIG_SUBCOMMANDS)" ;;
    esac
}
