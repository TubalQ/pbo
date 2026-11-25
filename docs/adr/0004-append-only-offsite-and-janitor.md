# ADR 0004, append-only offsite with a separate janitor

- **Status:** Accepted, built 2026-11-21
- **Decision:** Support a restic **rest-server in `--append-only` mode** as the
  offsite repo. The PVE host can add snapshots there but never delete. Retention
  moves to a second machine, the **janitor**, which runs the same `pbo` with
  `PBO_ROLE=janitor` against the repo on its local disk.

## Problem
Prune runs on the host, so the host holds credentials that can delete every
offsite snapshot. Whoever owns the host owns the backups. Without append-only,
provider snapshots (such as a Storage Box's) are the only backstop, and they're
outside pbo's control and outside what `doctor` can check.

## Why rest-server
restic's own rest-server has `--append-only`: it refuses DELETE on everything
except lock files, which is exactly the split we need. It's one static binary,
upstream, and restic speaks to it natively. An SFTP user with a restricted
command (or `rrsync`) could do something similar but is harder to get right and
impossible for pbo to verify. S3 object lock is the other good option and may
follow as a later backend.

`--private-repos` maps each HTTP user to its own path, so several hosts can share
one server without seeing each other's repos.

## Decisions

**The host must be told.** restic returns exit code 0 when the server answers a
`forget` with 403; it prints the error and the snapshot stays. A host that
doesn't know its offsite is append-only gets a prune that looks clean and does
nothing, and nobody notices until the disk fills. So it is an explicit setting,
`OFFSITE_APPEND_ONLY=true`, and with it the host:
- prunes the cache tier only, and reports `offsite_skipped: append_only`
- adds the new key but leaves the old one in place on `rotate-key`, and says so
  (`offsite_old_key_pending`); the janitor removes it

**`doctor` proves it.** It sends a DELETE for a key id that can't exist
(64 zeros). An append-only server answers 403; a normal one 200. Nothing exists
to be deleted, so the probe is harmless either way. 403 is OK; 200/404 is a hard
failure (the host believes it's protected and isn't); 401 is an auth failure.
A verified append-only server counts as the ransomware backstop, so the
provider-snapshot warning goes away. The reverse case is caught too: a server
that refuses deletes while `OFFSITE_APPEND_ONLY=false` gives a warning.

**Credentials.** `RESTIC_REST_USERNAME` + `RESTIC_REST_PASSWORD_FILE`, handed to
restic through its environment and to curl on stdin, never in argv. A
self-signed server cert is pinned with `RESTIC_CACERT` (`--cacert`). sftp
options are only sent to sftp repos, `--cacert` only to rest repos.

**The janitor is pbo, not a second tool.** `PBO_ROLE=janitor` with
`LOCAL_REPO=false` and `RESTIC_OFFSITE_REPO=<dir on disk>`. Retention logic is
the same code path as on a host (`prune` = GFS on offsite). Guest commands
(backup, restore, run-schedule, test-restore, backup-host, preflight) are
refused. `install.sh --janitor [--user <u>]` installs it without the PVE checks
and installs `pbo-janitor.timer` (daily 12:30) instead of `pbo.timer`. The timer
runs `prune`, then `verify --scheduled` (the next 1/`VERIFY_ROTATE` slice, cheap on local disk), then
`doctor`.

**The janitor runs as the rest-server user.** A prune as root writes new index
and pack files owned by root, which rest-server can't read; the next backup
fails. The unit sets `User=`, and `doctor` on a janitor fails if any file in the
repo has a different owner than the repo's `config`.

**The janitor watches the hosts.** It has no guests of its own, so `doctor`
there checks the newest snapshot of every vmid in the repo against
`DOCTOR_MAX_AGE`. A host that stops sending backups shows up on a machine the
host can't touch. `host-*` (manual `backup-host`) is not age-checked.

## Consequences
- The janitor must be a machine the hosts have no admin access to. A janitor in
  an LXC on the PVE host it guards protects nothing: host root is root in the
  container. That is fine for testing only.
- The janitor holds the repo password (it must, to prune) and full delete
  rights. It becomes the machine to protect: no inbound except rest-server, no
  SSH, not reachable from the hosts on anything but port 8000.
- Deleted-by-retention data is gone once the janitor prunes. Append-only stops a
  compromised host, not a compromised janitor.
- Restore is unaffected: reads go through the rest-server like before.
- Retention settings now live in two places (host for the cache, janitor for
  offsite). The host's `KEEP_OFFSITE_*` are ignored in append-only mode.

## Verified
Against restic's rest-server with `--append-only --private-repos --tls`: a
backup through pbo works, `restic forget` from the host is refused with 403 and
rc 0, a host prune leaves offsite untouched, a janitor prune applies GFS, the
doctor probe returns 403 on an append-only server and 200 on a writable one,
and a restore from the append-only repo boots. Steps are in the RUNBOOK.
