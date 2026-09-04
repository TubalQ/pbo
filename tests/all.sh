#!/usr/bin/env bash
# Kör alla testsviter. Använd före commit.
cd "$(dirname "$0")/.." || exit 1
fail=0
for t in run preflight backup upload list; do
    printf '\n=== %s ===\n' "$t"
    bash "tests/$t.sh" || fail=1
done
exit "$fail"
