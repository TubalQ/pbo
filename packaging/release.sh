#!/usr/bin/env bash
# packaging/release.sh <version>: cut a release (x.y.z, or x.y.z-rcN for a
# release candidate: a GitHub pre-release, and the CHANGELOG entry stays
# "(unreleased)" until x.y.z).
#   1. sets VERSION in pbo, dates the "(unreleased)" CHANGELOG entry (not for -rcN)
#   2. runs the test suite, and on a Proxmox host the integration test
#   3. commits and creates a SIGNED annotated tag v<version> (git tag -s)
# Pushing is left to you: git push origin main v<version>. CI builds the .deb
# for the tag and attaches it to the release.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
ver="${1:-}"; [[ "$ver" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-rc[0-9]+)?$ ]] || { echo "usage: $0 <x.y.z|x.y.z-rcN>" >&2; exit 64; }
base="${BASH_REMATCH[1]}" rc="${BASH_REMATCH[2]}"
[[ -z "$(git status --porcelain)" ]] || { echo "working tree not clean" >&2; exit 1; }
git config user.signingkey >/dev/null || { echo "no user.signingkey: releases are signed tags, set up a GPG/SSH signing key first" >&2; exit 1; }
grep -q "^## $base (unreleased)" CHANGELOG.md || { echo "CHANGELOG.md has no '## $base (unreleased)' entry" >&2; exit 1; }

sed -i "s/^readonly VERSION=\".*\"/readonly VERSION=\"$ver\"/" pbo
[[ -n "$rc" ]] || sed -i "s/^## $ver (unreleased)/## $ver ($(date +%F))/" CHANGELOG.md
bash tests/all.sh >/dev/null || { echo "tests failed, nothing committed" >&2; git checkout -- pbo CHANGELOG.md; exit 1; }
# On a Proxmox host, every release also passes the real-PVE integration test
# (tests/integration/pve.sh; PBO_IT_* env passes through, e.g. PBO_IT_JANITOR_CT
# and PBO_IT_JANITOR_URL for the append-only path). PBO_RELEASE_IT=0 skips it.
if [[ "${PBO_RELEASE_IT:-1}" != 0 ]] && command -v pct >/dev/null 2>&1; then
    echo "running the integration test on this Proxmox host (a few minutes)..."
    itlog="$(mktemp -t pbo-release-it.XXXXXX)"
    tests/integration/pve.sh > "$itlog" 2>&1 \
        || { echo "integration test failed (see $itlog), nothing committed" >&2; git checkout -- pbo CHANGELOG.md; exit 1; }
    grep -E '^[0-9]+ passed' "$itlog"
elif [[ "${PBO_RELEASE_IT:-1}" != 0 ]]; then
    echo "not a Proxmox host: integration test skipped. Run tests/integration/pve.sh on one before pushing the tag." >&2
fi
# The storage plugin against the real PVE libraries (read-only, no install):
# opt-in with PBO_IT_PVE_STORAGE=1, on a Proxmox host.
if [[ "${PBO_IT_PVE_STORAGE:-0}" == 1 ]]; then
    tests/integration/pve-storage.sh --load-only | tail -1 \
        || { echo "storage plugin integration test failed, nothing committed" >&2; git checkout -- pbo CHANGELOG.md; exit 1; }
fi
git commit -qam "Release $ver"   # an rc changes only VERSION
git tag -s "v$ver" -m "pbo $ver"
echo "tagged v$ver. Push: git push origin main v$ver"
