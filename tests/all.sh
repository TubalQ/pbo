#!/usr/bin/env bash
# Run all test suites. Use before commit.
cd "$(dirname "$0")/.." || exit 1
fail=0
for t in run preflight backup upload list restore prune testrestore schedule; do
    printf '\n=== %s ===\n' "$t"
    bash "tests/$t.sh" || fail=1
done
exit "$fail"
