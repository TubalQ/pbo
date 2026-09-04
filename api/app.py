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

def set_config(updates: dict):
    """Skriv/uppdatera KEY=VALUE i configen (bevarar resten), atomiskt, 0600."""
    lines = open(CONFIG).readlines() if os.path.exists(CONFIG) else []
    done = set()
    for i, l in enumerate(lines):
        st = l.strip()
        if st and not st.startswith("#") and "=" in st:
            k = st.split("=", 1)[0].strip()
            if k in updates:
                lines[i] = f"{k}={updates[k]}\n"; done.add(k)
    for k, v in updates.items():
        if k not in done:
            lines.append(f"{k}={v}\n")
    tmp = CONFIG + ".tmp"
    with open(tmp, "w") as fh:
        fh.write("".join(lines))
    os.chmod(tmp, 0o600); os.replace(tmp, CONFIG)

def rclone_env():
    cfg = read_config()
    return dict(os.environ, RCLONE_CONFIG=cfg.get("RCLONE_CONFIG_FILE", "/etc/lxc-offsite/rclone.conf"))

def parse_rclone_conf():
    """Läs rclone.conf → {section: {key: val}} men UTAN password-fälten."""
    path = read_config().get("RCLONE_CONFIG_FILE", "/etc/lxc-offsite/rclone.conf")
    out, cur = {}, None
    try:
        for line in open(path):
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                cur = line[1:-1]; out[cur] = {}
            elif cur and "=" in line and not line.startswith("#"):
                k, v = [x.strip() for x in line.split("=", 1)]
                if "password" not in k.lower():
                    out[cur][k] = v
    except OSError:
        pass
    return out

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

# ---- onboarding: cache + remote direkt i UI:t ----
_NAME = re.compile(r"^[A-Za-z0-9_\-]{1,40}$")
_PATH = re.compile(r"^/[\w./\-]{1,200}$")

@app.get("/api/config")
def get_config(user: str = Depends(current_user)):
    cfg = read_config(); rc = parse_rclone_conf()
    sftp = {}
    for name, sec in rc.items():
        if sec.get("type") == "sftp":
            sftp = {"name": name, "host": sec.get("host"), "user": sec.get("user"),
                    "port": sec.get("port", "23"), "key_file": sec.get("key_file", "")}
            break
    return {"cache_dir": cfg.get("CACHE_DIR"), "remote": cfg.get("RCLONE_REMOTE"),
            "remote_path": cfg.get("REMOTE_PATH"), "offsite_enabled": cfg.get("OFFSITE_ENABLED", "true"),
            "sftp": sftp, "crypt": any(s.get("type") == "crypt" for s in rc.values())}

_cpu_prev = None
def cpu_percent():
    """Riktig CPU-belastning via /proc/stat-delta (pvesh cpu-fältet läser ofta 0)."""
    global _cpu_prev
    def read():
        v = [int(x) for x in open("/proc/stat").readline().split()[1:]]
        return sum(v), v[3] + v[4]  # total, idle+iowait
    try:
        if _cpu_prev is None:
            t1, i1 = read()
            time.sleep(0.2)
            t2, i2 = read()
            _cpu_prev = (t2, i2)
            dt, di = t2 - t1, i2 - i1
        else:
            pt, pi = _cpu_prev
            total, idle = read()
            _cpu_prev = (total, idle)
            dt, di = total - pt, idle - pi
        return round(1 - di / dt, 4) if dt > 0 else 0.0
    except Exception:  # noqa: BLE001
        return None

@app.get("/api/resources")
def resources(user: str = Depends(current_user)):
    node = os.uname().nodename.split(".")[0]
    try:
        p = subprocess.run(["pvesh", "get", f"/nodes/{node}/status", "--output-format", "json"],
                           capture_output=True, text=True, timeout=10)
        d = json.loads(p.stdout)
        ci = d.get("cpuinfo", {})
        return {"node": node, "cpu": cpu_percent(), "cpus": ci.get("cpus"),
                "cpu_model": ci.get("model"), "memory": d.get("memory"), "swap": d.get("swap"),
                "loadavg": d.get("loadavg"), "uptime": d.get("uptime"),
                "rootfs": d.get("rootfs"), "kversion": d.get("kversion")}
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)}

@app.get("/api/storages")
def storages(user: str = Depends(current_user)):
    pools = []
    try:
        p = subprocess.run(["zpool", "list", "-H", "-o", "name"], capture_output=True, text=True, timeout=10)
        pools = [x for x in p.stdout.split() if x]
    except Exception:  # noqa: BLE001
        pass
    stores = []
    try:
        p = subprocess.run(["pvesh", "get", "/storage", "--output-format", "json"],
                           capture_output=True, text=True, timeout=15)
        for s in json.loads(p.stdout):
            if "rootdir" in (s.get("content") or ""):
                stores.append(s["storage"])
    except Exception:  # noqa: BLE001
        pass
    # Monterade riktiga filsystem (ext4/xfs/zfs/md…) → cachen kan ligga på vilken som helst.
    mounts = []
    try:
        p = subprocess.run(["findmnt", "-rnbo", "TARGET,FSTYPE,AVAIL,SOURCE", "--real"],
                           capture_output=True, text=True, timeout=10)
        for line in p.stdout.splitlines():
            parts = line.split()
            if len(parts) < 4:
                continue
            target, fstype, avail = parts[0], parts[1], parts[2]
            source = " ".join(parts[3:])
            if target.startswith(("/proc", "/sys", "/dev", "/run", "/boot")):
                continue
            if fstype in ("overlay", "squashfs", "iso9660") or fstype.startswith("fuse."):
                continue
            # hoppa container-/VM-diskar (rootfs-subvols, vm-disks) — inte cache-mål
            if "subvol-" in source or "subvol-" in target or "vm-" in source:
                continue
            mounts.append({"path": target, "fstype": fstype,
                           "avail_gb": (int(avail) // (1024 ** 3)) if avail.isdigit() else None,
                           "source": " ".join(parts[3:])})
    except Exception:  # noqa: BLE001
        pass
    return {"pools": pools, "storages": sorted(set(stores)), "mounts": mounts}

@app.post("/api/config/cache")
def cfg_cache(user: str = Depends(current_user), path: str = Body(...),
              create_dataset: bool = Body(default=False), pool: str = Body(default=""),
              quota_gb: int = Body(default=0)):
    if not _PATH.match(path):
        raise HTTPException(400, "invalid path")
    created = None
    if create_dataset:
        if not _NAME.match(pool) or int(quota_gb) <= 0:
            raise HTTPException(400, "invalid pool/quota")
        ds = f"{pool}/lxc-offsite-cache"
        subprocess.run(["zfs", "create", "-o", f"mountpoint={path}", "-o", f"quota={int(quota_gb)}G", ds],
                       check=True, capture_output=True, text=True, timeout=30)
        subprocess.run(["pvesm", "add", "dir", "lxc-offsite-cache", "--path", path, "--content",
                        "backup", "--is_mountpoint", "1"], capture_output=True, text=True, timeout=30)
        created = ds
    else:
        os.makedirs(path, exist_ok=True)
    set_config({"CACHE_DIR": path}); audit(user, f"config-cache path={path} dataset={created}")
    return {"ok": True, "cache_dir": path, "created": created}

@app.post("/api/config/remote")
def cfg_remote(user: str = Depends(current_user), name: str = Body(...), host: str = Body(...),
               sftp_user: str = Body(...), port: str = Body(default="23"),
               key_file: str = Body(default=""), use_crypt: bool = Body(default=True),
               password: str = Body(default=""), password2: str = Body(default=""),
               remote_path: str = Body(default="lxc")):
    if not _NAME.match(name) or not host or not sftp_user:
        raise HTTPException(400, "invalid name/host/user")
    env = rclone_env()
    args = [name, "sftp", f"host={host}", f"user={sftp_user}", f"port={port}", "shell_type=unix",
            "md5sum_command=md5sum", "sha1sum_command=sha1sum"]
    if key_file:
        if not _PATH.match(key_file):
            raise HTTPException(400, "invalid key_file")
        args.append(f"key_file={key_file}")
    subprocess.run(["rclone", "config", "create", *args], env=env, check=True,
                   capture_output=True, text=True, timeout=30)
    remote_name = name
    if use_crypt:
        cname = f"{name}-crypt"
        cargs = [cname, "crypt", f"remote={name}:lxc-offsite", "filename_encryption=standard",
                 "directory_name_encryption=true"]
        if password:
            cargs.append(f"password={password}")
        if password2:
            cargs.append(f"password2={password2}")
        subprocess.run(["rclone", "config", "create", "--obscure", *cargs], env=env, check=True,
                       capture_output=True, text=True, timeout=30)
        remote_name = cname
    set_config({"RCLONE_REMOTE": remote_name, "REMOTE_PATH": remote_path,
                "RCLONE_CONFIG_FILE": env["RCLONE_CONFIG"]})
    audit(user, f"config-remote name={remote_name} host={host}")
    return {"ok": True, "remote": remote_name}

@app.post("/api/config/test")
def cfg_test(user: str = Depends(current_user)):
    cfg = read_config(); env = rclone_env()
    tgt = f"{cfg.get('RCLONE_REMOTE','')}:{cfg.get('REMOTE_PATH','')}"
    try:
        m = subprocess.run(["rclone", "mkdir", tgt], env=env, capture_output=True, text=True, timeout=30)
        if m.returncode == 0:
            return {"ok": True, "msg": f"Reachable · {tgt}"}
        return {"ok": False, "msg": (m.stderr or "unreachable").strip()[:200]}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "msg": str(e)[:200]}

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
