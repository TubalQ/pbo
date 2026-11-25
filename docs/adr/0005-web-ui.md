# ADR 0005, a web UI on top of the CLI

- **Status:** Superseded by [ADR 0008](0008-remove-web-ui.md) on 2026-11-24:
  pbo-web is removed in 0.5.0. Accepted 2026-11-22; shipped in 0.4.0
  and 0.4.1. Kept as history.
- **Decision:** pbo gets a web UI that can do what the terminal does. It is a
  frontend only: every action and every read goes through `pbo --json`, so the CLI
  stays the single code path (locks, preflight, policy, audit). The web service is
  a **Go** binary, listens on **port 8008** on the management address, logs users
  in **against PVE** and authorizes them from the **PVE ACL**. It ships in 0.4.0.
- **Supersedes:** the "no daemon, no web service" positioning in the README, and
  ADR 0003's choice of a terminal-only interface (the menu stays).

## Why now
Day-to-day operation (is everything backed up, restore this guest, what did the
last restore test show) should not need a root shell on the hypervisor, and
people other than the admin should be able to see the state without getting
one. PBS has a web UI; an "enterprise alternative" without one is a hard sell.

## What went wrong last time
An earlier FastAPI console in PBS style on port 8008 was frozen for the TUI and
then removed. Two lessons:
- It parsed human output. The job-status regexes broke as soon as the tool's
  messages were reworded. Here the UI reads only JSON envelopes with a schema
  version, and tests pin the contract.
- It needed a Python venv on the host. Here it is one static binary.

## Stack: Go
- One file, no runtime dependencies on the host, built in CI into the .deb.
- `net/http` with TLS is a production-grade server in the standard library;
  `html/template` escapes by default. Assets are embedded; no npm, no CDN, no
  request leaves the host (it may be offline).
- Rejected: Python stdlib only (no venv, but `http.server` is not meant to face a
  network); Perl on PVE's libraries (deep integration, hard to maintain); a plugin
  inside the PVE GUI (overwritten by pve-manager updates, unsupported).

## Shape
- **Privilege split.** The HTTP side (TLS, sessions, parsing: the attack surface)
  runs as an unprivileged user. A small root helper, the same binary in another
  mode, listens on a local Unix socket and accepts only allowlisted pbo
  invocations with validated arguments, run with an argv list, never a shell. It
  re-checks the caller's permission for the action it is asked to run.
- **Login against PVE**: user, realm, password and TFA through the local API
  (`/access/ticket` on 127.0.0.1:8006). No user database of its own. Short sessions,
  HttpOnly + Secure + SameSite cookies, CSRF token on every change, login rate limit.
- **Authorization from the PVE ACL** of the logged-in user, per request (the
  table in the README is the reference): reads, including the config (secrets
  masked), timers and status, need `Sys.Audit` on `/` (an inventory-wide read);
  backup of a guest `VM.Backup` on `/vms/<vmid>`, test-restore also `VM.PowerMgmt`
  and `VM.Allocate` on `/vms`; restore to a new vmid `VM.Backup` on the source,
  `VM.Allocate` on the new id and `Datastore.AllocateSpace` on the storage (plus
  `VM.PowerMgmt` to start it); privileged containers, `--keep-network`, prune,
  unlock, verify, run-schedule and notifications `Sys.Modify` on `/`.
- **Jobs**: long actions run as transient systemd units with a job id, a log
  and an exit code, so they survive a closed tab and the CLI/menu see them too.
- **Audit**: the PVE user (`alice@pve`), `via: web` and the client address go into
  `audit.jsonl` for every action.
- **Network**: TLS with pbo-web's own certificate (never the node's key), port
  8008 opened only for the management network in the PVE firewall; the pbo-web
  user may open no outbound connection.

## Security review and what it changed

A security review before 0.4.0 shipped found, among others:
- **Browsers send PVE's login cookie to every port of the same host name.** If
  pbo-web is reached by the same name as the PVE UI, every request carries the
  admin's PVE ticket. pbo-web strips unknown cookies before any handler runs and
  warns; its user may open no outbound connection (nftables, `meta skuid`), so a
  compromised process cannot use a ticket against the API itself; `PBO_WEB_HOSTS`
  pins the names it answers to. **Residual risk:** a compromised process still sees
  the cookie in memory. Reach pbo-web by a different name or address than the PVE UI.
- **The web process sees passwords at sign-in** (as pveproxy does). The helper is a
  boundary for tickets, not for credentials typed into the web process.
  `PBO_WEB_DENY_USERS` keeps chosen accounts (e.g. root@pam) out entirely.
- Restore checks were widened (VM.PowerMgmt for `--start`, Sys.Modify for
  `--keep-network`) and web restores are always isolated (`--isolate`), because
  `pct restore` runs as root and would otherwise keep host bindings a PVE user
  could not create. pbo-web has its own certificate, never the node's key. The
  helper bounds concurrency, kills whole process groups on timeout, caps output and
  validates the ticket format and client address; both units are sandboxed.

## Order
JSON contract → jobs → service, login, ACL → read-only dashboard (first usable
state) → actions → restore and evidence → settings → packaging, hardening and a
security review, which gates the release.
