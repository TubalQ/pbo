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

readonly CONFIG_SUBCOMMANDS="show, list [--all], get KEY, template [--role host|janitor], check [--file F] [--role host|janitor] [--compare-bash]"

rdo_config() {
    local sub="${1:-show}"; [[ $# -gt 0 ]] && shift
    case "$sub" in
        show|list) _config_view "$sub" "$@" ;;
        get)       _config_get "$@" ;;
        template)  _config_template_cmd "$@" ;;
        check)     _config_check_cmd "$@" ;;
        set|unset)
            die "$EX_USAGE" "config $sub: not yet available (planned for pbo 0.6); edit ${PBO_CONFIG_LOCAL:-/etc/pbo/config} by hand or run 'pbo setup'" ;;
        *) die "$EX_USAGE" "config: unknown subcommand '$sub' (valid: $CONFIG_SUBCOMMANDS)" ;;
    esac
}
