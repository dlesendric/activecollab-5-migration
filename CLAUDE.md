# CLAUDE.md — Kontekst projekta helpdesk-migrate

## Šta je ovaj projekat

Docker-based alat za migraciju ActiveCollab self-hosted instalacija.
Upgrade putanja: **5.8.7 → 7.1.382 → 7.4.766 → 8.0.318+**

Korisnik (Darko) pravi ZIP release-ove AC verzija i smešta ih lokalno.
`init.sh` i `migrate.sh` se pokreću **unutar `migrate-app` kontejnera**.

---

## Kako se pokreće

```bash
# 1. Postavi .env (DB_NAME=db.sql ili naziv SQL fajla)
# 2. Unutar migrate-app kontejnera:
sh /migrate/init.sh          # reset baze, import dumpa
sh /migrate/migrate.sh       # puna migracija

# Nastavak od određene tačke:
sh /migrate/migrate.sh --from 7.1.382
sh /migrate/migrate.sh --from final   # samo finalni upgrade
```

---

## Arhitektura kontejnera

- **migrate-app** — Rocky Linux 9, PHP 7.4 FPM (:9004), PHP 8.3 FPM (:9008)
- **migrate-db** — MariaDB 10.11
- **migrate-nginx** — nginx, porta 8886 (AC 6.x), 8887 (AC 7.1.x), 8888 (AC 7.4.x+)

PHP binariji: `/usr/bin/php74`, `/usr/bin/php83`

---

## PHP verzije po stepenicama

| Stepenica | PHP | Razlog |
|---|---|---|
| 5.8.7 → 7.1.382 | PHP 7.4 | PHP 8.x puca na `Angie\Error::$file` (untyped vs typed) |
| 7.1.382 → 7.4.766 | PHP 8.3 | AC 7.4.766 koristi union types — zahteva PHP 8.0+ |
| finalni upgrade | PHP 8.3 | |

7.1.382 kumulativno sadrži sve migracije od 5.8.7 naviše — 6.0.x i 7.1.0 ZIP-ovi nisu potrebni.

---

## Ključne implementacione odluke

### init.sh
- Strip DEFINER iz SQL dumpa pri importu: `sed -E 's/DEFINER=\`[^\`]+\`@\`[^\`]+\`//g'`
- Briše sve verzije > 5.8.7 iz `activecollab/activecollab/` direktorijuma
- Briše `work/` sadržaj
- Resetuje `version.php` na 5.8.7

### migrate.sh
- `build_steps()` automatski skenira `activecollab/*.zip`, sortira ih po verziji — **svaki ZIP je jedan korak** (nije par from→to)
- PHP prag: verzije ≥ 7.4.0 dobijaju PHP 8.3, ostale PHP 7.4 (promenljiva `PHP_THRESHOLD`)
- `run_step` ekstraktuje i upgraduje tačno na tu verziju; AC kumulativno pokreće sve migracije koje još nisu izvršene
- Verzija se čita iz `version.php` (`get_file_version`), ne iz baze — AC piše `define('APPLICATION_VERSION', ...)` u fajl, ne u `config_options`
- Finalni upgrade (`run_final_upgrade`) pokreće `php tasks/activecollab-cli.php upgrade` **bez** `--dont-download-latest` — ista komanda kao na korisnikovom serveru, AC sam preuzima novu verziju
- `extract_version_folder` i `set_version` se **ne pozivaju** za finalni upgrade (AC to radi sam)

---

## Rešeni problemi (detalji u Migrate-Uputstva.md)

### Problem 1 — DEFINER korisnik ✅
`helpdesk_usr@%` ne postoji u novoj MariaDB. Fix: sed strip u init.sh.

### Problem 2 — PHP kompatibilnost ✅
`Angie\Error::$file` typed property PHP 8.0+ issue. Fix: PHP 7.4 za sve 7.x korake.

### Problem 3 — `MigrateAddedReferenceColumnToRemoteInvoices` ✅
`Integrations::findFirstByType()` ima find-or-create semantiku. QB integracija je obrisana
u koraku 7.4.766, pa ORM pokušava INSERT sa `updated_on` koje ne postoji u `integrations` tabeli (5.8.7 dump nema tu kolonu).

**Fix:** Direktorijum migracije `MigrateAddIntegrationsUpdatedOn` premešten:
- Bilo: `2026-01-20-add-integrations-updated-on/`
- Sada: `2025-04-11-add-integrations-updated-on/`

AC sortira migracije po datumu direktorijuma (`ksort`), pa sada `updated_on` postoji
pre nego što `2025-04-14-added-reference-column-to-remote-invoices` pokuša find-or-create.

### Problem 4 — Finalni upgrade tražio ZIP ✅
`migrate.sh` pozivao `extract_version_folder` za finalni korak. Fix: uklonjeni
`extract_version_folder` i `set_version` iz finalnog bloka — `upgrade` bez
`--dont-download-latest` sam preuzima i instalira novu verziju.

---

## Trenutni status

**Sve stepenice prolaze, uključujući finalni upgrade.** Migracija 5.8.7 → 8.0.318 radi end-to-end sa samo dva ZIP-a (7.1.382 + 7.4.766).

---

## Fajlovi koji se menjaju u AC kodu (8.0.318)

```
activecollab/activecollab/activecollab/8.0.318/migrations/
  2025-04-11-add-integrations-updated-on/   ← pomereno sa 2026-01-20
    MigrateAddIntegrationsUpdatedOn.class.php
```

Sve ostalo u AC kodu je netaknuto.

---

## Lokacija ZIP-ova

ZIPs se stavljaju u `activecollab/` direktorijum. Minimalni set:
```
activecollab-7.1.382.zip
activecollab-7.4.766.zip
```
Finalna verzija (8.0.318+) se preuzima automatski.
