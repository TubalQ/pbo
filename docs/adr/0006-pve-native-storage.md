# ADR 0006, pbo as a native Proxmox VE backup provider

- **Status:** Accepted 2026-11-23, with the [amendments at acceptance](#amendments-at-acceptance-2026-11-23) at the end of this ADR; where they conflict with the text above them, the amendments win. Proposed 2026-11-22. Built in 0.5 (pre-release 0.5.0-rc1); first released in 0.6.0.
- **See also:** [ADR 0007](0007-install-modes.md), install modes and guest ownership.
- **Decision (short):** pbo becomes a **native PVE storage type `pbo`** that does **not** set the Backup Provider feature. PVE then lists and restores pbo's existing vzdump `.tar`/`.vma` snapshots through its ordinary file-archive path. Later the same storage becomes a Datacenter -> Backup target: it writes to a spool and a hook hands each archive to `pbo ingest`. A real Backup Provider (`PVE::BackupProvider::Plugin::Base`) is deferred. It gets built only if the first two phases leave a concrete gap.
- **Supersedes (partly):** ADR 0005's rejection of "Perl on PVE's libraries" and "a plugin inside the PVE GUI" (docs/adr/0005-web-ui.md:32-34). This ADR covers one narrow storage-plugin adapter only. It is a supported public plugin API (storage APIVER), not a patch to pve-manager.

## Context

The goal is for pbo to feel like PBS inside PVE:
- pick it under Datacenter -> Backup,
- see its backups on a storage,
- restore from the GUI.

PVE 9.x ships a Backup Provider API (`/usr/share/perl5/PVE/BackupProvider/Plugin/Base.pm`, in libpve-storage-perl). The spike read that API and every call site in vzdump, qemu-server, pve-container and pve-manager in the PVE 9.2 source (pve-manager 9.2.x, libpve-storage-perl 9.1.x). It also read pbo 0.4.

What pbo does today:
- It runs `vzdump --compress 0 --dumpdir $CACHE_DIR/<vmid>`, then `restic backup` of that directory into a cache repo, tagged vmid/ts/type/keep, and then `restic copy` to offsite (lib/restic.sh:165-237, 185-211).
- So pbo already stores **real, uncompressed vzdump archives** inside restic (ADR 0001 Path A).
- Retention, the janitor and append-only offsite (ADR 0004), isolated restores (lib/restic.sh:356-389), restore tests and pbo-web all depend on that format.
- The design must cover privileged and unprivileged containers, with and without fuse=1. The VM paths were checked against the source only, not exercised.

## What the API actually provides

These are verified facts from the PVE 9.2 source (pve-manager 9.2.x, libpve-storage-perl 9.1.x). Line numbers refer to that source and will shift on upgrade.

**Shape of a provider**
- A provider is two Perl modules:
  - a storage plugin that sets `plugindata()->{features}->{'backup-provider'}` and implements `new_backup_provider($class,$scfg,$storeid,$log_function)` (Base.pm:16-20; Storage/Plugin.pm:342-350, 2821-2834; Storage.pm:358-364, 2359-2365);
  - a provider class derived from Base.pm.
- Third-party plugins load from `/usr/share/perl5/PVE/Storage/Custom/*.pm`. They must subclass `PVE::Storage::Plugin`, and `api()` must return a value in 9..17 (Storage.pm:46, 50, 131-176). That directory does not exist on a stock PVE host.
- The provider API has **no version of its own**. Its semantics changed in a minor release: 9.1.17 fixed an argument passed to `archive_get_guest_config` (changelog). Upstream HEAD already documents guest-identity keys that PVE 9.2 (pve-manager 9.2.x, libpve-storage-perl 9.1.x) does not send yet, because they need qemu-server >= 9.2.21 and pve-container >= 6.1.25.

**What a provider receives and returns**
- It **never receives a vzdump archive** (Base.pm:29-33, 92-118).
- CTs come only as a `directory` (VZDump/LXC.pm:415-430). `backup_container` runs in a forked user-namespace child as the CT's mapped root, and any change it makes to `$self` is lost (VZDump/LXC.pm:433-444; LXC/Namespaces.pm:41-68; Base.pm:693-696).
- VMs come over `nbd` or `file-handle`. Fleecing is mandatory, and the job dies with "cannot setup backup access without fleecing" (VZDump/QemuServer.pm:1568-1571). That rules out VM templates (:679). `file-handle` also needs `/usr/bin/nbdfuse` (:1582-1586), which is not installed by default.
- Provider restore of a VM supports only `qemu-img`, and PVE reads the source as raw (QemuServer.pm:7147-7150, 7185). PVE runs `file_size_info` on the path, so it must be a path that can be stat()ed (:7192). Live restore is refused (:7112).
- Provider restore of a CT supports `tar` (a regular file, restored as untrusted) or `directory` (LXC/Create.pm:229-283).
- **Privileged CTs are refused** on the provider path, in three places (API2/LXC.pm:112-121, 538-539; LXC/Create.pm:171-172, 232-233).
- The provider log function writes to the task log only. It does not reach the per-guest log or the notification body (VZDump.pm:215).

**The ordinary file path, used when a custom storage does *not* set the feature.** This is the key finding.
- **LXC restore.** `restore_archive` skips the PBS and provider branches. It calls `abs_filesystem_path` and then `restore_tar_archive` without the untrusted flag (LXC/Create.pm:24-51, :49-50). `assert_not_restore_from_external` returns early (API2/LXC.pm:118). So **privileged CTs restore as privileged**. Sys.Modify on `/` is needed only when no CT with that vmid exists, or the existing one is unprivileged (API2/LXC.pm:542-547).
- **VM restore.** `classify_restore_archive` returns type `file` (API2/Qemu.pm:1248-1281). The archive then goes through `restore_file_archive` and `archive_info` to `restore_vma_archive` (QemuServer.pm:6451-6467, 7490). So **`.vma` restores work**.
- **Show Configuration.** `extract_vzdump_config` reads the config out of the archive file itself (Storage.pm:2042-2078).
  - For a tar it runs `tar tf`, stops at the first matching config member, then runs `tar -xpOf --occurrence=1` (Storage.pm:1962-1994).
  - For an uncompressed vma it runs `vma config <file>` (Storage.pm ~2034).
- **Conditions the plugin must meet:**
  - `abs_filesystem_path` = `activate_volumes` (which calls `activate_storage` and then `activate_volume`), then `path()`, then `-f` (Storage.pm:848-866, 1498-1520).
  - The basename must match `vzdump-(lxc|openvz|qemu)-...<ext>`, or `archive_info` dies (Storage.pm:185, 1904-1932).
  - LXC paths must end in `.tar[.<comp>]` (LXC/Create.pm:86-103).
  - pbo's archive names already satisfy all of this.

**Using the storage as a backup target**
- If the storage is neither a provider nor PBS, vzdump calls `get_backup_dir` and then the plugin's `get_subdir`, and writes ordinary vzdump files to `<path>/dump` (VZDump.pm:195-223; Storage.pm:641-648; Plugin.pm:1037-1049).
- The storage must have content `backup` (VZDump.pm:202-203).
- If `get_subdir` dies, the job fails at init and a failure notification is sent (VZDump.pm:664-698).

**Hooks and modes**
- The hook script gets `phase mode vmid` and `STOREID`/`TARGET`. `TARGET` is already set at `backup-start`, extension included (VZDump.pm:787-815, 980-994).
- A non-zero exit fails that guest. A refusal at `backup-start` happens before the guest is stopped (VZDump.pm:1088-1100).
- At `backup-end` the archive has already been renamed into place (VZDump.pm:1186, 1261). A failed hook marks the guest failed but leaves the archive where it is.
- A **job-level `script` replaces the `/etc/vzdump.conf` one**; the two are not chained (VZDump.pm:587-600). Only root@pam may set `script` (API2/VZDump.pm:45).
- Mode is one per job, seeded per task (VZDump.pm:1399-1412). A guest that is not running is backed up in stop mode (:1054). Only LXC falls back from snapshot to suspend (VZDump/LXC.pm:180-182).

**Retention and attributes**
- vzdump prunes only when `prune-backups` is not keep-all. The default keep-all sets remove=0 (VZDump.pm:676, 686-689, 1223-1249; VZDump/Common.pm:343-357).
- The API/GUI prune endpoint calls the plugin's `prune_backups` whatever vzdump is set to (API2/Storage/PruneBackups.pm:194-205; Storage.pm:2081-2097).
- The base `prune_backups` would `archive_remove` vzdump-named files (Plugin.pm:2270-2335; Storage.pm:1935-1958).
- The base `free_image` unlinks the file (Plugin.pm:1304-1330).
- The base `update_volume_attribute` always dies (Plugin.pm:1480-1515).

**GUI**
- The Backups tab appears for any storage whose content includes `backup` (pvemanagerlib.js:72452-72472).
- Restore is enabled for any selected row. The VM/CT type comes from `subtype` or a `:backup/vzdump-(qemu|lxc)-` volid; if neither matches, the button silently does nothing (2494-2512, 71978-72006).
- "Prune group" needs a `vzdump-` name or a pbs format (71925-71950).
- File Restore, the Encrypted/Verify columns, Live restore and forced zstd are tied to the literal type `'pbs'` (71976, 72008-72030, 72102-72125, 23547-23554, 31305-31316).
- The job storage selector filters only on content, disable and nodes (9641-9697, 31528-31537).
- Add/Edit dialogs for custom plugins are generated from `GET /plugins/storage/plugin`. That needs storage 9.1.17 plus pve-manager 9.2.29 (36589-36591, 36659-36665). The retention panel appears only if `content.supported` includes backup **and** the schema contains `prune-backups`.

**Daemon cost**
- pvestatd calls `storage_info`, which calls `activate_storage` and then `status()` on every storage, every cycle (Service/pvestatd.pm:726; Storage.pm:1619, 1625).
- Both must be cheap and must never touch the network or FUSE.

**Failure mode**
- A plugin that fails to load is left out on its own (Storage.pm:90-128, from 9.1.18).
- But storage.cfg sections of an unknown type are skipped on parse (Storage/Plugin.pm:623; SectionConfig.pm:1504-1510). The next API write of storage.cfg drops them (API2/Storage/Config.pm:278, 307).

## Options considered

Three designs were written and scored by three independent judges. Each judge scored feasibility, native GUI feel, keeping pbo's guarantees, low risk and low effort, 10 points each, 50 total.

| Design | Judge 1 | Judge 2 | Judge 3 | Sum | Fatal flaws named |
|---|---|---|---|---|---|
| **Catalogue first** (storage plugin without the provider feature; PVE jobs plus hook ingest later; provider last) | 37 | 40 | 38 | **115** | none |
| **Thin shim** (provider; CT `directory` tarred to a vzdump-identical .tar; bash ingest) | 33 | 35 | 35 | 103 | none |
| **Full provider** (provider; restic runs in the CT userns; new file-level format) | 25 | 27 | 26 | 78 | Judge 2: repo password exposed to uid 100000; GUI delete forgets non-append-only offsite. Judge 3: unverified credential path (rest-server on a unix socket) |

- **Full provider.** It feels the most like PBS. But:
  - It forces ADR 0001 Path B: two formats per guest and a one-time full re-upload to the offsite repo.
  - It puts a restic password into a process running as the CT's mapped root.
  - It depends on several unverified building blocks.
  - It can never restore privileged CTs or `.vma` natively.
  - Estimated effort is 4-6 weeks.
- **Thin shim.**
  - Strengths: it keeps Path A, and no secrets or restic run inside the userns.
  - Weakness: every restore takes the provider path, so privileged CTs and all VMs are refused.
  - Restores always stage the full tar.
  - It depends on the unversioned Base.pm.
  - It needs a lock-fd hand-off between Perl and bash.
- **Catalogue first.**
  - Strengths: it keeps Path A and only uses long-stable plugin methods (the PBSPlugin set). It is the only design that restores privileged CTs and `.vma` from the GUI. Nothing in PVE can delete.
  - Weakness, as all three judges noted: as written, the backup target was a separate dir storage (`pbo-spool`), so it was not "pick pbo like PBS".

## Decision

Build **catalogue first**, with the judges' grafts. The main graft is that the **`pbo` storage itself carries the spool `path`**, so `pbo` is the Datacenter -> Backup target. There is no separate spool storage.

**One Debian package** `pbo-pve-storage` (Architecture: all, AGPL-3.0, the same licence as pbo, LICENSE:1-2):
- `/usr/share/perl5/PVE/Storage/Custom/PboPlugin.pm`
- `debian/triggers: activate-noawait pve-api-updates`
- Depends: `pbo (= version)`, `libpve-storage-perl (>= 9.1.18)` (9.1.17 at first, raised by amendment 3), `pve-manager (>= 9.2.29)`
- It is a separate package so a janitor host never gets Perl.

**Plugin invariants**, carried over from all three designs:
- `list_volumes`, `status`, `activate_storage` and `parse_volname` never fork, never touch the network and never touch FUSE.
  - They read a pbo-written index.
  - `list_volumes` dies with "run pbo catalog refresh" when the index is missing or unreadable. It never returns an empty list, following pbo's rule that an unreadable repo is an error.
- Volname = the real archive basename, `backup/vzdump-<lxc|qemu>-<vmid>-<YYYY_MM_DD-HH_MM_SS>.<tar|vma>`.
  - `parse_volname` returns vtype `backup` with the owner vmid, so the non-admin ACL path works (Storage.pm:684-711).
  - `list_volumes` also sets `subtype`.
- Perl never runs restic for writes and never deletes:
  - `free_image` dies.
  - `prune_backups` with dryrun=1 returns pbo's real verdicts (`LIST_WITH_REASONS=1 pbo --json list`); dryrun=0 dies with "retention is owned by pbo".
  - `update_volume_attribute` is overridden with explicit returns.
  - `get_volume_attribute('protected')` reports pbo's keep state.
- No `prune-backups` in the plugin's options, so no retention panel and vzdump's keep-all default applies.
- `activate_storage` warns in the task log when libpve-storage-perl, pve-manager or qemu-server are newer than the tested set recorded in the package.

**Phase 0: ADR and spikes (no change on a production host)**
- Accept this ADR.
- Run spikes A-C from the prototype plan against a test repo or test node.
- Exit criteria:
  - Measured numbers exist for (a) `restic mount` layout and read speed for one CT `.tar`, cache and offsite, and (b) the time for `extract_vzdump_config` through FUSE versus `restic dump` staging.
  - It is known whether `restic mount` blocks `restic prune` and whether `--no-lock` is honoured.
  - There is a go or no-go decision for Phase 1 on a test node.

**Phase 1: read-only catalogue**
- What it does:
  - `pbo catalog refresh --json` writes `/var/lib/pbo/catalog/index.json` from `list --json` (lib/restic.sh:242-298). Each entry carries volname, snapshot ids per tier, vmid, type, ts, size, keep and "offsite only".
  - The index is refreshed after backup, prune, copy and janitor sync, and by a 15-minute timer, because the janitor prunes offsite behind the host's back.
  - One storage `pbo` shows both tiers merged.
- Restore and Show Configuration:
  - `activate_volume` resolves volname -> (vmid, ts). For the cache repo it ensures an on-demand `restic mount`, and `path()` returns the archive file inside it.
  - For offsite-only entries, and as the general fallback, `activate_volume` stages the single archive with `restic dump` into `$CACHE_DIR/staging/` (sized for the largest archive), cleaned up by a TTL timer.
  - pbo stops the mount before prune.
- In this phase the storage has no `path`, so the plugin's `get_subdir` dies and any job targeting it fails at init with a clear message.
- Exit criteria:
  - 14 days with no pvestatd or pveproxy stalls.
  - A GUI restore to a new vmid of one unprivileged CT and of one privileged CT matches a `pbo restore` of the same snapshot (file list with owners and modes, plus checksums of key files).
  - At least one restore from an offsite-only entry works.
  - Remove, Prune (real run) and Change Protection refuse cleanly.
  - The `pbo doctor --pve-plugin` smoke test passes after at least one PVE package upgrade.

**Phase 2: `pbo` as the backup target**
- Setup:
  - The storage gains a `path` = `$CACHE_DIR/spool`, so vzdump writes plain archives to `<path>/dump`.
  - Recommended jobs: compression none. One snapshot-mode job, and one stop-mode job for fuse and pbo-stop guests.
- The global hook `/usr/local/lib/pbo/vzdump-hook`, active only when `STOREID` is a pbo storage:
  - At `backup-start` it exits 1 if pbo policy says stop and the mode is not stop (fuse=1, `VZDUMP_STOP_VMIDS`, pbo-stop; lib/backup.sh:46-62).
  - It also exits 1 if `TARGET` is compressed, because restic dedup needs uncompressed archives.
  - At `backup-end` it runs `pbo ingest --vmid V --archive $TARGET --json`.
- What `pbo ingest` does:
  - It reuses the upload half of `rdo_backup` (lib/restic.sh:196-227): restic backup to cache, then `restic copy` to offsite, **synchronously**. It deletes the spool file and refreshes the index.
  - pbo's stderr streams into the PVE task log.
  - It exits non-zero on any failure, so a PVE job is never green while offsite failed.
- Locking:
  - Ingest takes only pbo's per-vmid lock, which is already non-blocking (lib/lock.sh:88-89), plus restic `--retry-lock`.
  - It never waits on `pbo.global`. The pbo timer holds that lock while waiting for `/var/run/vzdump.lock` (pbo:169-170), and waiting on it from inside vzdump would deadlock.
- `list_volumes` merges spool files that have not been ingested yet, shown with an "not ingested" note.
- `pbo sync` retries leftovers.
- `pbo doctor` reads `pvesh get /cluster/backup` and warns about:
  - a fuse or pbo-stop guest in a non-stop pbo job,
  - a pbo-skip guest that is selected,
  - a job-level `script` (which silently disables the hook),
  - `prune-backups` or `protected` set on a pbo job,
  - compression that is not none,
  - a guest covered both by a PVE job and by the pbo timer.
- Exit criteria:
  - 30 nightly runs in which every PVE job result matches pbo's repo state.
  - A blocked-sftp test once gives a failed guest, a notification, and recovery through `pbo sync`.
  - The doctor drift check is clean, and spool space was never exceeded.
  - Only then is the pbo timer switched off for the covered guests. It keeps running prune, verify, test-restore and host backup.

**Phase 3: real Backup Provider (decision point only, do not build now)**
- Start only if Phases 1-2 leave a concrete gap: no spool space, CT file-level dedup, or a need for provider-based VM backups.
- Scope: unprivileged CTs only, on a separate storage id, after re-reading Base.pm at the then-installed version.
- Keep secrets root-only: use the thin-shim FD-passing tar pattern or credential FDs opened in `backup_container_prepare`. Never put `RESTIC_PASSWORD` in the userns child's environment, and never let `free_image` forget offsite.
- Exit criterion for opening the phase: a written gap analysis and a separate ADR.

## Consequences

**pbo keeps**
- the restic engine and the DR key;
- the two tiers and the cache-to-offsite copy;
- Path A format, so there is no migration and no re-upload;
- pbo-keep-* tags, GFS, the KEEP_OVERRIDE_MIN_LAST floor;
- the janitor and the append-only model;
- rotating verify, `test-restore` with `restore-tests.jsonl`, doctor, metrics, host backup;
- the JSON contract and the job model.

**Append-only and janitor: unchanged.**
- Nothing in PVE can delete: `free_image`, `prune_backups` (real run) and protect all refuse.
- `restic mount` and `restic dump` are read-only.
- The host gains no new delete path, so the threat model in ADR 0004 is unchanged.
- Whether a `restic mount` lock is created and released cleanly on an `--append-only` rest-server is unverified (spike C).

**Isolated restores: not covered by GUI restores.**
- A PVE GUI restore has no hook for link_down, onboot 0 or host-binding stripping (lib/restic.sh:356-389).
- From a guest's Backup tab it overwrites in place (force=1).
- Mitigation: restrict the `pbo` storage ACL to admins, document it, and keep pbo-web as the default path for isolated and test restores. ADR 0005's rule that web restores are always isolated stays true for pbo-web.
- A doctor check for restored copies that carry a source guest's MAC is a possible later addition (unverified that it can be done reliably).

**Policy tags**
- For PVE-job guests, per-guest mode becomes one job per mode plus the hook guard.
- pbo-skip becomes a doctor warning, because a PVE job's explicit selection wins.
- `BACKUP_MODE=batch` does not apply to PVE jobs.
- pbo-keep-* is unchanged: ingest still reads the tags.

**Restore tests: unchanged.** PVE-job snapshots look exactly like timer snapshots, so `test-restore` and its evidence cover them.

**pbo-web stays** for isolated restore, test-restore evidence, verify, janitor and prune view, doctor and job history. It can link to the PVE storage view.

**New code**
- `pve-plugin/` (Perl plus debian/), `lib/catalog.sh`, the `pbo catalog` and `pbo ingest` subcommands, the hook, and doctor checks.
- Rough size: about 500 lines of Perl. Effort is roughly 1.5-2 weeks for Phase 1 and about 1 week for Phase 2 (estimates from the design, unmeasured).

**Lost, as in every design**
- File Restore, Live restore and the Encrypted/Verify columns (tied to type `'pbs'`).
- Notes/protected editing from the GUI (refused or read-only).
- Provider log lines reaching the notification body (not relevant in Phases 1-2).

## Risks and open questions

**Risks**
- **FUSE hangs.** A stalled restic mount can pin a pvedaemon or restore worker in D-state. Mitigations: never touch the mount from `status`, `list_volumes` or `activate_storage` (pvestatd calls these every cycle, Storage.pm:1619, 1625); mount only the local cache repo; stage offsite entries with `restic dump`.
- **Show Configuration cost without FUSE.** `extract_vzdump_config` reads the archive file, so with staging alone, opening the restore dialog stages the whole archive inside a synchronous API call. How the API timeout behaves under that is unverified. This is why FUSE on the cache repo is the default.
- **Mount vs prune locks.** `restic mount` probably holds a non-exclusive lock that blocks pbo's exclusive prune (unverified). restic 0.18 lists `--no-lock` as a global flag, but whether `mount` honours it is unverified. pbo stops the mount before prune either way.
- **storage.cfg loss when the plugin fails to load.** The `pbo` section is skipped on parse and dropped by the next API write of storage.cfg. Keep the storage.cfg entry in the host's recipe (version control), and don't edit storage via the API while the plugin is broken.
- **The hook is a single point.** A job-level `script` replaces it silently. Then ingest never runs, archives pile up in the spool, and fuse guests lose their stop guard. Doctor must check.
- **Upload inside the vzdump lock.** Ingest runs while vzdump holds the node lock, so a slow sftp upload delays the next guest and any other vzdump on the node.
- **A failure at `backup-end`** leaves a valid spool archive next to a failed task. That is by design, and `pbo sync` recovers it.
- **Stale index** after janitor forgets offsite. The GUI can show an entry that is already gone until the next refresh, and restoring it fails at `activate_volume` with a clear error.
- **Widening privileged restore.** GUI restore of privileged CTs is possible for anyone with Sys.Modify. Restrict the storage ACL to admins.
- **API drift and age resets.** APIAGE was reset in 7.0. Every libpve-storage-perl, pve-manager or qemu-server upgrade needs the smoke test (list, extractconfig, restore to a new vmid, checksum compare, destroy).

**Open questions**
1. One merged `pbo` storage, or separate `pbo-cache`/`pbo-offsite` ids? This ADR proposes merged with cache-first reads. `pbo fetch` currently reads offsite when offsite is enabled, so it needs a prefer-cache switch.
2. Is the `restic mount` layout `ids/<id>/<path>` stable enough to build `path()` on? Answered by spike A: yes, `ids/<short id>/<absolute path>` on restic 0.18.0 (amendment 13).
3. Can the plugin reuse the existing `path` property in `options()` without redeclaring it, and without isolate-properties? Unverified (it is the usual pattern for path-based plugins). Isolate-properties would need api 17 and its own property names.
4. Where do GUI notes go: a local attribute store only, or into the snapshot at ingest?
5. Privileged CTs stay privileged (now GUI-restorable). Is that acceptable, or should they be converted? Answered: they may stay privileged (amendment 22).
6. Does the PVE restore path itself restrict host bind mounts on restore of a CT that has a host-path mp? Unverified.

## Prototype plan

Default rule: everything below runs on a **disposable PVE 9.2 test node**, nested or on spare hardware, with the same package versions. Steps marked **[ADMIN OK]** change cluster or host configuration or production repos. They need the host admin's explicit approval, and on a production host only after the test node passes.

1. This ADR is committed to the pbo repository as `docs/adr/0006-pve-native-storage.md` (repo change only).
2. **Spike A, test repo.** Make a copy of a small CT's snapshot into a scratch restic repo. Then:
   - `restic mount` it and record the path layout;
   - time `tar tf | head` up to `./etc/vzdump/pct.conf`, and a full sequential read;
   - run `restic prune` while it is mounted, with and without `--no-lock`.

   **[ADMIN OK]** if this runs against a production cache repo, because `restic mount` writes a lock file into the repo.
3. **Spike B.** Do the same against a test sftp repo and a test append-only rest-server. Record lock create and release, and throughput. Decide whether offsite entries use FUSE or `restic dump` staging.
4. **Spike C.** Time `restic dump <snap> <file>` staging of one CT archive, cache and offsite, to size the staging fallback and the cost of Show Configuration.
5. Implement `pbo catalog refresh --json` and test it with pbo's tests against a throwaway repo. This is a repo change only.
6. Write `PboPlugin.pm` and a standalone Perl test that loads it next to `PVE::Storage::Plugin` without installing it. Assert:
   - `parse_volname`, `list_volumes` and `path` work against the index;
   - `get_subdir` dies while there is no path;
   - `free_image` and `prune_backups(dryrun=0)` die with the "managed by pbo" text;
   - `list_volumes` dies when the index is missing.
7. On the test node:
   - install the package. This writes `/usr/share/perl5/PVE/Storage/Custom/` and the trigger restarts pvedaemon, pveproxy and pvestatd;
   - `pvesm add pbo pbo-test --content backup --nodes <node>`, which writes `/etc/pve/storage.cfg`;
   - check that "pbo (restic)" appears in Storage -> Add, that the Backups tab shows date, format and size, and that Show Configuration and Restore work;
   - restore an unprivileged CT and a privileged CT to new vmids (this writes `/etc/pve/lxc/<id>.conf`), compare against `pbo restore`, then destroy both.

   **[ADMIN OK]** for doing any of this on a production host: package install, the storage.cfg entry, and the test guests. Pin `nodes=<node>`.
8. Run 14 days on the test node, or on a production host after OK, and check the Phase 1 exit criteria. Include one PVE package upgrade, then run `pbo doctor --pve-plugin`.
9. **Phase 2 on the test node:**
   - give the storage `path=<spool>`, which writes storage.cfg;
   - add the hook as `script:` in `/etc/vzdump.conf`, which is host config;
   - create two jobs, snapshot and stop, which writes `/etc/pve/jobs.cfg`;
   - run them manually and check: the task log shows the ingest; both repos hold the snapshot with tags vmid/ts/type/keep; the spool is empty; the index lists it;
   - put a fuse CT in the snapshot job and confirm the hook refuses it;
   - set compression to zstd and confirm the hook refuses it;
   - block sftp and confirm the guest is marked failed and `pbo sync` recovers;
   - start `pbo run-schedule` while a PVE job runs and confirm ingest fails fast on the vmid lock instead of deadlocking.

   **[ADMIN OK]** for the same steps on a production host (storage.cfg path, `/etc/vzdump.conf`, jobs.cfg). Start with one low-risk guest for a week next to the pbo timer, and put fuse or `pbo-stop` guests in the stop-mode job.
10. Record the recipe (storage.cfg entry, jobs.cfg entries, vzdump.conf line, package version) in the host's configuration repository.

## Appendix: corrections from the verification pass

The spike had independent reviewers try to refute each load-bearing claim against
the PVE 9.2 source. What they refuted or narrowed, and how this ADR accounts for it:

1. **"The PVE web UI has no plugin-type gating; Restore is enabled when subtype or a vzdump volid matches."** Refuted.
   - File Restore, the Encrypted/Verify columns, Live restore and forced zstd are gated on the literal type `'pbs'` (pvemanagerlib.js:71976, 72008-72030, 72102-72125, 23547-23554, 31305-31316).
   - Restore is enabled for *any* selected row. subtype or volid only picks the VM or CT type, and with neither the button silently does nothing (2494-2512, 71978-72006).
   - "Prune group" needs a `vzdump-` name or a pbs format; subtype alone is not enough (71925-71950).
   - The Backups tab also needs a Datastore.* privilege (72452-72472).
   - **ADR:** it lists these features as lost under every option. It uses real vzdump basenames *and* sets subtype. It does not claim Prune group comes from subtype.
2. **"Mode is job-wide; neither a hook nor a provider can change one guest's mode."** Partly refuted.
   - The suspend fallback exists only for LXC (VZDump/LXC.pm:180-182).
   - Mode is decided from a live `vm_status` check right before each guest (VZDump.pm:1043, 1054). A hook that stops a guest earlier makes it back up in stop mode, and PVE will not restart it (:1089-1101, 1285-1297). That is possible but unsupported and racy.
   - **ADR:** it keeps "one PVE job per mode" as the supported design and does not rely on the hook-stop trick. The hook only *refuses* at `backup-start`, before the guest is stopped (VZDump.pm:1088-1100).
3. **"vzdump prunes only when not keep-all; base update_volume_attribute dies after updating notes; overrides needed to keep retention with pbo."** Partly refuted.
   - The API/GUI prune endpoint and `pvesm prune-backups` call the plugin's `prune_backups` whatever vzdump is set to (PruneBackups.pm:194-205; Storage.pm:2081-2097).
   - The base `prune_backups` classifies names through `archive_info`, honours protected, and removes through `archive_remove` (Plugin.pm:2270-2335; Storage.pm:1935-1958).
   - The base `free_image` refuses protected volumes and otherwise unlinks (Plugin.pm:1304-1330).
   - The base `update_volume_notes` always dies, so the base `update_volume_attribute` never writes notes and always dies (Plugin.pm:1480-1515). It is not a deletion vector.
   - **ADR:** it overrides `prune_backups` and `free_image` *because of* the API and GUI paths, not only vzdump. Attribute overrides are a feature choice. If protected is implemented it reports pbo's keep state, which the base paths honour.
4. **LXC non-provider restore** (not refuted, narrowed).
   - The range is Create.pm:24-51.
   - `path()` must return a real regular file (Storage.pm:848-866) ending in `.tar[.<comp>]` (Create.pm:86-103), on an enabled, non-pbs storage.
   - **ADR:** these are listed as plugin conditions. That is the reason for FUSE or staging in `activate_volume`.
5. **VM non-provider restore** (narrowed).
   - The range is Qemu.pm:1248-1281.
   - The `file` type goes through `restore_file_archive` and `archive_info`, so the basename must match `vzdump-qemu-*`. Live restore is refused on this path too (Qemu.pm:1555-1557).
   - On the provider path a provider *could* unpack VMA to a raw file itself (Base.pm:104-108, 969-982). That is practicality unverified, not impossible.
   - **ADR:** it requires vzdump-style basenames, does not offer live restore, and does not claim provider-based `.vma` restore is impossible, only unbuilt.
6. **`abs_filesystem_path` / `extract_vzdump_config`** (narrowed).
   - `activate_volumes` runs `activate_storage` first (Storage.pm:1512).
   - `archive_info` dies unless the basename follows the vzdump scheme (:1904-1932).
   - QEMU archives must be VMA (:2073).
   - **ADR:** it adopts this. In addition, the spike found that `extract_vzdump_config` reads the archive file itself (Storage.pm:1962-1994). The judges' graft "serve Show Configuration from a cached config in the index" therefore **cannot work on the non-provider path**. The ADR drops it and makes FUSE on the cache repo the default, so Show Configuration reads only the first tar member.
7. **Privileged restore on the non-provider path** (narrowed).
   - The early return is at API2/LXC.pm:118 and the call site at 538-539.
   - Sys.Modify is needed only when no CT exists or the existing one is unprivileged (:542-547).
   - It works only when the archive resolves to a local file.
   - **ADR:** it adopts this and adds the admin-only storage ACL as a mitigation.
8. **Plugin loading, generated GUI, failure isolation** (narrowed).
   - The generated dialog needs pve-manager 9.2.29, not only storage 9.1.17.
   - The retention panel needs content `backup` *and* `prune-backups` in the schema.
   - Isolate-properties needs api >= 17.
   - Clash isolation is new in 9.1.18.
   - A plugin that fails to load gets its storage.cfg sections skipped, and they are dropped by the next API write (Plugin.pm:623; SectionConfig.pm:1504-1510; API2/Storage/Config.pm:278, 307).
   - **ADR:** it adds `pve-manager (>= 9.2.29)` to Depends, keeps `prune-backups` out of options, and lists storage.cfg loss as a risk with the "recipe in version control" mitigation.
9. **Custom plugin as a vzdump target** (narrowed).
   - Needs content `backup` and `path` among the plugin's options.
   - `content-dirs` can override `dump`.
   - `activate_storage` failures also fail init (VZDump.pm:664-698).
   - **ADR:** used for the Phase 1 guard (`get_subdir` dies) and the Phase 2 spool path.
10. **Hook script semantics** (narrowed).
    - Job phases get only the phase.
    - The mode is the effective mode, so a guest that is not running gets `stop`.
    - `TARGET` is set in every per-guest phase, extension included.
    - `STOREID` is set only when a storage is given.
    - A failure at `backup-end` leaves the renamed archive in place.
    - A job-level `script` replaces the global one.
    - **ADR:** the hook guard also uses `TARGET`'s extension to refuse compressed archives. Spool leftovers are recovered by `pbo sync`. Doctor warns about job-level `script`.
11. **Conflicts between the documentation and the PVE 9.2 source resolved by the stricter reading.**
    - (a) "the VM `qemu-img-path` may be an NBD URI" (Base.pm text) versus `file_size_info(...,untrusted=1)` stat()ing it (QemuServer.pm:7192). The ADR treats it as "must be a path that can be stat()ed".
    - (b) The upstream examples' `new_backup_provider` has an extra `$bandwidth_limit` argument that does not match the signature in the PVE 9.2 source (Storage.pm:2364). That matters only for Phase 3, which must code against the Base.pm of the PVE version it targets.
    - (c) Upstream guest-identity keys are not in the PVE 9.2 source, so they are not relied on.
12. **Design-level claims dropped.**
    - The full-provider design's GUI delete that forgets offsite snapshots on non-append-only sftp: dropped. Nothing in PVE deletes.
    - Its rest-server-on-unix-socket credential path is unverified: not used.
    - The thin shim's non-blocking flocks on `pbo.global` from Perl are replaced by the simpler rule that ingest takes only the already non-blocking per-vmid lock (lib/lock.sh:88-89) and never `pbo.global`.

## Amendments at acceptance (2026-11-23)

Planning the implementation at acceptance changed some of the text above. These
amendments record the changes. Where they conflict with an earlier section, the
amendment wins. Line numbers refer to the PVE 9.2 source (pve-manager 9.2.x,
libpve-storage-perl 9.1.x, libpve-common-perl 9.2.x).

1. **Integration is optional, chosen per host through install modes.** A host runs
   `standalone` (today's pbo, no plugin), `both` or `integrated`, set by the config
   key `PBO_INTEGRATION`. In `both`, every guest has exactly one owner: an enabled PVE
   job that targets a `pbo` storage, or else the pbo timer. See
   [ADR 0007](0007-install-modes.md). The default stays `standalone`, which behaves
   exactly as before and makes no extra `pvesh` calls.
   - This replaces the Phase 2 exit step "only then is the pbo timer switched off for
     the covered guests". In `both` the timer skips PVE-owned guests by itself.
   - The doctor warning "a guest covered both by a PVE job and by the pbo timer" can
     no longer happen by construction. Its place is taken by "a guest in two pbo jobs".

2. **A step-by-step bring-up is an alternative to the test-node rule.** The
   prototype plan's default rule ("everything runs on a disposable test node first")
   is not mandatory. An operator without a test node may bring the integration up
   on a production host instead, in reversible steps, checking each one before
   starting the next:
   1. Read-only: load the plugin against the host's PVE libraries without
      installing it; run `integrate status` and `catalog refresh` into a scratch
      file.
   2. Upgrade pbo with `--integration standalone`; nothing may change.
   3. Spike A in a scratch repo, fed by `restic dump --no-lock` from the cache
      (the production repo gets no lock): mount layout, time to `pct.conf`, a
      full read, `dump` staging, prune with the mount active.
   4. Plugin and catalogue without a backup target (`integrate enable both
      --catalog-only`); GUI restore of an unprivileged and a privileged CT to new
      vmids, compared with `pbo restore`; an offsite-only restore; Remove, Prune
      and Protection refused; then a soak period.
   5. Spool, hook and one PVE job with one guest; negative tests on a throwaway
      CT; then a soak period.
   6. Widen one step at a time (a snapshot job, a stop job for the fuse and
      `pbo-stop` guests); switch to `integrated` only after a long run of clean
      nightly jobs.

   Each step can be undone before the next one starts. Work that only changes
   the source tree never touches a host.

3. **Depends `libpve-storage-perl (>= 9.1.18)`**, not 9.1.17. 9.1.18 is the first
   version that leaves a custom plugin out on its own when it fails to load
   (`init_plugins`, Storage.pm:90-128). Before that, one broken third-party plugin
   could fail the initialization of every plugin. `pve-manager (>= 9.2.29)` stays.

4. **The version-drift warning moves from `activate_storage` to `activate_volume`.**
   pvestatd calls `activate_storage` on every storage in every cycle
   (Service/pvestatd.pm:726; Storage.pm:1619), so a warning there would flood the
   journal. `activate_volume` runs only through `activate_volumes` for a restore or
   Show Configuration (Storage.pm:1498-1520), so the warning lands in that task's log.

5. **`path` is reused, optional and not fixed** (answers open question 3).
   - The base plugin declares `path` once in its shared properties, as an optional
     `pve-storage-path` string (Storage/Plugin.pm:230-237). In SectionConfig's default
     unified mode a plugin may list any registered property in `options()`
     (SectionConfig.pm:386-394). So `PboPlugin` lists `path => { optional => 1 }`
     without redeclaring it and without isolate-properties.
   - The dir plugin marks it `path => { fixed => 1 }` (Storage/DirPlugin.pm:76).
     Fixed keys are left out of the update schema and refused on change
     (SectionConfig.pm:493-494, 710-715, 1654-1655). pbo does **not** fix it, so
     `pvesm set pbo --path <spool>` turns a catalogue-only storage into a backup
     target, and `--delete path` turns it back.
   - Without a path the base `get_subdir` already dies with "storage definition has
     no path" (Storage/Plugin.pm:1037-1050). The Phase 1 guard needs no override.

6. **`pbo sync` becomes `pbo ingest --pending`** everywhere above (Phase 2, Risks,
   Appendix item 10). There is no separate `sync` subcommand.

7. **PVE-job snapshots lack the vzdump `.log`.** vzdump copies the task log next to
   the archive only after `backup-end`, just before `log-end`
   (`cp $tmplog $logfile`, VZDump.pm:1367-1368; `backup-end` at :1172 and :1261,
   `log-end` at :1372). Ingest runs at `backup-end`, so the snapshot holds the
   archive and pbo's `.conf` sidecar but not the `.log`. pbo's own runs are
   unchanged. `log-end` removes the leftover `.log` from the spool.

8. **The hook wrapper runs no pbo code for other storages or for pbo's own runs.**
   - vzdump sets `STOREID` only when the run has a storage (VZDump.pm:807). pbo's
     own runs use `--dumpdir`, and then vzdump resolves no storage at all
     (`get_storage_param`, VZDump.pm:73-78, applied at :637-639; vzdump.conf's
     `storage:` is merged only when neither `dumpdir` nor `storage` is given,
     :587-598).
   - The wrapper (`lib/vzdump-hook`, plain sh) exits 0 when `STOREID` is unset or
     is not a storage of type `pbo`, before it starts pbo. Only then does it run
     `pbo _vzdump-hook`.

9. **`protected` is reported as 1; notes are accepted and dropped.**
   - `get_volume_attribute('protected')` returns 1 for every pbo volume, not pbo's
     keep state. Nothing in PVE may delete a pbo snapshot, and the base paths honour
     protected (Storage.pm:1938; Plugin.pm:1304-1330). `free_image` and
     `prune_backups` (real run) still die with a "managed by pbo" message.
     Changing protection is refused.
   - `update_volume_attribute('notes', ...)` returns without storing anything. A
     job's `notes-template` would otherwise put "unable to add notes" into every
     task log (VZDump.pm:1203-1213). This answers open question 4: GUI notes are not
     kept.

10. **PVE's "not backed up" view cannot be used for ownership.**
    `GET /cluster/backup-info/not-backed-up` builds its set from every vzdump job in
    `vzdump.cron` and `jobs.cfg` without looking at `enabled` or the job's storage
    (API2/Cluster/BackupInfo.pm:20-32, 105-114). A disabled job, or a job to some
    other storage, would count as coverage. pbo computes ownership itself (ADR 0007).
    The job's `node` restriction *is* honoured there, through
    `get_included_guests` (VZDump.pm:1596).

11. **install.sh hosts get the plugin without the .deb.** A host can run pbo from
    `install.sh` instead of packages. `install.sh --integration both|integrated`
    copies the plugin, hook and units itself, after the same version check the
    package would enforce through Depends (pve-manager >= 9.2.29,
    libpve-storage-perl >= 9.1.18), and load-tests the plugin with
    `perl -MPVE::Storage`, removing it again on failure. Packaged hosts install
    `pbo-pve-storage`. Neither path ever creates the storage, edits storage.cfg or
    edits vzdump.conf; `pbo integrate enable` does that.

12. **Open questions answered at acceptance.**
    - Question 1: one merged storage id `pbo` (cache first, offsite-only entries
      staged).
    - Question 3: see amendment 5.
    - Question 4: see amendment 9.
    - Question 2: answered by spike A (amendment 13).
    - Question 5 is answered by amendment 22; question 6 by amendment 21.

13. **Spike results (spike A, restic 0.18.0).** What restic's FUSE mount and
    `restic dump` do with a CT archive in a pbo repo. `restic dump --no-lock`
    reads a repo without writing a lock into it, so a scratch repo can be filled
    from a cache repo without touching it.
    - **Layout (answers open question 2):** `restic mount` shows `hosts/`, `ids/`,
      `snapshots/` and `tags/`; an archive is at
      `ids/<8-char short id>/<absolute path in the snapshot>`, which is exactly what
      `_catalog_mount_file` builds. Tags show up as `tags/vmid=<vmid>/` and so on.
    - **Mount start:** `ids/` lists the snapshots almost at once.
      `fusermount3 -u` stops the mount and restic removes its lock almost at once.
    - **Time to the config:** reading `.tar.conf` through the mount is almost
      free; `restic dump` of the same small file costs mostly restic start-up.
    - **Full read:** `restic dump` reads faster than the FUSE mount. Both give
      the archive byte for byte (the sha256 of the source).
    - **Offsite (sftp, read-only `--no-lock`):** snapshot lookup, `.tar.conf` and
      the whole archive work the same way, slower than from the cache, and give
      the same bytes.
    - **prune with a locking mount:** `restic forget --prune` fails at once with
      exit 11 ("repository is already locked"). Nothing is removed. This is why
      prune and verify stop `pbo-mount.service` first (amendment 17).
    - **prune with a `--no-lock` mount:** prune succeeds. A reader that already has
      the file open then gets EIO, the pruned snapshot is still listed under
      `ids/`, a new open gets EIO too, and the mount log fills with
      "Load(<data/...>) failed: no such file or directory". `restic check` of the
      repo stays clean: the repo is intact, the mount is not. **The mount must
      keep its lock; never add `--no-lock`.**
    - **New snapshots in a running mount** appear only after a delay, which can
      be longer than `CATALOG_MOUNT_WAIT` (30 s). A just ingested archive can
      therefore miss it, and materialize falls back to `restic dump`, which is
      correct.
    - **`restic dump --no-lock` during a prune** can fail in the same way. It
      writes to `<name>.part.*` and renames only on success, so a failed staging
      leaves no partial archive behind (lib/catalog.sh).
    - **Default:** see amendment 18.

## Amendments from the implementation review (2026-11-23)

A review of the implementation against the PVE 9.2 source found gaps that
the decision text above did not cover. These amendments win over the sections above.

14. **Stop-mode guests are uploaded at `job-end`, not at `backup-end`.** vzdump runs
    `backup-end` inside the guest's task (VZDump.pm:1261) and restarts a guest it
    stopped only afterwards, in the task's cleanup (:1287-1300, `$cleanup->{restart}`
    set at :1100). A synchronous upload at `backup-end` kept a stop-mode CT (fuse,
    `VZDUMP_STOP_VMIDS`, `pbo-stop`) down until the offsite copy was
    done. So in stop mode `backup-end` only checks the archive and records it under
    `STATE_DIR/ingest-deferred`, and `job-end` ingests the recorded archives once every
    guest runs again. `job-end` runs inside the job's eval (:1435-1446): a failed
    upload still fails the job, so "never green while offsite failed" holds, but the
    guest's own row stays "ok" and the `job-end` output goes to the job notification,
    not the task log. Snapshot and suspend mode stay synchronous at `backup-end`;
    the cost there is that the vzdump snapshot of a CT (and `lock: backup`) lives
    until the upload is done.
15. **Synchronous API requests never stage.** `activate_volume` also runs inside
    synchronous requests: `GET /nodes/{node}/vzdump/extractconfig` (Show
    Configuration and the Restore dialog; API2/VZDump.pm:270-307, Storage.pm:2065,
    853) and the QEMU restore before it forks its worker (API2/Qemu.pm:1277, 1478).
    pvedaemon has three workers and pveproxy gives up after 30 s, so a `restic dump`
    there tied up a worker for as long as the copy took. The plugin now tells a
    request (REST environment `priv`/`pub`, not a worker) from a task or a CLI. In a
    request it runs `pbo catalog materialize --background` with a 20 s timeout: a
    staged archive is used at once, otherwise pbo stages it detached and the request
    fails with "retry in a few minutes". A forked task (LXC restore) and the CLI
    (`qmrestore`, `pct restore`) still wait. The default stays `restic dump` until
    spike A; with it, opening the Restore dialog of an archive that is not staged
    starts a background staging.
16. **`catalog release` runs from `pbo-catalog.service`** (every 15 minutes, before
    the refresh; a failure never skips the refresh). It also removes a staged
    archive the index no longer lists, so a pruned snapshot does not survive as a
    decrypted copy in staging.
17. **The mount is never stopped under a reader.** prune, verify and `catalog
    release` check `/proc` for processes with a file or cwd inside
    `PVE_CATALOG_MOUNT_DIR` before they stop `pbo-mount.service`. prune and verify
    wait up to `CATALOG_MOUNT_BUSY_WAIT` seconds (900) and then exit 75; release
    leaves the mount running. In `standalone`, prune and verify do not look at the
    mount at all.

## Amendments from testing

18. **The mount is the default.** `PVE_CATALOG_MOUNT` defaults to
    `true`. The mount answers Show Configuration without copying the archive;
    with `restic dump` the whole archive is copied first, which takes long for a
    large archive and longer from offsite. A restore through the mount is about
    as fast as one with dump: both are bound by writing the CT's files, not by
    reading the archive. The mount holds a shared restic lock on the cache repo
    while it runs: backups and `restic copy` take shared
    locks too and are not affected; prune and verify stop it first (amendment 17);
    `catalog release` stops it when no staged archive points into it. From a
    synchronous request (`--background`, amendment 15) a cache archive is now
    linked through the mount inline, waiting at most `CATALOG_MOUNT_BG_WAIT`
    (10 s) inside the plugin's 20 s. A snapshot that the running mount does not
    list yet (new snapshots show up in it only after a delay) still falls back to the detached
    staging and "retry". Offsite-only archives always use `restic dump`.
19. **Privileged containers.** `pbo restore` and `test-restore` used to turn a
    privileged CT into an unprivileged copy (Proxmox leaves `unprivileged:` out of
    a privileged CT's config). Fixed in 0.5; a GUI
    restore through the plugin was never affected, it reads the archive's own
    config. Privileged CTs are GUI-restorable by root only (doctor warns on a
    storage ACL for anyone else); open question 5 is answered by amendment 22,
    question 6 by amendment 21.
20. **pbo-web is removed (ADR 0008, 2026-11-24).** Where this ADR says "pbo-web
    stays" (Consequences) or names it as the isolated and test restore path, read
    `pbo restore` and `pbo test-restore` (CLI). The Proxmox GUI through this plugin
    is the only graphical interface from 0.5 on.
21. **GUI restore of a CT with a host bind mount (answers open question 6).**
    When root@pam restores such a CT through the plugin to a new vmid, Proxmox
    keeps the bind mount (`mpN: <host path>`) and the raw `lxc.idmap` lines as
    they are, keeps `onboot`, gives a new MAC with "unique", and recreates a
    `backup=0` volume empty. For anyone but root@pam the same restore fails:
    "restoring 'mp1' to bind mount is only possible for root" (API2/LXC.pm,
    storage-only restore). Privileged restores are not blocked as "external": that
    check applies only to storages with the backup-provider feature, which this
    plugin does not set. An **unprivileged** restore through the mount fails without
    allow_other ("tar: -: Cannot open: Permission denied"): Proxmox passes the
    archive's open fd to `lxc-usernsexec tar`, and FUSE refuses the CT's mapped
    root without allow_other. So `pbo-mount.service` mounts with
    `--allow-other`, under the root-only `/run/pbo`.
22. **Privileged CTs may stay privileged (answers open question 5).** They are
    GUI-restorable by root@pam only (a privileged restore needs Sys.Modify on `/`,
    and the storage stays admin-only); `pbo restore` and `test-restore` keep them
    privileged since 0.5. A privileged CT with fuse runs in stop mode, so it
    belongs in the stop-mode job.
