# Migrate-Uputstva — Poznati problemi i rešenja

Ovaj fajl dokumentuje probleme koji se pojavljuju tokom migracije i predložena rešenja koja treba implementirati u kod.

---

## Problem 1 — Missing definer user (`helpdesk_usr@%`) ✅ REŠENO

**Gde se pojavljuje:** Stepenica `5.8.7 → 6.0.7`, migracija `MigrateUpdateUserLanguage`

**Simptom:**
```
Error #1: Query failed with message 'The user specified as a definer
('helpdesk_usr'@'%') does not exist'
(SQL: UPDATE users SET language_id = ? WHERE language_id = ?)
```

**Uzrok:**  
Originalna produkciona baza imala je MySQL korisnika `helpdesk_usr@%` koji je definisan kao DEFINER na triggerima i/ili stored procedurama. SQL dump (`db.sql`) sadrži te triggere sa `DEFINER='helpdesk_usr'@'%'`. Naša nova MariaDB instanca nema tog korisnika — jedino `root` postoji — pa MariaDB odbija da izvrši trigger tokom migracije.

**Rešenje — stripovati DEFINER iz dumpa tokom importa u `init.sh`:**

```bash
sed -E 's/DEFINER=`[^`]+`@`[^`]+`//g' "$SQL_FILE" \
    | mysql -h mysql -uroot -proot activecollab
```

**Status:** Implementirano u `init.sh`. Korak 5.8.7 → 6.0.7 prošao u potpunosti (smoke test HTTP 200).

---

## Problem 2 — PHP kompatibilnost po verzijama AC ✅ REŠENO

**Uzrok:**  
- PHP 8.0+ uvodi typed property inheritance — `Exception::$file` je `string`, child klase bez tipa pucaju. AC 7.1.x je pisan pre tog PHP-a.
- PHP 8.0+ uvodi union type sintaksu (`int|string`) — AC 7.4.766 je koristi. PHP 7.4 je ne razume (parse error).

**Finalni raspored PHP verzija po stepenicama:**

| Stepenica | PHP | Razlog |
|---|---|---|
| 5.8.7 → 6.0.7 | PHP 7.4 | |
| 6.0.7 → 7.1.0 | PHP 7.4 | PHP 8.x puca na `Angie\Error::$file` |
| 7.1.0 → 7.1.382 | PHP 7.4 | Isti razlog |
| 7.1.382 → 7.4.766 | PHP 8.3 | AC 7.4.766 koristi union types — zahteva PHP 8.0+ |
| 7.4.766 → 8.0.31 | PHP 8.3 | |

**Status:** Implementirano i potvrđeno testiranjem — sve stepenice prošle smoke test HTTP 200.

---

## Problem 3 — `MigrateAddedReferenceColumnToRemoteInvoices` pada u koraku `7.4.766 → 8.0.31` ✅ REŠENO

**Gde se pojavljuje:** Stepenica `7.4.766 → 8.0.31`, pri kraju liste migracija

**Simptom:**
```
OK: OK: Executing MigrateRemoveXeroIntegrationAndInvoices
Error #1054: Unknown column 'updated_on' in 'INSERT INTO'
```

**Uzrok (pretpostavka):**  
Migracija `MigrateAddedReferenceColumnToRemoteInvoices` pokušava da uradi INSERT u tabelu `remote_invoices` sa kolonom `updated_on`, ali ta kolona ne postoji u šemi. Prethodna migracija `MigrateRemoveXeroIntegrationAndInvoices` je možda uklonila ili rekreirala tabelu bez te kolone, ili je kolona trebalo da bude dodata u ranijem koraku koji nije prošao ispravno zbog MariaDB razlike u ponašanju.

**Mogući uzroci:**
1. Redosled migracija — `MigrateAddedReferenceColumnToRemoteInvoices` pretpostavlja da `updated_on` već postoji (trebalo da ga doda neka ranija migracija)
2. MariaDB vs MySQL razlika u DDL ponašanju (`ALTER TABLE` semantika)

**Root cause (utvrđen query logom):**

`integrations` tabela u dumpu (5.8.7 era) **nema `updated_on`** kolonu. `MigrateRemoveSelfhostedOauth1QuickbookIntegration` (korak 7.4.766) obrisao je QB integraciju iz baze. Kada `MigrateAddedReferenceColumnToRemoteInvoices` pozove `Integrations::findFirstByType(QuickbooksIntegration::class)`, AC 8.x ORM ima **find-or-create** semantiku — ne nalazeći QB, pravi novi record:

```sql
INSERT INTO integrations (type, created_on, updated_on) VALUES ('QuickbooksIntegration', ...)
```

Ovaj INSERT puca jer `integrations` nema `updated_on`.

**Fix — zameniti ORM poziv direktnim SQL-om u migraciji:**

```php
$row = DB::executeFirstRow(
    "SELECT raw_additional_properties FROM integrations WHERE type = 'QuickbooksIntegration' LIMIT 1"
);
if ($row) {
    $props = @unserialize($row['raw_additional_properties']);
    $realm_id = $props['realm_id'] ?? null;
    if (!empty($realm_id)) {
        $this->execute('UPDATE remote_invoices SET reference_id = ? WHERE type = ?', $realm_id, 'QuickbooksInvoice');
    }
}
```

Ovo zaobilazi find-or-create i ne dira `integrations` tabelu.

`MigrateCheckForUpdatedOnRemoteInvoices` (prethodni fix) bio je no-op jer `remote_invoices` VEĆ ima `updated_on` u dumpu — problem je bio u `integrations` tabeli.

**Status:** Implementirano — direktorijum `2026-01-20-add-integrations-updated-on` (migracija `MigrateAddIntegrationsUpdatedOn`) premešten na `2025-04-11-add-integrations-updated-on`. AC sortira migracije po datumu direktorijuma (`ksort`), pa sada `updated_on` kolona postoji pre nego što `MigrateAddedReferenceColumnToRemoteInvoices` (`2025-04-14`) pozove `findFirstByType()` koji ima find-or-create semantiku.

---

*(ovaj fajl se dopunjava kako migracija napreduje)*
