#!/usr/bin/env bash
export PBO_NO_NOTIFY=1
# tests/config_parse.sh: the strict config reader (lib/config_parse.sh, ADR 0009
# "Config grammar", 0.6 M2). Every line it accepts must give exactly the value
# bash gives when it sources the file; every line bash cannot parse it must
# refuse; the fast paths and the character scanner must agree; the shipped
# configs read cleanly; `pbo config check`, doctor's shadow comparison and the
# startup cost are pinned. Only accepted fixtures are ever sourced, by a clean
# `env -i bash` in run-config-parse/; the refused ones use harmless commands
# (true, id, printf) in case one were sourced by mistake.
#
# tests/config_parse.sh --corpus <log>: the check tests/all.sh runs last over
# PBO_TEST_CONFIG_LOG, the strict reader's verdict on every config file the
# whole suite loaded (load_config's test hook).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start) are the
# machine's own files: point them into the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.env" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
    PBO_PVE_CFS_DIR="$PWD/run-none/pve" PVE_STORAGE_CFG="$PWD/run-none/pve/storage.cfg"
ROOT="$PWD"; BIN=./pbo
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

# --- corpus mode ------------------------------------------------------------------------------
# Only this suite's own fixtures may give a problem: since 0.6 M3 the config is
# no longer run as code, so no other suite may rely on code in a config (a test
# that needs a changed function copies the source tree, tests/regressions.sh).
if [[ "${1:-}" == --corpus ]]; then
    log="${2:-}"
    printf 'pbo: strict reader over every config the suite loaded\n'
    [[ -s "$log" ]] || { bad "no corpus log ($log): run through tests/all.sh"; printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1; }
    expected() { [[ "$1" == "$ROOT/run-config-parse/"* ]]; }
    nfiles="$(awk -F'\t' '$1 == "FILE" { print $2 }' "$log" | sort -u | grep -vc "^$ROOT/run-config-parse/")"
    nloads="$(grep -c '^FILE' "$log")"
    probs=''
    while IFS=$'\t' read -r kind a b; do
        case "$kind" in
            ERROR) expected "$a" || probs+="  error  $a"$'\n' ;;
            DIFF)  expected "$a" || probs+="  differs  $b ($a)"$'\n' ;;
        esac
    done < "$log"
    probs="$(sort -u <<<"$probs")"
    [[ -z "$probs" ]] && ok "the strict reader accepts every one and agrees with bash on every key" \
        || bad "strict reader vs bash on the suite's configs:"$'\n'"$probs"
    # positive controls: this suite's fixtures reach the log, so "accepts every
    # one" and "agrees on every key" above did check something
    grep -qxF "DIFF	$ROOT/run-config-parse/crlf.cfg:9	VERIFY_SUBSET" "$log" \
        && ok "it reports the key crlf.cfg reads differently from bash (DIFF records reach the log)" || bad "crlf.cfg's difference not in the corpus log"
    grep -q "^ERROR	$ROOT/run-config-parse/bad.cfg:9: command substitution" "$log" \
        && ok "it reports the line bad.cfg has that pbo refuses (ERROR records reach the log)" || bad "bad.cfg's error not in the corpus log"
    # no suite reads (or doctor --fix changes) the machine's own secret files:
    # every RESTIC_ENV_FILE a load resolved is inside the checkout, every other
    # secret file inside it or absent (SECRETFILE records, _cfg_test_log_files)
    probs=''
    while IFS=$'\t' read -r k p c; do
        [[ -n "$k" ]] || continue
        [[ "$k" == RESTIC_ENV_FILE || -e "$p" ]] && probs+="  $k=$p ($c)"$'\n'
    done < <(awk -F'\t' -v r="$ROOT/" '$1 == "SECRETFILE" && index($3, r) != 1 { print $2 "\t" $3 "\t" $4 }' "$log" | sort -u)
    [[ -z "$probs" ]] && ok "no config a suite loaded points a secret file (RESTIC_ENV_FILE, the password files, NTFY_CREDS_FILE) at the machine's own" \
        || bad "secret files outside the checkout (set them to a path in run*/):"$'\n'"$probs"
    # the check above passes on a machine without those files: a load that
    # resolved a secret file to its schema default (the path an installed pbo
    # uses) fails on every machine, so it does not wait for one that has the
    # file. A test that resolves the default on purpose (a guard test that
    # stops pbo after load_config) runs without PBO_TEST_CONFIG_LOG.
    probs=''
    while IFS=$'\t' read -r k p; do
        [[ -n "$k" ]] || continue
        probs+="$(awk -F'\t' -v k="$k" -v p="$p" '$1 == "SECRETFILE" && $2 == k && $3 == p { print "  " k "=" p " (" $4 ")" }' "$log" | sort -u)"
    done < <(bash -c 'source lib/config_schema.sh; _cs_load; for k in RESTIC_ENV_FILE RESTIC_PASSWORD_FILE RESTIC_REST_PASSWORD_FILE NTFY_CREDS_FILE; do printf "%s\t%s\n" "$k" "${CS_DEFAULT[$k]}"; done')
    [[ -z "$probs" ]] && ok "no load resolved a secret file to its schema default (whether or not this machine has it)" \
        || bad "secret files at their schema default, the path an installed pbo uses:"$'\n'"$probs"
    grep -q "^SECRETFILE	RESTIC_ENV_FILE	$ROOT/" "$log" \
        && ok "the resolved secret files reach the log (SECRETFILE records)" || bad "no SECRETFILE record for RESTIC_ENV_FILE in the corpus log"
    # most suites skip themselves without restic: the same test here, not
    # whether a run-*/ dir exists (one may be left over from an earlier run)
    if command -v restic >/dev/null 2>&1; then
        [[ "$nfiles" -ge 40 ]] && ok "the suite loaded $nfiles distinct config files ($nloads loads)" || bad "only $nfiles config files in the corpus"
    else
        ok "restic not installed: corpus size assertion skipped (those suites skipped; $nfiles files, $nloads loads)"
    fi
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    (( fail == 0 )); exit
fi

printf 'pbo: strict config reader tests\n'
RUN="$ROOT/run-config-parse"; rm -rf "$RUN"; mkdir -p "$RUN"/{fx,cache,state,log,lock,bin,conf,lxc}
install -m 0755 tests/mocks/pct tests/mocks/qm tests/mocks/vzdump tests/mocks/pvesh tests/mocks/pvesm tests/mocks/systemctl "$RUN/bin/"   # never the real host
export PATH="$RUN/bin:$PATH" MOCK_CONF_DIR="$RUN/conf" MOCK_LOG="$RUN/calls"

# P <file...>: the reader's view of each file (each read alone), in a clean
# environment: "<file>|V|<key>|<value %q>|<raw %q>", "<file>|E|<line>|<message>",
# "<file>|W|<line>|<message>", "<file>|X|<key>" (exported). SLOW=1: no fast paths.
P() {
    env -i PATH="$PATH" _CFG_SLOW="${SLOW:-0}" bash -c 'set -u; source lib/config_schema.sh; source lib/config_parse.sh
        for f in "$@"; do
            _cfg_reset; _cfg_parse_file "$f" local
            for k in "${!CFG_VAL[@]}"; do printf "%s|V|%s|%q|%q\n" "$f" "$k" "${CFG_VAL[$k]}" "${CFG_RAW[$k]}"; done
            for k in "${!CFG_EXPORT[@]}"; do printf "%s|X|%s\n" "$f" "$k"; done
            for e in "${CFG_ERRORS[@]}"; do r="${e#"$f:"}"; printf "%s|E|%s|%s\n" "$f" "${r%%:*}" "${r#*: }"; done
            for e in "${CFG_WARNINGS[@]}"; do r="${e#"$f:"}"; printf "%s|W|%s|%s\n" "$f" "${r%%:*}" "${r#*: }"; done
        done | sort' _ "$@"
}
# B <file> <key>: what bash makes of KEY after sourcing the file (set -u, clean env), %q
B() { ( cd "$RUN" && env -i bash --norc --noprofile -c 'set -u; source "$1"; printf %q "${!2}"' _ "$1" "$2" 2>/dev/null ); }

# --- the fixture table ----------------------------------------------------------------------------
# fx <expect> <content> [note]. expect: ok KEY (accepted; KEY must equal bash),
# err[:<text in the message>] (refused), crlf KEY / bom KEY (accepted with a
# warning; equal to bash once the CR / BOM is gone).
fx_exp=(); fx_body=()
fx() { fx_exp+=("$1"); fx_body+=("$2"); }
fx 'ok CACHE_DIR'  'CACHE_DIR=/a#b'
fx 'ok CACHE_DIR'  'CACHE_DIR=#x'
fx 'ok CACHE_DIR'  'CACHE_DIR="a # b"'
fx 'ok CACHE_DIR'  'CACHE_DIR="a"#b'
fx 'ok CACHE_DIR'  "CACHE_DIR='\$(id)'"
fx 'ok CACHE_DIR'  'CACHE_DIR="\$x \" \\ \n"'
fx 'ok CACHE_DIR'  'CACHE_DIR="a\\\$b \`"'
fx 'ok CACHE_DIR'  'CACHE_DIR='
fx 'ok CACHE_DIR'  'CACHE_DIR=""'
fx 'ok CACHE_DIR'  "CACHE_DIR=''"
fx 'ok CACHE_DIR'  $'\tCACHE_DIR=x\t# a comment after a tab'
fx 'ok CACHE_DIR'  $'CACHE_DIR="a\tb"'
fx 'ok CACHE_DIR'  '   CACHE_DIR=x   '
fx 'ok CACHE_DIR'  'CACHE_DIR=x#'
fx 'ok CACHE_DIR'  'CACHE_DIR=x"y"'"'z'"
fx 'ok CACHE_DIR'  "CACHE_DIR='a'\"b\"c"
fx 'ok CACHE_DIR'  "CACHE_DIR=\"it's\""
fx 'ok CACHE_DIR'  "CACHE_DIR='say \"hi\"'"
fx 'ok CACHE_DIR'  'CACHE_DIR=a=b,c:d@e%f+g'
fx 'ok CACHE_DIR'  'CACHE_DIR=*'
fx 'ok CACHE_DIR'  'CACHE_DIR={a,b}'
fx 'ok CACHE_DIR'  'CACHE_DIR=[x]?'
fx 'ok CACHE_DIR'  'CACHE_DIR=a~b'
fx 'ok CACHE_DIR'  'CACHE_DIR="~/x"'
fx 'ok CACHE_DIR'  'CACHE_DIR=/var/cache/pbo-é'
fx 'ok CACHE_DIR'  'CACHE_DIR="dump all→upload"'
fx 'ok CACHE_DIR'  'CACHE_DIR=a!b'
fx 'ok CACHE_DIR'  'export CACHE_DIR=/x'
fx 'ok https_proxy' 'export https_proxy=http://proxy.invalid:3128'
fx 'ok RESTIC_CACHE_REPO' $'CACHE_DIR=/c\nRESTIC_CACHE_REPO=${CACHE_DIR}/x'
fx 'ok RESTIC_CACHE_REPO' $'CACHE_DIR=/c\nRESTIC_CACHE_REPO=$CACHE_DIR/x'
fx 'ok RESTIC_CACHE_REPO' $'CACHE_DIR=/c\nRESTIC_CACHE_REPO="$CACHE_DIR/r e"'
fx 'ok RESTIC_CACHE_REPO' $'CACHE_DIR=\nRESTIC_CACHE_REPO=${CACHE_DIR}/x'
fx 'ok PVE_SPOOL_DIR' $'CACHE_DIR="/a b"\nPVE_SPOOL_DIR=${CACHE_DIR}:"${CACHE_DIR}"'"'\$CACHE_DIR'"
fx 'ok KEEP_LOCAL' $'KEEP_LOCAL=2 # first\nKEEP_LOCAL=3'
fx 'ok KEEP_LOCAL' $'KEEP_LOCAL=3\n# KEEP_LOCAL=9\n   # indented comment\n\n\t\n'
fx 'ok MY_TYPO'    'MY_TYPO=1'
fx 'crlf CACHE_DIR' $'CACHE_DIR=/x\r\nKEEP_LOCAL=2\r'
fx 'bom CACHE_DIR'  $'\xef\xbb\xbfCACHE_DIR=/x'
fx 'err:export FOO is not allowed'      'export FOO=1'
fx 'err:export takes exactly one'        'export CACHE_DIR'
fx 'err:command substitution'            'CACHE_DIR=$(id)'
fx 'err:command substitution'            'CACHE_DIR="$(id)"'
fx 'err:command substitution'            'CACHE_DIR=`id`'
fx 'err:command substitution'            'CACHE_DIR="x`id`"'
fx "err:';' is a shell operator"         'CACHE_DIR=a;id'
fx "err:'&' is a shell operator"         'CACHE_DIR=a&true'
fx "err:'|' is a shell operator"         'CACHE_DIR=a|true'
fx "err:'>' is a shell operator"         'CACHE_DIR=a>b'
fx 'err:quote the value: CACHE_DIR="a b"' 'CACHE_DIR=a b'
fx 'err:quote the whole value (NTFY_TOPIC=' 'NTFY_TOPIC=sec ret'
fx 'err:quote the whole value'           'CACHE_DIR="a" b'
fx "err:no spaces around '='"            'CACHE_DIR = v'
fx "err:a space after '='"               'CACHE_DIR= true'
fx 'err:one assignment per line'         'CACHE_DIR=1 KEEP_LOCAL=2'
fx 'err:CACHE_DIR+= appends'             'CACHE_DIR+=v'
fx 'err:arrays are not supported'        'CACHE_DIR[1]=v'
fx 'err:arrays are not supported'        'CACHE_DIR=(a b)'
fx 'err:function definitions'            'f() { true; }'
fx 'err:function definitions'            'function f { true; }'
fx 'err:function definitions'            $'f() {\n  true\n}\nKEEP_LOCAL=3'
fx 'err:source / . is not allowed'       'source /dev/null'
fx 'err:source / . is not allowed'       '. /dev/null'
fx 'err:shell commands'                  'if true; then CACHE_DIR=1; fi'
fx 'err:shell commands'                  'for i in 1; do true; done'
fx 'err:shell commands'                  'while false; do true; done'
fx 'err:readonly is not allowed'         'readonly CACHE_DIR=1'
fx 'err:declare is not allowed'          'declare CACHE_DIR=1'
fx 'err:unset is not allowed'            'unset CACHE_DIR'
fx 'err:not a KEY=VALUE line'            'true'
fx 'err:unterminated double quote'       'CACHE_DIR="abc'
fx "err:unterminated single quote"       "CACHE_DIR='abc"
fx 'err:unterminated double quote'       $'CACHE_DIR="a\nb"\nKEEP_LOCAL=3'
fx 'err:a trailing backslash'            $'CACHE_DIR=a\\\nb'
fx 'err:a backslash outside quotes'      'CACHE_DIR=a\ b'
fx 'err:write the full path'             'CACHE_DIR=~/x'
fx 'err:write the full path'             'CACHE_DIR=~'
fx 'err:write the full path'             'CACHE_DIR=/a:~/x'
fx 'err:is used before it is set'        'RESTIC_CACHE_REPO=${CACHE_DIR}/x'
fx 'err:is used before it is set'        'RESTIC_CACHE_REPO="$CACHE_DIR/x"'
fx 'err:$HOME is not a config key'       'CACHE_DIR=${HOME}'
fx 'err:$HOME is not a config key'       'CACHE_DIR="$HOME/x"'
fx 'err:not ${X:-y}'                     'CACHE_DIR=${X:-y}'
fx 'err:not ${CACHE_DIR:-/y}'            $'CACHE_DIR=/c\nRESTIC_CACHE_REPO=${CACHE_DIR:-/y}'
fx 'err:not ${#CACHE_DIR}'               $'CACHE_DIR=/c\nRESTIC_CACHE_REPO=${#CACHE_DIR}'
fx "err:'\$1' is not a reference"        'CACHE_DIR=$1'
fx "err:'\$\$' is not a reference"       'CACHE_DIR=a$$'
fx 'err:$CACHE_DIRx is not a config key' $'CACHE_DIR=/c\nRESTIC_CACHE_REPO=$CACHE_DIRx'

# write the fixtures
nfx="${#fx_exp[@]}"; files=()
for i in "${!fx_exp[@]}"; do printf '%s\n' "${fx_body[i]}" > "$RUN/fx/$i.cfg"; files+=("$RUN/fx/$i.cfg"); done
out="$(P "${files[@]}")"
fails=''; nacc=0; nrej=0
for i in "${!fx_exp[@]}"; do
    f="$RUN/fx/$i.cfg"; exp="${fx_exp[i]}"; mine="$(grep -F "$f|" <<<"$out")"
    errs="$(grep -F "$f|E|" <<<"$mine")"
    case "$exp" in
        ok\ *|crlf\ *|bom\ *)
            k="${exp#* }"
            v="$(sed -n "s#^$f|V|$k|\([^|]*\)|.*#\1#p" <<<"$mine")"
            if [[ -n "$errs" || -z "$(grep -F "$f|V|$k|" <<<"$mine")" ]]; then fails+="  #$i refused: ${fx_body[i]@Q} → ${errs:-no value for $k}"$'\n'; continue; fi
            src="$f"
            case "$exp" in
                crlf*) tr -d '\r' < "$f" > "$f.bash"; src="$f.bash"
                       grep -qF "$f|W|1|Windows line endings" <<<"$mine" || fails+="  #$i: no CR warning"$'\n' ;;
                bom*)  tail -c +4 "$f" > "$f.bash"; src="$f.bash"
                       grep -qF "$f|W|1|a UTF-8 byte order mark" <<<"$mine" || fails+="  #$i: no BOM warning"$'\n' ;;
            esac
            b="$(B "$src" "$k")" || { fails+="  #$i: bash could not source ${fx_body[i]@Q}"$'\n'; continue; }
            [[ "$v" == "$b" ]] || fails+="  #$i ${fx_body[i]@Q}: reader $v, bash $b"$'\n'
            nacc=$((nacc+1)) ;;
        err*)
            want="${exp#err}"; want="${want#:}"
            if [[ -z "$errs" ]]; then fails+="  #$i accepted: ${fx_body[i]@Q}"$'\n'
            elif [[ -n "$want" ]] && ! grep -qF -- "$want" <<<"$errs"; then fails+="  #$i ${fx_body[i]@Q}: '$want' not in: $errs"$'\n'; fi
            nrej=$((nrej+1)) ;;
    esac
done
[[ -z "$fails" ]] && ok "fixture table: $nacc accepted lines equal bash's value, $nrej refused with the right reason" || bad "fixtures:"$'\n'"$fails"

# every fixture bash cannot even parse is refused too
fails=''
for i in "${!fx_exp[@]}"; do
    bash -n "$RUN/fx/$i.cfg" 2>/dev/null && continue
    grep -qF "$RUN/fx/$i.cfg|E|" <<<"$out" || fails+=" #$i"
done
[[ -z "$fails" ]] && ok "every fixture bash -n rejects is refused" || bad "bash rejects, the reader accepts:$fails"

# details the table does not show
g() { grep -F "$RUN/fx/$1.cfg|$2" <<<"$out"; }
idx() { local i; for i in "${!fx_body[@]}"; do [[ "${fx_body[i]}" == "$1" ]] && { echo "$i"; return; }; done; echo none; }
i="$(idx 'export CACHE_DIR=/x')"; g "$i" 'W|1|export CACHE_DIR: pbo 0.6 reads CACHE_DIR but does not export it' >/dev/null && ! g "$i" X >/dev/null \
    && ok "export of a schema key: accepted with a warning, not exported" || bad "export schema key: $(g "$i" '')"
i="$(idx 'export https_proxy=http://proxy.invalid:3128')"; g "$i" 'X|https_proxy' >/dev/null && ! g "$i" W >/dev/null \
    && ok "export of a proxy variable: accepted and recorded for export (M3 passes it on)" || bad "export proxy: $(g "$i" '')"
i="$(idx 'export FOO=1')"; g "$i" 'E|1|export FOO is not allowed' | grep -q 'systemd drop-in (Environment=)' && ! g "$i" V >/dev/null \
    && ok "export of any other variable: refused with the drop-in hint, nothing assigned" || bad "export other: $(g "$i" '')"
i="$(idx 'MY_TYPO=1')"; g "$i" 'W|1|unknown key MY_TYPO' >/dev/null && ok "an unknown key: kept for the comparison, with a warning" || bad "unknown: $(g "$i" '')"
i="$(idx $'KEEP_LOCAL=2 # first\nKEEP_LOCAL=3')"; g "$i" 'W|2|KEEP_LOCAL is set again (also on line 1): the last one wins' >/dev/null \
    && ok "a key set twice: the last wins, with a warning" || bad "dup: $(g "$i" '')"
i="$(idx $'f() {\n  true\n}\nKEEP_LOCAL=3')"; [[ "$(g "$i" 'E|' | wc -l)" == 1 ]] && g "$i" 'E|1|function definitions are not allowed: pbo 0.6 does not run the config (lines 1-3)' >/dev/null \
    && g "$i" 'V|KEEP_LOCAL|3|' >/dev/null && ok "a function body is one error for its lines, the line after it is read" || bad "function body: $(g "$i" '')"
i="$(idx $'CACHE_DIR="a\nb"\nKEEP_LOCAL=3')"; g "$i" 'E|1|unterminated double quote: a value must fit on one line (lines 1-2)' >/dev/null && g "$i" 'V|KEEP_LOCAL|3|' >/dev/null \
    && ! g "$i" 'V|CACHE_DIR' >/dev/null && ok "a multi-line quote: refused with its lines, nothing inside it read" || bad "multi-line: $(g "$i" '')"
i="$(idx 'CACHE_DIR="abc')"; g "$i" 'E|1|unterminated double quote: a value must fit on one line (from line 1 to the end of the file)' >/dev/null \
    && ok "an unterminated quote: named to the end of the file" || bad "unterminated: $(g "$i" '')"
i="$(idx 'NTFY_TOPIC=sec ret')"; ! grep -q 'sec ret' <<<"$(g "$i" E)" && ok "a refused secret line does not repeat the value" || bad "secret hint: $(g "$i" E)"
# no refusal message repeats a secret's value, a URL credential or the value of
# a key the schema does not know (doctor, config check, the install.sh guard and
# the .deb postinst print them); a plain key keeps the helpful text
printf '%s\n' 'NTFY_TOKEN= tk_abc123' > "$RUN/leak1.cfg"
printf '%s\n' 'NTFY_TOKEN=${NTFY_TOKEN:-tk_abc123}' > "$RUN/leak2.cfg"
printf '%s\n' 'NTFY_TOPIC="${NTFY_TOPIC:-tk_abc123}"' > "$RUN/leak3.cfg"
printf '%s\n' 'RESTIC_OFFSITE_REPO= rest:https://u:tk_abc123@h/r' > "$RUN/leak4.cfg"
printf '%s\n' 'RESTIC_OFFSITE_REPO=${X:-rest:https://u:tk_abc123@h/r}' > "$RUN/leak5.cfg"
printf '%s\n' 'MY_TYPO= tk_abc123' > "$RUN/leak6.cfg"
printf '%s\n' 'RESTIC_OFFSITE_REPO=${X:-https://h/r?token=tk_abc123}' > "$RUN/leak9.cfg"
printf '%s\n' 'NTFY_TOKEN=ab tk_abc123=1' > "$RUN/leak10.cfg"
printf '%s\n' 'NTFY_TOKEN=$tk_abc123' > "$RUN/leak7.cfg"
printf '%s\n' 'NTFY_TOKEN="x$tk_abc123"' > "$RUN/leak8.cfg"
leaks=("$RUN"/leak{1..10}.cfg)
fails=''
for slow in 0 1; do
    lo="$(SLOW=$slow P "${leaks[@]}")"
    for f in "${leaks[@]}"; do grep -qF "$f|E|1|" <<<"$lo" || fails+=" not refused (SLOW=$slow): $(cat "$f");"; done
    grep -q 'tk_abc123' <<<"$(grep '|E|' <<<"$lo")" && fails+=" leaked (SLOW=$slow): $(grep '|E|.*tk_abc123' <<<"$lo");"
done
lo="$(P "$RUN/fx/$(idx 'CACHE_DIR= true').cfg" "$RUN/fx/$(idx 'CACHE_DIR=${X:-y}').cfg")"
grep -qF "|E|1|a space after '=': bash runs 'true' as a command" <<<"$lo" && grep -qF 'not ${X:-y}: write the value out' <<<"$lo" || fails+=" plain key lost its hint: $lo"
[[ -z "$fails" ]] && ok "refusals never repeat a secret, a URL credential or an unknown key's value (a plain key keeps the hint)" || bad "refusal messages:$fails"

# export is a declaration builtin: bash brace-expands its argument, so an
# unquoted { there is refused (fast path and scanner); a plain assignment or a
# quoted brace is read literally, as bash does
printf '%s\n' 'export http_proxy=http://{a,b}:3128' > "$RUN/br1.cfg"
printf '%s\n' 'export KEEP_LOCAL={1,2}' > "$RUN/br2.cfg"
printf '%s\n' "export KEEP_LOCAL='{'1,2}x{'a',b}" > "$RUN/br3.cfg"
printf '%s\n' 'KEEP_LOCAL={1,2}' > "$RUN/br4.cfg"
printf '%s\n' "export http_proxy='http://{a,b}:3128'" > "$RUN/br5.cfg"
fails=''
for slow in 0 1; do
    lo="$(SLOW=$slow P "$RUN"/br{1..5}.cfg)"
    for f in "$RUN"/br{1..3}.cfg; do
        grep -qF "$f|E|1|an unquoted { on an export line: bash brace-expands it" <<<"$lo" && ! grep -qF "$f|V|" <<<"$lo" || fails+=" accepted (SLOW=$slow): $(cat "$f");"
    done
    grep -qxF "$RUN/br4.cfg|V|KEEP_LOCAL|\{1\,2\}|\{1\,2\}" <<<"$lo" || fails+=" plain {1,2} (SLOW=$slow): $(grep -F br4 <<<"$lo");"
    [[ "$(B "$RUN/br4.cfg" KEEP_LOCAL)" == '\{1\,2\}' ]] || fails+=" bash reads br4 as $(B "$RUN/br4.cfg" KEEP_LOCAL);"
    grep -qF "$RUN/br5.cfg|V|http_proxy|http://\{a\,b\}:3128|" <<<"$lo" && grep -qxF "$RUN/br5.cfg|X|http_proxy" <<<"$lo" && ! grep -qF "$RUN/br5.cfg|E|" <<<"$lo" \
        || fails+=" quoted braces (SLOW=$slow): $(grep -F br5 <<<"$lo");"
done
[[ "$(B "$RUN/br5.cfg" http_proxy)" == 'http://\{a\,b\}:3128' ]] || fails+=" bash reads br5 as $(B "$RUN/br5.cfg" http_proxy);"
[[ -z "$fails" ]] && ok "export with an unquoted brace: refused on both paths (bash brace-expands it); KEEP_LOCAL={1,2} and quoted braces read literally" || bad "export braces:$fails"
i="$(idx $'CACHE_DIR=/c\nRESTIC_CACHE_REPO=${CACHE_DIR}/x')"; g "$i" 'V|RESTIC_CACHE_REPO|/c/x|\$\{CACHE_DIR\}/x' >/dev/null \
    && ok "CFG_RAW keeps the value as written (the reference)" || bad "raw: $(g "$i" V)"

# --- fast paths and the scanner agree ---------------------------------------------------------------
corpus=("${files[@]}" etc/config.example etc/config.janitor.example etc/config.dev)
a="$(P "${corpus[@]}")"; b="$(SLOW=1 P "${corpus[@]}")"
[[ -n "$a" && "$a" == "$b" ]] && ok "fast paths and the scanner give the same result on every fixture and example ($(grep -c '|V|' <<<"$a") values)" \
    || bad "fast vs slow: $(diff <(echo "$a") <(echo "$b") | head -20)"
n="$(env -i PATH="$PATH" bash -c 'set -u; source lib/config_schema.sh; source lib/config_parse.sh
    _cfg_line_slow() { echo slow >&2; return 1; }; _cfg_parse_file etc/config.example local' 2>&1 | grep -c slow)"
[[ "$n" == 0 ]] && ok "etc/config.example takes the fast paths only" || bad "config.example: $n line(s) took the scanner"

# --- the shipped configs ----------------------------------------------------------------------------
for f in etc/config.example etc/config.janitor.example etc/config.dev; do
    mine="$(P "$f")"; fails=''
    grep -q "^$f|E|" <<<"$mine" && fails+=" errors: $(grep "^$f|E|" <<<"$mine")"
    while IFS='|' read -r _ kind k v _; do
        [[ "$kind" == V ]] || continue
        b="$(cd "$ROOT" && env -i bash --norc --noprofile -c 'set -u; source "$1"; printf %q "${!2}"' _ "$f" "$k" 2>/dev/null)"
        [[ "$v" == "$b" ]] || fails+=" $k: reader $v bash $b;"
    done <<<"$mine"
    nk="$(grep -c "^$f|V|" <<<"$mine")"
    [[ -z "$fails" && "$nk" -gt 10 ]] && ok "$f: no errors, all $nk keys equal bash's" || bad "$f:$fails"
done
# every commented line of the example, uncommented on its own: alone in a file
# (a minimal config, or the cluster-shared one read before the local file) and
# in the example as shipped, the reader accepts it and reads what bash reads
probs=''; n=0
while IFS=: read -r ln l; do
    k="${l#\#}"; k="${k%%=*}"; n=$((n+1))
    printf '%s\n' "${l#\#}" > "$RUN/one.cfg"
    sed "${ln}s/^#//" etc/config.example > "$RUN/one-in.cfg"
    for f in "$RUN/one.cfg" "$RUN/one-in.cfg"; do
        mine="$(P "$f")"
        if grep -q '|E|' <<<"$mine"; then probs+=" $k ($(basename "$f")): $(grep '|E|' <<<"$mine");"; continue; fi
        v="$(sed -n "s#^$f|V|$k|\([^|]*\)|.*#\1#p" <<<"$mine")"
        [[ "$v" == "$(B "$f" "$k")" ]] || probs+=" $k ($(basename "$f")): reader $v, bash $(B "$f" "$k");"
    done
done < <(grep -nE '^#[A-Z][A-Z0-9_]*=' etc/config.example)
[[ -z "$probs" && "$n" -gt 30 ]] && ok "each of the $n commented example lines, uncommented alone or in the example, reads strictly as bash reads it" \
    || bad "commented example lines ($n):$probs"

# --- references to the environment, and the merge of two files ---------------------------------------
printf 'RESTIC_CACHE_REPO=${CACHE_DIR}/r\n' > "$RUN/envref.cfg"
out="$(env -i PATH="$PATH" CACHE_DIR=/envc bash -c 'set -u; source lib/config_schema.sh; source lib/config_parse.sh
    _cfg_env_snapshot; _cfg_parse_file "$1" local; echo "${CFG_VAL[RESTIC_CACHE_REPO]-} ${#CFG_ERRORS[@]}"; printf "%s\n" "${CFG_WARNINGS[@]}"
    unset CFG_ENV; _cfg_reset; _cfg_parse_file "$1" local; echo "nosnap ${#CFG_ERRORS[@]}"' _ "$RUN/envref.cfg" 2>&1)"
b="$(cd "$RUN" && env -i CACHE_DIR=/envc bash -c 'set -u; source "$1"; printf %s "$RESTIC_CACHE_REPO"' _ "$RUN/envref.cfg")"
[[ "$(head -1 <<<"$out")" == "$b 0" && "$out" == *"\${CACHE_DIR} is not set earlier in the config: it is taken from pbo's environment"* && "$out" == *"nosnap 1"* ]] \
    && ok "a reference to a key only the environment sets: bash's value ($b), with a warning; refused without a snapshot (install.sh)" || bad "env ref: $out (bash $b)"

printf 'CACHE_DIR=/s\nKEEP_LOCAL=5\nRESTIC_SFTP_COMMAND="ssh -p 23 x"\nPBO_VZDUMP_HOOK=/x\nKEEP_OFFSITE_DAILY=9\n' > "$RUN/shared.cfg"
printf 'RESTIC_CACHE_REPO=${CACHE_DIR}/r\nKEEP_LOCAL=6\n' > "$RUN/local.cfg"
out="$(env -i PATH="$PATH" S="$RUN/shared.cfg" L="$RUN/local.cfg" bash -c 'set -u; source lib/config_schema.sh; source lib/config_parse.sh
    _cfg_config_files() { _CFG_FPATH=("$S" "$L"); _CFG_FORIGIN=(shared local); }
    _cfg_parse_all; echo "rc=$? files=${PBO_CONFIG_FILES[*]}"
    for k in CACHE_DIR KEEP_LOCAL RESTIC_CACHE_REPO KEEP_OFFSITE_DAILY; do echo "$k=${CFG_VAL[$k]-} ${CFG_SRC[$k]%%:*}"; done
    echo "sftp=${CFG_VAL[RESTIC_SFTP_COMMAND]-unset}"; printf "%s\n" "${CFG_ERRORS[@]}" "${CFG_WARNINGS[@]}"; printf "ignored %s\n" "${CFG_IGNORED[@]}"' 2>&1)"
exp="rc=0 files=$RUN/shared.cfg $RUN/local.cfg
CACHE_DIR=/s shared
KEEP_LOCAL=6 local
RESTIC_CACHE_REPO=/s/r local
KEEP_OFFSITE_DAILY=9 shared
sftp=unset
ignored $RUN/shared.cfg:3: RESTIC_SFTP_COMMAND may not be set in the cluster-shared config (it runs a program or is per node): pbo ignores it there; set it in /etc/pbo/config on each node
ignored $RUN/shared.cfg:4: PBO_VZDUMP_HOOK may not be set in the cluster-shared config (it runs a program or is per node): pbo ignores it there; set it in /etc/pbo/config on each node"
[[ "$(sed '/^$/d' <<<"$out")" == "$exp" ]] && ok "shared then local: the local file wins, references cross files, no duplicate warning; exec/local-only keys ignored in the shared file (not errors)" \
    || bad "merge: $(diff <(echo "$exp") <(sed '/^$/d' <<<"$out"))"
out="$(env -i PATH="$PATH" PBO_CONFIG="$RUN/local.cfg" bash -c 'source lib/config_schema.sh; source lib/config_parse.sh; _cfg_parse_all; echo "${PBO_CONFIG_FILES[*]} ${#CFG_ERRORS[@]}"; printf "%s\n" "${CFG_ERRORS[@]}"')"
[[ "$out" == "$RUN/local.cfg 1"*"used before it is set"* ]] && ok "PBO_CONFIG set: that file alone (its reference to CACHE_DIR then has nothing to refer to)" || bad "PBO_CONFIG: $out"

# --- timing ----------------------------------------------------------------------------------------
# The best of several runs: the budget is for the reader, not for a busy
# machine. The bounds leave several times the usual parse time as headroom,
# so a slower CPU passes; a real
# regression (a subshell per line, a quadratic slip) costs far more than that.
# Warm: the schema already loaded (doctor, config check after load_config).
# Cold: a fresh shell, the reader's own schema load included (the install.sh
# guard, the first parse).
sed -n 's/^#\([A-Z][A-Z0-9_]*=\)/\1/; /^[A-Z]/p' etc/config.example > "$RUN/all-active.cfg"
t="$(env -i PATH="$PATH" bash -c 'source lib/config_schema.sh; source lib/config_parse.sh; _cs_load
    best() { local b=999999 i s e; for i in 1 2 3 4 5 6 7; do s=$EPOCHREALTIME; _cfg_reset; _cfg_parse_file "$1" local; e=$EPOCHREALTIME; (( ${e/./} - ${s/./} < b )) && b=$(( ${e/./} - ${s/./} )); done; echo "$b"; }
    echo "$(best etc/config.example) $(best "$1") $(wc -l < "$1")"' _ "$RUN/all-active.cfg")"
read -r t1 t2 nl <<<"$t"
t3=999999
for i in 1 2 3 4 5; do
    c="$(env -i PATH="$PATH" bash -c 'source lib/config_schema.sh; source lib/config_parse.sh
        s=$EPOCHREALTIME; _cfg_parse_file "$1" local; e=$EPOCHREALTIME; echo $(( ${e/./} - ${s/./} ))' _ "$RUN/all-active.cfg")"
    [[ "$c" =~ ^[0-9]+$ ]] && (( c < t3 )) && t3="$c"
done
ms() { printf '%d.%d ms' "$(($1/1000))" "$(( ($1%1000)/100 ))"; }
[[ "$t1" =~ ^[0-9]+$ ]] && (( t1 < 50000 && t2 < 50000 )) \
    && ok "parse time, warm reader: etc/config.example $(ms "$t1"), $nl active lines $(ms "$t2") (budget 50 ms)" \
    || bad "parse time, warm reader: $t (us; budget 50 ms)"
(( t3 < 80000 )) && ok "parse time, cold first parse including the schema load: $nl active lines $(ms "$t3") (budget 80 ms)" \
    || bad "parse time, cold first parse including the schema load: $t3 us (budget 80 ms)"

# --- pbo config check ------------------------------------------------------------------------------
base() { printf 'CACHE_DIR=%s\nLOG_DIR=%s\nSTATE_DIR=%s\nLOCK_DIR=%s\nOFFSITE_ENABLED=false\nRESTIC_CACHE_REPO=${CACHE_DIR}/repo\nRESTIC_PASSWORD_FILE=%s\nPBO_PVE_LXC_DIR=%s\n' \
    "$RUN/cache" "$RUN/log" "$RUN/state" "$RUN/lock" "$RUN/pass" "$RUN/lxc"; }
printf 'testpass\n' > "$RUN/pass"; chmod 600 "$RUN/pass"
{ base; printf 'NTFY_TOPIC="a secret topic"\nKEEP_LOCAL=3   # comment\n'; } > "$RUN/good.cfg"; chmod 600 "$RUN/good.cfg"
out="$(PBO_CONFIG="$RUN/good.cfg" $BIN config check 2>&1)"; rc=$?
[[ $rc == 0 && "$out" == *"pbo config check: 0 error(s), 1 warning(s) in 1 file(s)"* ]] && ! grep -q 'bash' <<<"$out" \
    && grep -q "good.cfg:8: warning: PBO_PVE_LXC_DIR is a test hook" <<<"$out" \
    && ok "config check: a clean config, exit 0, no bash involved" || bad "check good: rc=$rc $out"
out="$(PBO_CONFIG="$RUN/good.cfg" $BIN --json config check 2>/dev/null)"; rc=$?
[[ $rc == 0 ]] && jq -e --arg f "$RUN/good.cfg" '.status == "ok" and .ok == true and .command == "config" and .errors == 0 and .ignored == 0 and .keys == 10
    and .files == [{file:$f, errors:[], warnings:[{line:8, message:"PBO_PVE_LXC_DIR is a test hook (internal): it does not belong in a production config"}], valid_bash:false}]
    and .compare_bash == null' >/dev/null <<<"$out" \
    && ok "config check --json: status, files with their lines, no bash comparison unless asked" || bad "check good json: rc=$rc $out"
out="$(PBO_CONFIG="$RUN/good.cfg" $BIN config check --compare-bash 2>&1)"; rc=$?
[[ $rc == 0 && "$out" == *"config: bash reads every key the same (10 keys)"* ]] && ok "config check --compare-bash: bash agrees on a clean config" || bad "compare good: rc=$rc $out"
out="$(PBO_CONFIG="$RUN/good.cfg" $BIN --json config check --compare-bash 2>/dev/null)"
jq -e '.compare_bash == {agree:true, keys:10, differences:[], bash_failed:[]}' >/dev/null <<<"$out" && ok "config check --compare-bash --json: the comparison object" || bad "compare good json: $out"

# a CR keeps bash's value apart from the reader's (a warning, not an error): the
# corpus check's positive control for DIFF records (tests/all.sh)
{ base; printf 'VERIFY_SUBSET=5%%\r\n'; } > "$RUN/crlf.cfg"; chmod 600 "$RUN/crlf.cfg"
out="$(PBO_CONFIG="$RUN/crlf.cfg" $BIN config check --compare-bash 2>&1)"; rc=$?
[[ $rc == 0 ]] && grep -q "crlf.cfg:9: warning: Windows line endings" <<<"$out" \
    && grep -qF "config: VERIFY_SUBSET reads differently when bash sources the file (bash: \$'5%\\r', pbo: 5%), $RUN/crlf.cfg line 9" <<<"$out" \
    && ok "config check --compare-bash: a value bash reads differently (CR) is named, exit 0 (a warning)" || bad "compare crlf: rc=$rc $out"

{ base; printf 'CACHE_DIR=$(printf %%s %s)\nexport FOO=1\nKEEP_LOCAL=x\nVERIFY_SUBSET=5%%\r\nNTFY_TOPIC=topsecret\r\n' "$RUN/cache2"; } > "$RUN/bad.cfg"; chmod 600 "$RUN/bad.cfg"
out="$(PBO_CONFIG="$RUN/bad.cfg" $BIN config check 2>&1)"; rc=$?
[[ $rc == 78 ]] && grep -q "bad.cfg:9: error: command substitution \$(...) is not allowed" <<<"$out" && grep -q "bad.cfg:10: error: export FOO is not allowed" <<<"$out" \
    && grep -q "bad.cfg:11: warning: KEEP_LOCAL='x' is not a whole number" <<<"$out" && grep -q "bad.cfg:12: warning: Windows line endings" <<<"$out" \
    && grep -q 'pbo refuses this config' <<<"$out" && grep -qF "$RUN/bad.cfg is valid bash, but pbo 0.6 no longer runs the config as code; see the 0.6.0 migration notes in CHANGELOG.md" <<<"$out" \
    && ! grep -q 'reads differently' <<<"$out" && ! grep -q topsecret <<<"$out" \
    && ok "config check: errors and warnings by file:line, the migration hint for a file bash accepts, exit 78" || bad "check bad: rc=$rc $out"
out="$(PBO_CONFIG="$RUN/bad.cfg" $BIN config check --compare-bash 2>&1)"; rc=$?
[[ $rc == 78 ]] && grep -q "config: CACHE_DIR reads differently when bash sources the file (bash: $RUN/cache2, pbo: $RUN/cache), $RUN/bad.cfg line 1" <<<"$out" \
    && grep -qF "config: VERIFY_SUBSET reads differently when bash sources the file (bash: \$'5%\\r', pbo: 5%), $RUN/bad.cfg line 12" <<<"$out" \
    && grep -q "config: NTFY_TOPIC reads differently when bash sources the file (<differs>)" <<<"$out" && ! grep -q topsecret <<<"$out" \
    && ok "config check --compare-bash: the keys bash reads differently (a secret only as <differs>)" || bad "compare bad: rc=$rc $out"
out="$(PBO_CONFIG="$RUN/bad.cfg" $BIN --json config check --compare-bash 2>/dev/null)"; rc=$?
[[ $rc == 78 && "$(grep -c . <<<"$out")" == 1 ]] && jq -e '.status == "invalid" and .ok == false and .errors == 2
    and (.files[0].errors | map(.line)) == [9, 10] and (.files[0].warnings | any(.line == 11)) and .files[0].valid_bash
    and .compare_bash.agree == false and (.compare_bash.differences | map(.key) | sort) == ["CACHE_DIR", "NTFY_TOPIC", "VERIFY_SUBSET"]
    and (.compare_bash.differences[] | select(.key == "CACHE_DIR") | .line) == 1' >/dev/null <<<"$out" && ! grep -q topsecret <<<"$out" \
    && ok "config check --json: one object, exit 78, errors with lines, the differences" || bad "check bad json: rc=$rc $out"

# --- every other command: the config is read, never run ----------------------------------------------
{ base; printf 'KEEP_LOCAL=$(touch %s/ran)\nCACHE_DIR=`touch %s/ran2`\nf() { touch %s/ran3; }\nX=a b\nKEEP_OFFSITE_DAILY=3 4\n' "$RUN" "$RUN" "$RUN"; } > "$RUN/code.cfg"; chmod 600 "$RUN/code.cfg"
out="$(PBO_CONFIG="$RUN/code.cfg" $BIN version 2>&1)"; rc=$?
[[ $rc == 78 && ! -e "$RUN/ran" && ! -e "$RUN/ran2" && ! -e "$RUN/ran3" ]] \
    && grep -q '^pbo: the config has 5 line(s) pbo cannot read:$' <<<"$out" \
    && [[ "$(grep -c "^  $RUN/code.cfg:" <<<"$out")" == 3 ]] && grep -q "^  $RUN/code.cfg:9: command substitution" <<<"$out" \
    && grep -qx "pbo: run 'pbo config check' for all of them" <<<"$out" \
    && grep -qxF "pbo: $RUN/code.cfg is valid bash, but pbo 0.6 no longer runs the config as code; see the 0.6.0 migration notes in CHANGELOG.md" <<<"$out" \
    && ok "a config with code: nothing runs, exit 78, the first three errors, 'pbo config check', the migration hint" || bad "code config: rc=$rc $out"
{ base; printf 'CACHE_DIR="unterminated\n'; } > "$RUN/nobash.cfg"; chmod 600 "$RUN/nobash.cfg"
out="$(PBO_CONFIG="$RUN/nobash.cfg" $BIN version 2>&1)"; rc=$?
[[ $rc == 78 ]] && grep -q 'nobash.cfg:9: unterminated double quote' <<<"$out" && ! grep -q 'valid bash' <<<"$out" \
    && ok "a file bash cannot parse either: no 'valid bash' hint" || bad "nobash: rc=$rc $out"
out="$(PBO_CONFIG="$RUN/code.cfg" $BIN --json config template 2>/dev/null)"; rc=$?
[[ $rc == 0 ]] && jq -e '.ok and (.template | startswith("# /etc/pbo/config"))' >/dev/null <<<"$out" \
    && ok "config template does not depend on the config: it works on a refused one" || bad "template on a refused config: rc=$rc"

# only schema keys become variables; precedence file > environment > default;
# the proxy variables a config exports reach the programs pbo runs, a config
# key it exports does not (RESTIC_BIN: a fake restic prints its environment)
printf '#!/usr/bin/env bash\necho "restic ${https_proxy:-none}/${KEEP_LOCAL:-none}/${MY_TYPO:-none}"\n' > "$RUN/bin/fake-restic"; chmod 755 "$RUN/bin/fake-restic"
{ base; printf 'RESTIC_BIN=%s\nexport https_proxy=http://proxy.invalid:3128\nexport KEEP_LOCAL=3\nMY_TYPO=1\nPBO_REPO=cache\nKEEP_OFFSITE_DAILY=\n' "$RUN/bin/fake-restic"; } > "$RUN/vars.cfg"; chmod 600 "$RUN/vars.cfg"
out="$(env -u https_proxy PBO_CONFIG="$RUN/vars.cfg" $BIN --json version 2>/dev/null | jq -r .restic)"
[[ "$out" == "http://proxy.invalid:3128/none/none" ]] && ok "export https_proxy reaches restic; an exported config key and an unknown key do not" || bad "exports: $out"
out="$(PBO_CONFIG="$RUN/vars.cfg" bash -c 'set -euo pipefail; SELF_DIR="$PWD"; source lib/common.sh; p="$PATH"; i="$IFS"
    load_config; [[ "$PATH" == "$p" && "$IFS" == "$i" ]] || echo "PATH/IFS changed"
    echo "${MY_TYPO-unset} ${PBO_REPO-unset} $KEEP_LOCAL $KEEP_OFFSITE_DAILY"' 2>&1)"
[[ "$out" == "unset unset 3 7" ]] && ok "load_config: unknown keys and environment switches in the file are never assigned; an empty value is the default" || bad "assigned: $out"
{ base; printf 'PATH=/nonexistent\nIFS=x\nBASH_ENV=%s/benv\nEX_CONFIG=1\nVERSION=9\nKEEP_LOCAL=4\n' "$RUN"; } > "$RUN/evil.cfg"; chmod 600 "$RUN/evil.cfg"
out="$(PBO_CONFIG="$RUN/evil.cfg" $BIN --json config get KEEP_LOCAL 2>/dev/null | jq -r .value)"; rc=$?
out2="$(PBO_CONFIG="$RUN/evil.cfg" $BIN version 2>&1)"
[[ "$out" == 4 && "$out2" == "pbo 0.6.0-dev "* ]] && ok "PATH, IFS, BASH_ENV and pbo's readonly names in the config change nothing (unknown keys)" || bad "evil: [$out] [$out2]"
fails=''
for c in "5||5|env" "5|KEEP_LOCAL=3|3|config" "5|KEEP_LOCAL=|2|config" "||2|default" "|KEEP_LOCAL=6|6|config"; do
    IFS='|' read -r e line want wsrc <<<"$c"
    { base; [[ -z "$line" ]] || printf '%s\n' "$line"; } > "$RUN/prec.cfg"; chmod 600 "$RUN/prec.cfg"
    if [[ -n "$e" ]]; then out="$(KEEP_LOCAL="$e" PBO_CONFIG="$RUN/prec.cfg" $BIN --json config get KEEP_LOCAL 2>/dev/null)"
    else out="$(env -u KEEP_LOCAL PBO_CONFIG="$RUN/prec.cfg" $BIN --json config get KEEP_LOCAL 2>/dev/null)"; fi
    jq -e --arg v "$want" --arg s "$wsrc" '.value == $v and .source == $s' >/dev/null <<<"$out" || fails+=" [env=$e file=$line: $(jq -c '{value, source}' <<<"$out")]"
done
[[ -z "$fails" ]] && ok "precedence: the file beats the environment, which beats the default; an empty value is the default; config get names the source (env too)" || bad "precedence:$fails"

# --file: read only, never sourced, even when bash cannot parse it
printf 'KEEP_LOCAL=2\ntrue $(touch %s/sourced)\nCACHE_DIR="unterminated\n' "$RUN" > "$RUN/broken.cfg"
out="$(PBO_CONFIG="$RUN/good.cfg" $BIN config check --file "$RUN/broken.cfg" 2>&1)"; rc=$?
[[ $rc == 78 && ! -e "$RUN/sourced" ]] && grep -q "broken.cfg:2: error: not a KEY=VALUE line" <<<"$out" && grep -q "broken.cfg:3: error: unterminated double quote" <<<"$out" \
    && ! grep -q 'reads differently\|bash reads' <<<"$out" && ! grep -q 'valid bash' <<<"$out" && ok "config check --file: that file alone, never sourced, exit 78" || bad "check --file: rc=$rc $out"
out="$(PBO_CONFIG="$RUN/good.cfg" $BIN --json config check --file "$RUN/broken.cfg" 2>/dev/null)"
jq -e '.compare_bash == null and (.files | length) == 1 and .errors == 2' >/dev/null <<<"$out" && ok "config check --file --json: no bash comparison" || bad "check --file json: $out"
# --compare-bash is the explicit opt-in that does run it (as pbo 0.5 did), in a subshell
chmod 600 "$RUN/broken.cfg"
out="$(PBO_CONFIG="$RUN/good.cfg" $BIN --json config check --file "$RUN/broken.cfg" --compare-bash 2>/dev/null)"; rc=$?
[[ $rc == 78 && -e "$RUN/sourced" ]] && jq -e '.compare_bash.bash_failed == [{file: .files[0].file, why: "parse"}] and (.files[0].warnings | any(.line == 0 and (.message | test("bash cannot parse"))))' >/dev/null <<<"$out" \
    && ok "config check --compare-bash: sources the file (it runs), names a file bash cannot parse" || bad "compare --file: rc=$rc $(ls "$RUN/sourced" 2>&1) $out"
chmod 666 "$RUN/broken.cfg"; rm -f "$RUN/sourced"
PBO_CONFIG="$RUN/good.cfg" $BIN config check --file "$RUN/broken.cfg" --compare-bash >/dev/null 2>&1; rc=$?
[[ $rc == 78 && ! -e "$RUN/sourced" ]] && ok "config check --compare-bash: a world-writable file is not sourced (the owner/mode rules)" || bad "compare ww: rc=$rc"
out="$(PBO_CONFIG="$RUN/good.cfg" $BIN config check --file etc/config.janitor.example --role janitor 2>&1)"; rc=$?
[[ $rc == 0 && "$out" == *"0 error(s), 0 warning(s)"* ]] && ok "config check --role janitor: etc/config.janitor.example is clean" || bad "janitor example: rc=$rc $out"
out="$(PBO_CONFIG="$RUN/good.cfg" $BIN config check --file etc/config.example 2>&1)"; rc=$?
[[ $rc == 0 && "$out" == *"0 error(s), 0 warning(s)"* ]] && ok "config check: etc/config.example is clean" || bad "example: rc=$rc $out"
out="$(PBO_CONFIG="$RUN/good.cfg" $BIN config check --file etc/config.example --role janitor 2>&1)"
grep -q 'VZDUMP_MODE is not used on a janitor (it is a host key)' <<<"$out" && ok "config check --role: keys the role does not use are named" || bad "role: $out"
printf 'RESTIC_SFTP_COMMAND="ssh x"\nNTFY_ON_SUCCESS=true\n' > "$RUN/sh.cfg"
out="$(PBO_CONFIG="$RUN/good.cfg" $BIN config check --file "$RUN/sh.cfg" --shared 2>&1)"; rc=$?
[[ $rc == 78 ]] && grep -q 'sh.cfg:1: error: RESTIC_SFTP_COMMAND may not be set in the cluster-shared config (it runs a program or is per node): pbo ignores it there' <<<"$out" \
    && grep -q 'sh.cfg:2: warning: NTFY_ON_SUCCESS is replaced by NOTIFY_LEVEL' <<<"$out" && grep -q 'pbo ignores the lines marked error above' <<<"$out" \
    && ok "config check --shared: an exec/local-only key pbo ignores there is an error here (78), a deprecated key named" || bad "shared: rc=$rc $out"
fails=''
for a in '--file' '--role x' '--shared' '--bogus'; do
    # shellcheck disable=SC2086  # the arguments split on purpose
    PBO_CONFIG="$RUN/good.cfg" $BIN config check $a >/dev/null 2>&1; rc=$?
    [[ $rc == 64 ]] || fails+=" '$a': $rc"
done
[[ -z "$fails" ]] && ok "config check: bad arguments exit 64" || bad "config check usage errors:$fails"

# lenient: config check reports what every other command stops on
{ base; printf 'KEEP_LOCAL=4\nRESTIC_CACHE_DIR=${NOT_A_KEY_UNSET}/x\n'; } > "$RUN/unset.cfg"; chmod 600 "$RUN/unset.cfg"
out="$(PBO_CONFIG="$RUN/unset.cfg" $BIN config check 2>&1)"; rc=$?
[[ $rc == 78 ]] && grep -q 'unset.cfg:10: error: \$NOT_A_KEY_UNSET is not a config key' <<<"$out" && ok "config check: a refused reference is reported (78), not fatal" || bad "lenient ref: rc=$rc $out"
out="$(PBO_CONFIG="$RUN/unset.cfg" $BIN version 2>&1)"; rc=$?
[[ $rc == 78 && "$out" == *"unset.cfg:10: \$NOT_A_KEY_UNSET is not a config key"* ]] && ok "... while every other command stops on it (78, the line named)" || bad "version with unset ref: rc=$rc $out"
# main() sets PBO_CFG_LENIENT itself: inherited, it would run a command on what
# is left of a refused config (a default repo, default retention)
out="$(PBO_CFG_LENIENT=1 PBO_CONFIG="$RUN/unset.cfg" $BIN version 2>&1)"; rc=$?
[[ $rc == 78 ]] && grep -q 'unset.cfg:10: \$NOT_A_KEY_UNSET is not a config key' <<<"$out" \
    && ok "an inherited PBO_CFG_LENIENT=1 does not make a normal command run on a refused config (78)" || bad "lenient env leak: rc=$rc $out"
{ base; printf 'KEEP_LOCAL=4\nif then\n'; } > "$RUN/syntax.cfg"; chmod 600 "$RUN/syntax.cfg"
out="$(PBO_CONFIG="$RUN/syntax.cfg" $BIN --json config check 2>/dev/null)"; rc=$?
[[ $rc == 78 ]] && jq -e '(.files[0].errors | map(.line)) == [10] and .files[0].valid_bash == false' >/dev/null <<<"$out" \
    && ok "config check: a file bash cannot parse: the line, no 'valid bash'" || bad "lenient syntax: rc=$rc $out"
out="$(PBO_CONFIG="$RUN/syntax.cfg" $BIN --json config check --compare-bash 2>/dev/null)"; rc=$?
[[ $rc == 78 ]] && jq -e '.files[0].warnings | any(.line == 0 and (.message | test("bash cannot parse")))' >/dev/null <<<"$out" \
    && ok "config check --compare-bash: ... and names it as one bash cannot parse" || bad "compare syntax: rc=$rc $out"
# a ${X:?} or an exit would end the shell that sources the file: the reader
# refuses both lines; --compare-bash (in a subshell) names bash's stop
{ base; printf 'KEEP_LOCAL=${NOPE:?set it}\n'; } > "$RUN/qmark.cfg"; chmod 600 "$RUN/qmark.cfg"
{ base; printf 'exit 3\nKEEP_LOCAL=4\n'; } > "$RUN/exit.cfg"; chmod 600 "$RUN/exit.cfg"
out="$(PBO_CONFIG="$RUN/qmark.cfg" $BIN config check --compare-bash 2>&1)"; rc=$?
[[ $rc == 78 ]] && grep -qF 'qmark.cfg:9: error: only ${KEY} and $KEY references to config keys are allowed, not ${NOPE:?set it}' <<<"$out" \
    && grep -q 'qmark.cfg:0: warning: bash stops on this file' <<<"$out" && grep -q 'pbo config check: 1 error(s)' <<<"$out" \
    && ok "config check: a config with \${X:?} is reported (78), its line named; --compare-bash names bash's stop" || bad "lenient :?: rc=$rc $out"
out="$(PBO_CONFIG="$RUN/qmark.cfg" $BIN config check --file "$RUN/qmark.cfg" 2>&1)"; rc=$?
[[ $rc == 78 ]] && grep -qF 'qmark.cfg:9: error: only ${KEY}' <<<"$out" && ok "config check --file on it (also the active config): reported too" || bad "lenient :? --file: rc=$rc $out"
out="$(PBO_CONFIG="$RUN/exit.cfg" $BIN --json config check --compare-bash 2>/dev/null)"; rc=$?
[[ $rc == 78 ]] && jq -e '(.files[0].warnings | any(.line == 0 and (.message | test("bash stops on this file")))) and (.files[0].errors | any(.line == 9 and (.message | test("not a KEY=VALUE line"))))
    and .compare_bash.bash_failed == [{file: .files[0].file, why: "stops"}]' >/dev/null <<<"$out" \
    && ok "config check --json: an exit in the config is reported (78), bash's stop named" || bad "lenient exit: rc=$rc $out"
fails=''
for f in qmark exit; do PBO_CONFIG="$RUN/$f.cfg" $BIN version >/dev/null 2>&1; [[ $? == 78 ]] || fails+=" $f"; done
[[ -z "$fails" ]] && ok "... and pbo version stops on both (78)" || bad "version did not stop on:$fails"

# a broken role config: every other command stops in _role_check at startup,
# config check reports it at its line instead
fails=''
for c in 'PBO_ROLE=Janitor|PBO_ROLE='"'"'Janitor'"'"' is not' 'PBO_ROLE=janitor\nPBO_INTEGRATION=both|PBO_ROLE=janitor with PBO_INTEGRATION=both' \
         'PBO_ROLE=janitor\nOFFSITE_APPEND_ONLY=true|PBO_ROLE=janitor with OFFSITE_APPEND_ONLY=true'; do
    { base; printf "${c%%|*}\n"; } > "$RUN/role.cfg"; chmod 600 "$RUN/role.cfg"
    out="$(PBO_JANITOR_ALLOW_ROOT=1 PBO_CONFIG="$RUN/role.cfg" $BIN config check 2>&1)"; rc=$?
    [[ $rc == 78 ]] && grep -qF "role.cfg:9: error: ${c#*|}" <<<"$out" || fails+=" [${c%%|*}: rc=$rc $out]"
    out="$(PBO_JANITOR_ALLOW_ROOT=1 PBO_CONFIG="$RUN/role.cfg" $BIN --json config check 2>/dev/null)"; rc=$?
    [[ $rc == 78 ]] && jq -e --arg m "${c#*|}" '.compare_bash == null and (.files[0].errors | any(.line == 9 and (.message | startswith($m))))' >/dev/null <<<"$out" \
        || fails+=" [json ${c%%|*}: rc=$rc $out]"
    out="$(PBO_JANITOR_ALLOW_ROOT=1 PBO_CONFIG="$RUN/role.cfg" $BIN config check --file "$RUN/role.cfg" 2>&1)"; rc=$?
    [[ $rc == 78 ]] && grep -qF "role.cfg:9: error: ${c#*|}" <<<"$out" || fails+=" [--file ${c%%|*}: rc=$rc $out]"
    PBO_JANITOR_ALLOW_ROOT=1 PBO_CONFIG="$RUN/role.cfg" $BIN version >/dev/null 2>&1; rc=$?
    [[ $rc == 78 ]] || fails+=" [version ${c%%|*}: rc=$rc]"
done
[[ -z "$fails" ]] && ok "config check: a bad PBO_ROLE, janitor with integration or append-only: reported at the line (78), other commands still stop" || bad "role config:$fails"
# a role error is no reader refusal: the summary says pbo stops on it (not that
# it ignores the line), and no migration hint for a file that holds no code
{ base; printf 'PBO_ROLE=jantor\n'; } > "$RUN/role.cfg"; chmod 600 "$RUN/role.cfg"
out="$(PBO_CONFIG="$RUN/role.cfg" $BIN config check 2>&1)"; rc=$?
out2="$(PBO_CONFIG="$RUN/role.cfg" $BIN --json config check 2>/dev/null)"
[[ $rc == 78 ]] && grep -qF "role.cfg:9: error: PBO_ROLE='jantor' is not" <<<"$out" \
    && grep -qx 'pbo stops on this config: every command refuses the errors above' <<<"$out" \
    && ! grep -q 'pbo ignores\|pbo refuses\|valid bash' <<<"$out" && jq -e '.errors == 1 and .files[0].valid_bash == false' >/dev/null <<<"$out2" \
    && ok "config check: a role error is one pbo stops on, no 'ignores' wording and no migration hint (valid_bash false)" || bad "role summary: rc=$rc $out $out2"

out="$(PBO_CONFIG="$RUN/good.cfg" $BIN help 2>&1)"; [[ "$out" == *"config check [--file F] [--role host|janitor] [--compare-bash]"* ]] && ok "help lists config check" || bad "help"
out="$(PBO_CONFIG="$RUN/good.cfg" $BIN config bogus 2>&1)"; [[ "$out" == *"check [--file F]"*"--compare-bash"* ]] && ok "config: the valid subcommands include check" || bad "subcommands: $out"

# --- the cluster-shared file, through pbo itself ----------------------------------------------------------
# load_config reads the fixed /etc/pve/pbo/config and /etc/pbo/config when
# PBO_CONFIG is unset. A copy of the source tree whose _cfg_config_files names
# two test files instead (appended to the copy: no hook in pbo itself).
mkdir -p "$RUN/src"
cp -a pbo lib "$RUN/src/"
cat >> "$RUN/src/lib/config_parse.sh" <<EOT
_cfg_config_files() { _CFG_FPATH=("$RUN/c-shared" "$RUN/c-local"); _CFG_FORIGIN=(shared local); }
EOT
{ base; printf 'RESTIC_BIN=/nonexistent/restic\nRESTIC_SFTP_COMMAND="ssh -p 23 x"\nKEEP_OFFSITE_DAILY=11\nKEEP_LOCAL=5\n'; } > "$RUN/c-shared"; chmod 600 "$RUN/c-shared"
printf 'KEEP_LOCAL=6\n' > "$RUN/c-local"; chmod 600 "$RUN/c-local"
SP() { env -u PBO_CONFIG "$RUN/src/pbo" "$@"; }
# a fake restic of its own (not $RUN/bin, which other calls share): the test
# does not depend on a real one, and its marker shows which binary answered
mkdir -p "$RUN/rbin"; printf '#!/bin/sh\necho "restic 9.9.9-pbo-test compiled with go"\n' > "$RUN/rbin/restic"; chmod 755 "$RUN/rbin/restic"
out="$(PATH="$RUN/rbin:$PATH" SP --json version 2>/dev/null | jq -r .restic)"
[[ "$out" == 9.9.9-pbo-test ]] && ok "an exec key in the shared file is ignored (RESTIC_BIN there does not replace restic)" || bad "shared RESTIC_BIN: $out"
out="$(SP --json config list 2>/dev/null)"
jq -e --arg s "$RUN/c-shared" --arg l "$RUN/c-local" '.shared_file == $s and .file == $l and .local_file == $l
    and any(.keys[]; .key == "KEEP_LOCAL" and .value == "6" and .source == "config")
    and any(.keys[]; .key == "KEEP_OFFSITE_DAILY" and .value == "11" and .source == "shared")
    and any(.keys[]; .key == "RESTIC_BIN" and .value == "restic" and .source == "default")' >/dev/null <<<"$out" \
    && ok "shared then local: the local file wins, shared keys are labelled shared, the ignored key is the default" || bad "shared list: $(head -c 600 <<<"$out")"
out="$(SP doctor 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g')"
grep -qx "  FAIL  config $RUN/c-shared line 9: RESTIC_BIN may not be set in the cluster-shared config (it runs a program or is per node): pbo ignores it there; set it in /etc/pbo/config on each node" <<<"$out" \
    && grep -q "FAIL  config $RUN/c-shared line 10: RESTIC_SFTP_COMMAND may not be set" <<<"$out" \
    && ok "doctor: FAIL for each exec/local-only key pbo ignores in the shared file" || bad "doctor shared: $(grep -i 'config' <<<"$out")"
out="$(SP config check 2>&1)"; rc=$?
[[ $rc == 78 ]] && grep -q "c-shared:9: error: RESTIC_BIN may not be set" <<<"$out" && ok "config check: ... and an error there (78)" || bad "check shared: rc=$rc $out"
# only the shared file exists: it is the loaded one, the local file is still where pbo writes
rm -f "$RUN/c-local"
out="$(SP --json config list 2>/dev/null)"
jq -e --arg s "$RUN/c-shared" --arg l "$RUN/c-local" '.file == $s and .shared_file == null and .local_file == $l
    and any(.keys[]; .key == "KEEP_LOCAL" and .value == "5" and .source == "shared")' >/dev/null <<<"$out" \
    && ok "no local file: the shared one is read, the local one is still the file pbo writes (local_file)" || bad "shared only: $(head -c 400 <<<"$out")"

# a non-root caller outside www-data cannot read the pmxcfs file (root:www-data
# 0640): pbo runs on the rest with a note, as 0.5 did (its source failed and
# went on), instead of stopping every command on a cluster node. A world-readable
# copy of the tree under /tmp (nobody cannot enter /root).
if [[ "$(id -u)" == 0 ]] && id nobody >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1; then
    nt="$(mktemp -d -p /tmp)"; chmod 0755 "$nt"; cp -a pbo lib "$nt/"; chmod -R a+rX "$nt/pbo" "$nt/lib"
    mkdir -p "$nt/state"; chown nobody "$nt/state"
    printf '_cfg_config_files() { _CFG_FPATH=("%s/c-shared" "%s/c-local"); _CFG_FORIGIN=(shared local); }\n' "$nt" "$nt" >> "$nt/lib/config_parse.sh"
    printf 'KEEP_LOCAL=5\n' > "$nt/c-shared"; chown root:root "$nt/c-shared"; chmod 0640 "$nt/c-shared"
    NB() { (cd /tmp && setpriv --reuid=nobody --regid="$(id -g nobody)" --clear-groups env -u PBO_CONFIG STATE_DIR="$nt/state" LOG_DIR="$nt/state/log" CACHE_DIR="$nt/state/cache" RESTIC_PASSWORD_FILE="$nt/restic-pass" "$nt/pbo" "$@"); }
    out="$(NB version 2>&1)"; rc=$?
    [[ $rc == 0 && "$out" == *"pbo: note: $nt/c-shared is not readable by uid $(id -u nobody)"*"skipped"* && "$out" == *"pbo 0.6"* ]] \
        && ok "a non-root caller that cannot read the shared file: a note, pbo runs on the rest (exit 0)" || bad "unreadable shared as nobody: rc=$rc $out"
    out="$(NB --json config get KEEP_LOCAL 2>/dev/null)"
    jq -e '.value == "2" and .source == "default"' >/dev/null <<<"$out" && ok "... the skipped file's keys are the defaults" || bad "unreadable shared get: $out"
    out="$(cd /tmp && env -u PBO_CONFIG STATE_DIR="$nt/state" LOG_DIR="$nt/state/log" CACHE_DIR="$nt/state/cache" LOCK_DIR="$nt/state/lock" RESTIC_PASSWORD_FILE="$nt/restic-pass" "$nt/pbo" --json config get KEEP_LOCAL 2>&1)"
    jq -e '.value == "5" and .source == "shared"' >/dev/null <<<"$out" && ok "... root still reads it" || bad "shared as root: $out"
    rm -rf "$nt"
else echo "  (skip: no root/nobody/setpriv for the unreadable shared file check)"; fi

# --- doctor ------------------------------------------------------------------------------------------------
D() { PBO_CONFIG="$1" timeout 120 $BIN doctor 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g'; }
out="$(D "$RUN/good.cfg")"
! grep -qE '(WARN|FAIL)  config ' <<<"$out" && ! grep -q 'test hook' <<<"$out" \
    && ok "doctor: nothing to say about a clean config (a test hook is config check's to name)" || bad "doctor good: $(grep -i config <<<"$out")"
out="$(D "$RUN/crlf.cfg")"
grep -qx "  WARN  config $RUN/crlf.cfg line 9: Windows line endings: the CR at the end of 1 line(s) is ignored (bash keeps it in the value)" <<<"$out" \
    && ok "doctor: the reader's warnings (here a CR)" || bad "doctor crlf: $(grep -i config <<<"$out")"
out="$(D "$RUN/bad.cfg")"
grep -q '^pbo: the config has 2 line(s) pbo cannot read:' <<<"$out" && ! grep -q topsecret <<<"$out" \
    && ok "doctor on a config pbo refuses: stops like every command, with the lines" || bad "doctor bad: $out"
# an exported proxy variable reaches the programs pbo runs: not an unknown key
{ base; printf 'export HTTPS_PROXY=http://p.invalid:3128\n'; } > "$RUN/proxy.cfg"; chmod 600 "$RUN/proxy.cfg"
out="$(D "$RUN/proxy.cfg")"
! grep -q 'unknown config key' <<<"$out" && grep -q 'doctor: [0-9]* problem(s)' <<<"$out" \
    && ok "doctor: an exported proxy variable is no unknown key" || bad "doctor proxy: $(grep -i config <<<"$out")"
{ base; printf 'HTTPS_PROXY=http://p.invalid:3128\n'; } > "$RUN/proxy2.cfg"; chmod 600 "$RUN/proxy2.cfg"
out="$(D "$RUN/proxy2.cfg")"
grep -q "unknown config key(s) in $RUN/proxy2.cfg: HTTPS_PROXY" <<<"$out" \
    && ok "doctor: ... a bare (not exported) one is: pbo ignores it" || bad "doctor bare proxy: $(grep -i config <<<"$out")"
{ base; printf 'http_proxy=http://x.invalid:1\nexport http_proxy=http://y.invalid:2\n'; } > "$RUN/proxy3.cfg"; chmod 600 "$RUN/proxy3.cfg"
out="$(PBO_CONFIG="$RUN/proxy3.cfg" $BIN --json config list 2>/dev/null)"
[[ "$(jq '[.keys[] | select(.key == "http_proxy")] | length' <<<"$out")" == 1 ]] \
    && ok "config list: a proxy variable set bare and exported is one row" || bad "proxy rows: $(jq -c '[.keys[] | select(.key == "http_proxy")]' <<<"$out")"
{ base; for i in $(seq 1 12); do printf 'KEEP_LOCAL=%d\n' "$i"; done; } > "$RUN/many.cfg"; chmod 600 "$RUN/many.cfg"
out="$(D "$RUN/many.cfg")"
[[ "$(grep -c 'is set again' <<<"$out")" == 10 ]] && grep -q "config: 1 more warning(s) ('pbo config check' lists them all)" <<<"$out" \
    && ok "doctor: at most 10 reader warnings, then a count" || bad "doctor many: $(grep -c 'set again' <<<"$out") $(grep 'more warning' <<<"$out")"

# --- startup cost: every command reads the config with the strict reader now ----------------------------
n="$(env -u PBO_TEST_CONFIG_LOG PBO_CONFIG="$RUN/good.cfg" bash -x $BIN version 2>&1 >/dev/null | grep -c '_cfg_parse_file ')"
m="$(env -u PBO_TEST_CONFIG_LOG PBO_CONFIG="$RUN/good.cfg" bash -x $BIN version 2>&1 >/dev/null | grep -cE '(^|[^_])source .*(good\.cfg)')"
[[ "$n" == 1 && "$m" == 0 ]] && ok "pbo version reads the config once with the strict reader and never sources it" || bad "reader on the main path: $n parse(s), $m source(s)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ -n "${KEEP_RUN:-}" ]] || rm -rf "$RUN"
(( fail == 0 ))
