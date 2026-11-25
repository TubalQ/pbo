#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# Run all test suites. Use before commit.
#
# The suites are independent (each has its own run*/ directory, its own
# LOCK_DIR and mocks), so they run in parallel: PBO_TEST_JOBS (default: the
# number of CPUs) at a time, each into its own log, printed in the usual order
# afterwards. PBO_TEST_JOBS=1 runs them one after the other. Suites that assert
# a time budget run alone at the end, so the parallel load cannot make them
# flaky. Output keeps the "=== <suite> ===" headers CI turns into annotations.
cd "$(dirname "$0")/.." || exit 1
# The config corpus (0.6 M2, M3, ADR 0009): the strict reader's verdict on every config a
# suite loads through load_config is logged, and for each file it accepts, the
# keys bash reads differently when it sources the file in a clean subshell
# (load_config's test hook, values never written). The last step proves the
# reader accepts each of them and agrees with bash on every key. A hook rather
# than a list of the tests' config bodies: suites write many configs, rewrite
# them in place and delete them, so only load time sees each version. Appends
# of one short line from several suites at once are atomic.
export PBO_TEST_CONFIG_LOG="$PWD/run-config-corpus/log"
rm -rf run-config-corpus; mkdir -p run-config-corpus; : > "$PBO_TEST_CONFIG_LOG"

par_suites=(run restic schedule ownership catalog ingest integrate install perl menu host appendonly verify policy retention notify metrics restoretest json jobs regressions perms config_write)
serial_suites=(config config_parse)   # time-budget assertions: run without other load
jobs="${PBO_TEST_JOBS:-$(nproc 2>/dev/null || echo 2)}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || jobs=2

logs="$PWD/run-testlogs"; rm -rf "$logs"; mkdir -p "$logs"
export PBO_TEST_LOGS="$logs"
_one() {   # _one <suite>: run it into $PBO_TEST_LOGS/<suite>.{log,rc,sec}
    local s="$1" t0=$SECONDS rc=0
    bash "tests/$s.sh" > "$PBO_TEST_LOGS/$s.log" 2>&1 || rc=$?
    printf '%s\n' "$rc" > "$PBO_TEST_LOGS/$s.rc"
    printf '%s\n' "$(( SECONDS - t0 ))" > "$PBO_TEST_LOGS/$s.sec"
}
export -f _one

t_start=$SECONDS
printf '%s\n' "${par_suites[@]}" | xargs -P "$jobs" -I{} bash -c '_one "$1"' _ {}
for s in "${serial_suites[@]}"; do _one "$s"; done

fail=0
for s in "${par_suites[@]}" "${serial_suites[@]}"; do
    printf '\n=== %s ===\n' "$s"
    cat "$logs/$s.log" 2>/dev/null
    rc="$(cat "$logs/$s.rc" 2>/dev/null || echo missing)"
    [[ "$rc" == 0 ]] || { fail=1; printf '  (suite %s exited %s)\n' "$s" "$rc"; }
done
printf '\n=== config corpus ===\n'
bash tests/config_parse.sh --corpus "$PBO_TEST_CONFIG_LOG" || fail=1

printf '\n=== timing (%s parallel) ===\n' "$jobs"
for s in "${par_suites[@]}" "${serial_suites[@]}"; do printf '%s %ss\n' "$s" "$(cat "$logs/$s.sec" 2>/dev/null || echo ?)"; done | sort -k2 -t' ' -rn | head -5 | sed 's/^/  slowest: /'
printf '  total: %ss\n' "$(( SECONDS - t_start ))"
exit "$fail"
