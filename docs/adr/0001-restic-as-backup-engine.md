# ADR 0001 — restic as backup engine (Path A: vzdump tar in restic)

- **Status:** Accepted — 2026-09-04
- **Decision:** Adopt **restic** as lxc-offsite's storage/transport/encryption/
  verification/retention engine, in **Path A** (the vzdump archive is stored *in* restic).
  Keep the CLI's JSON envelope and the `pct restore` integration — change the engine, not the contract.
- **Context tags:** SFTP-only · local-only · web-UI · no remote compute

> This ADR is the SSOT for the engine choice. Recipe/config/code should reference it,
> not duplicate the reasoning. The proofs below were run against **restic 0.18.0**
> (Debian trixie/main) in a throwaway environment on 2026-09-04.

---

## 1. Context and problem

lxc-offsite is deliberately built for people who do **not** have a machine to run
PBS on, but who do have a dumb **SFTP box** (Hetzner Storage Box, rsync.net, own
ssh). The constraints are fixed: **transport = SFTP**, **operation = local-only on
a Proxmox host, self-contained, with a web UI**, **no remote compute**.

Current engine: `vzdump → full tar.zst per run → rclone crypt over sftp`. It has a
hard ceiling:

- **Always full.** No dedup, no incremental → bandwidth + storage grow linearly and
  set a floor on RPO (how often you can run).
- **No browsing** of contents (unlike PBS).
- A lot of **custom code** for what are solved problems: sha256 sidecars, `zstd -t`,
  `tar -tf`, rclone `cryptcheck`, the fetch+verify dance, a custom GFS prune.

The four guarantees that separate "near-enterprise" from "cron+rclone" —
**immutability, proven restorability, least-privilege/traceability,
observability** — require dedup/incremental + client-side encryption + integrity.
On dumb SFTP the chunk store can only live on the **client side**. That is exactly
what restic is: content-addressed dedup that writes **ordinary files** to any SFTP
box.

## 2. Decision

Adopt **restic**. Use **Path A**: let `vzdump` keep producing the CT archive, but
store it (uncompressed) *in* a restic repo instead of pushing tar.zst via rclone.
Restore goes via `restic restore → pct restore` — **the entire Proxmox integration
and sidecar logic (unprivileged/storage/bind-mounts) is left untouched.**

### Pipeline (Path A)

```
preflight (unchanged)
  → vzdump <id> --mode <m> --compress 0 --dumpdir $CACHE/<id>   # UNCOMPRESSED tar + .conf/.meta
  → restic -r $CACHE_REPO   backup $CACHE/<id> --tag vmid=<id> --host <node>   # local (cache tier)
  → restic -r $OFFSITE_REPO copy   --from-repo $CACHE_REPO                    # → SFTP (offsite)
  → restic -r $OFFSITE_REPO check   [--read-data]                            # verification (background)
retention:
  host:    restic -r $CACHE_REPO forget --keep-daily/weekly/monthly [--prune]   # KEEP_* map 1:1
  janitor: restic -r $OFFSITE_REPO forget --prune                               # never from the host
restore / test-restore:
  → restic -r $OFFSITE_REPO restore <snapshot-id> --target $CACHE/restore
  → pct restore <new-vmid> <extracted tar> --storage <pool> --unprivileged <n>   # UNCHANGED
```

The offsite repo is initialized with a shared chunker for dedup parity:
`restic -r $OFFSITE_REPO init --copy-chunker-params --from-repo $CACHE_REPO`.

### Backend: restic's built-in sftp (native), not rclone

`$OFFSITE_REPO` is restic's **built-in sftp backend**, directly over ssh — no
rclone in the data path:

```
OFFSITE_REPO=sftp:uXXXXX-subN@uXXXXX.your-storagebox.de:23/lxc-restic
# ssh key via ~/.ssh/config or -o sftp.args; parallel connections: -o sftp.connections=N
```

Reasons:
- **One layer fewer.** The product is "for SFTP" → the direct backend is the most
  honest fit; the SSH key already exists (`/root/.ssh/id_rsa`).
- **Append-only enforcement lives in the SSH layer.** `restic backup` only *adds*
  pack files; it is `prune` that deletes. An SSH endpoint (forced-command /
  no-delete key / `chattr +a`) that permits write but forbids delete lets the host's
  backups through but blocks deletion = append-only. With native sftp, *you* own
  that point. (restic's documented `--append-only` applies only to the rest-server
  backend, not sftp — on SFTP the SSH side is the enforcement point.)

**The crypt remote (`hetzner-crypt`) goes away** regardless of backend — restic
encrypts itself.
**Alternative (documented, not chosen):** `rclone:hetzner:lxc-restic` reuses the
*plain* rclone-sftp remote as transport (giving rclone's pool/retry/`--bwlimit` in
the data path) — choose it only if a single transport config for everything is
desirable.

### Modes: local cache or offsite-only (selectable)

The user should be able to choose **where the backups live** — not everyone has a
spare disk for a local repo. Two orthogonal config keys (added in Phase 1):

| Mode | `LOCAL_REPO` | `OFFSITE_ENABLED` | Flow |
|---|---|---|---|
| **cached** (default) | `true` | `true` | `restic backup` → local repo → `restic copy` → offsite. Local repo = fast restore tier + staging. `KEEP_LOCAL` applies. |
| **offsite-only** | `false` | `true` | `vzdump --stdout \| restic backup --stdin` **directly** to the offsite sftp repo. No persistent local data storage — only transient scratch for the current guest. `KEEP_LOCAL` N/A. |
| local-only | `true` | `false` | backup to local repo, no push (airgap/test). |

- **offsite-only** minimizes disk footprint (important for small hosts): no local
  repo to maintain; restic still has its metadata cache (`RESTIC_CACHE_DIR`) for
  speed. The price: every restore/test-restore fetches from offsite (already true
  today), and the `--stdin` snapshot carries the tar but **not** the `.conf` sidecar
  in the same snapshot — the config is added as a second path in the scratch
  directory that gets backed up (i.e. `restic backup $SCRATCH/<id>/` instead of pure
  stdin when sidecars are needed).
- **cached** gives the fastest restore (local copy) and a cheap `copy` to offsite.
- The UI (onboarding) exposes the choice as a simple toggle: **"Where should the
  backups live? · Local cache + offsite · Offsite only"** (see §6).

## 3. Alternatives considered (and why not)

- **Keep the bespoke tar.zst.** Simple and auditable, but the ceiling is permanent
  "always full, no dedup, no browsing". Not PBS-like. Rejected as a goal, kept as a
  *coexistence* track during migration (see §8).
- **Path B — restic backup of the CT's extracted filesystem.** Best dedup
  (file-level, PBS-class) + file browsing. But restore is **not** `pct restore` —
  you have to rebuild the CT yourself (idmap/unprivileged shifting, xattrs, special
  files). Much more invasive. **Deferred** as a future optimization, not v1.
- **S3 Object Lock (B2/Wasabi/MinIO).** Provides true WORM, but **breaks the
  SFTP-only intent** — it is a different product. Rejected.
- **PBS as backend.** "Real" PBS dedup, but requires a machine/service to run PBS on
  → **breaks local-only / no-extra-machine**, the entire reason for existing.
  Rejected.

## 4. Proof (restic 0.18.0, against our own flow)

| What | Result |
|---|---|
| Dedup/incremental | Line change in 9.5 MiB → **9.8 KiB stored**; repo does not grow per run |
| Cache→offsite | `restic copy` (chunker-shared) → dedup preserved between tiers |
| Offsite = dumb tier | repo = ordinary files (`config data index keys snapshots`) → works on any SFTP |
| Verification | `check --read-data` = re-reads + hashes all data → **stronger** than rclone cryptcheck |
| Restore | bit-identical (sha256 on all 202 files matched) |
| stdin | `vzdump --stdout | restic backup --stdin` works (even dedups against the file backup) |

## 5. What restic REPLACES / what STAYS

**Replaced (custom code that can be removed):**

| Today | With restic |
|---|---|
| `upload.sh`: rclone copy + **crypt** | `restic copy` (restic encrypts itself → the crypt layer disappears) |
| sha256 sidecar + `zstd -t` + `tar -tf` | restic content-addressed integrity + `check` |
| `list.sh`: rclone lsjson + jq per vmid | `restic snapshots --json` (filter on `--tag vmid=<id>`) |
| `prune.sh`: custom GFS engine | `restic forget --keep-daily/weekly/monthly` — **`KEEP_*` map 1:1** |
| `_fetch_core`: fetch + sha256-verify | `restic restore` (verifies on extraction) |
| rclone `cryptcheck` | `restic check` (`--read-data` for depth) |

**Stays (the product's value):** preflight.sh, the vzdump orchestration, `pct restore`
+ unprivileged/storage/bind-mount sidecars, the fuse→stop mode, the web UI/API, the
schedule, ntfy, audit, and the two-part append-only design.

**Bonus:** one repo for all guests → restic dedups **between** guests (shared OS
layers), not just within a guest.

## 6. UI impact (the web console)

The read panels become **cheaper/better**; the write panels are **scoped** work.

| Panel | Source with restic | Verdict |
|---|---|---|
| Content (grouped snapshots) | `restic snapshots --json` → `id`, `time`, `tags:["vmid=…"]`, **`summary.total_bytes_processed`** (size in the same call) | Better, one call |
| Offsite used / Datastore Usage | `restic stats --mode raw-data` → `total_size` (physical, deduped) | Cleaner |
| Verify — last result | `restic check` exit code → OK/FAIL | More robust (rc, not string match) |
| Guests retention / Options | `KEEP_*` → `--keep-*` (1:1), text | Trivial |
| Tasks + log color | mechanism unchanged; tune the `_job_status` tokens ("Fatal:", "no errors were found") | Almost unchanged |

**Three panels require a real rewrite:**
1. **Remotes/onboarding** (biggest): repo URL (`sftp:`) + repo password +
   one-time `restic init`; the crypt-password/salt fields **disappear**. Plus a
   **mode toggle** "Local cache + offsite / Offsite only" (§2) that sets
   `LOCAL_REPO`/`OFFSITE_ENABLED`, and a line about the immutability mode (local
   janitor → rely on provider snapshots; §7).
2. **Prune panel**: `forget --dry-run --json` gives `{keep:[ids], remove:[ids]}` +
   reclaimed bytes — not filename arrays; `renderPrune()` is rewritten.
3. **Restore modal + export-key**: `ts` → snapshot `id`; export-key gives the repo
   password + repo URL instead of `rclone.conf`.

**The migration path for the UI:** the API is a thin shell (`cli(... --json)` +
`_cached`). If the CLI keeps its **JSON envelope**, the web UI **does not change**
for the read panels — only the three semantically changed panels are touched.
`check --read-data` is expensive → run it as a **background task** (like
test-restore), never in a poll.

**Upside later:** per-run dedup delta (`summary.data_added_packed`), repo-wide
"space saved" (stats), `restic ls`/`mount` for file browsing (requires Path B).

## 7. Immutability on SFTP (still core)

restic does not change the immutability strategy — it **reinforces** it:
- **Two credentials.** The host gets a key that may only **write/append**;
  `forget --prune` (which deletes/repacks offsite) is run from a **janitor** outside
  the host. A ransomware-hit host cannot wipe out history.
- **Provider snapshots** as a baseline where append-only cannot be enforced (Hetzner
  BTRFS / rsync.net ZFS) — verified, not just checked off.
- **Tension to manage:** `restic prune` requires delete offsite → belongs to the
  janitor. `forget` (releasing snapshot references) is cheap and can be run from the
  host; the heavy `prune` (repack + delete) is run separately.

### Janitor: local systemd timer / cron script (default)

`prune` runs as its **own systemd service+timer** (or a cron that calls a script),
**separate from the backup timer**. Simple and self-contained — a fit for
local-only.

> **Honest consequence:** run the janitor on the **same host** and the host must
> have a **delete-capable** credential locally → a compromised host *can* then run
> prune and delete offsite. In that case the append-only key is **not** the real
> ransomware protection; **provider snapshots** (Hetzner BTRFS / rsync.net ZFS)
> become it. It is an acceptable homelab default, but it must be stated clearly in
> the UI.
>
> **Hardened mode (optional):** the host gets *only* the append key; the janitor is
> triggered from another trust domain (a separate machine, cron on the SFTP box, or
> an offline key). Then append-only is the real protection. Built as a mode, not as
> a mandate.

## 8. Migration / coexistence

Do not tear down the tar track before the restic track is proven in production.

1. **Phase 0 (infra):** install restic (host, `apt install restic`), add the
   `restic` config keys (repo URL, cache-repo path, `RESTIC_PASSWORD` source in
   your password manager + a 0600 file). `restic init` on both the cache and offsite repos.
2. **Phase 1 (parallel track):** a new `lib/restic.sh` behind a config flag
   `ENGINE=restic|tar`. Run the restic track **alongside** the tar track for a
   subset of guests; compare size/time/restore.
3. **Phase 2 (verify):** test-restore from restic-offsite boots → green. Run
   `check --read-data` on a schedule.
4. **Phase 3 (switch):** flip the default to `ENGINE=restic`; keep the tar track
   readable for old archives until retention works through them. Rewrite the three
   UI panels (§6).
5. **Phase 4 (clean up):** remove `upload.sh`/sha256/zstd-verify/`prune.sh`-GFS once
   no tar archives remain offsite.

## 9. Consequences

**Positive:** dedup/incremental (lower RPO floor, less offsite), client-side
encryption + integrity built in, fewer custom failure sources (more code deleted
than written), cross-guest dedup, append-only fit, `pct restore` untouched, the UI
read panels improve.

**Negative / price:** a new dependency (restic on the host); `VZDUMP_COMPRESS=zstd`
→ `--compress 0` (restic compresses) = more cache churn transiently; `copy` needs
**two** password envs (`RESTIC_PASSWORD` + `RESTIC_FROM_PASSWORD`); the repo
password becomes the new DR key (your password manager + `export-key` repointed); no
file-level browsing in Path A (the snapshot is a tar blob).

**Risks:** a large/slow repo → `restic stats`/`check` cost (mitigated: cache stats
via the existing `_cached`; `check --read-data` as a background task). If the
janitor side is not built, append-only is only partial (the same risk as today with
unprepared Storage Box snapshots).

## 10. Open questions / follow-up

- ~~The janitor domain~~ **Decided: local systemd timer/cron script (default)**, hardened external mode optional (see §7). Open: the exact form of the hardened mode's trigger.
- ~~native `sftp:` vs `rclone:` backend~~ **Decided: native sftp** (see §2, Backend).
- ~~local cache vs offsite-only~~ **Decided: both, selectable** via `LOCAL_REPO`/`OFFSITE_ENABLED` (see §2, Modes).
- VM support (`qm`) in the same engine — Path A works for `vzdump-qemu` too (different restore).
- Key rotation for the repo password (split knowledge?).
- Path B as a later file-level optimization — a separate ADR if/when it becomes relevant.
