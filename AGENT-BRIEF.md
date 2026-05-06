# Brief za coding agenta — Automatska migracija ActiveCollab 5.8.7 → 8.0.31

> **Status:** Specifikacija. Ovaj dokument opisuje **šta agent treba da napiše**.
> Agent **ne pokreće** migraciju niti dira korisničku bazu — samo isporučuje
> radne `init.sh`, `migrate.sh`, `Dockerfile`, izmene `docker-compose.yaml` i
> prateće config fajlove. Verifikacija da sve radi je obaveza agenta unutar
> docker okruženja koje je već pripremljeno u repo-u.

---

## 1. Kontekst

Repo `helpdesk-migrate/` je proof-of-concept koji simulira korisnikov sistem.
Cilj je da krajnji korisnik (helpdesk operater) klonira repo, pokrene
`sh init.sh` jednom, pa `sh migrate.sh`, i dobije AC 8.0.31 instancu sa
migriranom bazom iz `db.sql`.

Postojeći artefakti:

| Fajl / folder | Šta sadrži | Status |
|---|---|---|
| `db.sql` | MySQL dump produkcione AC 5.8.7 baze (~244 MB) | dato, ne menjati |
| `.env` | `DB_NAME="db.sql"`, `LICENSE_KEY="..."` | dato, agent može dodavati varijable |
| `Dockerfile` | `FROM rockylinux:latest` + `top -b` (placeholder) | **agent piše ispravan — dual PHP 7.4 + 8.3 (vidi §6.5)** |
| `docker-compose.yaml` | app + mysql + phpmyadmin + nginx | **agent ispravlja bagove** (vidi §6) |
| `servers/ac7.conf`, `servers/ac8.conf` | nginx vhost konfigi | dato, agent dodaje `ac6.conf` |
| `servers/custom_php.ini` | `memory_limit = 512M` | dato |
| `init.sh` | prazan | **agent piše** |
| `migrate.sh` | prazan | **agent piše** |
| `activecollab/` | prazan folder | agent koristi kao radni prostor za AC izvor |

---

## 2. Cilj migracije

Sekvencijalna nadogradnja kroz **tačno ove verzije, ovim redom**:

```
5.8.7  →  6.0.7  →  7.1.0  →  7.1.382  →  7.4.766  →  8.0.31
```

Svaka stepenica koristi ugrađeni AC upgrade alat (`tasks/upgrade.php` ili
`tasks/console.php upgrade`, agent treba da proveri u distribuciji svake
verzije i pozove pravu komandu).

**Obim:** samo baza. Fajlovi (avatari, attachments, uploads) **nisu** u opsegu —
agent ne treba da migrira `/files`, ne treba da generiše `files/` folder, i
treba da onemogući/preskoči korake koji bi prijavljivali nedostatak fajlova
gde god je to bezbedno.

---

## 3. Kako se nabavlja AC izvorni kod

`migrate.sh` preuzima ZIP arhive sa `downloads.activecollab.com` koristeći
`LICENSE_KEY` iz `.env`. Format URL-a koji koristi AC distribucija
(agent treba da potvrdi i parametrizuje kroz funkciju):

```
https://downloads.activecollab.com/<LICENSE_KEY>/activecollab-<VERSION>.zip
```

Lista verzija koje se preuzimaju (svaka kao zaseban ZIP):

- `6.0.7`
- `7.1.0`
- `7.1.382`
- `7.4.766`
- `8.0.31`

Arhive se kešaju u `_cache/` na korenu repo-a (gitignore) da ponovljena
pokretanja ne udaraju download server. Pre svakog koraka, raspakuj
odgovarajući ZIP **direktno u `./activecollab/`** (jedna verzija u datom
trenutku — overwriting je u redu, AC stanje je u bazi, ne na disku).

> **Bitno:** `./activecollab/` je istovremeno mountovan u `app` kontejneru
> kao `/var/www/html/app` i u `nginx` kontejneru kao `/var/www/html/app`
> (vidi §6.1). Zato AC kod **ne sme** da ide u podfolder kao `_runtime/`,
> jer nginx očekuje `public/` taman na korenu te mape. Pre `unzip`-a, skripta
> briše sadržaj `./activecollab/` osim `config/config.php` (koji se prenosi
> između stepenica) i bilo kog `.gitkeep` fajla.

**Fallback:** ako download vrati 401/403/404, skripta jasno javlja korisniku
da proveri `LICENSE_KEY` i izlazi sa exit kodom ≠ 0. Ne pokušavati skidanje
sa drugog izvora.

---

## 4. `init.sh` — šta tačno treba da radi

Idempotentan bootstrap. Pretpostavi da korisnik može pokrenuti više puta.

1. **Provera preduslova:** `docker`, `docker compose`, `unzip`, `curl`. Ako
   nešto nedostaje — jasna poruka i exit 1.
2. **Učita `.env`** i validira da postoje `DB_NAME` i `LICENSE_KEY`.
3. **`docker compose up -d mysql`** i čeka da MySQL bude healthy
   (loop sa `mysqladmin ping`, timeout 60 s).
4. **Drop & create** baze `activecollab` (čisto stanje — bitno za retry).
5. **Učitava `db.sql`** u `activecollab` bazu kroz `docker compose exec -T mysql mysql`.
   Mora da rukuje fajlom od ~244 MB — koristiti pipe, ne `-e`.
6. **Generiše `activecollab/config/config.php`** za **AC 6.0.7** (prvi korak
   migracije) sa:
   - `DB_HOST=mysql`, `DB_USER=root`, `DB_PASS=root`, `DB_NAME=activecollab`
   - `ROOT_URL='http://ac6.local:8886'`
   - `LICENSE_KEY` iz `.env`
   - `DEBUG=true` u toku migracije, prebaciti na `false` na kraju
7. **Kreira mape** koje AC očekuje (`activecollab/work/`, `activecollab/cache/`,
   `activecollab/logs/`) i postavlja prava (`chmod -R 777` unutar kontejnera,
   jer migracija se vrti kao `root` u app kontejneru). **Napomena:** ove mape
   ne smeju da idu u git (vidi `.gitignore`).
8. Štampa: "Init OK — pokreni `sh migrate.sh`".

---

## 5. `migrate.sh` — šta tačno treba da radi

Vodi sekvencijalnu nadogradnju kroz pet stepenica. Svaka stepenica je idealno
zasebna funkcija (`step_5_to_6`, `step_6_to_71`, …) tako da se može ponovo
pokrenuti od pojedine tačke (`migrate.sh --from 7.1.382`).

Za **svaku stepenicu**:

1. **Download** odgovarajuće ZIP arhive (vidi §3) ako je nema u `_cache/`.
2. **Očisti i raspakuj** u `./activecollab/` direktno:
   - sačuvaj `activecollab/config/config.php` u temp lokaciju,
   - obriši sve ostalo iz `./activecollab/` (osim `.gitkeep`),
   - unzip nove verzije,
   - vrati `config.php` na mesto.
3. **Prepiši** `config/config.php` iz prethodnog koraka (kredencijali ostaju isti,
   menja se eventualno `APPLICATION_VERSION` ako AC to čita, što obično ne radi).
4. **Pokreni upgrade** unutar `migrate-app` kontejnera, koristeći **pravi
   PHP binary za tu stepenicu** (vidi §6.5). Putanje su pod
   `/var/www/html/app/` jer je tako mount unutar app kontejnera (vidi §6.1):

   ```bash
   # 5.8.7 → 6.0.7 (PHP 7.4)
   docker compose exec -T -w /var/www/html/app app /usr/bin/php74 tasks/upgrade.php

   # 6.0.7 → 7.1.0  i sve naredne (PHP 8.3)
   docker compose exec -T -w /var/www/html/app app /usr/bin/php83 tasks/upgrade.php
   ```

   Tačna komanda i radni direktorijum mogu varirati po verziji — agent mora
   proveriti `tasks/`, `cli/`, `bin/` u svakom ZIP-u i pozvati pravu binarku.
   AC vraća non-zero exit code kod neuspeha; skripta mora da prekine i ne
   prelazi na sledeću stepenicu.

   **Dodatno za stepenicu 6.0.7 → 7.1.0:** pre poziva upgrade, `migrate.sh`
   mora da rekonfiguriše nginx tako da `ac7.conf` (port 8887) i `ac8.conf`
   (port 8888) gađaju `migrate-app:9008` (PHP 8.3). Pošto `ac7.conf` i
   `ac8.conf` već imaju `fastcgi_pass migrate-app:9008` posle popravke iz §6.5,
   ovaj korak se svodi na `docker compose kill -s HUP nginx` (reload). AC6
   vhost na portu 8886 i dalje pokazuje na `:9004` što je u redu — više se
   ne koristi posle ove stepenice.
5. **Snapshot baze** posle svake stepenice u `_snapshots/after-<VERSION>.sql.gz`
   (kroz `docker compose exec mysql mysqldump`). Ovo daje korisniku rollback
   tačku ako konkretna stepenica pukne kasnije, i daje agentu artefakt za
   verifikaciju.
6. **Smoke test:** `curl -fsS http://localhost:<port>/api/v1/info` ili AC
   ekvivalent — minimalno proveriti da se aplikacija diže i čita verziju iz
   baze. (Verzija mora biti tačno ono što očekujemo posle te stepenice.)

Redosled:

| # | Iz | U | Snapshot fajl |
|---|---|---|---|
| 1 | 5.8.7 | 6.0.7 | `after-6.0.7.sql.gz` |
| 2 | 6.0.7 | 7.1.0 | `after-7.1.0.sql.gz` |
| 3 | 7.1.0 | 7.1.382 | `after-7.1.382.sql.gz` |
| 4 | 7.1.382 | 7.4.766 | `after-7.4.766.sql.gz` |
| 5 | 7.4.766 | 8.0.31 | `after-8.0.31.sql.gz` |

Po završetku: prebaci nginx vhost na AC8 root, restartuj nginx, štampaj URL
i početne kredencijale.

---

## 6. Šta agent mora da uradi u `docker-compose.yaml` i prateće promene

Trenutni `docker-compose.yaml` (verzija od poslednje korisnikove izmene) je
u dobrom stanju u pogledu mreže (jedan konsolidovan `migrate-activecollab`
sa top-level definicijom) i mount-a za nginx (`./activecollab:/var/www/html/app`).
Ostaje sledeće:

1. **Path alignment app ↔ nginx — kritično.** Trenutno:
   - `app` mount: `./activecollab/:/app`
   - `nginx` mount: `./activecollab:/var/www/html/app`

   Vhost-ovi šalju `SCRIPT_FILENAME=/var/www/html/app/public/...`, a PHP-FPM
   u `app` kontejneru taj path **ne poznaje** (kod njega je `/app/public/...`).
   Rezultat: `File not found.` na svaki PHP zahtev, FastCGI ne radi.

   **Fix:** u `app` servisu promeniti `./activecollab/:/app` u
   `./activecollab:/var/www/html/app`. U Dockerfile-u staviti
   `WORKDIR /var/www/html/app`. Sve `migrate.sh` upgrade pozivi koriste
   `/var/www/html/app/...` (već je tako u §5).

2. **Volumes tipfeleri za skripte.** Linije sa
   `- .init.sh:/app/init.sh` i `- .migrate.sh:/app/migrate.sh` — vodeća tačka
   znači "skriveni fajl `.init.sh` u trenutnom folderu", koji ne postoji.
   Docker bind-uje **prazan direktorijum** umesto skripte. Fix:
   `./init.sh:/var/www/html/app/init.sh` i isto za migrate. (Putanja unutra
   se menja jer je WORKDIR sada `/var/www/html/app`.)

3. **`.env` mount.** Linija `.env:/app/.env` je sintaksički u redu (jer fajl
   `.env` postoji), ali ciljnu putanju treba uskladiti:
   `./.env:/var/www/html/app/.env`.

4. **Suvišno izlaganje portova 9004 i 9008 na host.** Trenutno:
   ```yaml
   ports:
     - "9004:9004"
     - "9008:9008"
   ```
   Nginx pristupa kroz internu Docker mrežu (`migrate-app:9004`,
   `migrate-app:9008`), ovi `ports:` mapinzi su nepotrebni i mogu pasti sa
   "address already in use" ako korisnik ima nešto drugo na 9004/9008.
   **Ukloniti** `ports:` iz `app` servisa; ostaviti samo `EXPOSE 9004 9008`
   u Dockerfile-u.

5. **Nginx port 8886 nije izložen za AC6.** Trenutno nginx servis ima samo
   `"8887:8887"` i `"8888:8888"`. AC6 vhost (vidi §6.7) sluša na 8886.
   Dodati u `nginx.ports`:
   ```yaml
   - "8886:8886"
   ```

6. **`container_name: sh-nginx`** je leftover iz starog imenovanja. Promeniti
   u `migrate-nginx` radi konzistencije sa `migrate-app` i `migrate-db`.
   (Nije breaking, ali agent neka uskladi.)

7. **`app` kontejner nema PHP-FPM** — `Dockerfile` je samo `top -b`.
   **Obavezna arhitektura (zadato):** jedan `migrate-app` image koji ima
   instalirane **i PHP 7.4 i PHP 8.3**, oba pokrenuta kao zasebni PHP-FPM
   master procesi unutar istog kontejnera, na portovima:

   | PHP verzija | FPM port (interni) | Koristi se za stepenice |
   |---|---|---|
   | 7.4 | **9004** | 5.8.7 (učitana baza) i 6.0.7 |
   | 8.3 | **9008** | 7.1.0, 7.1.382, 7.4.766, 8.0.31 |

   Razlog: AC 6.0.7 ne radi pouzdano na PHP 8.x, a AC 8.0.31 ne radi na
   PHP 7.4 — jedan image sa oba runtime-a je najjednostavniji način da nginx
   tokom migracije menja samo `fastcgi_pass` ciljni port, bez ponovnog
   builda kontejnera.

   **Implementacioni zahtevi za Dockerfile:**
   - Bazni image: `rockylinux:9` (ili `:latest` ako agent potvrdi da repos
     daju oba potrebna PHP modula). Ako Rocky repos ne daju PHP 7.4 i 8.3
     paralelno, koristiti **Remi repo** (`dnf module reset php`, pa
     `dnf install php74 php83 php74-php-fpm php83-php-fpm` plus odgovarajući
     extension paketi). Agent neka u komentaru Dockerfile-a napiše tačno
     izvor paketa.
   - Oba FPM-a se startuju **istovremeno** kroz `supervisord`
     (preporuka — `dnf install supervisor`), ne kroz `ENTRYPOINT` koji bira
     jednu verziju. Konfiguracije:
     - `/etc/php74-fpm.d/www.conf` — `listen = 0.0.0.0:9004`, pool `www`,
       user `nginx` (ili kojeg god agent odabere konzistentno).
     - `/etc/php83-fpm.d/www.conf` — `listen = 0.0.0.0:9008`, isti pool/user.
   - `EXPOSE 9004 9008`. U `docker-compose.yaml` ne treba mapirati ove
     portove na host (vidi tačku §6.4).

   **Posledice za nginx vhost-ove (agent mora da ih primeni):**
   - `servers/ac6.conf` (novi): `fastcgi_pass migrate-app:9004;`
   - `servers/ac7.conf` (postojeći): promeniti `fastcgi_pass migrate-app:9000;`
     u `fastcgi_pass migrate-app:9008;`
   - `servers/ac8.conf` (postojeći): isto — `fastcgi_pass migrate-app:9008;`

   **Posledice za `migrate.sh`:** komanda za upgrade unutar kontejnera
   mora eksplicitno da koristi pravi PHP binary, **ne** sistemski default
   (paths su pod `/var/www/html/app/` — vidi §5 i §6.1):
   - stepenica 5.8.7→6.0.7:
     `docker compose exec -T -w /var/www/html/app app /usr/bin/php74 tasks/upgrade.php`
   - stepenica 6.0.7→7.1.0: **prvi put se prebacuje na PHP 8.3** —
     `docker compose exec -T -w /var/www/html/app app /usr/bin/php83 tasks/upgrade.php`
   - sve naredne stepenice: `php83`.

   Tačan put binarki (`/usr/bin/php74`, `/usr/bin/php83` ili
   `/opt/remi/php74/root/usr/bin/php`, itd.) zavisi od izabrane distribucije
   paketa — agent verifikuje `which` unutar kontejnera i hardkoduje konzistentno.

8. **Ekstenzije za AC:** `mysqli`, `pdo_mysql`, `mbstring`, `gd`, `curl`,
   `zip`, `xml`, `intl`, `bcmath`, `imagick`, `exif`, `opcache`. Sve
   instalirati u Dockerfile **za obe PHP verzije** (npr. paketi
   `php74-php-mysqlnd` + `php83-php-mysqlnd` itd.).

9. **`servers/ac6.conf` ne postoji** — agent ga piše po šablonu `ac7.conf`,
   ali sa `listen 8886`, root `/var/www/html/app/public`, i
   `fastcgi_pass migrate-app:9004` (PHP 7.4 FPM). Postojeći `ac7.conf` i
   `ac8.conf` se editujem tako da `fastcgi_pass` pokazuje na port 9008
   (PHP 8.3 FPM) umesto trenutnog 9000.

---

## 7. Acceptance kriterijumi (agent verifikuje na sebi pre predaje)

Agent mora da pokaže da je sve sledeće prošlo unutar docker okruženja:

- [ ] `migrate-app` kontejner unutra paralelno drži aktivna oba FPM master
      procesa: `php74-fpm` na portu 9004 i `php83-fpm` na portu 9008
      (provera: `docker compose exec app ss -ltnp | grep -E '9004|9008'`).
- [ ] PHP-FPM zaista nalazi `index.php`: `curl -fsS http://localhost:8886/`
      (AC6 phase) i `http://localhost:8888/` (AC8 phase) **ne smeju** vratiti
      `File not found` ili 502. Ovo verifikuje da je path alignment iz §6.1
      ispravno odrađen.
- [ ] `sh init.sh` prolazi do kraja sa exit 0 na čistom `docker compose down -v` stanju.
- [ ] `sh migrate.sh` prolazi svih 5 stepenica sa exit 0.
- [ ] Posle svake stepenice, `SELECT value FROM config_options WHERE name='version'`
      (ili AC ekvivalent — proveriti u shemi) vraća očekivanu verziju.
- [ ] `_snapshots/` sadrži svih 5 `*.sql.gz` fajlova, svaki nije prazan.
- [ ] Otvaranje `http://localhost:8888/` (ili port iz `ac8.conf`) prikazuje
      AC 8.0.31 login ekran.
- [ ] Migracija je idempotentna na nivou koraka: ponovno pokretanje
      `migrate.sh --from <verzija>` posle prekida nastavlja, ne ruši.
- [ ] `migrate.sh` ne ostavlja viseće temp fajlove u `/tmp` host-a.
- [ ] Sve poruke ka korisniku su na srpskom (kao i README), `set -euo pipefail`
      je uključen u oba sh skripta, a logovi koraka idu i u stdout i u
      `_logs/migrate-<timestamp>.log`.

---

## 8. Šta agent **ne** sme

- Ne menjati `db.sql` (read-only ulaz).
- Ne hardkodirati `LICENSE_KEY` — uvek čitati iz `.env`.
- Ne commitovati `_cache/`, `_snapshots/`, `_logs/`, sadržaj `activecollab/`
  (raspakovani vendor kod), `db.sql`, `.env`, `activecollab/config/config.php`
  — agent piše/ažurira `.gitignore`.
- Ne dodirivati host MySQL — sve ide kroz `migrate-db` kontejner.
- Ne preskakati stepenice "jer izgleda da AC 8 može da pojede 6 šemu"
  — sekvenca iz §2 je obavezna.

---

## 9. Deliverables (šta agent na kraju predaje)

Izmene/novi fajlovi u `helpdesk-migrate/`:

1. `Dockerfile` — Rocky Linux + PHP-FPM + ekstenzije
2. `docker-compose.yaml` — popravljen (vidi §6)
3. `servers/ac6.conf` — novi
4. `init.sh` — kompletan (§4)
5. `migrate.sh` — kompletan (§5), sa flagovima `--from <verzija>` i `--help`
6. `.gitignore` — već postavljen u korenu repo-a (vidi §11). Agent ga može
   proširiti ako uvede nove temp folder-e, ali postojeće rule-ove ne dira.
7. `README.md` — proširen: preduslovi, troubleshooting (česte greške i fix),
   kako pokrenuti rollback iz snapshot-a
8. Kratak `CHANGELOG.md` ulaz koji opisuje verziju POC-a

---

## 10. Otvoreno pitanje za korisnika (Darka) pre nego što agent počne

- Da li krajnji korisnik koji pokreće migraciju može da ima Docker Desktop, ili
  je strogo CLI Docker Engine? (Utiče na `docker compose` vs `docker-compose`.)
- Da li `downloads.activecollab.com/<LICENSE_KEY>/activecollab-<VERSION>.zip`
  zaista služi tačno te stare verzije (6.0.7, 7.1.0, 7.1.382), ili postoji
  poseban "legacy releases" endpoint? Agent neka prvo testira `curl -I` pre
  pisanja kompletnog download koda.

Ova pitanja agent **ne sme** sam da odluči — postavlja ih korisniku pre
finalizacije.

---

## 11. Git i `.gitignore`

Repo je inicijalizovan sa `git init`. `.gitignore` na korenu pokriva:

- **Tajne i veliki binarni ulazi:** `.env`, `db.sql`
- **Vendor kod koji raspakuje migracija:** sve unutar `activecollab/` osim
  `.gitkeep` — to je AC kod koji je vlasništvo Active Collab-a, ne ovog repo-a
- **Generisani fajlovi između stepenica:** `activecollab/config/config.php`
  (sadrži DB kredencijale, ne treba u git)
- **Radni folderi koje skripte prave:** `_cache/`, `_snapshots/`, `_logs/`
- **IDE i OS smeće:** `.idea/`, `.vscode/`, `.DS_Store`, `*.swp`

Agent **ne sme** da commit-uje fajlove koji potpadaju pod ove paterne.
Ako pravi novi tipa privremenog foldera, dodaje ga u `.gitignore` u istoj
PR-u/commit-u.
