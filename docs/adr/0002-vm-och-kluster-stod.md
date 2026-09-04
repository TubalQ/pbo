# ADR 0002 — VM- och kluster-stöd

- **Status:** Accepterad (riktning) — 2026-09-04
- **Beslut:** Stöd **qemu-VM** (utöver LXC) via typ-grenad backup/restore, och gör
  verktyget **kluster-medvetet** via modellen **agent-per-nod + delat offsite-repo
  + kluster-replikerad config** (pmxcfs). Fasas: **VM lokalt först**, kluster sedan.
- **Bygger på:** [ADR 0001](0001-restic-as-backup-engine.md) (restic, Väg A, native sftp).

> Undersökt mot verkligheten 2026-09-04: kluster **midvault**, 2 noder (**pve** +
> **pveT440**, quorate), 12 LXC på pveT440, **1 qemu — VM 101 `game-fedora-cloud`
> på pve** som verktyget **inte** kan nå idag (fel typ + fel nod).

---

## 1. Kontext

Verktyget är LXC-only och kör bara på pveT440. Två luckor:

1. **VM (qemu).** VM 101 kan inte backas: `vzdump` klarar båda typer, men restore
   skiljer sig — LXC via `pct restore` (`.tar.zst`), qemu via **`qmrestore`**
   (`.vma.zst`). restore.sh/testrestore.sh hårdkodar `pct restore`.
2. **Kluster.** `vzdump`/`qmrestore` måste köra **på noden där gästen bor**.
   pveT440 kan inte vzdumpa VM 101 (på pve). Läs-sidan är redan kluster-medveten
   (API:t läser `pvesh get /cluster/resources` → hela flottan med `node`), men
   *utförandet* når bara lokala gäster.

Detta bryter inte "local-only"-etoset: varje nod förblir self-contained; det som
delas är **offsite-repot** och **vyn**. Det är exakt hur PVE:s egna backup-jobb
fungerar (jobb definierat kluster-brett, kört per-nod).

## 2. Beslut — VM-stöd (qemu)

`vzdump <vmid>` auto-detekterar typ. Grena på **guest-typ** i restore-vägarna:

| | LXC | qemu (VM) |
|---|---|---|
| Backup | `vzdump` → `.tar` (`--compress 0`) | `vzdump` → `.vma` (`--compress 0`) |
| Restore | `pct restore <id> <arkiv> --storage --unprivileged <n>` | `qmrestore <arkiv> <id> --storage <pool>` |
| Konsistens | fuse → `--mode stop` (deadlock-spärr) | snapshot m. **qemu-guest-agent** (fsfreeze); annars `stop`/`suspend` |
| Sidecar | `unprivileged`, bind-mounts | ingen `unprivileged`; diskar, ej bind-mounts |

- **restic Väg A gäller oförändrat:** `.vma` (okomprimerad) lagras i restic som
  vilken blob som helst; disk-innehåll dedupar bra mellan körningar (CDC hittar
  oförändrade block). Restore = `restic restore` → `qmrestore`.
- Meta/sidecar-logiken grenas: qemu saknar `unprivileged`/bind-mounts, har diskar
  med egna storage-placeringar. `_effective_mode` behåller fuse→stop **bara** för
  LXC; för qemu: `snapshot` om guest-agent finns, annars konfigurerbart fallback.
- test-restore: `qmrestore` → `qm start` → vänta (guest-agent/ping) → `qm stop`
  → `qm destroy`. Engångs-vmid-poolen 9000–9099 delas.

**Fas 1 (lokalt):** VM-stöd på den lokala noden — unblockar lokala VM:ar direkt,
utan kluster-komplexiteten.

## 3. Beslut — kluster: agent-per-nod + delat repo + pmxcfs-config

**Modell A (vald):** installera lxc-offsite på **varje nod**. Varje nod backar upp
**sina egna** gäster (filtrera `cluster/resources` på `node == $localnode`) in i
**samma** offsite restic-repo (native sftp) → **kluster-brett dedup** i ett repo.

Varför Modell A framför en central dispatcher (Modell B, ssh/pvesh till andra
noder): behåller varje nod self-contained (local-only-etos), ingen extra
cross-node-trust/ssh-mesh, och PVE ger redan byggstenarna:

- **Config kluster-brett gratis:** lägg icke-hemlig config i **`/etc/pve/`**
  (pmxcfs — replikeras till alla noder automatiskt). `BACKUP_ORDER`, `KEEP_*`,
  schema syncas av sig själva. **Secrets INTE här** (pmxcfs replikeras i klartext)
  → repo-lösen per nod i `/etc/lxc-offsite/` 0600 + Vaultwarden.
- **Migrations-säkert:** restic taggar per **vmid** (ej nod). Flyttas en gäst backar
  nya noden upp den nästa körning; historiken fortsätter under samma vmid.
- **Samtidiga skrivare, ett repo:** restic tillåter flera parallella `backup` mot
  samma repo (lås-filer). **`prune` kräver exklusivt lås → körs från EXAKT en
  plats** (en nods janitor, eller den härdade externa janitorn; se ADR 0001 §7).
- **Schema:** varje nods timer betar av sina lokala gäster. Ingen central
  koordinator behövs för backup; bara för prune.

### Web-UI i kluster

Vyn är redan kluster-brett (gäst-lista med `node`-kolumn). Det som ändras är
**routing av åtgärder**: en `backup`/`restore` på en gäst som bor på annan nod
måste utföras **där**. Alternativ:

- **MVP:** varje nod kör sin egen API/konsol; en gäst-åtgärd är bara aktiverbar på
  den nod som äger gästen (övriga visas read-only med "körs på nod X"). Enklast,
  bryter inget.
- **Senare:** en konsol dispatchar till ägar-noden via PVE-API
  (`pvesh create /nodes/<node>/vzdump …`) eller en tunn per-nod-executor, så allt
  styrs från en vy.

**Fas 2 (kluster):** agent på pve-noden + delat repo + pmxcfs-config +
UI-routing (MVP-nivån först).

## 4. Konsekvenser

**Positiva:** full täckning (alla gäster, alla noder, båda typer); ett delat repo
→ dedup över hela klustret; config-sync gratis via pmxcfs; migrations-säkert.

**Negativa / pris:** installation på varje nod (pve-noden är "begränsad" — se
`pve-nod/`); qemu-restore-gren (`qmrestore`) + grenad sidecar/meta-logik; prune
måste centraliseras till en plats; UI-action-routing är nytt arbete.

**Risker:** pve-nodens resursbegränsning (räcker den för vzdump+restic?); pmxcfs
kräver quorum — tappat quorum ⇒ config-läsning kan blockera (mitigera: cache:a
config lokalt, degradera inte backup vid quorum-förlust på egna gäster);
qemu-snapshot utan guest-agent ger crash-konsistent (ej app-konsistent) backup —
dokumentera och varna i UI.

## 5. Fasning (kopplar till ADR 0001-migreringen)

- **Fas 1 — VM lokalt:** typ-gren i backup/restore/testrestore (`pct` vs `qm`),
  `.vma` i restic. Testa mot en lokal engångs-VM. *(Oberoende av kluster.)*
- **Fas 2 — kluster:** agent på pve, delat repo, pmxcfs-config, prune-centralisering,
  UI read-only för fjärrnods-gäster.
- **Fas 3 — UI-dispatch:** styr fjärrnods-åtgärder från en vy (`pvesh`/executor).

## 6. Öppna frågor

- pve-nodens kapacitet för vzdump+restic (mät; ev. `RCLONE_BWLIMIT`/nice/ionice).
- Prune-ägare i kluster: en utpekad nod vs extern janitor (ADR 0001 §7)?
- UI: en konsol-per-nod (MVP) vs central dispatch — när lönar sig steget?
- qemu app-konsistens: kräva guest-agent, eller tillåta crash-konsistent m. varning?
- Config i pmxcfs: exakt filuppdelning (icke-secret i `/etc/pve/lxc-offsite/`,
  secret per nod).
