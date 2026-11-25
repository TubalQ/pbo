# shellcheck shell=bash
# lib/config_parse.sh: the strict config reader (ADR 0009, "Reader").
#
# pbo 0.5 sources /etc/pbo/config as shell code. pbo 0.6 reads it instead: each
# line is blank, a comment, or KEY=VALUE in a small subset of the bash grammar,
# and the value comes out exactly as bash would assign it. The reader never runs
# anything and assigns no shell variable: load_config (lib/common.sh) assigns
# the schema keys from CFG_VAL and exports CFG_EXPORT (0.6 M3).
#
# Self-contained on purpose: install.sh sources it from the source tree (its
# upgrade guard runs before any file is installed). It uses the schema
# (lib/config_schema.sh, _cs_*) when that is loaded, and nothing else.
#
# Results (a load merges its files into one set, as sourcing them in order does):
#   CFG_VAL[K]     the value
#   CFG_RAW[K]     the value as written (quotes and references included)
#   CFG_SRC[K]     <origin>:<file>:<line> of the assignment that counts (the last)
#   CFG_LINE[K]    that line
#   CFG_EXPORT[K]  the exported proxy variables (load_config exports them to child processes)
#   CFG_UNKNOWN    keys the schema does not know, each once (never assigned)
#   CFG_ERRORS, CFG_WARNINGS   "<file>:<line>: <message>"; an error makes pbo refuse the config
#   CFG_IGNORED    the same form: lines that read fine but are not applied (an exec
#                  or local-only key in the cluster-shared file); pbo runs without
#                  them, doctor says FAIL, `pbo config check` counts them as errors
#   PBO_CONFIG_FILES           the files _cfg_parse_all read, in order
# CFG_ENV[K] is the input for references to keys no file set (_cfg_env_snapshot).

# _cfg_reset: empty results (CFG_ENV is left alone: it is input).
_cfg_reset() {
    declare -gA CFG_VAL=() CFG_RAW=() CFG_SRC=() CFG_LINE=() CFG_EXPORT=()
    declare -ga CFG_UNKNOWN=() CFG_ERRORS=() CFG_WARNINGS=() CFG_IGNORED=() PBO_CONFIG_FILES=()
}

# _cfg_env_snapshot: the schema keys set in this shell, as references see them.
# bash expands ${CACHE_DIR} in the config from the environment when no earlier
# line set it, so the reader does too (with a warning). Taken before the values
# are assigned (load_config): afterwards the shell holds the config's values.
# It also tells `pbo config list` which keys come from the environment.
# Without a snapshot no key comes from the environment (install.sh: the units
# run pbo with a clean one).
_cfg_env_snapshot() {
    declare -gA CFG_ENV=()
    declare -F _cs_core >/dev/null || return 0
    _cs_core
    local _cfg_k
    for _cfg_k in "${CS_ORDER[@]}"; do
        [[ -n "${!_cfg_k+x}" ]] && CFG_ENV[$_cfg_k]="${!_cfg_k}"
    done
    return 0
}

# _cfg_known KEY: a schema key (every key counts when the schema is not loaded;
# _CFG_CS, set by _cfg_parse_file).
_cfg_known() {
    [[ "${_CFG_CS:-0}" == 1 ]] || return 0
    [[ -n "${CS_FLAGS[$1]+x}" ]]
}

# _cfg_export_allowed NAME: an environment variable a config may export. Every
# other export is refused: an exported PATH, IFS, BASH_ENV or LD_PRELOAD would
# change what root runs. A case, not a variable: nothing a config or the
# environment sets can widen it.
_cfg_export_allowed() {
    case "$1" in http_proxy|https_proxy|HTTP_PROXY|HTTPS_PROXY|no_proxy|NO_PROXY) return 0 ;; esac
    return 1
}

# _cfg_may_quote KEY TEXT: a refusal message may repeat TEXT, taken from KEY's
# line, only when KEY is a schema key without the secret flag and TEXT holds
# nothing that looks like URL credentials (user:pw@, ://...?token=). The messages
# reach doctor, `pbo config check`, the install.sh guard and the .deb postinst
# (which apt writes to term.log): a secret value must never be among them.
_cfg_may_quote() {
    [[ "${_CFG_CS:-0}" == 1 && -n "${CS_FLAGS[$1]+x}" && ",${CS_FLAGS[$1]}," != *,secret,* && "$2" != *@* && "$2" != *://*\?* ]]
}

# _cfg_ref <text starting with $>: a ${KEY} or $KEY reference → _CFG_RV (its
# value), _CFG_RL (characters used); else _CFG_E. KEY must be a schema key that an
# earlier line set (or, as for bash, that the environment holds); anything else
# bash would expand from its own state ($HOME, $1, a :- default, $(...)) is refused.
# _CFG_KEY is the key whose value holds the reference: the text of a refused
# reference is repeated only when _cfg_may_quote allows it for that key.
_cfg_ref() {
    local s="$1" k
    if [[ "$s" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; then k="${BASH_REMATCH[1]}"
    elif [[ "$s" =~ ^\$([A-Za-z_][A-Za-z0-9_]*) ]]; then k="${BASH_REMATCH[1]}"
    elif [[ "$s" == '$('* ]]; then _CFG_E='command substitution $(...) is not allowed: pbo 0.6 does not run the config'; return 1
    elif [[ "$s" == '${'* ]]; then
        local e="${s%%\}*}"; [[ "$e" == "$s" ]] || e+='}'
        if _cfg_may_quote "${_CFG_KEY:-}" "$e"; then
            _CFG_E="only \${KEY} and \$KEY references to config keys are allowed, not ${e}: write the value out"
        else
            _CFG_E="only \${KEY} and \$KEY references to config keys are allowed, not a \${...} expansion (:- defaults, substrings and the like): write the value out"
        fi
        return 1
    else
        _CFG_E="'${s:0:2}' is not a reference to a config key: a literal \$ goes in single quotes"; return 1
    fi
    _CFG_RL="${#BASH_REMATCH[0]}"
    if ! _cfg_known "$k"; then
        # the name may be part of a secret written unquoted (NTFY_TOKEN=$ecret)
        if _cfg_may_quote "${_CFG_KEY:-}" "$k"; then
            _CFG_E="\$$k is not a config key: a value may refer only to config keys set earlier in the file"
        else
            _CFG_E='a $NAME reference to a name that is not a config key: a value may refer only to config keys set earlier in the file (a literal $ goes in single quotes)'
        fi
        return 1
    fi
    if [[ -n "${CFG_VAL[$k]+x}" ]]; then _CFG_RV="${CFG_VAL[$k]}"
    elif [[ -n "${CFG_ENV[$k]+x}" ]]; then
        _CFG_RV="${CFG_ENV[$k]}"
        _CFG_W+="${_CFG_W:+; }\${$k} is not set earlier in the config: it is taken from pbo's environment"
    else
        _CFG_E="\${$k} is used before it is set: set $k earlier in the file or write the value out (bash stops here under set -u)"; return 1
    fi
    return 0
}

# _cfg_dq <text starting with ">: a double-quoted segment → _CFG_DV (value), _CFG_DL
# (characters used). Inside, \" \\ \$ \` lose the backslash; any other pair stays
# two characters, as in bash. References as in _cfg_ref; ` and $( are refused.
_cfg_dq() {
    local s="${1:1}" v='' c re_lit='^[^"`$\]+'
    while :; do
        if [[ "$s" =~ $re_lit ]]; then v+="${BASH_REMATCH[0]}"; s="${s:${#BASH_REMATCH[0]}}"; fi
        case "${s:0:1}" in
            '"') s="${s:1}"; break ;;
            '\')
                c="${s:1:1}"
                if [[ -z "$c" ]]; then _CFG_E='unterminated double quote: a value must fit on one line'; _CFG_OPEN='"'; return 1; fi
                case "$c" in '"'|'\'|'$'|'`') v+="$c" ;; *) v+="\\$c" ;; esac
                s="${s:2}" ;;
            '`') _CFG_E='command substitution (`...`) is not allowed: pbo 0.6 does not run the config'; return 1 ;;
            '$') _cfg_ref "$s" || return 1; v+="$_CFG_RV"; s="${s:_CFG_RL}" ;;
            '') _CFG_E='unterminated double quote: a value must fit on one line'; _CFG_OPEN='"'; return 1 ;;
        esac
    done
    _CFG_DV="$v"; _CFG_DL=$(( ${#1} - ${#s} ))
    return 0
}

# _cfg_classify <line without leading blanks>: why a line that is not KEY=... is
# refused → _CFG_E (and _CFG_OPEN '{' for a function body on the next lines).
_cfg_classify() {
    local s="$1" n='[A-Za-z_][A-Za-z0-9_]*' sq="'"
    local re_fn='^[^][:space:]"`$;&|<>()='"$sq"']+[[:blank:]]*\(\)' re_fnend='\}[[:blank:]]*(;[[:blank:]]*)?(#.*)?$'
    local re_ctl='^(if|then|elif|else|fi|for|while|until|do|done|case|esac|select|\[\[|\{|\})([[:blank:]]|;|$)'
    if [[ "$s" =~ ^($n)\+= ]]; then
        _CFG_E="${BASH_REMATCH[1]}+= appends: write the whole value (${BASH_REMATCH[1]}=...)"
    elif [[ "$s" =~ ^($n)\[ ]]; then
        _CFG_E="arrays are not supported (${BASH_REMATCH[1]}[...]=): write ${BASH_REMATCH[1]}=VALUE"
    elif [[ "$s" =~ ^function([[:blank:]]|$) || "$s" =~ $re_fn ]]; then
        _CFG_E='function definitions are not allowed: pbo 0.6 does not run the config'
        # the body continues below unless the line closes it
        [[ "$s" =~ $re_fnend ]] || _CFG_OPEN='{'
    elif [[ "$s" =~ ^($n)[[:blank:]]+= ]]; then
        _CFG_E="no spaces around '=': write ${BASH_REMATCH[1]}=VALUE"
    elif [[ "$s" =~ ^(source|\.)([[:blank:]]|$) ]]; then
        _CFG_E='source / . is not allowed: pbo 0.6 reads only KEY=VALUE lines (the cluster-shared /etc/pve/pbo/config is read by itself)'
    elif [[ "$s" =~ $re_ctl ]]; then
        _CFG_E='shell commands (if/for/while/case) are not allowed: pbo 0.6 reads only KEY=VALUE lines'
    elif [[ "$s" =~ ^(declare|typeset|local|readonly)([[:blank:]]|$) ]]; then
        _CFG_E="${BASH_REMATCH[1]} is not allowed: write KEY=VALUE"
    elif [[ "$s" =~ ^unset([[:blank:]]|$) ]]; then
        _CFG_E='unset is not allowed: delete the line (an empty KEY= means the default)'
    else
        _CFG_E='not a KEY=VALUE line: pbo 0.6 reads only comments and KEY=VALUE, it does not run the config as shell code'
    fi
    return 1
}

# _cfg_line_slow <line>: the reader for the lines the fast paths do not take.
# → _CFG_K, _CFG_V, _CFG_RAW, _CFG_X (1: export), or _CFG_E (why the line is
# refused) and _CFG_OPEN (a construct that goes on below: ' " \ or {).
_cfg_line_slow() {
    local s="$1" k v='' seg c start pc=1 more t sq="'"
    local re_word='^[^[:blank:]"`$\;&|<>()'"$sq"']+' re_sqseg="^$sq([^$sq]*)$sq"
    _CFG_K='' _CFG_V='' _CFG_RAW='' _CFG_X='' _CFG_E='' _CFG_OPEN='' _CFG_KEY=''
    [[ "$s" =~ ^[[:blank:]]* ]]; s="${s:${#BASH_REMATCH[0]}}"
    if [[ "$s" =~ ^export([[:blank:]]+|$) ]]; then
        _CFG_X=1; s="${s:${#BASH_REMATCH[0]}}"
        if ! [[ "$s" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            _CFG_E='export takes exactly one KEY=VALUE here (no options, no bare names)'; return 1
        fi
    fi
    [[ "$s" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || { _cfg_classify "$s"; return 1; }
    k="${BASH_REMATCH[1]}"; s="${s:${#BASH_REMATCH[0]}}"; start="$s"; _CFG_KEY="$k"
    # pc: the next character follows the '=' or an unquoted ':' (where bash
    # expands a leading ~)
    while [[ -n "$s" ]]; do
        c="${s:0:1}"
        case "$c" in
            ' '|$'\t') break ;;
            "$sq")
                if [[ "$s" =~ $re_sqseg ]]; then v+="${BASH_REMATCH[1]}"; s="${s:${#BASH_REMATCH[0]}}"; pc=0
                else _CFG_E='unterminated single quote: a value must fit on one line'; _CFG_OPEN="$sq"; return 1; fi ;;
            '"') _cfg_dq "$s" || return 1; v+="$_CFG_DV"; s="${s:_CFG_DL}"; pc=0 ;;
            '$') _cfg_ref "$s" || return 1; v+="$_CFG_RV"; s="${s:_CFG_RL}"; pc=0 ;;
            '`') _CFG_E='command substitution (`...`) is not allowed: pbo 0.6 does not run the config'; return 1 ;;
            '\')
                if (( ${#s} == 1 )); then _CFG_E='a trailing backslash continues the line: a value must fit on one line'; _CFG_OPEN='\'
                else _CFG_E="a backslash outside quotes: put the value in single quotes ($k='...')"; fi
                return 1 ;;
            '(')
                if [[ -z "$v" ]]; then _CFG_E="arrays are not supported ($k=(...)): write $k=\"a b\" for a list"
                else _CFG_E="'(' is shell syntax here: quote the value ($k='...')"; fi
                return 1 ;;
            ';'|'&'|'|'|'<'|'>'|')') _CFG_E="'$c' is a shell operator: pbo 0.6 does not run the config (quote the value if it is part of it)"; return 1 ;;
            *)
                [[ "$s" =~ $re_word ]]; seg="${BASH_REMATCH[0]}"
                # export is a declaration builtin: bash brace-expands its argument
                # (export K={1,2} runs export K=1 K=2), a plain assignment it does not
                if [[ -n "$_CFG_X" && "$seg" == *'{'* ]]; then
                    _CFG_E="an unquoted { on an export line: bash brace-expands it (export $k={a,b} sets $k=b); quote the value ($k='...')"; return 1
                fi
                if [[ ( "$pc" == 1 && "$seg" == '~'* ) || "$seg" == *':~'* ]]; then
                    _CFG_E="~ is not expanded by pbo 0.6: write the full path ($k=/root/..., not ~/...)"; return 1
                fi
                v+="$seg"; s="${s:${#seg}}"
                if [[ "$seg" == *: ]]; then pc=1; else pc=0; fi ;;
        esac
    done
    if ! [[ "$s" =~ ^([[:blank:]]+(#.*)?)?$ ]]; then
        more="${s#"${s%%[![:blank:]]*}"}"
        if [[ "$more" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            t="${more%%[=[:blank:]]*}"
            # after a secret, the "name" may be the rest of the value (NTFY_TOKEN=ab cd=ef)
            if _cfg_may_quote "$k" "$t"; then _CFG_E="one assignment per line: put $t=... on a line of its own"
            else _CFG_E="one assignment per line: put each KEY=... on a line of its own"; fi
        elif [[ "$s" == "$start" ]]; then
            # the command word is the value the line meant to set (_cfg_may_quote)
            t="${more%%[[:blank:]]*}"
            if _cfg_may_quote "$k" "$t"; then
                _CFG_E="a space after '=': bash runs '$t' as a command; write $k=VALUE (quoted if it has spaces)"
            else
                _CFG_E="a space after '=': bash runs the rest of the line as a command; write $k=VALUE (quoted if it has spaces)"
            fi
        else
            t="${start%%[[:blank:]]#*}"; t="${t%"${t##*[![:blank:]]}"}"
            # the hint repeats the value: never for a secret, or a key the schema does not know
            if [[ "$t" == *[\"\'\$\\]* ]] || ! _cfg_may_quote "$k" "$t"; then
                _CFG_E="a space ends the value: quote the whole value ($k=\"...\")"
            else _CFG_E="quote the value: $k=\"$t\""; fi
        fi
        return 1
    fi
    _CFG_K="$k"; _CFG_V="$v"; _CFG_RAW="${start%"$s"}"
    return 0
}

# _cfg_record <file> <origin> <line> <key> <value> <raw> <export>: an accepted
# assignment, with the checks that depend on the key. The schema is read
# straight from CS_FLAGS (_CFG_CS: the core loaded): no function call or
# subshell per line.
_cfg_record() {
    local f="$1" o="$2" n="$3" k="$4" x="$7" known=0 fl='' prev
    if [[ "${_CFG_CS:-0}" != 1 ]]; then known=1
    elif [[ -n "${CS_FLAGS[$k]+x}" ]]; then known=1; fl=",${CS_FLAGS[$k]},"; fi
    # an envfile is exported as a whole (to restic only): export there is plain
    if [[ -n "$x" && "$o" != envfile ]]; then
        if (( known )); then
            CFG_WARNINGS+=("$f:$n: export $k: pbo 0.6 reads $k but does not export it to the programs it runs")
        elif _cfg_export_allowed "$k"; then
            CFG_EXPORT[$k]="$5"; known=1
        else
            CFG_ERRORS+=("$f:$n: export $k is not allowed: a config may export only the proxy variables (http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY); put variables for restic (backend credentials) in RESTIC_ENV_FILE, others in a systemd drop-in (Environment=)")
            return 0
        fi
    fi
    if [[ -n "$fl" ]]; then
        # the shared file is replicated to every node by pmxcfs: a key that runs
        # a program, or that only makes sense per node, stays in the local file.
        # Ignored, not fatal: one node's edit must not stop pbo on every node.
        if [[ "$o" == shared && ( "$fl" == *,exec,* || "$fl" == *,local-only,* ) ]]; then
            CFG_IGNORED+=("$f:$n: $k may not be set in the cluster-shared config (it runs a program or is per node): pbo ignores it there; set it in /etc/pbo/config on each node")
            return 0
        fi
        [[ "$fl" != *,internal,* ]] || CFG_WARNINGS+=("$f:$n: $k is a test hook (internal): it does not belong in a production config")
    fi
    if (( ! known )); then
        [[ " ${CFG_UNKNOWN[*]} " == *" $k "* ]] || CFG_UNKNOWN+=("$k")
        if declare -F _cs_env_switch >/dev/null && _cs_env_switch "$k"; then
            CFG_WARNINGS+=("$f:$n: $k is an environment switch, not a config key: pbo 0.6 ignores it in the config (set it in pbo's environment)")
        else
            CFG_WARNINGS+=("$f:$n: unknown key $k (typo?): pbo ignores it")
        fi
    fi
    if [[ -n "${CFG_SRC[$k]+x}" ]]; then
        prev="${CFG_SRC[$k]#*:}"
        [[ "${prev%:*}" != "$f" ]] || CFG_WARNINGS+=("$f:$n: $k is set again (also on line ${prev##*:}): the last one wins")
    fi
    CFG_VAL[$k]="$5"; CFG_RAW[$k]="$6"; CFG_SRC[$k]="$o:$f:$n"; CFG_LINE[$k]="$n"
    return 0
}

# _cfg_parse_file <file> [origin]: read one config file into the results (added
# to what earlier files gave, the way a later sourced file overrides an earlier
# one). origin: shared, local (default), file, or envfile (RESTIC_ENV_FILE: the
# same grammar, any variable name, export allowed; _restic_env_read gives it
# results of its own). Returns 1 when the file has errors.
#
# Grammar, per line (ADR 0009): a UTF-8 BOM on line 1 and a trailing CR are
# dropped (warnings); blank lines and lines whose first non-blank is # are
# skipped; everything else is [blanks][export ]KEY=VALUE[blanks[# comment]].
# VALUE is a run of segments up to the first unquoted blank: plain characters
# (not blank ' " ` $ \ ; & | < > ( ), a # inside is literal, a leading ~ or one
# after : is refused), '...' (literal), "..." (\" \\ \$ \` unescaped, other pairs
# kept) and ${KEY} / $KEY (unquoted or in "...") for a schema key set earlier.
# On an export line an unquoted { is refused too: bash brace-expands the
# argument of export (not a plain assignment), and the bare fast path below
# leaves such a line to the scanner.
#
# Three fast paths take almost every line, each equal to one regex:
#   bare  ^[[:blank:]]*(export[[:blank:]]+)?KEY=([^[:space:]'"`$\;&|<>()~]*)TAIL
#   "..." ^[[:blank:]]*(export[[:blank:]]+)?KEY="([^"`$\]*)"TAIL
#   '...' ^[[:blank:]]*(export[[:blank:]]+)?KEY='([^']*)'TAIL
# with KEY [A-Za-z_][A-Za-z0-9_]* and TAIL ([[:blank:]]+(#.*)?)?$. They are
# written as globs and parameter expansions: bash compiles a regex on every
# [[ =~ ]], a glob costs far less. Every
# other line goes through _cfg_line_slow, which also gives the reason a line is
# refused. _CFG_SLOW=1 sends every line there (tests prove both paths agree).
_cfg_parse_file() {
    local file="$1" origin="${2:-local}"
    declare -p CFG_VAL >/dev/null 2>&1 || _cfg_reset
    declare -p CFG_ENV >/dev/null 2>&1 || declare -gA CFG_ENV=()
    local -a lines=()
    if [[ ! -r "$file" ]] || ! { mapfile -t lines < "$file"; } 2>/dev/null; then
        CFG_ERRORS+=("$file:0: cannot read the file"); return 1
    fi
    # the core of the schema is enough (which keys exist, their flags): it is
    # all load_config loads on a plain start. An envfile (RESTIC_ENV_FILE,
    # lib/restic.sh) is no config: its keys are restic's environment, not
    # schema keys, so it is read as if no schema were loaded (every name
    # counts, and no message ever repeats a value).
    _CFG_CS=0; if [[ "$origin" != envfile ]] && declare -F _cs_core >/dev/null; then _cs_core; _CFG_CS=1; fi
    # byte-wise: the grammar is ASCII, and C-locale matching is faster
    local LC_ALL=C
    local nerr="${#CFG_ERRORS[@]}" n=0 l t k v x val body after r ok sq="'" slow="${_CFG_SLOW:-0}"
    local crs=0 crfirst=0 open='' ofrom=0 omsg='' re_dqclose='(^|[^\])(\\\\)*"'
    for l in "${lines[@]}"; do
        n=$((n+1))
        # most lines of a config: a comment in column 1 (every statement here counts)
        [[ "$l" == '#'* && -z "$open" ]] && continue
        if (( n == 1 )) && [[ "$l" == $'\xef\xbb\xbf'* ]]; then
            l="${l:3}"
            CFG_WARNINGS+=("$file:1: a UTF-8 byte order mark is ignored (bash does not ignore it: pbo 0.5 runs the first line as a command)")
        fi
        if [[ "$l" == *$'\r' ]]; then l="${l%$'\r'}"; crs=$((crs+1)); (( crfirst )) || crfirst="$n"; fi
        t="${l#"${l%%[![:blank:]]*}"}"
        # inside a construct an earlier line opened: skip to its end
        if [[ -n "$open" ]]; then
            case "$open" in
                "$sq") [[ "$l" == *"$sq"* ]] || continue ;;
                '"') [[ "$l" =~ $re_dqclose ]] || continue ;;
                '\') [[ "$l" == *'\' ]] && continue ;;
                '{') [[ "$t" == '}'* ]] || continue ;;
            esac
            CFG_ERRORS+=("$file:$ofrom: $omsg (lines $ofrom-$n)"); open=''
            continue
        fi
        [[ -z "$t" || "$t" == '#'* ]] && continue
        # the fast paths (see above); ok=1 when one takes the line
        ok=0; x=''
        if [[ "$t" == export[[:blank:]]* ]]; then x=1; t="${t:6}"; t="${t#"${t%%[![:blank:]]*}"}"; fi
        k="${t%%=*}"
        if [[ "$slow" != 1 && "$t" == *=* && "$k" == [A-Za-z_]* && "$k" != *[!A-Za-z0-9_]* ]]; then
            v="${t#*=}"
            case "$v" in
                \"*) val="${v:1}"; body="${val%%\"*}"
                     if [[ "$body" != "$val" && "$body" != *[\\\`\$]* ]]; then after="${val:${#body}+1}"; v="\"$body\""; ok=1; fi ;;
                "$sq"*) val="${v:1}"; body="${val%%"$sq"*}"
                     if [[ "$body" != "$val" ]]; then after="${val:${#body}+1}"; v="$sq$body$sq"; ok=1; fi ;;
                *) body="${v%%[[:blank:]]*}"
                   # an export line with a { goes to the scanner (bash brace-expands it there)
                   if [[ "$body" != *[\'\"\`\$\\\;\&\|\<\>\(\)~]* && ( -z "$x" || "$body" != *'{'* ) ]]; then after="${v:${#body}}"; v="$body"; ok=1; fi ;;
            esac
            if (( ok )) && [[ -n "$after" ]]; then
                r="${after#"${after%%[![:blank:]]*}"}"
                [[ "$after" == [[:blank:]]* && ( -z "$r" || "$r" == '#'* ) ]] || ok=0
            fi
        fi
        if (( ok )); then
            _cfg_record "$file" "$origin" "$n" "$k" "$body" "$v" "$x"
            continue
        fi
        _CFG_W=''
        if _cfg_line_slow "$l"; then
            _cfg_record "$file" "$origin" "$n" "$_CFG_K" "$_CFG_V" "$_CFG_RAW" "$_CFG_X"
            [[ -z "$_CFG_W" ]] || CFG_WARNINGS+=("$file:$n: $_CFG_W")
        elif [[ -n "$_CFG_OPEN" ]]; then
            open="$_CFG_OPEN"; ofrom="$n"; omsg="$_CFG_E"
        else
            CFG_ERRORS+=("$file:$n: $_CFG_E")
        fi
    done
    [[ -z "$open" ]] || CFG_ERRORS+=("$file:$ofrom: $omsg (from line $ofrom to the end of the file)")
    (( crs == 0 )) || CFG_WARNINGS+=("$file:$crfirst: Windows line endings: the CR at the end of $crs line(s) is ignored (bash keeps it in the value)")
    (( ${#CFG_ERRORS[@]} == nerr ))
}

# _cfg_config_files: the files load_config reads, in order → _CFG_FPATH and
# _CFG_FORIGIN. With PBO_CONFIG only that file; else the cluster-shared
# /etc/pve/pbo/config, then the local /etc/pbo/config (which wins). The entry
# with origin local is the file writers write (PBO_CONFIG_LOCAL), whether it
# exists or not.
_cfg_config_files() {
    if [[ -n "${PBO_CONFIG:-}" ]]; then _CFG_FPATH=("$PBO_CONFIG"); _CFG_FORIGIN=(local); return 0; fi
    _CFG_FPATH=(/etc/pve/pbo/config /etc/pbo/config); _CFG_FORIGIN=(shared local)
}

# _cfg_parse_all: read the config files as load_config merges them (each that
# exists), without its owner/mode rules (_config_file_check in lib/common.sh).
# Returns 1 when a file has errors.
_cfg_parse_all() {
    _cfg_reset
    _cfg_config_files
    local i rc=0
    for i in "${!_CFG_FPATH[@]}"; do
        [[ -f "${_CFG_FPATH[i]}" ]] || continue
        # skipped by load_config too: the shared file a non-root caller cannot read
        [[ "${_CFG_FORIGIN[i]}" != shared || "$EUID" == 0 || -r "${_CFG_FPATH[i]}" ]] || continue
        PBO_CONFIG_FILES+=("${_CFG_FPATH[i]}")
        _cfg_parse_file "${_CFG_FPATH[i]}" "${_CFG_FORIGIN[i]}" || rc=1
    done
    return "$rc"
}

# _cfg_check_values [role]: the checks `pbo config check` adds once the files are
# read (warnings at the line that set the value): the type of every schema key,
# keys the role does not use, deprecated keys. Needs the schema. The role checks
# every command makes at startup (_role_check, lib/appendonly.sh) are errors
# here: `config check` skips them so that it can report them.
_cfg_check_values() {
    local role="${1:-host}" k src f n msg new
    declare -F _cs_validate >/dev/null || return 0
    _cs_load
    for k in "${CS_ORDER[@]}"; do
        [[ -n "${CFG_VAL[$k]+x}" ]] || continue
        src="${CFG_SRC[$k]#*:}"; f="${src%:*}"; n="${src##*:}"
        if ! _cs_validate "$k" "${CFG_VAL[$k]}" >/dev/null; then
            msg="$(_cs_validate "$k" "${CFG_VAL[$k]}")" || true
            if [[ "$k" == PBO_ROLE ]]; then CFG_ERRORS+=("$f:$n: $msg: every pbo command stops on it")
            else CFG_WARNINGS+=("$f:$n: $msg"); fi
        fi
        _cs_has_role "$k" "$role" || CFG_WARNINGS+=("$f:$n: $k is not used on a $role (it is a ${CS_ROLES[$k]//,/ and } key)")
        if [[ ",${CS_FLAGS[$k]}" == *,deprecated=* ]]; then
            new="${CS_FLAGS[$k]#*deprecated=}"; new="${new%%,*}"
            CFG_WARNINGS+=("$f:$n: $k is replaced by $new")
        fi
    done
    if [[ "${CFG_VAL[PBO_ROLE]:-}" == janitor ]]; then
        src="${CFG_SRC[PBO_ROLE]#*:}"; f="${src%:*}"; n="${src##*:}"
        [[ "${CFG_VAL[PBO_INTEGRATION]:-standalone}" == standalone ]] \
            || CFG_ERRORS+=("$f:$n: PBO_ROLE=janitor with PBO_INTEGRATION=${CFG_VAL[PBO_INTEGRATION]}: a janitor has no Proxmox, only standalone is allowed (every pbo command stops on it)")
        [[ "${CFG_VAL[OFFSITE_APPEND_ONLY]:-false}" != true ]] \
            || CFG_ERRORS+=("$f:$n: PBO_ROLE=janitor with OFFSITE_APPEND_ONLY=true: the janitor is the one that prunes, it needs write access to the repo (every pbo command stops on it)")
    fi
    return 0
}

# _cfg_compare_bash: what bash makes of the files the reader read
# (PBO_CONFIG_FILES, in that order), for migration debugging (`pbo config check
# --compare-bash`) and the test corpus (load_config's test hook). It RUNS the
# files as code, as pbo 0.5 did, so it is never part of a normal load: in a
# subshell with a clean environment (env -i: PATH, and the schema keys the
# environment held, CFG_ENV, so a reference resolves as for the reader),
# stdin and stdout closed off, under a timeout, never in pbo's own shell.
# Without set -u: a value bash would stop on is still compared.
# → CFG_BASH[K] (the value bash gave K), CFG_BASH_SET[K] (1 when bash set K),
# CFG_DIFF (the keys the reader read whose two readings differ) and
# CFG_BASH_FAIL ("<file><US><why>": parse when bash -n rejects the file, stops
# when bash ended inside it: an exit or a ${X:?}).
_cfg_compare_bash() {
    declare -gA CFG_BASH=() CFG_BASH_SET=()
    declare -ga CFG_DIFF=() CFG_BASH_FAIL=()
    local k f rec out envs=() keys=() done_files=' '
    (( ${#PBO_CONFIG_FILES[@]} )) || return 0
    keys=("${!CFG_VAL[@]}")
    for k in "${!CFG_ENV[@]}"; do envs+=("$k=${CFG_ENV[$k]}"); done
    for f in "${PBO_CONFIG_FILES[@]}"; do
        "${BASH:-bash}" -n -- "$f" 2>/dev/null || CFG_BASH_FAIL+=("$f"$'\x1f'parse)
    done
    # records: F<US>file after each file bash got through, then K<US>key<US>set<US>value
    out="$(env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "${envs[@]+"${envs[@]}"}" timeout 60 bash --norc --noprofile -c '
        n="$1"; shift
        for f in "${@:1:n}"; do source "$f" >/dev/null 2>&1 </dev/null; printf "F\x1f%s\x1e" "$f"; done
        shift "$n"
        for k; do if [[ -n "${!k+x}" ]]; then printf "K\x1f%s\x1f1\x1f%s\x1e" "$k" "${!k}"; else printf "K\x1f%s\x1f0\x1f\x1e" "$k"; fi; done
    ' _ "${#PBO_CONFIG_FILES[@]}" "${PBO_CONFIG_FILES[@]}" "${keys[@]+"${keys[@]}"}" 2>/dev/null)" || true
    while [[ "$out" == *$'\x1e'* ]]; do
        rec="${out%%$'\x1e'*}"; out="${out#*$'\x1e'}"
        case "$rec" in
            F$'\x1f'*) done_files+="${rec#F$'\x1f'} " ;;
            K$'\x1f'*)
                rec="${rec#K$'\x1f'}"; k="${rec%%$'\x1f'*}"; rec="${rec#*$'\x1f'}"
                CFG_BASH_SET[$k]="${rec%%$'\x1f'*}"; CFG_BASH[$k]="${rec#*$'\x1f'}" ;;
        esac
    done
    for f in "${PBO_CONFIG_FILES[@]}"; do
        [[ "$done_files" == *" $f "* ]] && continue
        CFG_BASH_FAIL+=("$f"$'\x1f'stops); break
    done
    for k in "${keys[@]+"${keys[@]}"}"; do
        [[ "${CFG_BASH_SET[$k]:-0}" == 1 && "${CFG_BASH[$k]}" == "${CFG_VAL[$k]}" ]] || CFG_DIFF+=("$k")
    done
    return 0
}
