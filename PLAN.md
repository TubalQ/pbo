# lxc-offsite — plan

Nytt verktyg, byggt från grunden. Tar en lokal, verifierad `vzdump`-arkivfil av
en LXC, skeppar den till offsite via SFTP, och kan hämta tillbaka den till lokal
cache för återställning. Med gränssnitt i PBS-stil.

`RESEARCH.md` visar varför inget befintligt projekt duger som grund: de som
finns saknar verifiering, offsite-retention eller båda. Vi ärver ingen kodbas.

**Designprincip:** verktyget ska gå att felsöka klockan tre på natten av någon
som inte skrev det. Varje beslut nedan där enkelhet vinner över effektivitet är
medvetet.

Målmiljö: Proxmox VE, kluster `midvault`, ZFS-pooler `nvmepool` / `newbulk`.
Offsite: Hetzner Storage Box (SFTP, port 23) via rclone.

---

## 1. Varför vzdump och inte PBS

| | PBS-datastore | vzdump-arkiv |
|---|---|---|
| Artefakt | chunk-store, tusentals objekt | **en fil** per snapshot |
| Kräver hardlinks | ja | nej |
| Kräver random access | ja | nej |
| Fungerar över SFTP | **nej** | **ja** |
| Dedup mellan körningar | ja | nej |

PBS på 10.10.2.133 blir kvar orörd som primärt lokalt lager (snabb restore, dedup).
Detta verktyg är den **offsite-armen** — tredje kopian i 3-2-1. De konkurrerar inte.

Priset för SFTP-vägen: ingen dedup mellan körningar. Varje offsite-arkiv är fullt.

Detta är den enda avvägningen i hela designen som är värd att ifrågasätta, så den
förtjänar att skrivas ut. Alternativet vore ett Borg-repo över port 23, som ger
dedup och komprimering. Det underkändes av tre skäl:

1. Dedup mot ett redan zstd-komprimerat arkiv är i praktiken noll — komprimering
   förstör chunk-likheten mellan versioner. För att få nytta av Borg måste man
   dumpa okomprimerat, vilket kräver betydligt mer lokalt utrymme och en extra
   komprimering efteråt för cachen.
2. Återställningsvägen blir ett steg längre och ett steg mer att felsöka.
3. Append-only, det enda Borg skulle ge oss som rclone inte gör, fungerar inte
   pålitligt på Storage Box. Se `RESEARCH.md` avsnitt 7.

En full kopia som alltid går att återställa slår ett deduplicerat repo som kräver
att man förstår chunk-format under press. Kostnaden är diskutrymme, och
diskutrymme på Storage Box är billigt.

---

## 2. Dataflöde

### Backup (lokalt → offsite)

```
LXC (körande)
  │  vzdump --mode snapshot            ZFS-snapshot, ~sekunder frozen
  ▼
/var/cache/lxc-offsite/<vmid>/
  vzdump-lxc-<vmid>-<ts>.tar.zst       artefakten
  vzdump-lxc-<vmid>-<ts>.tar.zst.sha256
  vzdump-lxc-<vmid>-<ts>.meta.json     vmid, hostname, storage, size, pve-version
  │
  │  1. sha256 beräknas lokalt
  │  2. tar-integritet testas (zstd -t + tar -tf)
  │  3. rclone copy → offsite (crypt över sftp)
  │  4. rclone check --checksum mot offsite
  ▼
offsite:lxc/<vmid>/...
```

Ordningen är inte förhandlingsbar: **verifiera lokalt innan uppladdning**, och
**verifiera på offsite innan lokal prune**. Ett arkiv som aldrig verifierats
är inte en backup.

### Restore (offsite → cache → LXC)

```
offsite:lxc/<vmid>/
  │  rclone lsjson              lista tillgängliga arkiv
  │  rclone copy → cache        endast det valda arkivet
  ▼
/var/cache/lxc-offsite/restore/
  │  sha256 -c                  mot sidecar-filen
  │  zstd -t                    strukturkontroll
  ▼
pct restore <nytt-vmid> <arkiv> --storage <pool> --unprivileged <0|1>
```

Återställ **alltid till ett nytt vmid** som standard. Att skriva över en körande
container från ett script är hur man förlorar produktionsdata.

---

## 3. Komponenter

```
/usr/local/lib/lxc-offsite/
  lxc-offsite            huvudscript (bash, set -Eeuo pipefail)
  lib/backup.sh
  lib/restore.sh
  lib/verify.sh
  lib/notify.sh          ntfy
  api/                   FastAPI-app, tunt skal runt CLI:t
  web/                   statisk frontend, inget byggsteg
/etc/lxc-offsite/
  config                 KEY=VALUE, chmod 600
  rclone.conf            chmod 600, root:root
  api.env                bind-adress, OIDC-inställningar, chmod 600
/var/cache/lxc-offsite/  ZFS-dataset, egen quota
/var/log/lxc-offsite/
  lxc-offsite.log
  audit.log              vem gjorde vad via GUI:t
/var/lib/lxc-offsite/
  state.json
  jobs/                  en fil per asynkront jobb
```

Subkommandon:

| Kommando | Gör |
|---|---|
| `backup <vmid>` | dump → verifiera → ladda upp → verifiera → prune, en container |
| `run-schedule` | kör `backup` för varje vmid i `BACKUP_ORDER`, sekventiellt |
| `status` | visar pågående jobb, kölängd och vad som håller globala låset |
| `list [vmid]` | listar offsite-arkiv med storlek och datum |
| `fetch <vmid> <ts>` | hämtar ett arkiv till cache, verifierar |
| `restore <vmid> <ts> --to <nytt-vmid>` | fetch + `pct restore` |
| `verify <vmid>` | jämför lokala och offsite-hashar |
| `prune` | städar cache och offsite enligt policy |
| `test-restore <vmid>` | full restore till engångs-vmid, boot, sedan destroy |

---

## 4. Konfiguration

```ini
# /etc/lxc-offsite/config
CACHE_DIR=/var/cache/lxc-offsite
RCLONE_REMOTE=hetzner-crypt
REMOTE_PATH=lxc
VZDUMP_MODE=snapshot
VZDUMP_COMPRESS=zstd
VZDUMP_ZSTD_THREADS=4
RCLONE_TRANSFERS=4
RCLONE_CHECKERS=4          # < 8, Hetzner-gräns är 10 anslutningar
RCLONE_BWLIMIT=            # t.ex. "40M" nattetid
BACKUP_ORDER=104,105,103        # ordning för run-schedule, en i taget
GLOBAL_LOCK_TIMEOUT=7200        # sekunder en schemalagd körning väntar i kön
KEEP_LOCAL=2
KEEP_OFFSITE_DAILY=7
KEEP_OFFSITE_WEEKLY=4
KEEP_OFFSITE_MONTHLY=6
NTFY_URL=https://ntfy.example/lxc-offsite
NTFY_ON_SUCCESS=false      # larma på fel, inte på framgång
```

rclone-remote, best practice för Hetzner Storage Box:

```ini
# /etc/lxc-offsite/rclone.conf
[hetzner]
type = sftp
host = uXXXXX.your-storagebox.de
user = uXXXXX
port = 23
key_file = /etc/lxc-offsite/id_ed25519
shell_type = unix
md5sum_command = md5sum
sha1sum_command = sha1sum

[hetzner-crypt]
type = crypt
remote = hetzner:lxc-offsite
filename_encryption = standard
directory_name_encryption = true
password = <rclone obscure>
password2 = <rclone obscure>
```

`md5sum_command` / `sha1sum_command` sätts explicit — Storage Box har dem i sin
begränsade SSH-miljö, men rclone hittar dem inte alltid via autodetektering.
Utan dem faller `rclone check --checksum` tillbaka på storleksjämförelse, vilket
inte är verifiering.

---

## 5. Retention

Lokal cache är just en cache — kort och liten:

- **Lokalt:** 2 senaste arkiven per vmid. Räcker för snabb rollback, håller
  datasetet litet.
- **Offsite:** 7 dagliga, 4 veckovisa, 6 månatliga.

**Storage Box-snapshots ska vara aktiverade och schemalagda i Hetzner-konsolen.**
Detta är inte valfritt. SFTP ger ingen append-only, och borgs append-only är inte
pålitlig på Storage Box, så snapshots är det enda som hindrar en komprometterad
Proxmox-host från att radera hela offsite-kopian. Verktyget ska varna i
dashboarden om det inte kan bekräfta att snapshots är påslagna.

Eftersom vzdump-arkiv inte dedupliceras mot varandra är offsite-storleken
`antal_behållna × arkivstorlek`. Räkna på det innan du sätter policyn.

---

## 6. Fallgropar som måste hanteras i koden

**Bind-mounts backas inte upp.** `vzdump` tar med mountpoints som har `backup=1`.
Bind-mounts (`mp0: /host/path,mp=/data`) kan över huvud taget inte backas upp och
hoppas över **tyst**. Verktyget måste läsa `/etc/pve/lxc/<vmid>.conf`, upptäcka
bind-mounts och `backup=0`-volymer, och skriva ut en explicit varning i loggen och
i meta-filen. En backup som tyst saknar din data är värre än ingen backup.

**Partiella uppladdningar.** rclone laddar upp till temporärt namn och byter namn
vid slutförande — men bara om `--inplace` *inte* används. Sätt aldrig `--inplace`.

**Anslutningsgränsen.** Max 10 samtidiga anslutningar mot Storage Box. `--checkers`
och `--transfers` måste summera under det med marginal, annars får du md5-fel som
ser ut som datakorruption men är rate limiting.

**Crypt-nyckeln är single point of failure.** Med `filename_encryption = standard`
kan du inte ens lista arkiven utan rclone-konfigurationen. Förlorad nyckel = alla
offsite-backuper förlorade. `password` och `password2` ska finnas i Vaultwarden
**och** på papper eller USB utanför huset. Testa återställning från en ren maskin
med enbart nyckeln, minst en gång.

**Offsite är raderbart.** SFTP ger ingen append-only, och borgs append-only-läge
är inget alternativ här — det tillåter fortfarande `delete` och `prune`, och den
serversidiga varianten går inte att sätta upp på Storage Box begränsade skal. En
komprometterad Proxmox-host med rclone-credentials kan alltså radera hela
offsite-katalogen. Enda motmedlet är Storage Box egna schemalagda snapshots.
Utan dem är detta en kopia med extra steg, inte ett ransomware-skydd.

**ZFS-utrymme.** `--mode snapshot` kräver utrymme i poolen. En full pool avbryter
dumpen. Preflight-kontroll: kräv fritt utrymme ≥ 1,5 × containerns använda storlek.

**Överlappande körningar — global serialisering.** Verktyget kör **en LXC i
taget**, aldrig två parallellt. Skälet är I/O: `vzdump --mode snapshot` läser
tungt från poolen samtidigt som ZFS håller en snapshot öppen, och två samtidiga
dumpar mot `newbulk` (raidz2) ger både långsammare backup och märkbart sämre
svarstider för de containrar som körs.

Två lås, inte ett:

- **Globalt lås** (`/var/lock/lxc-offsite.global`) — släpper igenom exakt en
  backup- eller push-operation åt gången, oavsett vmid.
- **Per-vmid-lås** — hindrar att samma container köas två gånger.

Schemalagda körningar **köar** på det globala låset med timeout, de avslutar
inte. Manuella körningar från CLI eller GUI avslutar direkt med tydligt besked om
vad som blockerar och hur länge det pågått. Skillnaden spelar roll: en schemalagd
körning som tyst avslutar blir en backup som aldrig togs.

Fetch och restore tar **inte** det globala låset — de skriver inte från poolen
och ska gå att köra under en pågående backup.

**Klockskillnader.** Synka aldrig på modtime. Alla jämförelser med `--checksum`.

**Unprivileged-flaggan.** `pct restore` måste matcha originalets
`unprivileged`-inställning. Läs den från arkivets config och sätt den explicit
istället för att förlita dig på default.

**Återställning utan verktyget.** Dokumentera i runbooken hur man hämtar och
packar upp ett arkiv med enbart `rclone` och `pct` — om scriptet är trasigt
eller borta ska en människa kunna göra det för hand.

**Bind-mounts går inte att återskapa via GUI.** De innehåller godtyckliga
host-sökvägar och är root-begränsade, så efter restore måste de sättas manuellt
med `pct set`. Spara därför originalets `.conf` som separat sidecar-fil offsite
och visa den i GUI:t vid restore.

**Hookscriptet anropas av alla backupjobb.** Det går inte att koppla till ett
enskilt jobb — villkora på VMID inne i scriptet, annars skickar du oavsiktligt
allt offsite.

**`backup-end` betyder inte framgång.** Ingen statusvariabel finns. Behandla
`backup-abort` som felsignal; anta aldrig att `backup-end` innebär att det gick bra.

**Ingen plugin-API finns för PVE:s webbgränssnitt.** Patcha inte pve-manager
för att lägga in en flik. Fristående app på egen port.

---

## 7. GUI

Se `RESEARCH.md` för underlaget bakom besluten nedan.

### Två gränssnitt, inte ett

Den lokala cachen registreras som en PVE directory storage. Därmed får du
**PVE:s eget backupgränssnitt gratis** för allt som redan finns lokalt: lista,
datum, storlek, restore-knapp, prune-inställningar, skyddade backuper.

```bash
pvesm add dir lxc-offsite-cache \
  --path /var/cache/lxc-offsite \
  --content backup \
  --is_mountpoint 1 \
  --shared 0
```

Vårt egna GUI bygger vi bara för det PVE **inte** kan: offsite-inventariet,
push, fetch, verifieringsstatus och konfiguration. Att duplicera restore-vyn
vore slöseri och skulle dessutom ge två sanningar om vad som finns.

### Teknikval

Fristående webbapplikation på egen port, byggd med ExtJS och
`proxmox-widget-toolkit` från `/usr/share/javascript/`. Samma widgets som PBS
använder, alltså identiskt utseende — inte en efterlikning.

PVE:s egna GUI-filer patchas **aldrig**. Projektet licensieras AGPL-3.0.

### Vyer

**Dashboard.** Per LXC: senaste lyckade offsite-push, antal arkiv offsite,
total storlek, ålder på äldsta och nyaste, verifieringsstatus. Röd rad om
senaste push är äldre än `MAX_AGE_WARN`. Detta är den vy som ska svara på
"är mina backuper i ordning" på tre sekunder.

**Offsite-arkiv.** Grid med vmid, hostname, tidsstämpel, storlek, ålder,
verifierad ja/nej. Kolumnsortering och filter per vmid. Radåtgärder:
*Hämta till cache*, *Verifiera*, *Radera*.

**Lokal cache.** Samma grid för cachen, plus *Pusha till offsite* och
*Radera lokalt*. Länk till PVE:s backupvy för själva återställningen.

**Jobb.** Löpande och historiska jobb med realtidslogg, i samma stil som PBS
tasklog. Varje jobb har status, starttid, varaktighet och full output.

Eftersom verktyget kör en container i taget måste vyn visa **kön**: vad som körs
nu, vad som väntar, och hur länge. Utan det ser en köad backup ut som en backup
som inte händer. Manuell start av en container som redan står i kö ska ge tydligt
besked, inte tyst läggas till igen.

**Konfiguration.** Formulär mot `/etc/lxc-offsite/config`: retentionpolicy per
nivå, bandbreddsgräns, schema, ntfy-URL, cache-quota. Validering innan skrivning,
och konfigurationen versioneras — varje ändring sparas med tidsstämpel och
användare så att en felaktig retentionändring går att spåra och rulla tillbaka.

**Hookscript-sökvägen är inte redigerbar i GUI:t.** Den kräver root@pam eftersom
den tillåter körning av godtycklig kod. Visa den som skrivskyddad text.

### Backend

FastAPI-app som **enbart** anropar samma CLI som allting annat använder, med
`--json`. Ingen affärslogik i API-lagret. Om GUI:t och CLI:t kan ge olika svar
har vi byggt fel.

Långkörande operationer (backup, push, fetch, restore, verify) startas som
transienta systemd-units via `systemd-run --unit=lxc-offsite-job-<id>` och
returnerar direkt ett jobb-ID. GUI:t pollar status. **Ingen HTTP-request får
vänta på en rclone-uppladdning** — det ger timeouts som ser ut som fel men är
det inte.

### Säkerhet

API:t körs som en dedikerad användare, inte root. Exakt de kommandon som behöver
förhöjd behörighet listas i en `sudoers`-fil med fullständiga sökvägar och utan
wildcards.

Autentisering via Pocket-ID (OIDC) genom Traefik forward-auth. API:t binder till
nodens LAN-adress och brandväggen släpper bara igenom Traefik-VM:ens IP.
Lyssna inte på 0.0.0.0.

Destruktiva åtgärder (radera, restore, prune) kräver att användaren skriver in
vmid för hand som bekräftelse, och loggas i `audit.log` med OIDC-subjekt,
tidsstämpel och parametrar.

Om GUI:t inte kan nås ska allt gå att göra från CLI:t. GUI:t är bekvämlighet,
aldrig en förutsättning.

## 8. Schemaläggning

systemd timer, inte cron — ger journal-integration och `OnFailure=` för
notifiering.

**En timer, inte en per container.** En mall-timer per vmid skulle starta flera
jobb samtidigt och göra det globala låset till en kö man inte ser. Istället en
enda timer som startar ett jobb som betar av containrarna i konfigurerad ordning,
sekventiellt.

```ini
# /etc/systemd/system/lxc-offsite.timer
[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
```

```ini
# /etc/systemd/system/lxc-offsite.service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/lxc-offsite/lxc-offsite run-schedule
TimeoutStartSec=infinity
```

`BACKUP_ORDER` i config anger ordningen. Ingen `RandomizedDelaySec` — vi vill ha
förutsägbar starttid när körningen ändå är sekventiell.

03:30 lägger den efter PBS 02:00 så de inte konkurrerar om I/O. Tar hela kön
längre tid än till nästa fönster ska jobbet logga varning, inte hoppa över
resten.

---

## 9. Acceptanskriterier

Verktyget är inte klart förrän:

1. `backup` av en körande LXC ger ett arkiv som verifierar mot sin sha256 både
   lokalt och offsite.
2. Avbruten uppladdning (döda processen mitt i) lämnar inget halvt arkiv synligt
   offsite, och nästa körning lyckas.
3. `test-restore` bootar containern och den svarar, från ett arkiv som hämtats
   från offsite — inte från cachen.
4. Full restore lyckas på en maskin med enbart rclone.conf och crypt-nyckeln.
5. Bind-mounts genererar varning.
6. Fel skickar ntfy-notis; framgång är tyst.
7. `prune` kört med `--dry-run` visar korrekt vad som skulle raderas, och
   `prune` vägrar radera det senaste arkivet oavsett policy.
8. Cachen syns som storage i PVE:s eget backupgränssnitt och restore går att
   köra därifrån.
9. GUI:t visar samma siffror som `lxc-offsite list --json`. Avviker de är det
   ett blockerande fel.
10. En push som tar 40 minuter ger ingen HTTP-timeout och visar löpande logg.
11. API:t körs som icke-root och kan inte köra något utanför sudoers-listan.
12. Varje destruktiv åtgärd via GUI finns i `audit.log` med OIDC-subjekt.
13. Allt i GUI:t går att göra från CLI:t med stoppad API-tjänst.
