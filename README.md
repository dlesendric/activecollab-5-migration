# ActiveCollab Migration Tool

Alat za sekvencijalnu nadogradnju ActiveCollab self-hosted instalacije sa verzije **5.8.7** na najnoviju dostupnu verziju.

Upgrade putanja: `5.8.7 → 6.0.7 → 7.1.0 → 7.1.382 → 7.4.766 → latest`

---

## Preduslovi

- PHP 7.4 i PHP 8.3 dostupni na serveru
- MySQL ili MariaDB
- `unzip`, `mysqladmin`, `mysqldump`
- ZIP arhive AC verzija smeštene u `activecollab/` direktorijum (vidite sekciju ispod)

### Potrebne ZIP arhive

Preuzmite sledeće ZIP fajlove i smestite ih u `activecollab/` direktorijum:

```
activecollab/activecollab-6.0.7.zip
activecollab/activecollab-7.1.0.zip
activecollab/activecollab-7.1.382.zip
activecollab/activecollab-7.4.766.zip
```

ZIP arhive možete preuzeti na [activecollab.com/profile](https://activecollab.com/profile) u sekciji vaše licence, ili ih zatražiti slanjem mejla na [support@activecollab.com](mailto:support@activecollab.com).

Finalna verzija se preuzima automatski tokom migracije (potreban aktivan license key u `config.php`).

---

## Konfiguracija

### 1. `.env` fajl

Kreirajte `.env` fajl u root direktorijumu alata:

```bash
DB_NAME=ime_vaseg_dumpa.sql
```

`DB_NAME` treba da pokazuje na SQL dump vaše trenutne baze (fajl mora biti u istom direktorijumu kao `.env`).

### 2. `config.php`

Proverite da `activecollab/config/config.php` postoji i sadrži ispravne parametre konekcije na bazu. Ako ne postoji, kopirajte `config.empty.php` i popunite vrednosti.

### 3. PHP binariji

Skripta podrazumeva sledeće putanje:

| PHP verzija | Putanja |
|---|---|
| PHP 7.4 | `/usr/bin/php74` |
| PHP 8.3 | `/usr/bin/php83` |

Ako su PHP binariji na drugoj lokaciji na vašem serveru, izmenite promenljive `STEPS` i `FINAL_PHP` na vrhu `migrate.sh`.

---

## Pokretanje

### Korak 1 — Inicijalizacija

```bash
sh init.sh
```

Ova komanda:
- Proverava preduslove (komande, `.env`, SQL dump, `config.php`)
- Resetuje bazu — **importuje SQL dump iz početka**
- Čisti ekstraktovane verzije i privremene fajlove

> **Upozorenje:** `init.sh` uvek briše i rekreira bazu. Pokretajte ga samo kada počinjete migraciju iznova.

### Korak 2 — Migracija

```bash
sh migrate.sh
```

Migracija prolazi kroz sve stepenice automatski i na kraju pokreće finalni upgrade koji preuzima najnoviju verziju.

#### Nastavak od određene tačke

Ako je migracija prekinuta, možete nastaviti od konkretne stepenice:

```bash
sh migrate.sh --from 7.1.382
sh migrate.sh --from final    # samo finalni upgrade
```

Dostupne vrednosti za `--from`: `5.8.7`, `6.0.7`, `7.1.0`, `7.1.382`, `7.4.766`, `final`

---

## Šta skripta radi

Nakon svake stepenice:
- **Snapshot** — snima stanje baze u `_snapshots/after-<verzija>.sql.gz`
- **Smoke test** — proverava u bazi da li je poslednja migracija te verzije izvršena

Logovi se čuvaju u `_logs/`.

---

## Docker (opcionalno)

Ako nemate odgovarajuće PHP verzije na serveru ili želite izolovano okruženje za testiranje, možete koristiti priloženu Docker konfiguraciju.

### Preduslovi

- Docker Engine sa `docker compose` pluginom

### Pokretanje

```bash
# Podignite kontejnere
docker compose up -d

# Uđite u migrate-app kontejner
docker exec -it migrate-app bash

# Unutar kontejnera pokrenite skripte
sh /migrate/init.sh
sh /migrate/migrate.sh
```

### Kontejneri

| Kontejner | Uloga |
|---|---|
| `migrate-app` | PHP 7.4 + PHP 8.3 FPM, bash okruženje za skripte |
| `migrate-db` | MariaDB 10.11 |
| `migrate-nginx` | nginx (portovi 8886, 8887, 8888) |
| `migrate-phpmyadmin` | phpMyAdmin za pregled baze |

SQL dump i ZIP arhive se montuju automatski iz lokalnog direktorijuma u kontejner — nema potrebe da ih kopirate.
