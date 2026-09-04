# Förstudie — finns det något att bygga vidare på?

**Kort svar: nej.** Genomgången nedan är ett negativt resultat. Den bekräftar att
ett nytt verktyg är rätt beslut, och kartlägger vad de befintliga försöken
misslyckas med så att vi inte upprepar det.

Verifierat mot källor, inte minne.

---

## 1. Befintliga projekt

### proxmox-vzbackup-rclone (TheRealAlexV)

Hookscript som backar upp VM:ar, containrar och PVE-konfigurationer till
fjärrlagring med native vzdump plus rclone. Arkiven organiseras i
`ÅR/MÅNAD/DAG`-kataloger, och det finns ett medföljande script för att hämta
gamla arkiv från fjärrlagringen så att de kan återställas som vanligt.

**Varför det inte duger:** Scriptet **prunar inte fjärrlagringen** — det säger
uttryckligen att den hanteringen får du lösa separat. Ingen verifiering av att
det uppladdade går att läsa tillbaka, ingen jobbhantering, inget gränssnitt,
ingen statusrapportering. Det är ett fungerande hookscript, inte ett verktyg.

Retention och verifiering är precis de två delar som är farligast att göra fel,
och de saknas båda. Att bygga vidare på detta vore att ärva ett skelett utan de
organ som gör skillnad.

### proxmox-grapple (lingfish)

Python-ersättare för `vzdump-hook-script.pl` med elva backupfaser (`job-init`,
`job-start`, `job-end`, `job-abort`, `backup-start`, `backup-end`,
`backup-abort`, `log-end`, `pre-stop`, `pre-restart`, `post-restart`),
YAML-konfiguration med stöd för flera miljöer, två körlägen, och realtidsloggning
av subprocess-output med progressiva tidsstämplar — uttalat lämpligt för
långkörande processer som just rclone.

**Varför det inte duger:** Det är en generisk hook-runner, inte ett
backupverktyg. Det kör kommandon åt dig vid rätt tidpunkt och slutar där — ingen
kunskap om arkiv, offsite, verifiering eller återställning. Dess
`extract`-funktion är dessutom enligt författaren otestad proof-of-concept.

**Vad vi tar med oss som lärdom, inte som beroende:** realtidsloggning av
subprocess-output med progressiva tidsstämplar. Utan det ser en 40-minuters
rclone-uppladdning ut som en hängd process. Vi implementerar samma sak själva —
det är trettio rader, inte ett beroende värt att ärva.

### Övrigt granskat

`DerDanilo/proxmox-stuff` säkrar host-konfiguration, inte gästbackuper. Diverse
Borg-webbgränssnitt hanterar Borg-repon, inte vzdump-arkiv och `pct restore` —
de vet ingenting om Proxmox.

**Inget projekt hittades som gör vzdump → offsite → hämta tillbaka med
verifiering, retentionhantering och gränssnitt.** Slutsatsen är att verktyget
byggs från grunden. Ingen av kandidaterna ovan blir ett beroende.

---

## 2. Det stora fyndet: PVE:s egen GUI gör redan halva jobbet

En directory storage med `content backup` ger native i PVE-gränssnittet:
arkivlista, datum, storlek, restore-knapp, `prune-backups keep-last=N`,
`max-protected-backups`, samt `content-dirs` för att peka backupkatalogen till
en egen underväg.

Det betyder: **gör den lokala cachen till en riktig PVE directory storage**, så
får du listning, datum, storlekar och restore-knapp gratis, i ett gränssnitt som
inte bara liknar PBS utan *är* Proxmox.

Vårt egna GUI behöver då bara täcka det PVE inte kan: offsite-inventarium,
push, fetch, verifieringsstatus och konfiguration.

### `is_mountpoint` är obligatoriskt

Sätt `is_mountpoint 1` på storage. Utan den skriver PVE backuper till
rootfilsystemet om monteringen misslyckas — dokumenterat sätt att fylla
systemdisken utan förvarning.

```bash
pvesm add dir lxc-offsite-cache \
  --path /var/cache/lxc-offsite \
  --content backup \
  --is_mountpoint 1 \
  --shared 0
```

### Varför vi ändå INTE rclone-monterar offsite som PVE-storage

Det *fungerar* — det finns rapporter om att backup och restore går igenom
PVE-GUI:t mot en rclone-monterad molnlagring, med `--vfs-cache-mode full`. Men
invändningarna är befogade: om den fjärrmonterade lagringen blir otillgänglig får
du problem både vid boot och vid schemalagda backuper, och att installera rclone
och montera moln på hypervisorn räknas som en större ingrepp i host-miljön.

Vår design undviker detta: **rclone rör aldrig ett PVE-monterat filsystem.**
Offsite nås enbart via explicita `rclone copy`-anrop. PVE känner bara till den
lokala cachen, som alltid finns.

---

## 3. GUI-teknik: vad "efterlikna PBS" faktiskt kräver

PBS och PVE bygger båda på ExtJS plus `proxmox-widget-toolkit`, som beskriver sig
som basramverket med widgets, modeller och verktyg för Proxmox ExtJS-baserade
webbgränssnitt. Det ligger redan på disk under
`/usr/share/javascript/proxmox-widget-toolkit/`, och ExtJS finns i paketet
`libjs-extjs`.

Vi kan alltså använda exakt samma widgets som PBS. Utseendet blir inte "likt" —
det blir identiskt.

### Licensfällan, som är verklig

`proxmox-widget-toolkit` är **AGPL-3.0+**. ExtJS är svårare: Sencha släppte
version 7.0 som sista GPLv3-utgåva, och villkoren är explicita — du måste släppa
källkoden fritt och licensiera din applikation under GPLv3, och du kan inte
konvertera till kommersiell licens senare genom att köpa en.

Praktisk konsekvens:

| Scenario | Konsekvens |
|---|---|
| Enbart internt bruk, ingen distribution | Inga skyldigheter utlöses |
| Publiceras på ditt Gitea, publikt | Måste AGPL-3.0-licenseras, källkod fritt tillgänglig |
| Kommersialiseras | Inte möjligt utan att byta ut hela frontend-stacken |

AGPL:s nätverksklausul är den skarpa: för ett **webbgränssnitt** räcker det att
någon annan använder det över nätet för att källkodsskyldigheten ska aktiveras.

Rekommendation: bygg med widget-toolkit, licensiera projektet AGPL-3.0 från dag
ett. Det är ändå rätt licens för ett verktyg som detta, och det tar bort frågan.

### Ingen plugin-API finns för PVE:s webbgränssnitt

Man kan inte lägga till en flik i PVE-GUI:t på ett stödt sätt.
Communityprojekt som ändrar Proxmox-gränssnittet patchar filerna och använder en
apt-hook för att patcha om automatiskt efter uppdateringar av widget-toolkit,
pve-manager eller proxmox-backup-server.

**Gör inte det.** En apt-hook som patchar hypervisorns GUI vid varje uppdatering
är precis den sortens ingrepp som gör en produktionsmiljö oreparerbar. Vårt GUI
körs som en **fristående applikation på egen port**, som återanvänder
widget-toolkit men aldrig modifierar PVE:s egna filer.

---

## 4. Hookscript-mekaniken, verifierad

Faserna är `job-start`/`-end`/`-abort` för hela jobbet, `backup-start`/`-end`/
`-abort` per gäst, `pre-stop`/`pre-restart`/`post-restart` för gästen, samt
`log-end`. Fasen skickas som **argument** till scriptet, och miljövariabler som
`DUMPDIR`, `STOREID`, `TARGET` och `VMID` sätts av vzdump.

Tre fällor:

**Scriptet anropas av alla backupjobb.** Det går inte att sätta ett hookscript
för ett enskilt jobb — du måste villkora inne i scriptet på VMID, gästtyp,
målstorage eller nod.

**Bara root@pam får sätta det.** Parametern går inte att sätta för
oprivilegierade användare eftersom den tillåter körning av godtycklig kod. Vårt
GUI kan alltså aldrig låta en icke-root-användare ändra hookscript-sökvägen.

**`backup-end` betyder inte "lyckades".** Det finns ingen statusvariabel; du
måste behandla `backup-abort` som felsignal och inte anta framgång.

---

## 5. Bind-mounts — bekräftad och allvarligare än väntat

`backup`-flaggan gäller **endast reguljära volym-mountpoints**. Bind-mountpoints
innehåller godtyckliga host-sökvägar och är därför begränsade till root, och kan
inte läggas till på annat sätt än manuellt. Efter en restore måste de återskapas
för hand med `pct set` eller i en editor — **det går inte via GUI:t**.

Dessutom: sätter du `backup`-flaggan på en vanlig mountpoint återställs allt till
en enda katalog vid restore, vilket kan behöva rättas manuellt efteråt.

Konsekvens för vårt verktyg: vid backup ska bind-mounts flaggas som varning, och
den ursprungliga container-konfigurationen ska sparas som separat sidecar-fil
offsite, så att den som återställer kan se exakt vilka mountpoints som saknas.

---

## 6. Sammanfattad rekommendation

| Lager | Beslut |
|---|---|
| Kodbas | Nytt verktyg från grunden, inga arvda beroenden |
| Backupartefakt | Native `vzdump`, `--mode snapshot` |
| Lokal cache | PVE directory storage, `is_mountpoint 1` → gratis native GUI |
| Transport | `rclone copy` mot Hetzner SFTP, aldrig som monterat filsystem |
| Eget GUI | Fristående, ExtJS + `proxmox-widget-toolkit`, egen port |
| Ransomware-skydd | Storage Box snapshots — **inte** borg append-only |
| Licens | AGPL-3.0 från start |
| PVE-GUI-patchning | Nej |

---

## 7. Append-only på Hetzner håller inte

Detta undersöktes som alternativ till full-kopia-modellen och underkändes.

Hetzners dokumentation säger att Borg kan köras i append-only-läge som bara
tillåter nya arkiv och nekar radering av gamla — men noterar i samma andetag att
en begränsad klient ändå kan utföra arkivraderingar.

Borgs manual bekräftar varför: `--append-only` påverkar bara repots lågnivåstruktur,
och `delete` och `prune` tillåts fortfarande köras.

Det riktiga skyddet är serversidigt, via `command="borg serve --append-only"` i
`authorized_keys`. Men Storage Box erbjuder inget riktigt skal — miljön beskrivs
som starkt begränsad, och de restriktiva SSH-kommandona fungerar inte där.

**Därför:** Storage Box egna schemalagda snapshots är det enda som faktiskt
skyddar mot en komprometterad Proxmox-host. Det är ett krav i denna design, inte
en rekommendation. Utan dem kan en angripare med host-access radera hela
offsite-kopian, och då har vi byggt en kopia med extra steg.
