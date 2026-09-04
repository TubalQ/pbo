# Backlog — önskemål att bygga in

## GUI (steg 11–13)
- **Export key** — knapp som ger en färdig, kopieringsbar rclone-konfigsträng
  (`[hetzner]` + `[hetzner-crypt]`-sektionerna, crypt-lösen inkluderade) att
  importera på en ny host för disaster recovery. Motsvarar att kunna göra
  `install på ny host → klistra in strängen → list → restore`. Visa tydlig
  varning att strängen ÄR nyckeln (behandla som hemlighet; förvara offline).
  Kräver auth + audit-loggning (det är en secret-export).

## Övrigt
- (fyll på)
