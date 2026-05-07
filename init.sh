#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# init.sh — Bootstrap: pokretanje baze i uvoz SQL dumpa
# Pokreni unutar migrate-app kontejnera: sh /migrate/init.sh
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/_logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/init-$(date +%Y%m%d-%H%M%S).log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
die() { echo "[$(date '+%H:%M:%S')] GREŠKA: $*" | tee -a "$LOG_FILE" >&2; exit 1; }

AC_DIR="/var/www/html/app/activecollab"
INITIAL_VERSION="5.8.7"

# ---------------------------------------------------------------------------
# 1. Preduslovi
# ---------------------------------------------------------------------------
log "Proveravam preduslove..."
for cmd in mysql mysqladmin unzip; do
    command -v "$cmd" &>/dev/null || die "Nedostaje komanda '$cmd' u kontejneru."
done

# ---------------------------------------------------------------------------
# 2. Validacija
# ---------------------------------------------------------------------------
[[ -f "${SCRIPT_DIR}/.env" ]] || die "Fajl .env nije pronađen u ${SCRIPT_DIR}."
set -a; source "${SCRIPT_DIR}/.env"; set +a

[[ -n "${DB_NAME:-}" ]] || die ".env ne sadrži DB_NAME."

SQL_FILE="${SCRIPT_DIR}/${DB_NAME}"
[[ -f "$SQL_FILE" ]] || die "SQL dump '${SQL_FILE}' nije pronađen."

CONFIG_PHP="${AC_DIR}/config/config.php"
[[ -f "$CONFIG_PHP" ]] || die "Nedostaje ${CONFIG_PHP} — kopirajte config.empty.php u config/config.php i popunite vrednosti."

log "SQL dump:   $SQL_FILE"
log "config.php: $CONFIG_PHP"

# ---------------------------------------------------------------------------
# 3. Čišćenje: ukloni ekstraktovane verzije, work/ i resetuj version.php
# ---------------------------------------------------------------------------
log "Čistim stare verzije iz ${AC_DIR}/activecollab/ (zadržavam ${INITIAL_VERSION})..."
if [[ -d "${AC_DIR}/activecollab" ]]; then
    for dir in "${AC_DIR}/activecollab/"/*/; do
        ver=$(basename "$dir")
        if [[ "$ver" != "$INITIAL_VERSION" ]]; then
            rm -rf "$dir"
            log "  Uklonjen: ${ver}/"
        fi
    done
fi

log "Čistim work/ (interne AC backup kopije)..."
if [[ -d "${AC_DIR}/work" ]]; then
    rm -rf "${AC_DIR}/work/"*  2>/dev/null || true
fi

log "Resetujem version.php → ${INITIAL_VERSION}"
printf '<?php\n\n  const APPLICATION_VERSION = '"'"'%s'"'"';\n' "$INITIAL_VERSION" \
    > "${AC_DIR}/config/version.php"

# ---------------------------------------------------------------------------
# 4. Čekaj MySQL
# ---------------------------------------------------------------------------
log "Čekam MySQL na hostu 'mysql' (timeout ~120s)..."
for i in $(seq 1 24); do
    if mysqladmin ping -h mysql -uroot -proot --silent 2>/dev/null; then
        log "MySQL je spreman."; break
    fi
    [[ $i -lt 24 ]] || die "MySQL nije odgovorio. Proverite da li je migrate-db kontejner podignut."
    sleep 5
done

# ---------------------------------------------------------------------------
# 5. Drop & create baze
# ---------------------------------------------------------------------------
log "Kreiram čistu bazu 'activecollab'..."
mysql -h mysql -uroot -proot \
    -e "DROP DATABASE IF EXISTS activecollab; CREATE DATABASE activecollab CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# ---------------------------------------------------------------------------
# 6. Import SQL dumpa
# ---------------------------------------------------------------------------
log "Uvozim '${SQL_FILE}' (~244 MB, može potrajati nekoliko minuta)..."
sed -E 's/DEFINER=`[^`]+`@`[^`]+`//g' "$SQL_FILE" | mysql -h mysql -uroot -proot activecollab
log "Import završen."

# ---------------------------------------------------------------------------
log "================================================================"
log "Init OK — pokrenite: sh /migrate/migrate.sh"
log "================================================================"
