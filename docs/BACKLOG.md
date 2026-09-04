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

## Övrigt
- (fyll på)
