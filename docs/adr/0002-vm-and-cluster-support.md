# ADR 0002 — VM and cluster support

- **Status:** Accepted (direction) — 2026-09-04
- **Decision:** Support **qemu VMs** (in addition to LXC) via type-branched
  backup/restore, and make the tool **cluster-aware** via the model **agent-per-node
  + shared offsite repo + cluster-replicated config** (pmxcfs). Phased: **VM locally
  first**, cluster after.
- **Builds on:** [ADR 0001](0001-restic-as-backup-engine.md) (restic, Path A, native sftp).

> Investigated against reality on 2026-09-04: cluster **mycluster**, 2 nodes (**pve2** +
> **pve1**, quorate), 12 LXC on pve1, **1 qemu — VM 101 `example-vm`
> on pve2** which the tool **cannot** reach today (wrong type + wrong node).

---

## 1. Context

The tool is LXC-only and runs only on pve1. Two gaps:

1. **VM (qemu).** VM 101 cannot be backed up: `vzdump` handles both types, but
   restore differs — LXC via `pct restore` (`.tar.zst`), qemu via **`qmrestore`**
   (`.vma.zst`). restore.sh/testrestore.sh hardcode `pct restore`.
2. **Cluster.** `vzdump`/`qmrestore` must run **on the node where the guest lives**.
   pve1 cannot vzdump VM 101 (on pve2). The read side is already cluster-aware
   (the API reads `pvesh get /cluster/resources` → the whole fleet with `node`), but
   *execution* reaches only local guests.

This does not break the "local-only" ethos: each node remains self-contained; what
is shared is the **offsite repo** and the **view**. It is exactly how PVE's own
backup jobs work (job defined cluster-wide, run per-node).

## 2. Decision — VM support (qemu)

`vzdump <vmid>` auto-detects the type. Branch on **guest type** in the restore
paths:

| | LXC | qemu (VM) |
|---|---|---|
| Backup | `vzdump` → `.tar` (`--compress 0`) | `vzdump` → `.vma` (`--compress 0`) |
| Restore | `pct restore <id> <archive> --storage --unprivileged <n>` | `qmrestore <archive> <id> --storage <pool>` |
| Consistency | fuse → `--mode stop` (deadlock guard) | snapshot with **qemu-guest-agent** (fsfreeze); otherwise `stop`/`suspend` |
| Sidecar | `unprivileged`, bind mounts | no `unprivileged`; disks, no bind mounts |

- **restic Path A applies unchanged:** the `.vma` (uncompressed) is stored in restic
  like any other blob; disk content dedups well between runs (CDC finds unchanged
  blocks). Restore = `restic restore` → `qmrestore`.
- The meta/sidecar logic branches: qemu lacks `unprivileged`/bind mounts, has disks
  with their own storage placements. `_effective_mode` keeps fuse→stop **only** for
  LXC; for qemu: `snapshot` if a guest agent is present, otherwise a configurable
  fallback.
- test-restore: `qmrestore` → `qm start` → wait (guest-agent/ping) → `qm stop`
  → `qm destroy`. The throwaway-vmid pool 9000–9099 is shared.

**Phase 1 (local):** VM support on the local node — unblocks local VMs immediately,
without the cluster complexity.

## 3. Decision — cluster: agent-per-node + shared repo + pmxcfs config

**Model A (chosen):** install pbo on **every node**. Each node backs up
**its own** guests (filter `cluster/resources` on `node == $localnode`) into the
**same** offsite restic repo (native sftp) → **cluster-wide dedup** in one repo.

Why Model A over a central dispatcher (Model B, ssh/pvesh to other nodes): it keeps
each node self-contained (the local-only ethos), no extra cross-node trust/ssh
mesh, and PVE already provides the building blocks:

- **Config cluster-wide for free:** put non-secret config in **`/etc/pve/`**
  (pmxcfs — replicated to all nodes automatically). `BACKUP_ORDER`, `KEEP_*`, and
  the schedule sync themselves. **Secrets NOT here** (pmxcfs replicates in plaintext)
  → the repo password per node in `/etc/pbo/` 0600 + your password manager.
- **Migration-safe:** restic tags per **vmid** (not node). If a guest is moved, the
  new node backs it up on the next run; the history continues under the same vmid.
- **Concurrent writers, one repo:** restic allows multiple parallel `backup`
  operations against the same repo (lock files). **`prune` requires an exclusive
  lock → run from EXACTLY one place** (one node's janitor, or the hardened external
  janitor; see ADR 0001 §7).
- **Schedule:** each node's timer works through its local guests. No central
  coordinator is needed for backup; only for prune.

### Web UI in a cluster

The view is already cluster-wide (a guest list with a `node` column). What changes
is the **routing of actions**: a `backup`/`restore` on a guest that lives on another
node must be executed **there**. Options:

- **MVP:** each node runs its own API/console; a guest action is only enabled on the
  node that owns the guest (others shown read-only with "runs on node X"). Simplest,
  breaks nothing.
- **Later:** one console dispatches to the owner node via the PVE API
  (`pvesh create /nodes/<node>/vzdump …`) or a thin per-node executor, so everything
  is controlled from one view.

**Phase 2 (cluster):** an agent on the pve2 node + shared repo + pmxcfs config +
UI routing (the MVP level first).

## 4. Consequences

**Positive:** full coverage (all guests, all nodes, both types); one shared repo →
dedup across the whole cluster; config sync for free via pmxcfs; migration-safe.

**Negative / price:** installation on every node (the pve2 node is "constrained" — see
`pve-node/`); the qemu restore branch (`qmrestore`) + branched sidecar/meta logic;
prune must be centralized to one place; UI action routing is new work.

**Risks:** the pve2 node's resource constraint (is it enough for vzdump+restic?);
pmxcfs requires quorum — lost quorum ⇒ config reading may block (mitigate: cache the
config locally, do not degrade backup on quorum loss for own guests); a qemu
snapshot without a guest agent gives a crash-consistent (not app-consistent)
backup — document and warn in the UI.

## 5. Phasing (ties to the ADR 0001 migration)

- **Phase 1 — VM locally:** type branch in backup/restore/testrestore (`pct` vs `qm`),
  `.vma` in restic. Test against a local throwaway VM. *(Independent of cluster.)*
- **Phase 2 — cluster:** agent on pve2, shared repo, pmxcfs config, prune
  centralization, UI read-only for remote-node guests.
- **Phase 3 — UI dispatch:** control remote-node actions from one view (`pvesh`/executor).

## 6. Open questions

- The pve2 node's capacity for vzdump+restic (measure; possibly `RCLONE_BWLIMIT`/nice/ionice).
- Prune owner in a cluster: a designated node vs an external janitor (ADR 0001 §7)?
- UI: one console-per-node (MVP) vs central dispatch — when is the step worth it?
- qemu app consistency: require a guest agent, or allow crash-consistent with a warning?
- Config in pmxcfs: the exact file split (non-secret in `/etc/pve/pbo/`,
  secret per node).
