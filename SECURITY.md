# Security

## Reporting a vulnerability

Don't open a public issue. Use GitHub's private reporting on
[TubalQ/PBO](https://github.com/TubalQ/PBO/security/advisories/new) (Security →
Report a vulnerability). Say what you found, how to reproduce it, and which version
(`pbo --version`, or the commit). Expect an answer within a week.

Supported: the latest release and `main`. Older releases get fixes only if the fix
is trivial to backport.

## Threat model

pbo runs as root on a Proxmox host, reads every guest's disks through `vzdump`, and
holds the key that decrypts all of it. That makes the host the thing to protect, and
the offsite copy the thing that has to survive when the host doesn't.

### What it holds and where

| Secret | Where | Mode | What it unlocks |
|---|---|---|---|
| Repo password (the DR key) | `RESTIC_PASSWORD_FILE`, default `/etc/pbo/restic-pass` | 0600 root | Decrypts every snapshot in the repo. Lose it and the backups are gone for good. |
| SFTP key | `/root/.ssh/…` (the key in `RESTIC_SFTP_COMMAND`) | 0600 root | Read, write **and delete** on the SFTP target. |
| rest-server HTTP password | `RESTIC_REST_PASSWORD_FILE` | 0600 root | Read and append on an append-only server. No deletes. |
| Pinned host key / server cert | `/etc/pbo/known_hosts`, `RESTIC_CACERT` | 0644 | Not secret. Stops a MITM from posing as the target. |
| ntfy token | `NTFY_CREDS_FILE` | 0600 root | Sending notifications. |
| Janitor copy of the repo password | janitor `/etc/pbo/restic-pass` | 0400 server user | Same as the DR key, plus delete rights on the repo files. |

`/etc/pbo/config` holds no secrets and is refused if it's group- or world-writable,
because root sources it. In a cluster, keep secrets out of `/etc/pve`: pmxcfs
replicates it to every node in cleartext.

`pbo backup-host` deliberately leaves out the DR key and SSH keys. A secret never goes
into the repo it protects.

### Who can do what

| Attacker | Can | Can't | Mitigation |
|---|---|---|---|
| Network on-path | See that you back up, and how much | Read data (restic encrypts client-side); impersonate the target once the host key or cert is pinned | `setup` pins the SFTP host key; `RESTIC_CACERT` pins a rest-server cert |
| Provider / storage operator | Delete, withhold, corrupt | Read data or forge snapshots without the DR key | Encryption; `verify --scheduled` reads every pack over time and fails on corruption; a second target (issue #8) |
| Root on the PVE host, SFTP target | Read everything, **delete every offsite snapshot**, then the guests | Nothing pbo can stop | Provider snapshots (`STORAGE_BOX_SNAPSHOTS_CONFIRMED`), or move to append-only |
| Root on the PVE host, append-only target | Read everything, stop new backups, add junk snapshots | Delete or overwrite existing offsite snapshots, remove keys | rest-server `--append-only`; `doctor` proves the server refuses deletes; the janitor flags a host that stops sending |
| Root on the janitor | Delete everything it serves | Reach the PVE hosts (it has no credentials for them) | Keep it on separate hardware and location, nothing inbound but the rest-server port, no SSH, provider snapshots under it if it's rented |
| Local non-root user on the host | Nothing by default | Read secrets (0600 root); change the config (refused if writable by others) | — |
| Someone who gets the DR key | Decrypt every snapshot they can reach | Delete through an append-only server | Store it offline (password manager + paper/USB); `pbo rotate-key` after a leak |

### Things to know

- **restic says yes when an append-only server says no.** A `forget` against a server
  that refuses deletes prints 403 per snapshot and exits 0. pbo therefore needs
  `OFFSITE_APPEND_ONLY=true` to know, and `doctor` tests that the setting matches the
  server. Without the setting, a host-side prune would look fine and do nothing.
- **Rotating the key doesn't revoke the old one everywhere by itself.** On an
  append-only target the old key stays valid until the janitor removes it, and
  `rotate-key` says so.
- **The janitor never runs as root.** Started as root, pbo re-execs as
  `JANITOR_USER`. Its state and log directories belong to that user, and root writing
  there could be redirected through a symlink; a root prune also leaves repo files the
  server can't read.
- **Restore always goes to a new vmid** and never overwrites a running guest. Every
  restore and test-restore lands in the audit log (`LOG_DIR/audit.log`).
- **A janitor on the same hardware is not offsite.** It protects against a compromised
  host, not against losing the building.

### Out of scope

Compromise of the Proxmox host's own boot chain or hypervisor, guests that are
already compromised when they're backed up (pbo backs up what's there), and
availability of the provider.
