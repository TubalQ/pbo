#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# Run all test suites. Use before commit.
cd "$(dirname "$0")/.." || exit 1
fail=0
for t in run restic schedule menu; do
    printf '\n=== %s ===\n' "$t"
    bash "tests/$t.sh" || fail=1
done
exit "$fail"
