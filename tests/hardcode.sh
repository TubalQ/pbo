#!/usr/bin/env bash
# tests/hardcode.sh: the lint against values that differ between installations
# (ADR 0009, "Portability": nothing that differs between hosts is hard-coded).
# It scans the code that runs on a host (pbo, lib/, install.sh, systemd/,
# pve-plugin/) for absolute paths, host names and IP addresses, and clock
# times. Each one must be a default in the schema (lib/config_schema.sh, not
# scanned), sit in a comment, or match an entry of tests/hardcode.allow: one
# extended regex and the reason it is fixed, per line, matched against
# "<file>:<value>". An entry that matches nothing fails too, so the list stays
# the list of what is really there.
#   tests/hardcode.sh           the lint (exit 1 on a finding)
#   tests/hardcode.sh --list    every value found, allowed or not, with the entry
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ALLOW=tests/hardcode.allow
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

FILES=(pbo install.sh lib/vzdump-hook systemd/* pve-plugin/*.pm)
for f in lib/*.sh; do [[ "$f" == lib/config_schema.sh ]] || FILES+=("$f"); done

# the schema keys whose default is a literal ("KEY<tab>default"): a fallback
# ${KEY:-<that default>} in the code is the schema's value, every other one
# (another value, a key the schema does not have, a computed default) is a
# value of its own and goes through the lint like any other
SCHEMA_DEFS="$(bash -c 'source lib/config_schema.sh; _cs_load
    for k in "${CS_ORDER[@]}"; do d="${CS_DEFAULT[$k]}"; [[ -n "$d" && "$d" != *\$* && "$d" != @* ]] && printf "%s\t%s\n" "$k" "$d"; done')"

# _values <file>: "<line>\t<kind>\t<value>" for every candidate outside a comment.
# Comments: a line whose first non-blank is # (; too in a unit), and the rest
# of a line after a blank-# that follows code (a # inside a word, as in
# ${#arr[@]} or a URL fragment, is not a comment). Shell and perl both.
_values() {
    local f="$1" unit=0
    [[ "$f" == systemd/* ]] && unit=1
    awk -v unit="$unit" -v defs="$SCHEMA_DEFS" '
        BEGIN {
            nd = split(defs, dl, "\n")
            for (i = 1; i <= nd; i++) { t = index(dl[i], "\t"); if (t) def[substr(dl[i], 1, t - 1)] = substr(dl[i], t + 1) }
            path = "(^|[^A-Za-z0-9_.$}{~-])/(etc|var|run|usr|opt|srv|home|root|tmp|mnt|media|proc|dev|sys|bin|sbin|lib|lib64|boot)(/[A-Za-z0-9_.@%*+=-]*)*"
            host = "[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.(com|net|org|de|io|lan|local|internal|home|arpa|example|test|invalid|localdomain)([^A-Za-z0-9]|$)"
            ip   = "(^|[^0-9.])([0-9]{1,3}\\.){3}[0-9]{1,3}([^0-9.]|$)"
            tm   = "(^|[^0-9:])([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?([^0-9:]|$)"
        }
        {
            l = $0
            if (l ~ /^[[:space:]]*#/) next
            if (unit && l ~ /^[[:space:]]*;/) next
            sub(/[[:space:]]#[[:space:]].*$/, "", l)
            sub(/[[:space:]]#$/, "", l)
            # ${KEY:-fallback}: dropped when it is KEY'"'"'s literal schema default
            # (the schema'"'"'s value), else replaced by the fallback alone, which
            # the patterns below then see like any other value
            l = fallbacks(l)
            emit(l, path, "path"); emit(l, host, "host"); emit(l, ip, "ip"); emit(l, tm, "time")
        }
        function fallbacks(s,   out, m, k, lit) {
            out = ""
            while (match(s, /\$\{[A-Z][A-Z0-9_]*:-[^}$]*\}/)) {
                m = substr(s, RSTART, RLENGTH)
                k = substr(m, 3); sub(/:-.*/, "", k)
                lit = substr(m, length(k) + 5, length(m) - length(k) - 5)
                out = out substr(s, 1, RSTART - 1)
                if (!((k in def) && def[k] == lit)) out = out " " lit " "
                s = substr(s, RSTART + RLENGTH)
            }
            return out s
        }
        function emit(s, re, kind,   m, v) {
            while (match(s, re)) {
                v = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
                # trim the context characters the patterns include
                if (kind == "path") sub(/^[^\/]/, "", v)
                else if (kind == "host") sub(/[^A-Za-z0-9]$/, "", v)
                else { sub(/^[^0-9]/, "", v); sub(/[^0-9]$/, "", v) }
                sub(/[.]$/, "", v)
                printf "%d\t%s\t%s\n", NR, kind, v
            }
        }' "$f"
}

# the allowlist: "<ERE> <reason>"; blank lines and # comments skipped
declare -a A_RE=() A_WHY=() A_LINE=()
declare -A A_USED=()
n=0
while IFS= read -r line; do
    n=$((n+1))
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    re="${line%%[[:space:]]*}"; why="${line#"$re"}"; why="${why#"${why%%[![:space:]]*}"}"
    if [[ -z "$why" ]]; then bad "$ALLOW:$n: an entry without a reason: $re"; continue; fi
    if ! { [[ "x" =~ $re ]]; (( $? != 2 )); }; then bad "$ALLOW:$n: not a valid regex: $re"; continue; fi
    A_RE+=("$re"); A_WHY+=("$why"); A_LINE+=("$n")
done < "$ALLOW"

list=0; [[ "${1:-}" == --list ]] && list=1
printf 'pbo: hard-coded values lint (%s)\n' "$ALLOW"
found=0 allowed=0 findings=()
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS=$'\t' read -r ln kind v; do
        [[ -n "$v" ]] || continue
        found=$((found+1)); hit=""
        for i in "${!A_RE[@]}"; do
            if [[ "$f:$v" =~ ${A_RE[i]} ]]; then hit="$i"; A_USED[$i]=1; break; fi
        done
        if (( list )); then printf '%s:%s\t%s\t%s\t%s\n' "$f" "$ln" "$kind" "$v" "${hit:+allow:${A_LINE[hit]}}"; fi
        if [[ -n "$hit" ]]; then allowed=$((allowed+1)); else findings+=("$f:$ln: $kind '$v'"); fi
    done < <(_values "$f")
done
(( list )) && exit 0
if (( ${#findings[@]} == 0 )); then
    ok "no hard-coded path, host name, address or clock time outside the schema, comments and the allowlist ($found found, $allowed allowed)"
else
    for x in "${findings[@]}"; do bad "$x: make it a config key (lib/config_schema.sh), derive it, or add it to $ALLOW with the reason it is fixed"; done
fi
stale=""
for i in "${!A_RE[@]}"; do [[ -n "${A_USED[$i]+x}" ]] || stale+=" ${A_LINE[i]}"; done
[[ -z "$stale" ]] && ok "every allowlist entry matches something (${#A_RE[@]} entries)" || bad "allowlist entries that match nothing (remove them): line(s)$stale"
# the list entries are anchored: a pbo path written into the files that hold
# them (a permission rule, restore-host) is still reported
leaky=""
for v in lib/perms.sh:/var/cache/pbo lib/perms.sh:/run/pbo/mnt lib/perms.sh:/var/lib/pbo/jobs lib/perms.sh:/etc/pbo/restic.env lib/host.sh:/var/lib/pbo; do
    for i in "${!A_RE[@]}"; do [[ "$v" =~ ${A_RE[i]} ]] && { leaky+=" $v (line ${A_LINE[i]})"; break; }; done
done
[[ -z "$leaky" ]] && ok "no entry lets a pbo path through in lib/perms.sh or lib/host.sh" || bad "allowlist too wide:$leaky"
# the lint finds what it is for: a planted path, host and time are reported
probe="$(mktemp -d "${TMPDIR:-/tmp}/pbo-hardcode.XXXXXX")"
printf 'x=/srv/backups/pbo\nh=backup.example.net\nip=192.0.2.10\nt="05:00"\n# /srv/in-a-comment 06:00\ny=1 # /srv/trailing 07:00\n' > "$probe/t.sh"
got="$(_values "$probe/t.sh" | cut -f2,3 | tr '\t\n' ': ')"
[[ "$got" == "path:/srv/backups/pbo host:backup.example.net ip:192.0.2.10 time:05:00 " ]] \
    && ok "the lint sees a path, a host name, an address and a time, and skips comments" || bad "lint self-test: $got"
printf 'a="${CACHE_DIR:-/var/cache/pbo}"\nb="${CACHE_DIR:-/srv/other}"\nc="${PBO_CACHE:-/var/cache/pbo}"\nd="${RESTIC_CACHE_DIR:-/srv/rc}"\n' > "$probe/f.sh"
got="$(_values "$probe/f.sh" | cut -f1,3 | tr '\t\n' ': ')"; rm -rf "$probe"
[[ "$got" == "2:/srv/other 3:/var/cache/pbo 4:/srv/rc " ]] \
    && ok "a \${KEY:-fallback} is skipped only when it is KEY's literal schema default" || bad "fallback self-test: $got"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
