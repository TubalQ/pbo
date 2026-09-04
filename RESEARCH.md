# Prior study — is there anything to build on?

**Short answer: no.** The review below is a negative result. It confirms that a new
tool is the right decision, and maps out what the existing attempts fail at so we
do not repeat it.

Verified against sources, not memory.

---

## 1. Existing projects

### proxmox-vzbackup-rclone (TheRealAlexV)

A hook script that backs up VMs, containers, and PVE configurations to remote
storage using native vzdump plus rclone. Archives are organized in
`YEAR/MONTH/DAY` directories, and there is an accompanying script to fetch old
archives back from the remote so they can be restored as usual.

**Why it is not good enough:** The script **does not prune the remote** — it
explicitly says you have to handle that separately. No verification that what was
uploaded can be read back, no job management, no interface, no status reporting.
It is a working hook script, not a tool.

Retention and verification are exactly the two parts most dangerous to get wrong,
and both are missing. Building on this would mean inheriting a skeleton without the
organs that make the difference.

### proxmox-grapple (lingfish)

A Python replacement for `vzdump-hook-script.pl` with eleven backup phases
(`job-init`, `job-start`, `job-end`, `job-abort`, `backup-start`, `backup-end`,
`backup-abort`, `log-end`, `pre-stop`, `pre-restart`, `post-restart`),
YAML configuration with support for multiple environments, two run modes, and
real-time logging of subprocess output with progressive timestamps — stated to be
suitable for long-running processes like rclone specifically.

**Why it is not good enough:** It is a generic hook runner, not a backup tool. It
runs commands for you at the right time and stops there — no knowledge of archives,
offsite, verification, or restore. Its `extract` function is, moreover, according
to the author an untested proof-of-concept.

**What we take from it as a lesson, not as a dependency:** real-time logging of
subprocess output with progressive timestamps. Without it, a 40-minute rclone
upload looks like a hung process. We implement the same thing ourselves — it is
thirty lines, not a dependency worth inheriting.

### Others reviewed

`DerDanilo/proxmox-stuff` secures host configuration, not guest backups. Various
Borg web interfaces manage Borg repos, not vzdump archives and `pct restore` —
they know nothing about Proxmox.

**No project was found that does vzdump → offsite → fetch back with verification,
retention management, and an interface.** The conclusion is that the tool is built
from scratch. None of the candidates above becomes a dependency.

---

## 2. The big finding: PVE's own GUI already does half the job

A directory storage with `content backup` gives natively in the PVE interface: an
archive list, date, size, restore button, `prune-backups keep-last=N`,
`max-protected-backups`, and `content-dirs` to point the backup directory to a
custom subpath.

That means: **make the local cache a real PVE directory storage**, and you get
listing, dates, sizes, and a restore button for free, in an interface that does not
just resemble PBS but *is* Proxmox.

Our own GUI then only needs to cover what PVE cannot: offsite inventory, push,
fetch, verification status, and configuration.

### `is_mountpoint` is mandatory

Set `is_mountpoint 1` on the storage. Without it, PVE writes backups to the root
filesystem if the mount fails — a documented way to fill the system disk without
warning.

```bash
pvesm add dir lxc-offsite-cache \
  --path /var/cache/lxc-offsite \
  --content backup \
  --is_mountpoint 1 \
  --shared 0
```

### Why we still do NOT rclone-mount offsite as PVE storage

It *works* — there are reports of backup and restore going through the PVE GUI
against an rclone-mounted cloud storage, with `--vfs-cache-mode full`. But the
objections are valid: if the remotely mounted storage becomes unavailable you get
problems both at boot and during scheduled backups, and installing rclone and
mounting cloud on the hypervisor counts as a larger intrusion into the host
environment.

Our design avoids this: **rclone never touches a PVE-mounted filesystem.** Offsite
is reached only via explicit `rclone copy` calls. PVE knows only about the local
cache, which is always present.

---

## 3. GUI technology: what "emulate PBS" actually requires

PBS and PVE both build on ExtJS plus `proxmox-widget-toolkit`, which describes
itself as the base framework with widgets, models, and tools for Proxmox
ExtJS-based web interfaces. It is already on disk under
`/usr/share/javascript/proxmox-widget-toolkit/`, and ExtJS is in the package
`libjs-extjs`.

So we can use exactly the same widgets PBS uses. The look will not be "similar" —
it will be identical.

### The license trap, which is real

`proxmox-widget-toolkit` is **AGPL-3.0+**. ExtJS is harder: Sencha released
version 7.0 as the last GPLv3 edition, and the terms are explicit — you must
release the source freely and license your application under GPLv3, and you cannot
convert to a commercial license later by buying one.

Practical consequence:

| Scenario | Consequence |
|---|---|
| Internal use only, no distribution | No obligations triggered |
| Published on your Gitea, public | Must be AGPL-3.0 licensed, source freely available |
| Commercialized | Not possible without replacing the entire frontend stack |

AGPL's network clause is the sharp one: for a **web interface** it is enough that
someone else uses it over the network for the source-code obligation to activate.

Recommendation: build with the widget toolkit, license the project AGPL-3.0 from
day one. It is the right license for a tool like this anyway, and it removes the
question.

### There is no plugin API for PVE's web interface

You cannot add a tab to the PVE GUI in a supported way. Community projects that
modify the Proxmox interface patch the files and use an apt hook to re-patch
automatically after updates to the widget toolkit, pve-manager, or
proxmox-backup-server.

**Do not do that.** An apt hook that patches the hypervisor's GUI on every update
is exactly the kind of intrusion that makes a production environment unrepairable.
Our GUI runs as a **standalone application on its own port**, which reuses the
widget toolkit but never modifies PVE's own files.

---

## 4. The hook-script mechanics, verified

The phases are `job-start`/`-end`/`-abort` for the whole job, `backup-start`/`-end`/
`-abort` per guest, `pre-stop`/`pre-restart`/`post-restart` for the guest, and
`log-end`. The phase is passed as an **argument** to the script, and environment
variables like `DUMPDIR`, `STOREID`, `TARGET`, and `VMID` are set by vzdump.

Three traps:

**The script is called by every backup job.** You cannot set a hook script for a
single job — you must condition inside the script on VMID, guest type, target
storage, or node.

**Only root@pam may set it.** The parameter cannot be set for unprivileged users
because it allows execution of arbitrary code. Our GUI can therefore never let a
non-root user change the hook-script path.

**`backup-end` does not mean "succeeded".** There is no status variable; you must
treat `backup-abort` as the failure signal and not assume success.

---

## 5. Bind mounts — confirmed and more serious than expected

The `backup` flag applies **only to regular volume mountpoints**. Bind mountpoints
contain arbitrary host paths and are therefore restricted to root, and cannot be
added any other way than manually. After a restore they must be recreated by hand
with `pct set` or in an editor — **it cannot be done via the GUI**.

Moreover: if you set the `backup` flag on a regular mountpoint, everything is
restored into a single directory at restore time, which may need manual correction
afterward.

Consequence for our tool: at backup time, bind mounts should be flagged as a
warning, and the original container configuration should be saved as a separate
sidecar file offsite, so that whoever restores can see exactly which mountpoints
are missing.

---

## 6. Summarized recommendation

| Layer | Decision |
|---|---|
| Codebase | New tool from scratch, no inherited dependencies |
| Backup artifact | Native `vzdump`, `--mode snapshot` |
| Local cache | PVE directory storage, `is_mountpoint 1` → free native GUI |
| Transport | `rclone copy` against Hetzner SFTP, never as a mounted filesystem |
| Own GUI | Standalone, ExtJS + `proxmox-widget-toolkit`, own port |
| Ransomware protection | Storage Box snapshots — **not** Borg append-only |
| License | AGPL-3.0 from the start |
| PVE GUI patching | No |

---

## 7. Append-only on Hetzner does not hold up

This was investigated as an alternative to the full-copy model and rejected.

Hetzner's documentation says Borg can be run in append-only mode that only permits
new archives and denies deletion of old ones — but notes in the same breath that a
restricted client can still perform archive deletions.

Borg's manual confirms why: `--append-only` affects only the repo's low-level
structure, and `delete` and `prune` are still allowed to run.

The real protection is server-side, via `command="borg serve --append-only"` in
`authorized_keys`. But Storage Box offers no real shell — the environment is
described as heavily restricted, and the restrictive SSH commands do not work
there.

**Therefore:** Storage Box's own scheduled snapshots are the only thing that
actually protects against a compromised Proxmox host. It is a requirement in this
design, not a recommendation. Without them, an attacker with host access can delete
the entire offsite copy, and then we have built a copy with extra steps.
