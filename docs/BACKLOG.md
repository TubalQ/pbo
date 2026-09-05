# Backlog — wishes to build in

## Settled / shipped (no longer backlog)
- **Engine = restic.** The tar.zst engine was replaced; restic is the production
  engine (dedup + client-side encryption over native SFTP, one repo). See
  [`docs/adr/0001-restic-as-backup-engine.md`](adr/0001-restic-as-backup-engine.md).
- **Interface = prompt-CLI.** The FastAPI web console and the Textual TUI were
  removed. The shipped interface is `pbo menu` (rclone-style prompt-CLI), with a
  whiptail TUI (`lib/tui.sh`) as a zero-dependency fallback. See
  [`docs/adr/0003-tui.md`](adr/0003-tui.md).
- **Export DR key** — done (`menu → Export DR key`): prints the restic repo
  password (the whole DR key) with a treat-as-secret warning.

## VM + cluster (open)
- **Direction set:** qemu VM support + cluster awareness — see
  [`docs/adr/0002-vm-and-cluster-support.md`](adr/0002-vm-and-cluster-support.md)
  (type branch `pct`/`qm`, `qmrestore` for `.vma`; cluster = agent-per-node +
  shared offsite repo + pmxcfs config). Phase 1 = VM locally, Phase 2 = cluster.
  Not started. **Investigation done 2026-09-05:** the LXC-vs-VM code seam is mapped
  file-by-line (ADR 0002 §7) and the multi-node data path (Model A per-node agent vs
  Model B3 central ssh-stream, with an A-base + B3-for-remote-VM hybrid) is worked
  out (ADR 0002 §3).

## Hardening (open)
- **Repo-password rotation** to a user-chosen key: `restic key add` → verify →
  `restic key remove` (immediate, no re-encryption). Wire it into the menu.
- **Hardened janitor.** `prune` runs locally today, so the host holds the delete
  key → the provider's scheduled snapshots are the real ransomware backstop. An
  optional externalized/append-only janitor would remove that single point.

## Other
- Public GitHub release: `origin` currently points at the private Gitea repo
  (`ai-pvet440/pbo`); add the public remote when ready.
