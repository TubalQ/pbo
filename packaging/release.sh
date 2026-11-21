#!/usr/bin/env bash
# packaging/release.sh <version>: cut a release.
#   1. sets VERSION in pbo, dates the "(unreleased)" CHANGELOG entry
#   2. runs the test suite
#   3. commits and creates a SIGNED annotated tag v<version> (git tag -s)
# Pushing is left to you: git push origin main v<version>. CI builds the .deb
# for the tag and attaches it to the release.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
ver="${1:-}"; [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <x.y.z>" >&2; exit 64; }
[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean" >&2; exit 1; }
git config user.signingkey >/dev/null || { echo "no user.signingkey: releases are signed tags, set up a GPG/SSH signing key first" >&2; exit 1; }
grep -q "^## $ver (unreleased)" CHANGELOG.md || { echo "CHANGELOG.md has no '## $ver (unreleased)' entry" >&2; exit 1; }

sed -i "s/^readonly VERSION=\".*\"/readonly VERSION=\"$ver\"/" pbo
sed -i "s/^## $ver (unreleased)/## $ver ($(date +%F))/" CHANGELOG.md
bash tests/all.sh >/dev/null || { echo "tests failed, nothing committed" >&2; git checkout -- pbo CHANGELOG.md; exit 1; }
git commit -qam "Release $ver"
git tag -s "v$ver" -m "pbo $ver"
echo "tagged v$ver. Push: git push origin main v$ver"
