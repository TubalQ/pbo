#!/usr/bin/env bash
export PBO_NO_NOTIFY=1   # tests must never reach a real ntfy server
# tests/perl.sh: the PVE storage plugin (pve-plugin/PboPlugin.pm) against stubbed
# PVE modules (tests/perl/lib), with Test::More. Needs no Proxmox: the real PVE
# libraries are exercised by tests/integration/pve-storage.sh (opt-in).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# the schema defaults of RESTIC_ENV_FILE, NTFY_CREDS_FILE, PBO_SYSTEMD_DIR (the
# timer drop-ins), PBO_PVE_CFS_DIR and PVE_STORAGE_CFG (pmxcfs: the derived
# PVE_STORAGE_ID reads its member list and storage.cfg on every start),
# PBO_PVE_LXC_DIR and PBO_PVE_QEMU_DIR (a guest's current name, read for a
# snapshot that records none) are the machine's own files: point them into
# the checkout, at paths nothing creates
# (a config line still wins)
export RESTIC_ENV_FILE="$PWD/run-none/restic.env" NTFY_CREDS_FILE="$PWD/run-none/ntfy.env" PBO_SYSTEMD_DIR="$PWD/run-none/systemd" \
    PBO_PVE_CFS_DIR="$PWD/run-none/pve" PVE_STORAGE_CFG="$PWD/run-none/pve/storage.cfg" \
    PBO_PVE_LXC_DIR="$PWD/run-none/pve/lxc" PBO_PVE_QEMU_DIR="$PWD/run-none/pve/qemu-server"
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
if ! command -v perl >/dev/null 2>&1 || ! command -v prove >/dev/null 2>&1; then
    echo "perl or prove not installed, skipping the plugin tests (SKIP)"; exit 0
fi

printf 'pbo: PVE storage plugin tests\n'
out="$(perl -I tests/perl/lib -c pve-plugin/PboPlugin.pm 2>&1)" \
    && ok "perl -c pve-plugin/PboPlugin.pm (stubbed PVE modules)" || bad "perl -c: $out"
# the plugin must not need PVE::Storage itself (loading it would load every plugin)
grep -Eq '^use PVE::Storage;' pve-plugin/PboPlugin.pm && bad "the plugin uses PVE::Storage" || ok "the plugin does not load PVE::Storage"
for t in tests/perl/*.t; do
    if out="$(prove -I tests/perl/lib "$t" 2>&1)"; then
        ok "prove $t ($(grep -Eo 'Tests=[0-9]+' <<<"$out" | head -1))"
    else
        bad "prove $t"; printf '%s\n' "$out" | sed 's/^/    /'
    fi
done
# the index stays readable for the plugin of the last release before the name
# field (0.6.1): a host may run that plugin until its pbo-pve-storage package
# is upgraded. A frozen copy of it is a fixture, so the check runs everywhere
# (CI's shallow clone has no tags, an export no git at all); where git has the
# release tag, the copy must still be the released file.
old_plugin=tests/perl/fixtures/PboPlugin-0.6.1.pm
RUN="$PWD/run-perl"; rm -rf "$RUN"; mkdir -p "$RUN/idx-old" "$RUN/idx-new"
if command -v git >/dev/null 2>&1 && git cat-file -e v0.6.1:pve-plugin/PboPlugin.pm 2>/dev/null; then
    if cmp -s <(sed '1,/^# --- end of header: the released file follows unchanged ---$/d' "$old_plugin") <(git show v0.6.1:pve-plugin/PboPlugin.pm); then
        ok "$old_plugin is the plugin of tag v0.6.1"
    else
        bad "$old_plugin differs from git show v0.6.1:pve-plugin/PboPlugin.pm (the fixture must stay the released file)"
    fi
fi
for p in "$old_plugin" pve-plugin/PboPlugin.pm; do
    d="$RUN/idx-old"; [[ "$p" == "$old_plugin" ]] || d="$RUN/idx-new"
    if out="$(perl -I tests/perl/lib tests/perl/index-compat.pl "$PWD/$p" "$d" 2>&1)"; then
        ok "$p reads an index with the name field ($(grep -c '^ok ' <<<"$out") checks)"
    else
        bad "$p and an index with the name field"; printf '%s\n' "$out" | sed 's/^/    /'
    fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
