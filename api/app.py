#!/usr/bin/env python3
"""lxc-offsite API — tunt skal runt CLI:t. Steg 11–13.

Ingen egen affärslogik: allt går via `lxc-offsite --json`. Serverar frontenden.
Auth: Proxmox ticket (login mot PVE:s /access/ticket) + signerad sessionscookie.
Skarpa åtgärder körs som transienta systemd-units (blockerar aldrig HTTP-svaret)
och audit-loggas med web-användaren.
"""
import base64
import glob
import hashlib
import hmac
import json
import os
import re
import ssl
import subprocess
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from fastapi import Body, Cookie, Depends, FastAPI, HTTPException, Response
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse

BIN = os.environ.get("LXCO_BIN", "/usr/local/sbin/lxc-offsite")
WEB = Path(__file__).resolve().parent.parent / "web"
JOBS = "/var/lib/lxc-offsite/jobs"
CONFIG = "/etc/lxc-offsite/config"
AUDIT = "/var/log/lxc-offsite/audit.log"
SECRET_FILE = "/etc/lxc-offsite/api-secret"
PVE_TICKET_URL = "https://127.0.0.1:8006/api2/json/access/ticket"

app = FastAPI(title="lxc-offsite", docs_url=None, redoc_url=None)

# ---- sessionshemlighet (genereras vid första start, 0600) ----
def _secret() -> bytes:
    try:
        return open(SECRET_FILE, "rb").read()
    except OSError:
        s = os.urandom(32)
        fd = os.open(SECRET_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, s); os.close(fd)
        return s
SECRET = _secret()

# Anropet går ENBART till 127.0.0.1:8006 (samma host, hårdkodat) — ren loopback.
# Cert-verifiering mot PVE:s CA är omöjlig med strikt OpenSSL: PVE:s självgenererade
# root-CA saknar keyUsage-extension ("CA cert does not include key usage extension").
# På loopback kräver MITM redan root på maskinen (då är allt redan förlorat), så vi
# hoppar cert-verifiering här medvetet. Detta är standard för PVE-lokala API-anrop.
_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode = ssl.CERT_NONE

# ---- Proxmox ticket-auth ----
def pve_ticket(username: str, password: str) -> str:
    data = urllib.parse.urlencode({"username": username, "password": password}).encode()
    req = urllib.request.Request(PVE_TICKET_URL, data=data)
    with urllib.request.urlopen(req, context=_SSL, timeout=10) as r:
        j = json.load(r)
    d = (j or {}).get("data") or {}
    if not d.get("ticket"):
        raise ValueError("no ticket")
    return d.get("username", username)

def sign(user: str) -> str:
    msg = f"{user}|{int(time.time()) + 8 * 3600}"
    sig = hmac.new(SECRET, msg.encode(), hashlib.sha256).hexdigest()
    return base64.urlsafe_b64encode(f"{msg}|{sig}".encode()).decode()

def verify(token: str):
    try:
        raw = base64.urlsafe_b64decode(token.encode()).decode()
        user, exp, sig = raw.rsplit("|", 2)
        good = hmac.new(SECRET, f"{user}|{exp}".encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, good) or int(exp) < time.time():
            return None
        return user
    except Exception:  # noqa: BLE001
        return None

def current_user(session: str = Cookie(default=None)) -> str:
    u = verify(session) if session else None
    if not u:
        raise HTTPException(status_code=401, detail="auth required")
    return u

# ---- helpers ----
def cli(*args, timeout=90):
    try:
        p = subprocess.run([BIN, "--json", *args], capture_output=True, text=True, timeout=timeout)
        out = p.stdout.strip()
        return json.loads(out) if out.startswith("{") else {"ok": p.returncode == 0, "raw": out, "rc": p.returncode}
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)}

_cache: dict = {}
def _cached(key, ttl, fn):
    now = time.time()
    hit = _cache.get(key)
    if hit and now - hit[0] < ttl:
        return hit[1]
    val = fn(); _cache[key] = (now, val); return val

def read_config():
    cfg = {}
    try:
        for line in open(CONFIG):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1); cfg[k] = v
    except OSError:
        pass
    return cfg

def get_order():
    cfg = read_config()
    return [x for x in cfg.get("BACKUP_ORDER", "").replace(" ", "").split(",") if x]

def write_backup_order(order):
    """Skriv om BACKUP_ORDER-raden i configen (bevarar resten), atomiskt, 0600."""
    try:
        lines = open(CONFIG).readlines()
    except OSError:
        lines = []
    newline = "BACKUP_ORDER=" + ",".join(order) + "\n"
    for i, l in enumerate(lines):
        if l.strip().startswith("BACKUP_ORDER="):
            lines[i] = newline
            break
    else:
        lines.append(newline)
    tmp = CONFIG + ".tmp"
    with open(tmp, "w") as fh:
        fh.write("".join(lines))
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONFIG)

def cluster_guests():
    guests = {}
    try:
        p = subprocess.run(["pvesh", "get", "/cluster/resources", "--type", "vm",
                            "--output-format", "json"], capture_output=True, text=True, timeout=15)
        for r in json.loads(p.stdout):
            guests[str(r["vmid"])] = {"name": r.get("name"), "type": r.get("type"),
                                      "status": r.get("status"), "node": r.get("node")}
    except Exception:  # noqa: BLE001
        pass
    return guests

VMID_RE = re.compile(r"^\d{1,9}$")
TS_RE = re.compile(r"^[0-9_\-]{1,32}$")
def _vmid(v):  # validering
    if not VMID_RE.match(str(v)):
        raise HTTPException(400, "invalid vmid")
    return str(v)

def audit(user, action):
    try:
        line = f"{datetime.now(timezone.utc).astimezone().isoformat()} user=web:{user} {action}\n"
        with open(AUDIT, "a") as fh:
            fh.write(line)
    except OSError:
        pass

def launch(user, args, tag):
    """Kör CLI:t som en transient systemd-unit — blockerar aldrig HTTP-svaret."""
    unit = f"lxco-web-{tag}-{int(time.time())}"
    subprocess.run(["systemd-run", "--collect", "--unit", unit, BIN, *args],
                   check=True, capture_output=True, text=True, timeout=20)
    return unit

# ---- auth-endpoints ----
@app.post("/api/login")
def login(response: Response, username: str = Body(...), password: str = Body(...)):
    try:
        u = pve_ticket(username, password)
    except Exception:  # noqa: BLE001
        raise HTTPException(status_code=401, detail="invalid credentials")
    response.set_cookie("session", sign(u), httponly=True, samesite="lax", max_age=8 * 3600)
    return {"ok": True, "user": u}

@app.post("/api/logout")
def logout(response: Response):
    response.delete_cookie("session")
    return {"ok": True}

@app.get("/api/me")
def me(user: str = Depends(current_user)):
    return {"user": user}

# ---- läs-endpoints ----
@app.get("/api/health")
def health():
    return {"ok": True, "bin": BIN, "has_config": os.path.exists(CONFIG)}

@app.get("/api/state")
def state(user: str = Depends(current_user)):
    cfg = read_config()
    order = get_order()
    allg = cluster_guests()
    listing = _cached("list", 30, lambda: cli("list"))
    snaps = {}
    for a in listing.get("archives", []):
        snaps.setdefault(a["vmid"], []).append(a)
    # Alla klustergäster, skyddade (i BACKUP_ORDER) först i ordning, sedan resten
    # (= nya/oskyddade LXC/VM som kan klickas in). Nya gäster upptäcks automatiskt.
    guests, seen = [], set()
    for v in order:
        g = allg.get(v, {}); seen.add(v)
        guests.append({"vmid": v, "name": g.get("name", v), "type": g.get("type", "lxc"),
                       "node": g.get("node"), "protected": True, "snapshots": len(snaps.get(v, []))})
    for v, g in sorted(allg.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0):
        if v in seen:
            continue
        guests.append({"vmid": v, "name": g.get("name"), "type": g.get("type"),
                       "node": g.get("node"), "protected": False, "snapshots": len(snaps.get(v, []))})
    tasks = [{"name": os.path.basename(f)[:-4], "mtime": int(os.path.getmtime(f))}
             for f in sorted(glob.glob(JOBS + "/*.log"), key=os.path.getmtime, reverse=True)[:10]]
    total = sum(a.get("size_bytes", 0) for arr in snaps.values() for a in arr)
    return JSONResponse({"status": _cached("status", 5, lambda: cli("status")), "guests": guests,
                         "snapshots": snaps, "tasks": tasks, "offsite_bytes": total, "user": user,
                         "config": {k: cfg.get(k) for k in ("BACKUP_ORDER", "RCLONE_REMOTE",
                                    "KEEP_LOCAL", "KEEP_OFFSITE_DAILY", "VZDUMP_MODE")}})

@app.get("/api/tasks/{name}")
def task_log(name: str, user: str = Depends(current_user)):
    p = os.path.join(JOBS, os.path.basename(name) + ".log")
    if os.path.exists(p):
        return PlainTextResponse(open(p).read()[-40000:])
    return PlainTextResponse("not found", status_code=404)

# ---- skydd på/av (klicka i/ur gäster → BACKUP_ORDER) ----
@app.post("/api/guests/{vmid}")
def protect_add(vmid: str, user: str = Depends(current_user)):
    vmid = _vmid(vmid)
    if vmid not in cluster_guests():
        raise HTTPException(404, "guest not found in cluster")
    order = get_order()
    if vmid not in order:
        order.append(vmid)
        write_backup_order(order)
        audit(user, f"protect-add vmid={vmid}")
    return {"ok": True, "protected": True, "order": order}

@app.delete("/api/guests/{vmid}")
def protect_remove(vmid: str, user: str = Depends(current_user)):
    vmid = _vmid(vmid)
    order = [x for x in get_order() if x != vmid]
    write_backup_order(order)
    audit(user, f"protect-remove vmid={vmid}")
    return {"ok": True, "protected": False, "order": order}

# ---- skriv-endpoints (skarpa åtgärder) ----
@app.post("/api/backup/{vmid}")
def api_backup(vmid: str, user: str = Depends(current_user)):
    vmid = _vmid(vmid); audit(user, f"backup vmid={vmid}")
    return {"ok": True, "unit": launch(user, ["backup", vmid], f"backup-{vmid}")}

@app.post("/api/run-schedule")
def api_run_schedule(user: str = Depends(current_user)):
    audit(user, "run-schedule")
    return {"ok": True, "unit": launch(user, ["run-schedule"], "schedule")}

@app.post("/api/prune")
def api_prune(user: str = Depends(current_user), dry_run: bool = Body(default=True, embed=True)):
    args = ["prune"] + (["--dry-run"] if dry_run else [])
    audit(user, f"prune dry_run={dry_run}")
    if dry_run:  # torrkörning är snabb → returnera resultatet direkt
        return {"ok": True, "result": cli(*args)}
    return {"ok": True, "unit": launch(user, args, "prune")}

@app.post("/api/test-restore/{vmid}")
def api_test_restore(vmid: str, user: str = Depends(current_user)):
    vmid = _vmid(vmid); audit(user, f"test-restore vmid={vmid}")
    return {"ok": True, "unit": launch(user, ["test-restore", vmid], f"testrestore-{vmid}")}

@app.post("/api/restore")
def api_restore(user: str = Depends(current_user), vmid: str = Body(...), ts: str = Body(...),
                target: str = Body(...), storage: str = Body(...)):
    vmid = _vmid(vmid); target = _vmid(target)
    if not TS_RE.match(ts) or not re.match(r"^[A-Za-z0-9_\-]{1,64}$", storage):
        raise HTTPException(400, "invalid ts/storage")
    audit(user, f"restore vmid={vmid} ts={ts} target={target} storage={storage}")
    unit = launch(user, ["restore", vmid, ts, "--to", target, "--storage", storage, "--yes"],
                  f"restore-{target}")
    return {"ok": True, "unit": unit}

# ---- DR-nyckel (rclone.conf) — auth + audit ----
@app.get("/api/export-key")
def export_key(user: str = Depends(current_user)):
    audit(user, "export-key")
    try:
        cfg = read_config()
        path = cfg.get("RCLONE_CONFIG_FILE", "/etc/lxc-offsite/rclone.conf")
        return PlainTextResponse(open(path).read())
    except OSError:
        raise HTTPException(404, "rclone.conf not found")


# ---- frontend ----
@app.get("/", response_class=HTMLResponse)
def index():
    return (WEB / "index.html").read_text()
