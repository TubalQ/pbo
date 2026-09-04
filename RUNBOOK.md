# RUNBOOK — lxc-offsite

Driftmanual. Offsite-backup av Proxmox-LXC:er till Hetzner Storage Box, krypterat
(rclone crypt över sftp). Kör **på hosten** som root. PBS på 10.10.2.133 är
orörd; detta är **offsite-armen** (tredje kopian i 3-2-1).

> Bärande regel: verifiera lokalt **före** upload, verifiera offsite **före** prune.
> Ett arkiv som aldrig verifierats är inte en backup.

## Installation (även på en ny host vid DR)

```bash
git clone https://git.midvault.se/ai-pvet440/lxc-offsite && cd lxc-offsite
./install.sh                      # installerar tool + units (enablar ej timern)
```
Sedan: redigera `/etc/lxc-offsite/config`, lägg `/etc/lxc-offsite/rclone.conf`
(0600), skapa cache-dataset. Se `install.sh`-utskriften.

## Konfiguration — en fil

Allt drift-beteende i **`/etc/lxc-offsite/config`** (KEY=VALUE):
- `BACKUP_ORDER` — vilka vmid:er, i vilken ordning (kritiska först).
- `KEEP_LOCAL`, `KEEP_OFFSITE_{DAILY,WEEKLY,MONTHLY}` — retention.
- `VZDUMP_MODE` (snapshot). Fuse-CT:er tvingas automatiskt till `stop`.
- `RCLONE_REMOTE`, `REMOTE_PATH`, `OFFSITE_ENABLED`.

Creds (nyckeln): **`/etc/lxc-offsite/rclone.conf`** (sftp-nyckel + crypt-lösen).
Detta är **hela nyckeln** — se "Disaster recovery" nedan.

## Daglig drift

```bash
lxc-offsite status                      # lås + senaste jobb
lxc-offsite backup <vmid>               # en CT: dump→verifiera→upp→verifiera
lxc-offsite --dry-run backup <vmid>     # visa plan, rör inget
lxc-offsite list [vmid]                 # offsite-inventarium
lxc-offsite run-schedule                # hela BACKUP_ORDER (det timern kör)
lxc-offsite prune --dry-run             # visa vad retention skulle radera
lxc-offsite test-restore <vmid>         # offsite→restore→boot→destroy (bevis)
```

Schema (dagligen 03:30):
```bash
systemctl enable --now lxc-offsite.timer
systemctl list-timers lxc-offsite.timer
journalctl -u lxc-offsite.service -f
```

## Återställning MED verktyget

```bash
lxc-offsite list <vmid>                              # hitta tidsstämpel
lxc-offsite restore <vmid> <ts> --to <nytt-vmid> --storage <pool> --yes
```
Restore går ALLTID till ett nytt vmid. `unprivileged` läses ur arkivet.
**Bind-mounts finns inte i arkivet** — återskapa manuellt från `<arkiv>.conf`:
```bash
pct set <nytt-vmid> --mp0 /host/path,mp=/data
```

## Disaster recovery UTAN verktyget (om scriptet är trasigt/borta)

Allt du behöver är **`rclone` + `rclone.conf` (nyckeln) + `pct`**:

```bash
export RCLONE_CONFIG=/etc/lxc-offsite/rclone.conf
rclone lsf hetzner-crypt:lxc                          # vilka vmid finns offsite
rclone lsf hetzner-crypt:lxc/<vmid>                   # vilka arkiv
mkdir -p /var/tmp/dr && cd /var/tmp/dr
rclone copy hetzner-crypt:lxc/<vmid> . --include "vzdump-lxc-<vmid>-<ts>*"
sha256sum -c vzdump-lxc-<vmid>-<ts>.tar.zst.sha256    # verifiera
pct restore <nytt-vmid> vzdump-lxc-<vmid>-<ts>.tar.zst --storage <pool> --unprivileged <0|1>
```
`unprivileged`-värdet och ev. bind-mounts står i `<arkiv>.conf`.

> **Nyckeln är single point of failure.** Med `filename_encryption=standard` kan du
> inte ens lista arkiven utan `rclone.conf`. Förvara crypt-lösenorden i Vaultwarden
> **och** offline (papper/USB) utanför huset. Testa DR från en ren maskin minst en gång.

## Gotchas / felsökning

- **Fuse-CT fryser vid backup** — ska inte hända: verktyget tvingar `--mode stop`
  för `features fuse=1` (111/114/116/122). Om en fryser ändå: döda den fastnade
  `vzdump`/`rsync`-processen (`request_wait_answer`), containern återupptas.
- **`md5sum`-fel som ser ut som korruption** = rate limiting. `RCLONE_TRANSFERS`
  + `RCLONE_CHECKERS` måste summera < 10 (Hetzners anslutningsgräns).
- **`invalid`/tomt vid list** — kolla att `rclone.conf` finns och `RCLONE_CONFIG`
  pekar rätt (`export RCLONE_CONFIG=/etc/lxc-offsite/config`... nej: `.../rclone.conf`).
- **prune raderar inget** — den skyddar alltid senaste per vmid och hoppar vmid
  utan verifierad sha256. Det är avsiktligt.
- **Storage Box-snapshots** — SFTP ger ingen append-only. En komprometterad host
  kan radera offsite. **Slå på Hetzners schemalagda snapshots** i konsolen — det är
  enda ransomware-skyddet.

## Var saker bor

| | |
|---|---|
| Program | `/usr/local/lib/lxc-offsite/` (symlänk `/usr/local/sbin/lxc-offsite`) |
| Config | `/etc/lxc-offsite/config` |
| Creds (nyckel) | `/etc/lxc-offsite/rclone.conf` (0600) |
| Cache | ZFS-dataset på `/var/cache/lxc-offsite` (PVE-storage `lxc-offsite-cache`) |
| Loggar/jobb | `/var/log/lxc-offsite/` · `/var/lib/lxc-offsite/jobs/` |
| Recept (SSOT) | `git.midvault.se/ai-pvet440/lxc-offsite` |
