# ActiveCollab Migration Tool

A tool for sequentially upgrading an ActiveCollab self-hosted installation from version **5.8.7** to the latest available version.

Upgrade path: `5.8.7 → 6.0.7 → 7.1.0 → 7.1.382 → 7.4.766 → latest`

---

## Prerequisites

- PHP 7.4 and PHP 8.3 available on the server
- MySQL or MariaDB
- `unzip`, `mysqladmin`, `mysqldump`
- AC version ZIP archives placed in the `activecollab/` directory (see section below)

### Required ZIP archives

Download the following ZIP files and place them in the `activecollab/` directory:

```
activecollab/activecollab-7.1.382.zip
activecollab/activecollab-7.4.766.zip
```

The script automatically detects available ZIPs and builds the upgrade sequence. The minimum required set is `7.1.382` and `7.4.766` — these are the PHP version boundary points and cumulatively contain all migrations from `5.8.7` onward. ZIPs for older versions (`6.0.x`, `7.1.0`) are not needed.

You can download the ZIP archives from [activecollab.com/profile](https://activecollab.com/profile) under your license section, or request them by emailing [support@activecollab.com](mailto:support@activecollab.com).

The final version is downloaded automatically during migration (an active license key in `config.php` is required).

---

## Configuration

### 1. `.env` file

Create a `.env` file in the root directory of the tool:

```bash
DB_NAME=your_dump_name.sql
```

`DB_NAME` should point to the SQL dump of your current database (the file must be in the same directory as `.env`).

### 2. `config.php`

Make sure `activecollab/config/config.php` exists and contains valid database connection parameters. If it does not exist, copy `config.empty.php` and fill in the values.

### 3. PHP binaries

The script assumes the following paths:

| PHP version | Path |
|---|---|
| PHP 7.4 | `/usr/bin/php74` |
| PHP 8.3 | `/usr/bin/php83` |

If PHP binaries are located elsewhere on your server, update the `STEPS` and `FINAL_PHP` variables at the top of `migrate.sh`.

---

## Running

### Step 1 — Initialization

```bash
bash init.sh
```

This command:
- Checks prerequisites (commands, `.env`, SQL dump, `config.php`)
- Resets the database — **imports the SQL dump from scratch**
- Cleans up extracted version folders and temporary files

> **Warning:** `init.sh` always drops and recreates the database. Only run it when starting the migration over from the beginning.

### Step 2 — Migration

```bash
bash migrate.sh
```

The migration runs through all steps automatically and finishes with a final upgrade that downloads the latest version.

#### Resuming from a specific step

If the migration was interrupted, you can resume from a specific step:

```bash
bash migrate.sh --from 7.1.382
bash migrate.sh --from final    # final upgrade only
```

Available values for `--from`: `5.8.7`, `6.0.7`, `7.1.0`, `7.1.382`, `7.4.766`, `final`

---

## What the script does

After each step:
- **Snapshot** — saves the database state to `_snapshots/after-<version>.sql.gz`
- **Smoke test** — verifies in the database that the last migration for that version was executed

Logs are saved to `_logs/`.

---

## Docker (optional)

If you do not have the required PHP versions on your server, or want an isolated environment for testing, you can use the included Docker configuration.

### Prerequisites

- Docker Engine with the `docker compose` plugin

### Running

```bash
# Start the containers
docker compose up -d

# Enter the migrate-app container
docker exec -it migrate-app bash

# Inside the container, run the scripts
sh /migrate/init.sh
sh /migrate/migrate.sh
```

### Containers

| Container | Role |
|---|---|
| `migrate-app` | PHP 7.4 + PHP 8.3 FPM, bash environment for scripts |
| `migrate-db` | MariaDB 10.11 |
| `migrate-nginx` | nginx (ports 8886, 8887, 8888) |
| `migrate-phpmyadmin` | phpMyAdmin for database inspection |

The SQL dump and ZIP archives are automatically mounted from the local directory into the container — no need to copy them manually.
