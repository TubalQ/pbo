# Backlog — önskemål att bygga in

## GUI (steg 11–13)
- **Export key** — knapp som ger en färdig, kopieringsbar rclone-konfigsträng
  (`[hetzner]` + `[hetzner-crypt]`-sektionerna, crypt-lösen inkluderade) att
  importera på en ny host för disaster recovery. Motsvarar att kunna göra
  `install på ny host → klistra in strängen → list → restore`. Visa tydlig
  varning att strängen ÄR nyckeln (behandla som hemlighet; förvara offline).
  Kräver auth + audit-loggning (det är en secret-export).

## Motor (restic)
- **Beslut fattat:** restic ersätter tar.zst-motorn — se
  [`docs/adr/0001-restic-as-backup-engine.md`](adr/0001-restic-as-backup-engine.md)
  (Väg A: vzdump-tar lagras i restic, `pct restore` orört, CLI-envelope behålls).
  Migrering i faser (`ENGINE=restic|tar`-flagga), coexistence tills bevisat skarpt.

## VM + kluster
- **Riktning satt:** qemu-VM-stöd + kluster-medvetenhet — se
  [`docs/adr/0002-vm-och-kluster-stod.md`](adr/0002-vm-och-kluster-stod.md)
  (typ-gren `pct`/`qm`; kluster = agent-per-nod + delat offsite-repo +
  pmxcfs-config). Fas 1 = VM lokalt, Fas 2 = kluster.

## Övrigt
- (fyll på)
