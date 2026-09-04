# ADR 0001 — restic som backup-motor (Väg A: vzdump-tar i restic)

- **Status:** Accepterad — 2026-09-04
- **Beslut:** Adoptera **restic** som lxc-offsites lagrings-/transport-/kryptering-/
  verifiering-/retention-motor, i **Väg A** (vzdump-arkiv lagras *i* restic).
  Behåll CLI:ts JSON-envelope och `pct restore`-integrationen — byt motorn, inte kontraktet.
- **Kontext-taggar:** SFTP-only · local-only · web-UI · ingen fjärr-compute

> Denna ADR är SSOT för motorvalet. Recept/config/kod ska referera hit, inte
> duplicera resonemanget. Bevisen nedan kördes mot **restic 0.18.0** (Debian
> trixie/main) i en engångsmiljö den 2026-09-04.

---

## 1. Kontext och problem

lxc-offsite är avsiktligt byggt för folk som **inte** har en maskin att köra PBS
på, men som har en dum **SFTP-box** (Hetzner Storage Box, rsync.net, egen ssh).
Ramarna är fasta: **transport = SFTP**, **drift = local-only på en Proxmox-host,
self-contained, med web-UI**, **ingen fjärr-compute**.

Nuvarande motor: `vzdump → full tar.zst per körning → rclone crypt över sftp`.
Den har ett hårt tak:

- **Alltid full.** Ingen dedup, ingen incremental → bandbredd + lagring växer
  linjärt och sätter ett golv för RPO (hur ofta man kan köra).
- **Ingen bläddring** av innehåll (till skillnad från PBS).
- Mycket **egen kod** för det som är lösta problem: sha256-sidecars, `zstd -t`,
  `tar -tf`, rclone `cryptcheck`, fetch+verify-dansen, egen GFS-prune.

De fyra garantierna som skiljer "near-enterprise" från "cron+rclone" —
**oföränderlighet, bevisad återställbarhet, least-privilege/spårbarhet,
observerbarhet** — kräver dedup/incremental + klient-kryptering + integritet.
På dum SFTP kan chunk-storen bara ligga **klient-sidan**. Det är exakt vad restic
är: content-addressed dedup som skriver **vanliga filer** till valfri SFTP-box.

## 2. Beslut

Adoptera **restic**. Använd **Väg A**: låt `vzdump` fortsätta producera CT-arkivet,
men lagra det (okomprimerat) *i* ett restic-repo i stället för att pusha tar.zst
via rclone. Restore går via `restic restore → pct restore` — **hela
Proxmox-integrationen och sidecar-logiken (unprivileged/storage/bind-mounts)
lämnas orörd.**

### Pipeline (Väg A)

```
preflight (oförändrad)
  → vzdump <id> --mode <m> --compress 0 --dumpdir $CACHE/<id>   # OKOMPRIMERAD tar + .conf/.meta
  → restic -r $CACHE_REPO   backup $CACHE/<id> --tag vmid=<id> --host <nod>   # lokalt (cache-tier)
  → restic -r $OFFSITE_REPO copy   --from-repo $CACHE_REPO                    # → SFTP (offsite)
  → restic -r $OFFSITE_REPO check   [--read-data]                            # verifiering (bakgrund)
retention:
  host:    restic -r $CACHE_REPO forget --keep-daily/weekly/monthly [--prune]   # KEEP_* mappar 1:1
  janitor: restic -r $OFFSITE_REPO forget --prune                               # aldrig från hosten
restore / test-restore:
  → restic -r $OFFSITE_REPO restore <snapshot-id> --target $CACHE/restore
  → pct restore <nytt-vmid> <utläst tar> --storage <pool> --unprivileged <n>   # OFÖRÄNDRAD
```

Offsite-repot initieras med delad chunker för dedup-paritet:
`restic -r $OFFSITE_REPO init --copy-chunker-params --from-repo $CACHE_REPO`.

## 3. Alternativ som övervägdes (och varför inte)

- **Behåll bespoke tar.zst.** Enkelt och revisionsbart, men taket är permanent
  "alltid full, ingen dedup, ingen bläddring". Inte PBS-likt. Avvisat som mål,
  behålls som *coexistence*-spår under migreringen (se §8).
- **Väg B — restic backup av CT:ns utpackade filsystem.** Bäst dedup (fil-nivå,
  PBS-klass) + fil-bläddring. Men restore blir **inte** `pct restore` — man måste
  återuppbygga CT:n själv (idmap/unprivileged-skiftning, xattrs, special-filer).
  Mycket mer invasivt. **Skjuts upp** som framtida optimering, inte v1.
- **S3 Object Lock (B2/Wasabi/MinIO).** Ger äkta WORM, men **bryter SFTP-only-
  intentionen** — det är en annan produkt. Avvisat.
- **PBS som backend.** "Riktig" PBS-dedup, men kräver en maskin/tjänst att köra
  PBS på → **bryter local-only / ingen-extra-maskin**, hela existensberättigandet.
  Avvisat.

## 4. Bevis (restic 0.18.0, mot vår egen flöde)

| Vad | Resultat |
|---|---|
| Dedup/incremental | Radändring i 9.5 MiB → **9.8 KiB lagrat**; repo växer inte per körning |
| Cache→offsite | `restic copy` (chunker-delad) → dedup bevarad mellan tiers |
| Offsite = dumt lager | repo = vanliga filer (`config data index keys snapshots`) → funkar på vilken SFTP som helst |
| Verifiering | `check --read-data` = läser om + hashar all data → **starkare** än rclone cryptcheck |
| Restore | bit-identisk (sha256 på alla 202 filer matchade) |
| stdin | `vzdump --stdout | restic backup --stdin` fungerar (dedupar t.o.m. mot fil-backupen) |

## 5. Vad restic ERSÄTTER / vad som STANNAR

**Ersätts (egen kod som kan tas bort):**

| Idag | Med restic |
|---|---|
| `upload.sh`: rclone copy + **crypt** | `restic copy` (restic krypterar själv → crypt-lagret försvinner) |
| sha256-sidecar + `zstd -t` + `tar -tf` | restic content-addressed integritet + `check` |
| `list.sh`: rclone lsjson + jq per vmid | `restic snapshots --json` (filtrera på `--tag vmid=<id>`) |
| `prune.sh`: egen GFS-motor | `restic forget --keep-daily/weekly/monthly` — **`KEEP_*` mappar 1:1** |
| `_fetch_core`: fetch + sha256-verify | `restic restore` (verifierar vid utläsning) |
| rclone `cryptcheck` | `restic check` (`--read-data` för djup) |

**Stannar (produktens värde):** preflight.sh, vzdump-orkestreringen, `pct restore`
+ unprivileged/storage/bind-mount-sidecars, fuse→stop-läget, web-UI/API, schema,
ntfy, audit, samt den tvådelade append-only-designen.

**Bonus:** ett repo för alla gäster → restic dedupar **mellan** gäster (delade
OS-lager), inte bara inom en gäst.

## 6. UI-påverkan (web-konsolen)

Läspanelerna blir **billigare/bättre**; skrivpanelerna är **avgränsat** arbete.

| Panel | Källa med restic | Dom |
|---|---|---|
| Content (grupperade snapshots) | `restic snapshots --json` → `id`, `time`, `tags:["vmid=…"]`, **`summary.total_bytes_processed`** (storlek i samma anrop) | Bättre, ett anrop |
| Offsite used / Datastore Usage | `restic stats --mode raw-data` → `total_size` (fysisk, dedup:ad) | Renare |
| Verify — last result | `restic check` exit-kod → OK/FAIL | Robustare (rc, ej strängmatch) |
| Guests retention / Options | `KEEP_*` → `--keep-*` (1:1), text | Trivial |
| Tasks + logg-färg | oförändrad mekanism; tuna `_job_status`-token ("Fatal:", "no errors were found") | Nästan oförändrad |

**Tre paneler kräver riktig omskrivning:**
1. **Remotes/onboarding** (störst): repo-URL (`sftp:`/`rclone:`) + repo-lösen + engångs-`restic init`; crypt-lösen/salt-fälten **försvinner**.
2. **Prune-panelen**: `forget --dry-run --json` ger `{keep:[ids], remove:[ids]}` + återvunna bytes — inte filnamns-arrayer; `renderPrune()` skrivs om.
3. **Restore-modal + export-key**: `ts` → snapshot-`id`; export-key ger repo-lösen + repo-URL i stället för `rclone.conf`.

**Migreringsvägen för UI:t:** API:t är ett tunt skal (`cli(... --json)` + `_cached`).
Behåller CLI:t sin **JSON-envelope** ändras web-UI:t **inte** för läspanelerna — bara
de tre semantiskt ändrade panelerna rörs. `check --read-data` är dyrt → körs som
**bakgrundstask** (som test-restore), aldrig i en poll.

**Uppsida senare:** per-körning dedup-delta (`summary.data_added_packed`),
repo-wide "space saved" (stats), `restic ls`/`mount` för fil-bläddring (kräver Väg B).

## 7. Oföränderlighet på SFTP (fortsatt kärna)

restic ändrar inte immutability-strategin — den **förstärker** den:
- **Två credentials.** Hosten får en nyckel som bara får **skriva/lägga till**;
  `forget --prune` (som raderar/repackar offsite) körs från en **janitor** utanför
  hosten. En ransomware-drabbad host kan inte utplåna historik.
- **Provider-snapshots** som baslinje där append-only inte kan tvingas (Hetzner
  BTRFS / rsync.net ZFS) — verifieras, inte bara bockas i.
- **Spänning att hantera:** `restic prune` kräver delete offsite → alltid från
  janitor-sidan, aldrig hosten. `forget` (släpper snapshot-referenser) är billigt
  och kan köras från hosten; det tunga `prune` hör janitorn till.

## 8. Migrering / coexistence

Riva inte tar-spåret innan restic-spåret är bevisat i skarp drift.

1. **Fas 0 (infra):** installera restic (host, `apt install restic`), lägg
   `restic`-config-nycklar (repo-URL, cache-repo-path, `RESTIC_PASSWORD`-källa i
   Vaultwarden + fil 0600). `restic init` på både cache- och offsite-repo.
2. **Fas 1 (parallellt spår):** ny `lib/restic.sh` bakom en config-flagga
   `ENGINE=restic|tar`. Kör restic-spåret **vid sidan av** tar-spåret för en
   delmängd gäster; jämför storlek/tid/restore.
3. **Fas 2 (verifiera):** test-restore från restic-offsite bootar → grönt. Kör
   `check --read-data` schemalagt.
4. **Fas 3 (byt):** flippa default `ENGINE=restic`; behåll tar-spåret läsbart för
   gamla arkiv tills retention betat av dem. Skriv om de tre UI-panelerna (§6).
5. **Fas 4 (städa):** ta bort `upload.sh`/sha256/zstd-verify/`prune.sh`-GFS när
   inga tar-arkiv återstår offsite.

## 9. Konsekvenser

**Positiva:** dedup/incremental (lägre RPO-golv, mindre offsite), klient-kryptering
+ integritet inbyggt, färre egna felkällor (mer kod raderas än skrivs),
cross-guest-dedup, append-only-passform, `pct restore` orört, UI-läspaneler
förbättras.

**Negativa / pris:** nytt beroende (restic på hosten); `VZDUMP_COMPRESS=zstd` →
`--compress 0` (restic komprimerar) = mer cache-churn transient; `copy` behöver
**två** lösenord-env (`RESTIC_PASSWORD` + `RESTIC_FROM_PASSWORD`); repo-lösenordet
blir den nya DR-nyckeln (Vaultwarden + `export-key` pekas om); ingen fil-nivå-
bläddring i Väg A (snapshoten är en tar-blob).

**Risker:** stort/långsamt repo → `restic stats`/`check` kostar (mitigeras: cacha
stats via befintlig `_cached`; `check --read-data` som bakgrundstask). Om
janitor-sidan inte byggs blir append-only bara delvis (samma risk som idag med
oförberedda Storage Box-snapshots).

## 10. Öppna frågor / uppföljning

- Janitor-domänen: separat maskin, cron på SFTP-boxen, eller offline-triggad?
- `restic` via native `sftp:` vs `rclone:`-backend (återanvänd befintlig rclone-remote)?
- VM-stöd (`qm`) i samma motor — Väg A funkar för `vzdump-qemu` också (annan restore).
- Nyckelrotation för repo-lösen (split knowledge?).
- Väg B som senare fil-nivå-optimering — separat ADR om/när det blir aktuellt.
