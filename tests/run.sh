#!/usr/bin/env bash
# tests/run.sh — enhetstester för steg 1 (skelett, config, tvånivålås).
# Rena bash-tester, inga externa beroenden. Kör inget mot riktig hårdvara.
# Riktiga vzdump/pct/rclone mockas i senare steg (steg 3+).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BIN=./lxc-offsite
export LXCO_CONFIG="$PWD/etc/config.dev"
LOCKDIR="$PWD/run/lock"
GLOBAL_LOCK="$LOCKDIR/lxc-offsite.global"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

# check <beskrivning> <förväntad exit> <kommando...>
check_exit() {
    local desc="$1" want="$2"; shift 2
    "$@" >/dev/null 2>&1; local got=$?
    [[ "$got" == "$want" ]] && ok "$desc (exit $got)" || bad "$desc (fick $got, ville $want)"
}

printf 'lxc-offsite — steg 1-tester\n'
rm -rf "$PWD/run"

# --- verktyget måste självt skapa LOCK_DIR (regression: ensure_dirs) ---
$BIN --json status >/dev/null 2>&1
[[ -d "$LOCKDIR" ]] && ok "skapar LOCK_DIR själv på tom miljö" || bad "LOCK_DIR auto-skapas"

# --- grundläggande CLI ---
$BIN --help    2>&1 | grep -q 'Användning' && ok "help visar användning" || bad "help"
$BIN --version 2>&1 | grep -q '0.1.0'      && ok "version" || bad "version"
check_exit "okänt kommando ger EX_USAGE" 64 $BIN nonsense
check_exit "inget kommando ger EX_USAGE" 64 $BIN

# --- --json-kontrakt: ren JSON på stdout ---
out="$($BIN --json status 2>/dev/null)"
[[ "$out" == '{'*'}' ]] && ok "status --json ger ett JSON-objekt" || bad "status --json ($out)"
grep -q '"status":"ok"' <<<"$out" && ok "status --json innehåller status:ok" || bad "status json-fält"

# prune är ännu ej implementerat och saknar preflight → testar json-envelopen isolerat.
out="$($BIN --json prune 2>/dev/null)"
grep -q '"status":"not_implemented"' <<<"$out" && ok "prune svarar not_implemented (json)" || bad "prune json ($out)"
grep -q '"dry_run":false' <<<"$out" && ok "dry_run-fält finns" || bad "dry_run-fält"
out="$($BIN --json --dry-run prune 2>/dev/null)"
grep -q '"dry_run":true' <<<"$out" && ok "--dry-run reflekteras i json" || bad "dry_run true"

# --- vmid-validering ---
check_exit "ogiltigt vmid (för litet) avvisas" 64 $BIN backup 5
check_exit "ogiltigt vmid (icke-numeriskt) avvisas" 64 $BIN backup abc
check_exit "backup utan vmid avvisas" 64 $BIN backup

# --- globalt lås: now-läge avslutar DIREKT när låset är upptaget ---
exec {H}>"$GLOBAL_LOCK"; flock -n "$H" || { bad "kunde inte ta testlås"; }
t0=$SECONDS
$BIN backup 9002 >/dev/null 2>&1; got=$?
elapsed=$((SECONDS - t0))
[[ "$got" == 75 ]] && ok "now-läge: EX_TEMPFAIL när globalt lås upptaget" || bad "now-läge exit ($got)"
[[ "$elapsed" -lt 3 ]] && ok "now-läge väntar INTE (${elapsed}s)" || bad "now-läge väntade ${elapsed}s"

# --- globalt lås: queue-läge VÄNTAR och timeoutar (config.dev: 5s) ---
t0=$SECONDS
$BIN backup --queue 9003 >/dev/null 2>&1; got=$?
elapsed=$((SECONDS - t0))
[[ "$got" == 75 ]] && ok "queue-läge: EX_TEMPFAIL efter timeout" || bad "queue-läge exit ($got)"
[[ "$elapsed" -ge 4 ]] && ok "queue-läge väntade på låset (${elapsed}s)" || bad "queue-läge väntade bara ${elapsed}s"
flock -u "$H"; exec {H}>&-

# --- per-vmid-lås: dubbelköning av SAMMA vmid avvisas ---
VLOCK="$LOCKDIR/lxc-offsite.vmid-9004.lock"
exec {V}>"$VLOCK"; flock -n "$V"
check_exit "per-vmid-lås hindrar dubbelköning" 75 $BIN backup 9004
flock -u "$V"; exec {V}>&-

# --- fetch/restore tar INTE globalt lås (går under pågående backup) ---
exec {H}>"$GLOBAL_LOCK"; flock -n "$H"
# fetch tar inte globalt lås → kör vidare förbi låset och faller på arkiv-lookup
# (dev-mock-remoten har inget arkiv) med EX_DATAERR, inte EX_TEMPFAIL(lås).
$BIN fetch 9005 2026_09_04-00_00_00 >/dev/null 2>&1; got=$?
[[ "$got" == 65 ]] && ok "fetch ignorerar globalt lås (kör vidare, faller på lookup)" || bad "fetch globalt lås ($got)"
flock -u "$H"; exec {H}>&-

# --- config: osäkra rättigheter vägras ---
tmpcfg="$PWD/run/badcfg"; echo 'CACHE_DIR=/tmp/x' > "$tmpcfg"; chmod 666 "$tmpcfg"
LXCO_CONFIG="$tmpcfg" $BIN status >/dev/null 2>&1
[[ $? == 78 ]] && ok "config med 666 vägras (EX_CONFIG)" || bad "osäker config vägrades ej"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
