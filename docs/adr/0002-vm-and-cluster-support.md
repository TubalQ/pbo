# ADR 0002, VM and cluster support

- **Status:** Accepted (direction), 2026-09-04
- **Decision:** Support **qemu VMs** (in addition to LXC) via type-branched
  backup/restore, and make the tool **cluster-aware** via the model **agent-per-node
  + shared offsite repo + cluster-replicated config** (pmxcfs). Phased: **VM locally
  first**, cluster after.
- **Builds on:** [ADR 0001](0001-restic-as-backup-engine.md) (restic, Path A, native sftp).

> Investigated against reality on 2026-09-04: cluster **mycluster**, 2 nodes (**pve2** +
> **pve1**, quorate), 12 LXC on pve1, **1 qemu, VM 101 `example-vm`
> on pve2** which the tool **cannot** reach today (wrong type + wrong node).
> Code investigation of the LXC-vs-VM assumptions completed 2026-09-05, see §7.

---

## 1. Context

The tool is LXC-only and runs only on pve1. Two gaps:

1. **VM (qemu).** VM 101 cannot be backed up: `vzdump` handles both types, but
   restore differs, LXC via `pct restore` (`.tar.zst`), qemu via **`qmrestore`**
   (`.vma.zst`). restore.sh/testrestore.sh hardcode `pct restore`.
2. **Cluster.** `vzdump`/`qmrestore` must run **on the node where the guest lives**.
   pve1 cannot vzdump VM 101 (on pve2). The read side is already cluster-aware
   (the API reads `pvesh get /cluster/resources` → the whole fleet with `node`), but
   *execution* reaches only local guests.

This does not break the "local-only" ethos: each node remains self-contained; what
is shared is the **offsite repo** and the **view**. It is exactly how PVE's own
backup jobs work (job defined cluster-wide, run per-node).

## 2. Decision, VM support (qemu)

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
  → `qm destroy`. The throwaway-vmid pool 9000-9099 is shared.

**Phase 1 (local):** VM support on the local node, unblocks local VMs immediately,
without the cluster complexity.

## 3. Decision, cluster: agent-per-node + shared repo + pmxcfs config

**Model A (chosen):** install pbo on **every node**. Each node backs up
**its own** guests (filter `cluster/resources` on `node == $localnode`) into the
**same** offsite restic repo (native sftp) → **cluster-wide dedup** in one repo.

Why Model A over a central dispatcher (Model B, ssh/pvesh to other nodes): it keeps
each node self-contained (the local-only ethos), no extra cross-node trust/ssh
mesh, and PVE already provides the building blocks:

- **Config cluster-wide for free:** put non-secret config in **`/etc/pve/`**
  (pmxcfs, replicated to all nodes automatically). `BACKUP_ORDER`, `KEEP_*`, and
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

### Concrete: the data path (Model A vs Model B)

The two models differ in **where the restic work runs** and thus how the archive
reaches the shared repo.

**Model A, autonomous per-node agent (PBS-faithful).** pbo on every node; each
node's own timer runs `vzdump → restic → the shared repo`, streaming **straight to
the target**:

```
pve1 ─ timer ─ vzdump(local guests) ─ restic ─┐
                                               ├─► sftp:…/lxc-restic  (one repo)
pve2 ─ timer ─ vzdump(101) ─────────── restic ─┘
```
Config shared via pmxcfs (`/etc/pve/pbo/`), secret per node
(`/etc/pbo/restic-pass`), prune from one `PRUNE_OWNER` node. No cross-node trust.
This is structurally how PVE+PBS already works: the "agent" that reaches every node
is each node's own `pvescheduler`; PBS is merely the shared **target**. Our shared
restic repo plays the PBS role; the data path is node→target, never node→central→target.

**Model B, API-orchestrated central ingest (no install on the remote node).** Only
a controller node runs pbo. It triggers the dump on the owning node over Proxmox's
own authenticated channel (`pvesh create /nodes/<node>/vzdump …`) and does the restic
work itself. The open question is how the (multi-GB) `.vma` reaches restic on the
controller:

| Var. | Transport | Note |
|---|---|---|
| B1 | dump to a **shared storage** both nodes see → restic reads it there | needs shared storage |
| B2 | `pvesh` dump on the node → `scp`/`rsync` the file to the controller → restic | staging file + ssh anyway |
| **B3** | `ssh <node> "vzdump <id> --stdout --compress 0" \| restic backup --stdin` | cleanest: one pipe, no staging. Needs ssh trust controller→node; loses the dumpdir grouping + `.conf` sidecar (fetch `qm config` via API separately) |

**Comparison**

| | A (per-node agent) | B3 (central ssh-stream) |
|---|---|---|
| Install on remote node | yes (script+restic+0600 pass) | **no** |
| Data path | node→target (1×) | node→controller→target (2×, but the extra hop is fast LAN; the WAN leg is an identical 1×) |
| restic CPU/crypto | runs **on the remote node** | on the **controller** (spares a constrained node) |
| Cross-node trust | none | ssh trust controller→node |
| Config sharing | pmxcfs | local (one node) |
| Prune | designated `PRUNE_OWNER` | central (free) |
| Single point of failure | none | the controller |
| Scales to more nodes | cleanly | controller becomes a bottleneck |
| Sidecar/grouping | kept | lost (`--stdin`), must be recreated |

**Refinement (2026-09-05 investigation).** Model A stays the default and the
end-state. But there is a real tension when a remote node is **resource-constrained**
(the `pve2` node is, see `pve-node/`): Model A puts restic's encryption/dedup/upload
on that weak node, while **B3 offloads it to the controller** and leaves only a cheap
`vzdump --stdout` on the remote node, and B3's "double network" falls only on the fast
LAN leg. **Recommended path:** run **A as the base** (the LXC node backs up its own
guests autonomously, already the case) and layer **B3 for the remote VM only**, via a
`REMOTE_NODES` table (guests listed there are triggered by ssh-stream instead of
locally), until/unless the remote node grows enough to host its own agent. This
unblocks the remote VM now without installing on the constrained node and does not
lock out the per-node agent later.

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

**Negative / price:** installation on every node (the pve2 node is "constrained", see
`pve-node/`); the qemu restore branch (`qmrestore`) + branched sidecar/meta logic;
prune must be centralized to one place; UI action routing is new work.

**Risks:** the pve2 node's resource constraint (is it enough for vzdump+restic?);
pmxcfs requires quorum, lost quorum ⇒ config reading may block (mitigate: cache the
config locally, do not degrade backup on quorum loss for own guests); a qemu
snapshot without a guest agent gives a crash-consistent (not app-consistent)
backup, document and warn in the UI.

## 5. Phasing (ties to the ADR 0001 migration)

- **Phase 1, VM locally:** type branch in backup/restore/testrestore (`pct` vs `qm`),
  `.vma` in restic. Test against a local throwaway VM. *(Independent of cluster.)*
- **Phase 2, cluster:** agent on pve2, shared repo, pmxcfs config, prune
  centralization, UI read-only for remote-node guests.
- **Phase 3, UI dispatch:** control remote-node actions from one view (`pvesh`/executor).

## 6. Open questions

- The pve2 node's capacity for vzdump+restic (measure; possibly `RCLONE_BWLIMIT`/nice/ionice).
- Prune owner in a cluster: a designated node vs an external janitor (ADR 0001 §7)?
- UI: one console-per-node (MVP) vs central dispatch, when is the step worth it?
- qemu app consistency: require a guest agent, or allow crash-consistent with a warning?
- Config in pmxcfs: the exact file split (non-secret in `/etc/pve/pbo/`,
  secret per node).
- The `REMOTE_NODES` table shape for the A-base + B3-per-remote-VM hybrid (§3).

## 7. Implementation map, Phase 1 (local VM support)

Code investigation 2026-09-05 against the current tree. The single explicit seam is
`lib/restic.sh:73-74` (`gtype="lxc" # TODO qemu`). Add a `_guest_type(vmid)` →
`lxc|qemu` (via `pct config` success vs `qm config`, or `.type` from
`/cluster/resources`, already read in `menu.sh:37`) and a thin type-aware layer:

| Concern | LXC (today) | qemu branch to add |
|---|---|---|
| Type detect | `pct config` | `qm config` / `.type` |
| Guest name | `hostname:` (`backup.sh:40`) | `name:` |
| Consistency | fuse→`stop` (`backup.sh:42-57`) | guest-agent fsfreeze else stop/suspend; fuse branch N/A |
| Dump output | `.tar` (`--compress 0`) | `.vma` (`--compress 0`) |
| Archive name | `vzdump-lxc-<id>` (`backup.sh:143`, `list.sh:79`, `prune.sh:61`, `restic.sh:149-152`) | `vzdump-qemu-<id>-*.vma[.zst]` |
| Structure check | `zstd -t` + tar (`backup.sh:156-163`) | `vma verify`/`vma list` |
| restic extract | `RX_TAR` find `vzdump-*.tar` (`restic.sh:168-183`) | find `.vma` |
| Snapshot tag | `type=lxc` (`restic.sh:108,422`) | `type=qemu` |
| Disk sizing | `rootfs:` (`restic.sh:359-368`) | `scsiN/virtioN/efidisk0` |
| Sidecar | `pct config` (`backup.sh:168`, `restic.sh:101`) | `qm config` |
| Restore verb | `pct restore <id> <arch> --unprivileged <n>` (`restore.sh:51`, `restic.sh:208`) | `qmrestore <arch> <id>` (no `--unprivileged`; note reversed arg order) |
| unpriv / bind-mounts | read from sidecar (`restore.sh:35-49`, `testrestore.sh:67`) | N/A for qemu |
| test-restore liveness | `pct exec -- true` (`testrestore.sh:18-25`) | `qm agent <id> ping` / `qm status` |
| test-restore verbs | `pct stop/destroy/start` (`testrestore.sh:10-34`) | `qm stop/destroy/start` |
| free-vmid scan | `pct config` (`testrestore.sh:28-34`) | also check `qm config`/cluster resources |
| preflight exists+vols | `pct config`, `rootfs/mpN` (`preflight.sh:55,65-77`) | `qm config`, VM disk keys |
| restore storage picker | `content ~ rootdir` (`menu.sh:247`) | `content ~ images` |
| deps | `pct vzdump zfs` (`install.sh:25`) | + `qm` |

The list/prune group-by keys off the stable dumpdir `$CACHE_DIR/<vmid>`, which is
**type-agnostic**, only the synthesized archive name (`.tar`, `type=lxc`) is wrong.

**Node-locality (ties to §3):** `.node` is fetched and shown (`menu.sh:37-66`) but
never routes execution, every `pct`/`vzdump` acts on the local node only. Phase 1
adds the local-node filter (`backup-set = BACKUP_ORDER ∩ guests_on_this_node`), a
no-op on a single node. Phase 2 wires Model A / B3 per §3.

**Proof (Phase 1):** a throwaway **local** VM → `backup` → restic → `restore` to a new
vmid → `qm start` → guest-agent ping / marker → `qm destroy`. No production VM is
touched (VM 101 lives on the remote node; it comes with Phase 2).
