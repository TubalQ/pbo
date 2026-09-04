# lxc-offsite

Offsite-backup av Proxmox-LXC:er till Hetzner Storage Box. Tar ett verifierat
`vzdump`-arkiv, skeppar det offsite via rclone över SFTP, och kan hämta tillbaka
det för återställning. PBS-likt webbgränssnitt.

**Offsite-armen i 3-2-1** — inte en ersättare för PBS (10.10.2.133), utan tredje
kopian. Se `PLAN.md` (kravspec) och `RESEARCH.md` (underlag).

> Verktyget ska gå att felsöka klockan tre på natten av någon som inte skrev det.

## Status

Under uppbyggnad, steg för steg enligt `docs/IMPLEMENTATION-PROMPT.md`.

| Steg | Innehåll | Läge |
|---|---|---|
| 1 | Skelett: subkommandon, config, logging, tvånivålås, `--dry-run`/`--json` | ✅ |
| 2 | Preflight (vmid, ZFS-utrymme, rclone, bind-mount-detektering) | ✅ |
| 3 | backup: vzdump + sha256 + strukturkontroll + meta.json | ✅ |
| 3b | realtidslogg av subprocess-output | ✅ |
| 4 | uppladdning + verifiering (crypt→cryptcheck) | ✅ |
| 5 | list + fetch | ✅ |
| 6 | restore (nytt vmid, unprivileged-flagga) | ✅ |
| 7 | prune (cache+offsite, skyddar senaste) | ✅ |
| 8 | test-restore + ntfy-notiser | ✅ |
| 9 | systemd timer + `run-schedule` + `status` | ✅ (units ej enablade) |
| 10 | PVE dir-storage för cachen | ✅ |
| 11 | FastAPI (tunt skal runt CLI:t) | ⏸ parkerad (CLI räcker) |
| 12 | ExtJS-frontend (proxmox-widget-toolkit) | ⏸ parkerad |
| 13 | Auth (Proxmox ticket) + audit | ⏸ parkerad |
| 14 | install.sh + RUNBOOK.md | ✅ |

## Snabbstart (isolerad dev)

```bash
# Inga riktiga operationer — enbart skelett/lås/config testas.
LXCO_CONFIG=$PWD/etc/config.dev ./lxc-offsite --json status
LXCO_CONFIG=$PWD/etc/config.dev ./lxc-offsite backup 9001   # not_implemented + lås
bash tests/run.sh
```

## Licens

AGPL-3.0-or-later. Se `LICENSE`. Nätverksklausulen gäller: används webb-GUI:t
över nät utlöses källkodsskyldigheten. Det är avsiktligt.
