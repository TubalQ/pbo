#!/usr/bin/env python3
"""lxc-offsite TUI (Textual). ADR 0003 — snygg, app-lik terminal-konsol.

Ingen egen affärslogik: allt går via `lxc-offsite [--json] <cmd>` (samma envelope
som web-UI:t använde) + `pvesh`. Fokus: setup · export-nyckel · backup · restore.
Kör: `lxc-offsite tui` (dispatchern startar denna i sin venv).
"""
from __future__ import annotations
import json, os, secrets, subprocess

from textual import work
from textual.app import App, ComposeResult
from textual.containers import Grid, Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import (Button, DataTable, Footer, Header, Input, Label,
                             RichLog, Select, Static, TabbedContent, TabPane)

BIN = os.environ.get("LXCO_BIN", "/usr/local/sbin/lxc-offsite")
CFG_PATH = os.environ.get("LXCO_CONFIG", "/etc/lxc-offsite/config")


# ----------------------------- datalager -----------------------------
def _run(args, timeout=60):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)


def cli_json(*args, timeout=60):
    rc, out, _ = _run([BIN, "--json", *args], timeout)
    out = out.strip()
    try:
        return json.loads(out) if out[:1] in "{[" else {}
    except Exception:  # noqa: BLE001
        return {}


def guests():
    rc, out, _ = _run(["pvesh", "get", "/cluster/resources", "--type", "vm",
                       "--output-format", "json"], 15)
    try:
        return sorted(json.loads(out), key=lambda g: int(g.get("vmid", 0)))
    except Exception:  # noqa: BLE001
        return []


def rootdir_storages():
    rc, out, _ = _run(["pvesh", "get", "/storage", "--output-format", "json"], 15)
    try:
        return sorted({s["storage"] for s in json.loads(out)
                       if "rootdir" in (s.get("content") or "")})
    except Exception:  # noqa: BLE001
        return []


def read_cfg():
    cfg = {}
    try:
        for line in open(CFG_PATH):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k] = v.strip().strip('"')
    except OSError:
        pass
    return cfg


def human(b):
    b = float(b or 0)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024 or u == "TB":
            return f"{b:.1f} {u}" if u != "B" and b < 10 else f"{int(b)} {u}"
        b /= 1024


TS_RE = __import__("re").compile(r"(\d{4}_\d{2}_\d{2}-\d{2}_\d{2}_\d{2})")


# ----------------------------- modaler -----------------------------
class LogScreen(ModalScreen):
    """Live-logg för en körande åtgärd (streamar CLI-output)."""
    BINDINGS = [("escape", "dismiss", "Stäng")]

    def __init__(self, title, argv):
        super().__init__()
        self._title, self._argv = title, argv

    def compose(self) -> ComposeResult:
        with Vertical(id="logbox"):
            yield Static(f" ▶ {self._title}", id="logtitle")
            yield RichLog(highlight=True, markup=True, wrap=True)
            yield Static("Esc för att stänga", id="logfoot")

    def on_mount(self):
        self.run_cmd()

    @work(thread=True)
    def run_cmd(self):
        log = self.query_one(RichLog)
        self.app.call_from_thread(log.write, f"[dim]$ {' '.join(self._argv)}[/dim]\n")
        try:
            p = subprocess.Popen(self._argv, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, bufsize=1)
            for line in iter(p.stdout.readline, ""):
                line = line.rstrip("\n")
                style = ("[red]" if any(t in line for t in ("ERROR", "Fatal", "FAIL", "misslyckades")) else
                         "[green]" if any(t in line for t in ("KLART", "OK", "saved", "no errors")) else "")
                self.app.call_from_thread(log.write, f"{style}{line}")
            p.wait()
            self.app.call_from_thread(log.write, f"\n[b]{'✓ klart' if p.returncode == 0 else '✗ fel'} (rc={p.returncode})[/b]")
        except Exception as e:  # noqa: BLE001
            self.app.call_from_thread(log.write, f"[red]fel: {e}[/red]")
        self.app.call_from_thread(self.query_one("#logfoot", Static).update,
                                  "Klart — Esc för att stänga")

    def action_dismiss(self):
        self.dismiss(True)


class RestoreModal(ModalScreen):
    BINDINGS = [("escape", "dismiss", "Avbryt")]

    def __init__(self, vmid, ts, name):
        super().__init__()
        self.vmid, self.ts, self.name = vmid, ts, name

    def compose(self) -> ComposeResult:
        used = {int(g["vmid"]) for g in guests() if str(g.get("vmid", "")).isdigit()}
        nf = 9100
        while nf in used:
            nf += 1
        stores = rootdir_storages() or ["nvmepool"]
        with Vertical(id="formbox"):
            yield Static(f"Återställ  {self.name} ({self.vmid})  ·  {self.ts}", classes="mtitle")
            with Horizontal(classes="row"):
                yield Label("Nytt VMID")
                yield Input(value=str(nf), id="newid")
            with Horizontal(classes="row"):
                yield Label("Storage")
                yield Select([(s, s) for s in stores], value=stores[0], id="store", allow_blank=False)
            yield Static("Återställs ALLTID till nytt vmid (aldrig överskrivning).", classes="help")
            with Horizontal(classes="toolbar"):
                yield Button("Återställ", variant="success", id="go", classes="-primary")
                yield Button("Avbryt", id="cancel")

    def on_button_pressed(self, e):
        if e.button.id == "cancel":
            self.dismiss(None)
            return
        newid = self.query_one("#newid", Input).value.strip()
        store = self.query_one("#store", Select).value
        self.dismiss(("restore", self.vmid, self.ts, "--to", newid, "--storage", store, "--yes"))

    def action_dismiss(self):
        self.dismiss(None)


# ----------------------------- huvudapp -----------------------------
class LxcoTUI(App):
    CSS_PATH = "lxco.tcss"
    TITLE = "lxc-offsite"
    SUB_TITLE = "offsite-backup för Proxmox"
    BINDINGS = [
        ("r", "refresh", "Uppdatera"),
        ("b", "backup_all", "Backa alla"),
        ("e", "export", "Export-nyckel"),
        ("q", "quit", "Avsluta"),
    ]

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        yield Static(id="statusbar")
        with TabbedContent(initial="tab-dash"):
            with TabPane("Översikt", id="tab-dash"):
                yield Grid(id="cards")
                yield Static("Offsite-arkiv", classes="section-title")
                yield DataTable(id="dstable")
            with TabPane("Gäster", id="tab-guests"):
                with Horizontal(classes="toolbar"):
                    yield Button("Backa upp vald", id="bk-one", classes="-primary")
                    yield Button("Backa upp alla", id="bk-all")
                    yield Button("Test-restore vald", id="tr-one")
                yield DataTable(id="gtable")
            with TabPane("Återställ", id="tab-restore"):
                yield Static("Välj en snapshot och tryck Återställ.", classes="help")
                with Horizontal(classes="toolbar"):
                    yield Button("Återställ vald", id="rs-one", classes="-primary")
                yield DataTable(id="rtable")
            with TabPane("Setup", id="tab-setup"):
                yield from self._setup_form()
            with TabPane("Underhåll", id="tab-maint"):
                with Vertical(classes="toolbar"):
                    yield Button("Prune — torrkörning", id="mt-prune-dry")
                    yield Button("Prune — skarpt", id="mt-prune", classes="-danger")
                    yield Button("Verifiera (restic check)", id="mt-verify")
                    yield Button("Exportera DR-nyckel", id="mt-export", classes="-primary")
        yield Footer()

    def _setup_form(self):
        cfg = read_cfg()
        with VerticalScroll(classes="form"):
            yield Static("Enkel restic-setup — fyll i och tryck [b]Spara & init[/b].", classes="help")
            with Horizontal(classes="row"):
                yield Label("Motor")
                yield Select([("restic", "restic"), ("tar", "tar")],
                             value=cfg.get("ENGINE", "restic"), id="f-engine", allow_blank=False)
            with Horizontal(classes="row"):
                yield Label("Läge")
                yield Select([("cache + offsite", "cached"), ("bara offsite", "offsite")],
                             value="cached" if cfg.get("LOCAL_REPO", "true") == "true" else "offsite",
                             id="f-mode", allow_blank=False)
            for lab, wid, val, ph in [
                ("SFTP-host", "f-host", "", "uXXXXX-subN.your-storagebox.de"),
                ("SFTP-user", "f-user", "", "uXXXXX-subN"),
                ("Port", "f-port", "23", ""),
                ("SSH-nyckel", "f-key", "/root/.ssh/id_rsa", ""),
                ("Repo-path (relativ)", "f-repo", "lxc-restic", ""),
            ]:
                with Horizontal(classes="row"):
                    yield Label(lab)
                    yield Input(value=val, placeholder=ph, id=wid)
            with Horizontal(classes="row"):
                yield Label("Repo-lösen")
                yield Input(value="", password=True, id="f-pass", placeholder="lämna tomt = generera")
            with Horizontal(classes="toolbar"):
                yield Button("Spara & init", id="setup-save", classes="-primary")
                yield Button("Generera lösen", id="setup-gen")

    # -------------------- livscykel --------------------
    def on_mount(self):
        for tid, cols in [("dstable", ("Namn", "Typ", "Storlek", "Snapshots")),
                          ("gtable", ("VMID", "Namn", "Typ", "Nod", "Status", "Snaps")),
                          ("rtable", ("VMID", "Namn", "Tidsstämpel", "Storlek", "Snapshot"))]:
            t = self.query_one(f"#{tid}", DataTable)
            t.cursor_type = "row"
            t.add_columns(*cols)
        self.refresh_data()

    def action_refresh(self):
        self.refresh_data()

    def refresh_data(self):
        cfg = read_cfg()
        eng = cfg.get("ENGINE", "tar")
        mode = "cache+offsite" if cfg.get("LOCAL_REPO", "true") == "true" else "offsite-only"
        listing = cli_json("list")
        arcs = listing.get("archives", []) if isinstance(listing, dict) else []
        total = sum(int(a.get("size_bytes", 0)) for a in arcs)
        vmids = sorted({a.get("vmid") for a in arcs})
        gs = guests()
        name_by = {str(g.get("vmid")): g.get("name", "") for g in gs}
        snaps_by = {}
        for a in arcs:
            snaps_by.setdefault(a.get("vmid"), 0)
            snaps_by[a.get("vmid")] += 1

        # statusrad
        sb = self.query_one("#statusbar", Static)
        ec = "green" if eng == "restic" else "yellow"
        repo = cfg.get("RESTIC_OFFSITE_REPO") or cfg.get("RCLONE_REMOTE") or "—"
        sb.update(f"  Motor [b {ec}]{eng}[/]   ·   läge [b cyan]{mode}[/]   ·   offsite [cyan]{repo}[/]"
                  f"   ·   gäster [b cyan]{len(gs)}[/]   ·   snapshots [b cyan]{len(arcs)}[/]")

        # kort
        cards = self.query_one("#cards", Grid)
        cards.remove_children()
        cards.mount(
            self._card("Motor", eng, "good" if eng == "restic" else "warn"),
            self._card("Läge", mode, "accent"),
            self._card("Offsite (logisk)", human(total), "accent"),
            self._card("Snapshots", str(len(arcs)), ""),
            self._card("Skyddade gäster", str(len(vmids)), "good" if vmids else ""),
            self._card("Kryptering", "on · restic" if eng == "restic" else "rclone crypt", "good"),
        )

        # datastore-tabell
        dt = self.query_one("#dstable", DataTable)
        dt.clear()
        for v in vmids:
            sz = sum(int(a.get("size_bytes", 0)) for a in arcs if a.get("vmid") == v)
            dt.add_row(f"{name_by.get(v, v)} ({v})", "LXC", human(sz), str(snaps_by.get(v, 0)))
        if not vmids:
            dt.add_row("— inga offsite-arkiv än —", "", "", "")

        # gäst-tabell
        gt = self.query_one("#gtable", DataTable)
        gt.clear()
        for g in gs:
            vid = str(g.get("vmid"))
            gt.add_row(vid, g.get("name", "-"), g.get("type", "-"), g.get("node", "-"),
                       g.get("status", "-"), str(snaps_by.get(vid, 0)))

        # restore-tabell
        rt = self.query_one("#rtable", DataTable)
        rt.clear()
        for a in sorted(arcs, key=lambda x: x.get("modtime", ""), reverse=True):
            m = TS_RE.search(a.get("archive", ""))
            ts = m.group(1) if m else "?"
            rt.add_row(a.get("vmid"), name_by.get(a.get("vmid"), ""), ts,
                       human(a.get("size_bytes", 0)), a.get("snapshot", ""))
        if not arcs:
            rt.add_row("—", "inga arkiv", "", "", "")

    def _card(self, k, v, cls):
        c = Static(classes=f"card {cls}".strip())
        c.update(f"[dim]{k}[/dim]\n[b]{v}[/b]")
        return c

    # -------------------- åtgärder --------------------
    def _sel(self, table_id, col=0):
        t = self.query_one(f"#{table_id}", DataTable)
        try:
            row = t.get_row_at(t.cursor_row)
            return str(row[col])
        except Exception:  # noqa: BLE001
            return None

    def on_button_pressed(self, e):
        bid = e.button.id
        if bid == "bk-all":
            self.action_backup_all()
        elif bid == "bk-one":
            v = self._sel("gtable")
            if v and v.isdigit():
                self.run_action(f"Backup {v}", [BIN, "backup", v])
        elif bid == "tr-one":
            v = self._sel("gtable")
            if v and v.isdigit():
                self.run_action(f"Test-restore {v}", [BIN, "test-restore", v])
        elif bid == "rs-one":
            self._restore_selected()
        elif bid == "mt-prune-dry":
            self.run_action("Prune (torrkörning)", [BIN, "--dry-run", "prune"])
        elif bid == "mt-prune":
            self.run_action("Prune (skarpt)", [BIN, "prune"])
        elif bid == "mt-verify":
            self.run_action("Verifiera", [BIN, "verify"])
        elif bid in ("mt-export",):
            self.action_export()
        elif bid == "setup-gen":
            self.query_one("#f-pass", Input).value = secrets.token_urlsafe(18)
        elif bid == "setup-save":
            self._setup_save()

    def action_backup_all(self):
        self.run_action("Backup — alla skyddade", [BIN, "run-schedule"])

    def _restore_selected(self):
        rt = self.query_one("#rtable", DataTable)
        try:
            row = rt.get_row_at(rt.cursor_row)
        except Exception:  # noqa: BLE001
            return
        vmid, name, ts = str(row[0]), str(row[1]), str(row[2])
        if not vmid.isdigit():
            return

        def done(res):
            if res:
                self.run_action(f"Restore {vmid}", [BIN, *res])
        self.push_screen(RestoreModal(vmid, ts, name), done)

    def action_export(self):
        cfg = read_cfg()
        try:
            pw = open(cfg.get("RESTIC_PASSWORD_FILE", "/etc/lxc-offsite/restic-pass")).read().strip()
        except OSError:
            pw = "<ingen lösenfil>"
        argv = ["sh", "-c",
                f'echo "# DR-nyckel — HEMLIG. Ny host: klistra in, kör list→restore"; '
                f'echo ENGINE=restic; echo "RESTIC_OFFSITE_REPO={cfg.get("RESTIC_OFFSITE_REPO","")}"; '
                f'echo "RESTIC_SFTP_COMMAND=\\"{cfg.get("RESTIC_SFTP_COMMAND","")}\\""; '
                f'echo "RESTIC_PASSWORD={pw}"']
        self.run_action("DR-nyckel (HEMLIG — förvara offline)", argv)

    def _setup_save(self):
        g = lambda i: self.query_one(f"#{i}").value
        eng = g("f-engine")
        if eng != "restic":
            self._write_cfg({"ENGINE": "tar"})
            self.run_action("Setup", ["sh", "-c", "echo ENGINE=tar satt."])
            return
        pw = (g("f-pass") or secrets.token_urlsafe(18)).strip()
        passfile = "/etc/lxc-offsite/restic-pass"
        try:
            fd = os.open(passfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.write(fd, (pw + "\n").encode()); os.close(fd)
        except OSError as e:  # noqa: BLE001
            self.run_action("Setup — FEL", ["sh", "-c", f"echo 'kan ej skriva {passfile}: {e}'"])
            return
        sftp = (f'ssh {g("f-user")}@{g("f-host")} -p {g("f-port")} -i {g("f-key")} '
                f'-o StrictHostKeyChecking=accept-new -s sftp')
        self._write_cfg({
            "ENGINE": "restic",
            "LOCAL_REPO": "true" if g("f-mode") == "cached" else "false",
            "OFFSITE_ENABLED": "true",
            "RESTIC_OFFSITE_REPO": f'sftp:hetzner:{g("f-repo")}',
            "RESTIC_PASSWORD_FILE": passfile,
            "RESTIC_SFTP_COMMAND": sftp,
        })
        self.run_action("Setup — skapar repo (init)", [BIN, "init"])

    def _write_cfg(self, updates):
        lines = []
        try:
            lines = open(CFG_PATH).read().splitlines()
        except OSError:
            pass
        done = set()
        for i, ln in enumerate(lines):
            s = ln.strip()
            if s and not s.startswith("#") and "=" in s:
                k = s.split("=", 1)[0].strip()
                if k in updates:
                    q = '"' if " " in updates[k] else ""
                    lines[i] = f"{k}={q}{updates[k]}{q}"; done.add(k)
        for k, v in updates.items():
            if k not in done:
                q = '"' if " " in v else ""
                lines.append(f"{k}={q}{v}{q}")
        tmp = CFG_PATH + ".tmp"
        with open(tmp, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        os.chmod(tmp, 0o600); os.replace(tmp, CFG_PATH)

    def run_action(self, title, argv):
        def after(_):
            self.refresh_data()
        self.push_screen(LogScreen(title, argv), after)


if __name__ == "__main__":
    LxcoTUI().run()
