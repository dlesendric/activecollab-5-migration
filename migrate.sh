#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# migrate.sh — Sekvencijalna nadogradnja ActiveCollab 5.8.7 → 8.0.31
#
# Pokreni unutar migrate-app kontejnera:
#   sh /migrate/migrate.sh
#   sh /migrate/migrate.sh --from 6.0.7
#   sh /migrate/migrate.sh --help
#
# Tok:
#   1. STEPS — kontrolisane stepenice 5.8.7 → 7.4.766 (specifični PHP, --dont-download-latest)
#   2. Finalni upgrade — php tasks/activecollab-cli.php upgrade (bez --dont-download-latest)
#      Ova komanda je ista kao ona koju korisnik pokreće na svom serveru.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

AC_ROOT="/var/www/html/app/activecollab"
VERSION_PHP="${AC_ROOT}/config/version.php"

SNAPSHOT_DIR="${SCRIPT_DIR}/_snapshots"
LOG_DIR="${SCRIPT_DIR}/_logs"
LOG_FILE="${LOG_DIR}/migrate-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$SNAPSHOT_DIR" "$LOG_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
die() { echo "[$(date '+%H:%M:%S')] GREŠKA: $*" | tee -a "$LOG_FILE" >&2; exit 1; }

# Stepenice: "from_ver  to_ver  php_bin"
# Idu do 7.4.766 — finalni upgrade (8.0.31) se radi zasebno bez --dont-download-latest
STEPS=(
    "5.8.7   6.0.7   /usr/bin/php74"
    "6.0.7   7.1.0   /usr/bin/php74"
    "7.1.0   7.1.382 /usr/bin/php74"
    "7.1.382 7.4.766 /usr/bin/php83"
)

FINAL_VERSION="8.0.31"
FINAL_PHP="/usr/bin/php83"

usage() {
    cat <<EOF
Upotreba: sh /migrate/migrate.sh [OPCIJE]

  --from <verzija>   Počni od stepenice: 5.8.7 | 6.0.7 | 7.1.0 | 7.1.382 | 7.4.766 | final
  --help             Prikaži ovaj tekst
EOF
}

# ---------------------------------------------------------------------------
# Parsiranje argumenata
# ---------------------------------------------------------------------------
FROM_VERSION=""
while [[ $# -gt 0 ]]; do
    case "${1:-}" in
        --from)  FROM_VERSION="${2:-}"; shift 2 ;;
        --help)  usage; exit 0 ;;
        *)       die "Nepoznat argument: $1  (koristite --help)" ;;
    esac
done

START_IDX=0
SKIP_STEPS=0
if [[ -n "$FROM_VERSION" ]]; then
    if [[ "$FROM_VERSION" == "final" ]]; then
        SKIP_STEPS=1
    else
        found=0
        for i in "${!STEPS[@]}"; do
            from_ver=$(echo "${STEPS[$i]}" | awk '{print $1}')
            if [[ "$from_ver" == "$FROM_VERSION" ]]; then
                START_IDX=$i; found=1; break
            fi
        done
        [[ $found -eq 1 ]] || die "Nepoznata verzija za --from: '$FROM_VERSION'  (dostupno: 5.8.7 | 6.0.7 | 7.1.0 | 7.1.382 | 7.4.766 | final)"
    fi
fi

# ---------------------------------------------------------------------------
# Učitaj .env i provjeri MySQL
# ---------------------------------------------------------------------------
[[ -f "${SCRIPT_DIR}/.env" ]] || die ".env nije pronađen. Pokrenite init.sh prvo."
set -a; source "${SCRIPT_DIR}/.env"; set +a

log "Proveravam MySQL..."
for i in $(seq 1 12); do
    if mysqladmin ping -h mysql -uroot -proot --silent 2>/dev/null; then
        log "MySQL spreman."; break
    fi
    [[ $i -lt 12 ]] || die "MySQL nije odgovorio. Da li je migrate-db podignut?"
    sleep 5
done

# ---------------------------------------------------------------------------
# Pomoćne funkcije
# ---------------------------------------------------------------------------

find_zip() {
    local version="$1"
    local name="activecollab-${version}.zip"
    if   [[ -f "${SCRIPT_DIR}/_cache/${name}"  ]]; then echo "${SCRIPT_DIR}/_cache/${name}"
    elif [[ -f "/var/www/html/app/${name}"     ]]; then echo "/var/www/html/app/${name}"
    else die "ZIP nije pronađen: ${name}  (stavite ga u _cache/ ili activecollab/)"; fi
}

get_db_version() {
    mysql -h mysql -uroot -proot -sN activecollab \
        -e "SELECT value FROM config_options WHERE name='version' LIMIT 1" 2>/dev/null \
        | tr -d '\r\n' || echo ""
}

extract_version_folder() {
    local version="$1"
    local zip
    zip=$(find_zip "$version")
    log "Ekstraktujem activecollab/${version}/ iz $(basename "$zip")..."
    unzip -q -o "$zip" "activecollab/${version}/*" -d "${AC_ROOT}"
    unzip -q -o "$zip" "tasks/*"  -d "${AC_ROOT}" 2>/dev/null || true
    unzip -q -o "$zip" "public/*" -d "${AC_ROOT}" 2>/dev/null || true
}

set_version() {
    local version="$1"
    log "Postavljam version.php → ${version}"
    printf '<?php\n\n  const APPLICATION_VERSION = '"'"'%s'"'"';\n' "$version" > "$VERSION_PHP"
}

run_upgrade() {
    local php_bin="$1"
    local to_ver="$2"
    log "Pokrećem upgrade → ${to_ver}  [${php_bin}]"
    cd "${AC_ROOT}"
    "$php_bin" -d memory_limit=2G -d max_execution_time=0 tasks/activecollab-cli.php upgrade --dont-download-latest
    cd - > /dev/null
    log "Upgrade na ${to_ver} završen."
}

run_final_upgrade() {
    local php_bin="$1"
    local to_ver="$2"
    log "Pokrećem finalni upgrade → ${to_ver}  [${php_bin}]"
    cd "${AC_ROOT}"
    "$php_bin" -d memory_limit=2G -d max_execution_time=0 tasks/activecollab-cli.php upgrade
    cd - > /dev/null
    log "Finalni upgrade na ${to_ver} završen."
}

snapshot_db() {
    local version="$1"
    local out="${SNAPSHOT_DIR}/after-${version}.sql.gz"
    log "Snimam snapshot → $(basename "$out")"
    mysqldump -h mysql -uroot -proot --single-transaction activecollab | gzip > "$out"
    log "Snapshot ok ($(du -h "$out" | cut -f1))."
}

smoke_test() {
    local version="$1"
    local migrations_dir="${AC_ROOT}/activecollab/${version}/migrations"

    if [[ ! -d "$migrations_dir" ]]; then
        log "Smoke test: migrations dir nije pronađen za ${version} — preskačem."
        return 0
    fi

    local last_dir
    last_dir=$(find "$migrations_dir" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)

    if [[ -z "$last_dir" ]]; then
        log "Smoke test: nema migracija za ${version} — preskačem."
        return 0
    fi

    local class_name
    class_name=$(find "$last_dir" -name "Migrate*.class.php" | head -1 | xargs -I{} basename {} .class.php)

    if [[ -z "$class_name" ]]; then
        log "Smoke test: ne mogu naći klasu migracije u $(basename "$last_dir") — preskačem."
        return 0
    fi

    local count
    count=$(mysql -h mysql -uroot -proot -sN activecollab \
        -e "SELECT COUNT(*) FROM executed_model_migrations WHERE migration = '${class_name}'" 2>/dev/null || echo "0")

    if [[ "${count:-0}" -gt 0 ]]; then
        log "Smoke test OK — '${class_name}' izvršena (AC ${version})"
    else
        log "Smoke test UPOZORENJE — '${class_name}' nije u executed_model_migrations! Migracija možda nije prošla."
    fi
}

# ---------------------------------------------------------------------------
# Jedna stepenica
# ---------------------------------------------------------------------------
run_step() {
    local from_ver to_ver php_bin
    read -r from_ver to_ver php_bin <<< "$1"

    log "================================================================"
    log "STEPENICA  ${from_ver} → ${to_ver}   [${php_bin}]"
    log "================================================================"

    local db_ver
    db_ver=$(get_db_version)
    if [[ -n "$db_ver" && "$db_ver" == "$to_ver" ]]; then
        log "Baza već na ${to_ver} — preskačem."; return 0
    fi

    extract_version_folder "$to_ver"
    set_version "$to_ver"
    run_upgrade "$php_bin" "$to_ver"
    snapshot_db "$to_ver"
    smoke_test "$to_ver"
}

# ---------------------------------------------------------------------------
# Glavna petlja — kontrolisane stepenice
# ---------------------------------------------------------------------------
if [[ $SKIP_STEPS -eq 0 ]]; then
    log "Pokretam migraciju: $(echo "${STEPS[$START_IDX]}" | awk '{print $1}') → ${FINAL_VERSION}"
    for (( i = START_IDX; i < ${#STEPS[@]}; i++ )); do
        run_step "${STEPS[$i]}"
    done
fi

# ---------------------------------------------------------------------------
# Finalni upgrade — php tasks/activecollab-cli.php upgrade (bez --dont-download-latest)
# Ista komanda koja se pokreće na korisnikovom serveru
# ---------------------------------------------------------------------------
log "================================================================"
log "FINALNI UPGRADE  → ${FINAL_VERSION}   [${FINAL_PHP}]"
log "================================================================"

db_ver=$(get_db_version)
if [[ -n "$db_ver" && "$db_ver" == "$FINAL_VERSION" ]]; then
    log "Baza već na ${FINAL_VERSION} — preskačem finalni upgrade."
else
    run_final_upgrade "$FINAL_PHP" "$FINAL_VERSION"
    local actual_ver
    actual_ver=$(get_db_version)
    snapshot_db "${actual_ver:-$FINAL_VERSION}"
    smoke_test "${actual_ver:-$FINAL_VERSION}"
fi

log "================================================================"
log "Migracija završena! AC ${FINAL_VERSION}+"
log "Snapshotovi: ${SNAPSHOT_DIR}/"
log "Log: ${LOG_FILE}"
log "================================================================"
