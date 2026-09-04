#!/usr/bin/env python3
"""lxc-offsite API — tunt skal runt CLI:t. Ingen egen affärslogik: allt går via
`lxc-offsite --json`. Serverar även den PBS-lika frontenden. Steg 11.

Bind:as till LAN/localhost i systemd-uniten. Auth (Proxmox ticket) läggs i steg 13
— tills dess: bind endast localhost eller lägg bakom traefik+forward-auth.
"""
import glob
import json
import os
import subprocess
import time
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse

BIN = os.environ.get("LXCO_BIN", "/usr/local/sbin/lxc-offsite")
WEB = Path(__file__).resolve().parent.parent / "web"
JOBS = "/var/lib/lxc-offsite/jobs"
CONFIG = "/etc/lxc-offsite/config"

app = FastAPI(title="lxc-offsite", docs_url=None, redoc_url=None)

# Enkel TTL-cache så `list` (som når offsite) inte körs vid varje sidladdning.
_cache: dict = {}
def _cached(key, ttl, fn):
    now = time.time()
    hit = _cache.get(key)
    if hit and now - hit[0] < ttl:
        return hit[1]
    val = fn()
    _cache[key] = (now, val)
    return val


def cli(*args, timeout=90):
    try:
        p = subprocess.run([BIN, "--json", *args], capture_output=True, text=True, timeout=timeout)
        out = p.stdout.strip()
        if out.startswith("{"):
            return json.loads(out)
        return {"ok": p.returncode == 0, "raw": out, "rc": p.returncode}
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)}


def read_config():
    cfg = {}
    try:
        for line in open(CONFIG):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k] = v
    except OSError:
        pass
    return cfg


def cluster_guests():
    """vmid -> {name,type,status,node} för hela klustret."""
    guests = {}
    try:
        p = subprocess.run(
            ["pvesh", "get", "/cluster/resources", "--type", "vm", "--output-format", "json"],
            capture_output=True, text=True, timeout=15,
        )
        for r in json.loads(p.stdout):
            guests[str(r["vmid"])] = {
                "name": r.get("name"), "type": r.get("type"),
                "status": r.get("status"), "node": r.get("node"),
            }
    except Exception:  # noqa: BLE001
        pass
    return guests


@app.get("/api/health")
def health():
    return {"ok": True, "bin": BIN, "has_config": os.path.exists(CONFIG)}


@app.get("/api/state")
def state():
    cfg = read_config()
    order = [x for x in cfg.get("BACKUP_ORDER", "").replace(" ", "").split(",") if x]
    allg = cluster_guests()
    listing = _cached("list", 30, lambda: cli("list"))

    snaps = {}
    for a in listing.get("archives", []):
        snaps.setdefault(a["vmid"], []).append(a)

    guests = []
    for vid in order:
        g = allg.get(vid, {})
        guests.append({
            "vmid": vid,
            "name": g.get("name", vid),
            "type": g.get("type", "lxc"),
            "node": g.get("node"),
            "snapshots": len(snaps.get(vid, [])),
        })

    tasks = []
    for f in sorted(glob.glob(JOBS + "/*.log"), key=os.path.getmtime, reverse=True)[:10]:
        base = os.path.basename(f)[:-4]
        tasks.append({"name": base, "mtime": int(os.path.getmtime(f))})

    total = sum(a.get("size_bytes", 0) for arr in snaps.values() for a in arr)
    return JSONResponse({
        "status": _cached("status", 5, lambda: cli("status")),
        "guests": guests,
        "snapshots": snaps,
        "tasks": tasks,
        "offsite_bytes": total,
        "config": {k: cfg.get(k) for k in ("BACKUP_ORDER", "RCLONE_REMOTE", "KEEP_LOCAL",
                                           "KEEP_OFFSITE_DAILY", "KEEP_OFFSITE_WEEKLY",
                                           "KEEP_OFFSITE_MONTHLY", "VZDUMP_MODE")},
    })


@app.get("/api/tasks/{name}")
def task_log(name: str):
    p = os.path.join(JOBS, os.path.basename(name) + ".log")
    if os.path.exists(p):
        with open(p) as fh:
            return PlainTextResponse(fh.read()[-40000:])
    return PlainTextResponse("not found", status_code=404)


@app.get("/", response_class=HTMLResponse)
def index():
    return (WEB / "index.html").read_text()
