# Implementationsprompt — lxc-offsite

Klistra in nedanstående i Claude Code i en tom repo-katalog.
Bifoga `PLAN.md` i samma katalog innan du kör.

---

Du ska bygga `lxc-offsite` från grunden — ett nytt produktionsverktyg för
Proxmox VE som tar vzdump-arkiv av LXC-containrar, skeppar dem till Hetzner
Storage Box via rclone över SFTP, och kan hämta tillbaka dem för återställning.
Med webbgränssnitt i PBS-stil.

Detta är inte ett script. Det är ett verktyg som ska gå att lita på i
produktion och felsöka klockan tre på natten av någon som inte skrev det.

`PLAN.md` i repot är kravspecifikationen och `RESEARCH.md` är underlaget bakom
den. Läs båda först och följ dem. Avvik bara om något är tekniskt felaktigt —
och säg då till istället för att tyst göra något annat.

**Ärv ingen befintlig kodbas.** `RESEARCH.md` går igenom kandidaterna och
underkänner dem alla — de saknar verifiering, offsite-retention eller båda. Läs
avsnitt 1 så att du vet vilka misstag som inte ska upprepas, men importera
ingenting.

## Miljö

- Proxmox VE, kluster `midvault`, två noder
- ZFS-pooler: `nvmepool` (NVMe mirror), `newbulk` (raidz2)
- Enbart LXC-containrar, inga VM:ar
- Befintlig PBS på 10.10.2.133 — **rör den inte**, detta är ett separat lager
- Befintlig ntfy för notiser
- Offsite: Hetzner Storage Box, SFTP port 23, via rclone crypt
- Befintlig Traefik i **egen dedikerad VM** — förutsätt aldrig att den delar VM
- Befintlig Pocket-ID som OIDC-provider

## Språk och stil

- CLI: Bash, `#!/usr/bin/env bash`, `set -Eeuo pipefail`
- API: Python 3 + FastAPI, i egen venv under `/opt/lxc-offsite`
- Frontend: ExtJS + `proxmox-widget-toolkit` från `/usr/share/javascript/`
- Projektet licensieras **AGPL-3.0**, LICENSE-fil i repo-roten från commit ett
- Inga externa beroenden utöver: `rclone`, `vzdump`, `pct`, `zstd`, `jq`,
  `sha256sum`, `flock`, `curl`, `systemd`
- Varje funktion som kan misslyckas returnerar en meningsfull exit-kod
- All output loggas till både stdout och `/var/log/lxc-offsite/lxc-offsite.log`
  med tidsstämpel och nivå (INFO/WARN/ERROR)
- Inga `echo` för fel — använd en `log_error`-funktion som även triggar notis
- Kommentarer på svenska, kod och variabelnamn på engelska

## Bygg i denna ordning

Bygg och testa ett steg i taget. Stanna och redovisa efter varje steg innan du
går vidare.

**Steg 1 — skelett och konfiguration.** Argumentparsning, subkommandon,
konfigläsning från `/etc/lxc-offsite/config`, logging, låshantering,
`--dry-run` och `--json` globalt.

Låsningen är två nivåer och måste sitta rätt från början: ett **globalt** lås som
släpper igenom en backup/push åt gången oavsett vmid, och ett **per-vmid**-lås
mot dubbelköning. Schemalagda körningar köar på det globala låset med timeout;
manuella avslutar direkt med besked om vad som blockerar. `fetch` och `restore`
tar aldrig det globala låset. Inga riktiga operationer än. Alla subkommandon
ska svara med "not implemented".

`--json` är inte valfritt och inte något som läggs till sist. GUI:t konsumerar
enbart den outputen, så varje subkommando måste ha den från början.

**Steg 2 — preflight.** Innan någon backup:
- containern finns (`pct config <vmid>`)
- ZFS-poolen har ≥ 1,5 × containerns använda storlek fritt
- cache-katalogen finns och är skrivbar
- rclone-remote svarar (`rclone about`)
- parsning av `/etc/pve/lxc/<vmid>.conf`: identifiera bind-mounts och
  `backup=0`-volymer, logga WARN per fynd, skriv in dem i meta-filen

**Steg 3 — backup.** `vzdump --mode snapshot --compress zstd`, sedan sha256,
sedan `zstd -t` + `tar -tf > /dev/null` som strukturkontroll, sedan meta.json.
Ingen uppladdning än.

**Steg 3b — realtidslogg.** Innan uppladdningen byggs: en funktion som strömmar
subprocess-output rad för rad med progressiva tidsstämplar till både logg och
jobbfil. Utan detta ser en 40-minuters rclone-överföring ut som en hängd process,
och då kommer någon att döda den mitt i. Cirka trettio rader, men den avgör om
verktyget känns tillförlitligt eller inte.

**Steg 4 — uppladdning och verifiering.** `rclone copy` med
`--transfers`/`--checkers` från config, aldrig `--inplace`. Efter uppladdning:
`rclone check --checksum` mellan cache och offsite. Misslyckas den, radera det
uppladdade objektet och avbryt med fel.

**Steg 5 — list och fetch.** `rclone lsjson` parsas med `jq` till en läsbar
tabell (vmid, tidsstämpel, storlek, ålder). `fetch` hämtar ett valt arkiv till
`$CACHE_DIR/restore/` och verifierar sha256 mot sidecar-filen.

**Steg 6 — restore.** `pct restore` till ett **nytt** vmid. Läs `unprivileged`
ur arkivets config och sätt flaggan explicit. Vägra köra om mål-vmid redan
existerar. Kräv `--yes` för att faktiskt köra; utan den, skriv ut kommandot
som skulle körts.

**Steg 7 — prune.** Separat policy för cache och offsite enligt config.
Måste stödja `--dry-run`. Måste vägra radera det senaste arkivet per vmid
oavsett vad policyn säger. Radera aldrig något offsite som inte har en
verifierad hash.

**Steg 8 — test-restore.** Full kedja: hämta från offsite (inte cache),
verifiera, restore till engångs-vmid i intervallet 9000–9099, starta, vänta på
att containern svarar, stoppa, destroy. Rapportera resultat via ntfy.

**Steg 9 — systemd och schemaläggning.** **En** timer, inte en mall per
container: `lxc-offsite.timer` + `lxc-offsite.service` som kör
`lxc-offsite run-schedule`. Det subkommandot betar av `BACKUP_ORDER`
sekventiellt, en container i taget. `Type=oneshot`,
`TimeoutStartSec=infinity`, `OnFailure=` som notifierar. Ingen
`RandomizedDelaySec` — körningen är ändå sekventiell och starttiden ska vara
förutsägbar.

Implementera även `lxc-offsite status`: pågående jobb, kölängd, och vilken vmid
som håller globala låset.

**Steg 10 — PVE-storage för cachen.** Registrera cachen som directory storage
med `pvesm add dir ... --content backup --is_mountpoint 1`. Verifiera att arkiv
dyker upp i PVE:s egna backupvy och att restore går att köra därifrån.
`is_mountpoint 1` är obligatoriskt — utan den skriver PVE till rootfilsystemet
om monteringen fallerar.

**Steg 11 — API.** FastAPI som enbart anropar CLI:t med `--json`. Ingen
affärslogik i API-lagret. Långkörande operationer startas som transienta
systemd-units via `systemd-run` och returnerar jobb-ID direkt; ingen endpoint
blockerar på en rclone-överföring. Loggar strömmas via en `/jobs/<id>/log`-endpoint.
Kör som dedikerad icke-root-användare med en sudoers-fil med fullständiga
sökvägar och inga wildcards. Bind till nodens LAN-adress, aldrig 0.0.0.0.

**Steg 12 — frontend.** ExtJS mot `proxmox-widget-toolkit`. Vyerna enligt
PLAN.md sektion 7: Dashboard, Offsite-arkiv, Lokal cache, Jobb, Konfiguration.
Använd toolkitens egna grid-, tasklog- och formulärkomponenter så att resultatet
blir identiskt med PBS, inte ungefär likt. Patcha aldrig PVE:s egna filer och
lägg inte in någon apt-hook.

**Steg 13 — auth och audit.** Pocket-ID via Traefik forward-auth. Destruktiva
åtgärder kräver att användaren skriver in vmid manuellt som bekräftelse. Allt
sådant loggas i `/var/log/lxc-offsite/audit.log` med OIDC-subjekt, tidsstämpel
och parametrar. Hookscript-sökvägen visas skrivskyddad — den kräver root@pam och
får aldrig vara redigerbar via webben.

**Steg 14 — installer och runbook.** `install.sh` som lägger filer på plats med
rätt ägare och rättigheter (config och rclone.conf `0600 root:root`). En
`RUNBOOK.md` som dokumenterar manuell återställning **utan verktyget** — enbart
med `rclone` och `pct` — steg för steg.

## Hårda krav

- Det senaste arkivet per vmid får aldrig raderas av prune
- Uppladdning som avbryts får inte lämna ett synligt halvt arkiv offsite
- `restore` skriver aldrig över ett existerande vmid
- Verifiering sker på checksumma, aldrig på storlek eller modtime
- Notiser skickas vid fel; framgång är tyst om inte `NTFY_ON_SUCCESS=true`
- Dashboarden varnar om Storage Box-snapshots inte kan bekräftas vara aktiva —
  de är det enda ransomware-skyddet i denna arkitektur
- Inga hemligheter i loggar, felmeddelanden eller `set -x`-output
- Aldrig två `vzdump` samtidigt — det globala låset är ett hårt krav, inte en
  optimering. Två parallella dumpar mot raidz2 straffar körande containrar
- Schemalagd körning som blockeras **köar**; manuell avslutar med besked
- GUI och CLI måste alltid visa samma siffror — GUI:t äger ingen egen sanning
- Ingen endpoint blockerar på en nätverksöverföring
- Allt i GUI:t går att göra från CLI:t med API-tjänsten stoppad
- Hookscriptet villkorar på VMID; `backup-abort` är felsignalen, inte `backup-end`

## Testning

Skriv `tests/` med bats eller ren bash. Minst:
- preflight avvisar för lite ZFS-utrymme
- bind-mount ger WARN och hamnar i meta.json
- prune med dry-run rör ingenting
- prune vägrar radera sista arkivet
- globalt lås hindrar två samtidiga backuper av *olika* vmid
- per-vmid-lås hindrar dubbelköning av *samma* vmid
- schemalagd körning köar vid upptaget lås, manuell avslutar
- `fetch` går att köra medan en backup pågår
- korrupt sidecar-hash gör att fetch misslyckas

Mocka `rclone`, `vzdump` och `pct` i testerna. Kör inte mot riktig hårdvara.

## Vad du inte ska göra

- Inte röra PBS-konfigurationen på 10.10.2.133
- Inte anta att Traefik delar VM med något annat
- Inte lägga till funktioner som inte står i PLAN.md
- Inte byta ut vzdump-arkiv mot borg, restic eller egen chunk-lagring — det
  beslutet är fattat och motiverat i PLAN.md avsnitt 1
- Inte förlita dig på borg append-only som skydd; det fungerar inte på Storage Box
- Inte skriva `rclone sync` någonstans — bara `copy`, `check`, `lsjson`,
  `delete` på explicit angivna sökvägar
- Inte rclone-montera offsite som PVE-storage — offsite nås bara via explicita
  `rclone copy`-anrop
- Inte patcha pve-manager eller widget-toolkit, och inte installera apt-hooks
- Inte lägga affärslogik i API-lagret
- Inte hårdkoda vmid, hostnamn eller sökvägar

Börja med steg 1. Redovisa och vänta på klartecken innan steg 2.
