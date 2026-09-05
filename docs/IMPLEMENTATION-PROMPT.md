# Implementation prompt — pbo

Paste the following into Claude Code in an empty repo directory.
Attach `PLAN.md` in the same directory before you run it.

---

You are to build `pbo` from scratch — a new production tool for Proxmox VE
that takes vzdump archives of LXC containers, ships them to Hetzner Storage Box via
rclone over SFTP, and can fetch them back for restore. With a PBS-style web
interface.

This is not a script. It is a tool that must be trustworthy in production and
troubleshootable at three in the morning by someone who did not write it.

`PLAN.md` in the repo is the requirements specification and `RESEARCH.md` is the
basis behind it. Read both first and follow them. Deviate only if something is
technically incorrect — and in that case say so instead of silently doing
something else.

**Inherit no existing codebase.** `RESEARCH.md` goes through the candidates and
rejects them all — they lack verification, offsite retention, or both. Read
section 1 so you know which mistakes not to repeat, but import nothing.

## Environment

- Proxmox VE, cluster `mycluster`, two nodes
- ZFS pools: `nvmepool` (NVMe mirror), `newbulk` (raidz2)
- LXC containers only, no VMs
- Existing PBS on 192.0.2.10 — **do not touch it**, this is a separate tier
- Existing ntfy for notifications
- Offsite: Hetzner Storage Box, SFTP port 23, via rclone crypt
- An existing reverse proxy in its **own dedicated VM** — never assume it shares a VM
- An existing OIDC provider

## Language and style

- CLI: Bash, `#!/usr/bin/env bash`, `set -Eeuo pipefail`
- API: Python 3 + FastAPI, in its own venv under `/opt/pbo`
- Frontend: ExtJS + `proxmox-widget-toolkit` from `/usr/share/javascript/`
- The project is licensed **AGPL-3.0**, LICENSE file in the repo root from commit one
- No external dependencies beyond: `rclone`, `vzdump`, `pct`, `zstd`, `jq`,
  `sha256sum`, `flock`, `curl`, `systemd`
- Every function that can fail returns a meaningful exit code
- All output is logged to both stdout and `/var/log/pbo/pbo.log`
  with timestamp and level (INFO/WARN/ERROR)
- No `echo` for errors — use a `log_error` function that also triggers a notification
- Comments in Swedish, code and variable names in English

## Build in this order

Build and test one step at a time. Stop and report after each step before moving
on.

**Step 1 — skeleton and configuration.** Argument parsing, subcommands, config
reading from `/etc/pbo/config`, logging, lock handling, `--dry-run` and
`--json` globally.

Locking is two-level and must be correct from the start: a **global** lock that
lets through one backup/push at a time regardless of vmid, and a **per-vmid** lock
against double-queuing. Scheduled runs queue on the global lock with a timeout;
manual ones exit immediately with a message about what is blocking. `fetch` and
`restore` never take the global lock. No real operations yet. All subcommands
should respond with "not implemented".

`--json` is not optional and not something added last. The GUI consumes only that
output, so every subcommand must have it from the start.

**Step 2 — preflight.** Before any backup:
- the container exists (`pct config <vmid>`)
- the ZFS pool has ≥ 1.5 × the container's used size free
- the cache directory exists and is writable
- the rclone remote responds (`rclone about`)
- parse `/etc/pve/lxc/<vmid>.conf`: identify bind mounts and `backup=0` volumes,
  log a WARN per finding, write them into the meta file

**Step 3 — backup.** `vzdump --mode snapshot --compress zstd`, then sha256, then
`zstd -t` + `tar -tf > /dev/null` as a structure check, then meta.json. No upload
yet.

**Step 3b — real-time log.** Before the upload is built: a function that streams
subprocess output line by line with progressive timestamps to both the log and the
job file. Without this, a 40-minute rclone transfer looks like a hung process, and
then someone will kill it midway. About thirty lines, but it determines whether the
tool feels reliable or not.

**Step 4 — upload and verification.** `rclone copy` with `--transfers`/`--checkers`
from config, never `--inplace`. After upload: `rclone check --checksum` between
cache and offsite. If it fails, delete the uploaded object and abort with an error.

**Step 5 — list and fetch.** `rclone lsjson` parsed with `jq` into a readable table
(vmid, timestamp, size, age). `fetch` retrieves a selected archive to
`$CACHE_DIR/restore/` and verifies sha256 against the sidecar file.

**Step 6 — restore.** `pct restore` to a **new** vmid. Read `unprivileged` from the
archive's config and set the flag explicitly. Refuse to run if the target vmid
already exists. Require `--yes` to actually run; without it, print the command that
would have been run.

**Step 7 — prune.** Separate policy for cache and offsite according to config. Must
support `--dry-run`. Must refuse to delete the latest archive per vmid regardless
of what the policy says. Never delete anything offsite that does not have a
verified hash.

**Step 8 — test-restore.** Full chain: fetch from offsite (not cache), verify,
restore to a throwaway vmid in the range 9000–9099, start, wait for the container
to respond, stop, destroy. Report the result via ntfy.

**Step 9 — systemd and scheduling.** **One** timer, not a template per container:
`pbo.timer` + `pbo.service` that runs `pbo run-schedule`.
That subcommand works through `BACKUP_ORDER` sequentially, one container at a time.
`Type=oneshot`, `TimeoutStartSec=infinity`, `OnFailure=` that notifies. No
`RandomizedDelaySec` — the run is sequential anyway and the start time should be
predictable.

Also implement `pbo status`: running jobs, queue length, and which vmid
holds the global lock.

**Step 10 — PVE storage for the cache.** Register the cache as a directory storage
with `pvesm add dir ... --content backup --is_mountpoint 1`. Verify that archives
show up in PVE's own backup view and that restore can be run from there.
`is_mountpoint 1` is mandatory — without it, PVE writes to the root filesystem if
the mount fails.

**Step 11 — API.** FastAPI that only calls the CLI with `--json`. No business logic
in the API layer. Long-running operations are started as transient systemd units
via `systemd-run` and return a job ID immediately; no endpoint blocks on an rclone
transfer. Logs are streamed via a `/jobs/<id>/log` endpoint. Run as a dedicated
non-root user with a sudoers file with full paths and no wildcards. Bind to the
node's LAN address, never 0.0.0.0.

**Step 12 — frontend.** ExtJS against `proxmox-widget-toolkit`. The views per
PLAN.md section 7: Dashboard, Offsite archives, Local cache, Jobs, Configuration.
Use the toolkit's own grid, tasklog, and form components so the result is identical
to PBS, not roughly similar. Never patch PVE's own files and do not add any apt
hook.

**Step 13 — auth and audit.** An OIDC provider via a reverse proxy forward-auth. Destructive
actions require the user to type the vmid manually as confirmation. All such
actions are logged in `/var/log/pbo/audit.log` with the OIDC subject,
timestamp, and parameters. The hook-script path is shown read-only — it requires
root@pam and must never be editable via the web.

**Step 14 — installer and runbook.** `install.sh` that puts files in place with the
right owner and permissions (config and rclone.conf `0600 root:root`). A
`RUNBOOK.md` that documents manual restore **without the tool** — with only
`rclone` and `pct` — step by step.

## Hard requirements

- The latest archive per vmid must never be deleted by prune
- An interrupted upload must not leave a visible half archive offsite
- `restore` never overwrites an existing vmid
- Verification is on checksum, never on size or modtime
- Notifications are sent on failure; success is silent unless `NTFY_ON_SUCCESS=true`
- The dashboard warns if Storage Box snapshots cannot be confirmed active — they
  are the only ransomware protection in this architecture
- No secrets in logs, error messages, or `set -x` output
- Never two `vzdump` at once — the global lock is a hard requirement, not an
  optimization. Two parallel dumps against raidz2 punish running containers
- A scheduled run that is blocked **queues**; a manual one exits with a message
- The GUI and CLI must always show the same numbers — the GUI owns no truth of its own
- No endpoint blocks on a network transfer
- Everything in the GUI can be done from the CLI with the API service stopped
- The hook script conditions on VMID; `backup-abort` is the failure signal, not `backup-end`

## Testing

Write `tests/` with bats or plain bash. At minimum:
- preflight rejects too little ZFS space
- a bind mount gives a WARN and ends up in meta.json
- prune with dry-run touches nothing
- prune refuses to delete the last archive
- the global lock prevents two concurrent backups of *different* vmids
- the per-vmid lock prevents double-queuing of the *same* vmid
- a scheduled run queues on a busy lock, a manual one exits
- `fetch` can run while a backup is in progress
- a corrupt sidecar hash causes fetch to fail

Mock `rclone`, `vzdump`, and `pct` in the tests. Do not run against real hardware.

## What you must not do

- Do not touch the PBS configuration on 192.0.2.10
- Do not assume the reverse proxy shares a VM with anything else
- Do not add features not in PLAN.md
- Do not replace vzdump archives with borg, restic, or your own chunk storage — that
  decision is made and justified in PLAN.md section 1
- Do not rely on borg append-only as protection; it does not work on Storage Box
- Do not write `rclone sync` anywhere — only `copy`, `check`, `lsjson`, `delete` on
  explicitly specified paths
- Do not rclone-mount offsite as PVE storage — offsite is reached only via explicit
  `rclone copy` calls
- Do not patch pve-manager or the widget toolkit, and do not install apt hooks
- Do not put business logic in the API layer
- Do not hardcode vmids, hostnames, or paths

Start with step 1. Report and wait for the go-ahead before step 2.
