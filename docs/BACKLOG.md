# Backlog — wishes to build in

## GUI (steps 11–13)
- **Export key** — a button that produces a ready, copy-pasteable rclone config
  string (the `[hetzner]` + `[hetzner-crypt]` sections, crypt passwords included) to
  import on a new host for disaster recovery. Equivalent to being able to do
  `install on new host → paste the string → list → restore`. Show a clear warning
  that the string IS the key (treat as a secret; store offline). Requires auth +
  audit logging (it is a secret export).

## Engine (restic)
- **Decision made:** restic replaces the tar.zst engine — see
  [`docs/adr/0001-restic-as-backup-engine.md`](adr/0001-restic-as-backup-engine.md)
  (Path A: vzdump tar stored in restic, `pct restore` untouched, CLI envelope kept).
  Migration in phases (`ENGINE=restic|tar` flag), coexistence until proven in
  production.

## VM + cluster
- **Direction set:** qemu VM support + cluster awareness — see
  [`docs/adr/0002-vm-and-cluster-support.md`](adr/0002-vm-and-cluster-support.md)
  (type branch `pct`/`qm`; cluster = agent-per-node + shared offsite repo +
  pmxcfs config). Phase 1 = VM locally, Phase 2 = cluster.

## Interface — reconsideration (2026-09-04)
- **TUI instead of/in addition to the web GUI?** The user is considering a terminal
  UI (TUI) instead of the web console. NOT decided, no effort spent yet — just
  noted. Consequence: the heavy **web onboarding rewrite (restic mode:
  repo-URL/sftp-command/repo-password + cache/offsite mode toggle) is PAUSED** until
  GUI-vs-TUI is settled. Engine-agnostic bits were done anyway: `_job_status` now
  recognizes restic's `Fatal:`/success markers (applies to a TUI as well). The
  restic list/prune/restore envelope is already UI-independent (CLI --json).

## Other
- (fill in)
