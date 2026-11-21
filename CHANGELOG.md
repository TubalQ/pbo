# Changelog

Versions follow [semver](https://semver.org/). Until 1.0, a minor bump can change
behaviour; the entry says so when it does.

## 0.2.0 (2026-11-21)

Added
- Append-only offsite: a restic rest-server in `--append-only` mode as the offsite
  repo (`OFFSITE_APPEND_ONLY`, `RESTIC_REST_USERNAME`, `RESTIC_REST_PASSWORD_FILE`,
  `RESTIC_CACERT`). `doctor` proves the server refuses deletes. ADR 0004.
- Janitor role (`PBO_ROLE=janitor`, `install.sh --janitor`, `pbo-janitor.timer`):
  retention and verify on the storage side, freshness check of every guest in the
  repo. Drops root and re-execs as `JANITOR_USER`.
- `verify --scheduled`: reads the next 1/`VERIFY_ROTATE` of the data per run, all of
  it every `VERIFY_ROTATE` runs. `pbo-verify.timer` (weekly). `doctor` reports the
  last verify and fails if it failed.
- `doctor` warns about config keys pbo doesn't know (typos) and about a config
  written for a newer pbo (`PBO_CONFIG_VERSION`).
- `.deb` package (`packaging/build-deb.sh`), built in CI.
- `SECURITY.md` with a threat model. Integration test against a real Proxmox host
  (`tests/integration/pve.sh`).

Changed
- sftp options are passed to sftp repos only, `--cacert` to rest repos only.
- A `PBO_CONFIG` that points at a missing file is an error (exit 78). It used to run
  on built-in defaults, against a different repo.

## 0.1.0 (2026-11-16)

First version used in production: restic engine (vzdump archive stored in restic,
cache tier + offsite copy over native SFTP), LXC and QEMU, cluster-aware
(`BACKUP_ORDER=auto`, `PRUNE_OWNER`), `menu`/`setup`, `doctor`, `test-restore`,
`rotate-key`, `backup-host`/`restore-host`, scheduled prune with a schedule lock
so prune and backup never overlap.
