# ADR 0008, remove the web UI (pbo-web)

- **Status:** Accepted 2026-11-24, once the Proxmox integration covered backup
  jobs and GUI restores end to end.
- **Decision:** pbo-web, the web UI from [ADR 0005](0005-web-ui.md), is removed in
  0.5.0: the Go code (`web/`), the `pbo-web` package, its units, its egress rule,
  its CI job and the web design files. The Proxmox GUI (through the integration of
  [ADR 0006](0006-pve-native-storage.md) and [ADR 0007](0007-install-modes.md)) and
  the CLI (`pbo menu`, the commands, `--json`) are the interfaces.
- **Supersedes:** [ADR 0005](0005-web-ui.md).

## Context

ADR 0005 added pbo-web because the terminal was the only interface. Since the
integration (0.5.0) a Proxmox host can show pbo as a storage in its own GUI:
browse every snapshot of both repos, show a guest's configuration, restore,
"Backup now" and backup jobs, with Proxmox's own users, ACLs, two-factor login and
notifications. The per-guest policy was always Proxmox tags, editable in the GUI.

pbo-web cost more than its share: a second login path to Proxmox credentials (it
saw passwords typed at sign-in and held tickets), a root helper with its own
allowlist, port 8008 in the firewall, a Go toolchain, a CI job and
a third package, and a permission model that had to mirror Proxmox's.

## What goes, and what covers it

| pbo-web | After 0.5.0 |
|---|---|
| list guests, snapshots, both tiers | Proxmox GUI, the `pbo` storage; `pbo list`, `pbo guests` |
| restore wizard (always isolated) | Proxmox GUI restore (**not isolated**, admins only); `pbo restore` (isolated) |
| backup now | Proxmox GUI "Backup now" to `pbo`; `pbo backup` |
| policy editor | the `pbo-*` tags in the Proxmox GUI; `pbo policy set` |
| restore-test evidence | `pbo restore-report` |
| jobs with a live log | `pbo job list/log --follow`; Proxmox task log for Proxmox jobs |
| maintenance (verify, prune plan, prune, unlock, run schedule) | `pbo verify`, `pbo --dry-run prune`, `pbo prune`, `pbo unlock`, `pbo run-schedule`, `pbo menu` |
| dashboard / health | `pbo doctor`, `pbo status`, Proxmox notifications, metrics |

What is lost: a browser UI on a host that runs pbo `standalone` (it has the menu
and the CLI), and an isolated restore from a browser. The CLI keeps the options
pbo-web used (`restore --isolate/--restricted`, `job`, the JSON views), since
scripts can use them too.

## Consequences

- `install.sh` removes a pbo-web it installed (services, binary, egress rule, the
  `pbo-web` user, `/etc/pbo/web.env`, `/etc/pbo/web-tls`) and says to close TCP
  8008. The `pbo` package `Breaks: pbo-web`, so apt removes an old pbo-web package.
- No Go in the build; CI checks that no `pbo-web` package is built.
- ADR 0006 named pbo-web as the isolated restore path; that is `pbo restore` now
  (ADR 0006 amendment 20, ADR 0007 amendment).
