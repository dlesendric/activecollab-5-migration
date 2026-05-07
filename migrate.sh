#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# migrate.sh — Sekvencijalna nadogradnja ActiveCollab → latest
#
# Pokreni unutar migrate-app kontejnera:
#   bash /migrate/migrate.sh
#   bash /migrate/migrate.sh --from 6.0.263
#   bash /migrate/migrate.sh --from final
#   bash /migrate/migrate.sh --help
#
# Tok:
#   1. STEPS — detektuju se automatski iz ZIP fajlova u activecollab/
#   2. Finalni upgrade — php tasks/activecollab-cli.php upgrade (bez --dont-download-latest)
#      Ova komanda je ista kao ona koju korisnik pokreće na svom serveru.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SNAPSHOT_DIR="${SCRIPT_DIR}/_snapshots"
LOG_DIR="${SCRIPT_DIR}/_logs"
LOG_FILE="${LOG_DIR}/migrate-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$SNAPSHOT_DIR" "$LOG_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
die() { echo "[$(date '+%H:%M:%S')] GREŠKA: $*" | tee -a "$LOG_FILE" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Učitaj .env — mora biti pre build_steps (PHP putanje)
# ---------------------------------------------------------------------------
[[ -f "${SCRIPT_DIR}/.env" ]] || die ".env nije pronađen."
set -a; source "${SCRIPT_DIR}/.env"; set +a

[[ -n "${DB_DATABASE:-}" ]]  || die ".env ne sadrži DB_DATABASE."
[[ -n "${DB_HOST:-}" ]]      || die ".env ne sadrži DB_HOST."
[[ -n "${DB_USER:-}" ]]      || die ".env ne sadrži DB_USER."
[[ -n "${DB_PASS:-}" ]]      || die ".env ne sadrži DB_PASS."
[[ -n "${AC_DIR:-}" ]]       || die ".env ne sadrži AC_DIR."
[[ -n "${PHP_BIN_74:-}" ]]   || die ".env ne sadrži PHP_BIN_74."
[[ -n "${PHP_BIN_83:-}" ]]   || die ".env ne sadrži PHP_BIN_83."

AC_ROOT="${AC_DIR}"
VERSION_PHP="${AC_ROOT}/config/version.php"

FINAL_PHP="${PHP_BIN_83}"
PHP74="${PHP_BIN_74}"
PHP83="${PHP_BIN_83}"
PHP_THRESHOLD="7.4.0"   # verzije >= ove zahtevaju PHP_BIN_83

# ---------------------------------------------------------------------------
# Helpers za poređenje verzija i PHP selekciju
# ---------------------------------------------------------------------------

version_ge() {
    # Vraća 0 (true) ako je $1 >= $2
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

php_for_version() {
    if version_ge "$1" "$PHP_THRESHOLD"; then echo "$PHP83"; else echo "$PHP74"; fi
}

# ---------------------------------------------------------------------------
# Detektuj stepenice iz ZIP fajlova u activecollab/
# ---------------------------------------------------------------------------
STEPS=()

build_steps() {
    local zip_dir="${SCRIPT_DIR}/activecollab"
    local versions=()

    for zip in "${zip_dir}"/activecollab-*.zip; do
        [[ -f "$zip" ]] || continue
        local ver
        ver=$(basename "$zip" .zip)
        ver="${ver#activecollab-}"
        versions+=("$ver")
    done

    [[ ${#versions[@]} -gt 0 ]] || die "Nema ZIP arhiva u ${zip_dir}/. Preuzmite ih i smestite tamo."

    local sorted=()
    while IFS= read -r ver; do
        sorted+=("$ver")
    done < <(printf '%s\n' "${versions[@]}" | sort -V)

    for ver in "${sorted[@]}"; do
        STEPS+=("${ver} $(php_for_version "$ver")")
    done

    if [[ ${#STEPS[@]} -gt 0 ]]; then
        log "Detektovane stepenice:"
        for step in "${STEPS[@]}"; do
            read -r t p <<< "$step"
            log "  → ${t}  [${p}]"
        done
    fi
}

build_steps

# ---------------------------------------------------------------------------
# Upotreba
# ---------------------------------------------------------------------------
usage() {
    local avail=""
    for s in "${STEPS[@]}"; do avail+="$(echo "$s" | awk '{print $1}') | "; done
    cat <<EOF
Upotreba: bash /migrate/migrate.sh [OPCIJE]

  --from <verzija>   Počni od stepenice (target verzija). Dostupno: ${avail}final
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
            to_ver=$(echo "${STEPS[$i]}" | awk '{print $1}')
            if [[ "$to_ver" == "$FROM_VERSION" ]]; then
                START_IDX=$i; found=1; break
            fi
        done
        if [[ $found -eq 0 ]]; then
            avail=""
            for s in "${STEPS[@]}"; do avail+="$(echo "$s" | awk '{print $1}') | "; done
            die "Nepoznata verzija za --from: '$FROM_VERSION'  (dostupno: ${avail}final)"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# MySQL check
# ---------------------------------------------------------------------------
log "Proveravam MySQL na hostu '${DB_HOST}'..."
for i in $(seq 1 12); do
    if mysqladmin ping -h "${DB_HOST}" -u"${DB_USER}" -p"${DB_PASS}" --silent 2>/dev/null; then
        log "MySQL spreman."; break
    fi
    [[ $i -lt 12 ]] || die "MySQL nije odgovorio na hostu '${DB_HOST}'."
    sleep 5
done

# ---------------------------------------------------------------------------
# Pomoćne funkcije
# ---------------------------------------------------------------------------

find_zip() {
    local version="$1"
    local name="activecollab-${version}.zip"
    if   [[ -f "${SCRIPT_DIR}/activecollab/${name}" ]]; then echo "${SCRIPT_DIR}/activecollab/${name}"
    elif [[ -f "${AC_ROOT}/${name}"                ]]; then echo "${AC_ROOT}/${name}"
    else die "ZIP nije pronađen: ${name}  (stavite ga u activecollab/)"; fi
}

get_file_version() {
    # Radi za oba formata koja AC koristi:
    #   const APPLICATION_VERSION = '7.4.766';      (naš set_version)
    #   define('APPLICATION_VERSION', '8.0.318');   (AC-ov updateVersionFile)
    grep "APPLICATION_VERSION" "$VERSION_PHP" 2>/dev/null \
        | sed "s/.*'\([^']*\)'[^']*$/\1/" \
        | head -1
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
    local actual_ver
    actual_ver=$(get_file_version)
    log "Finalni upgrade na ${actual_ver:-$to_ver} završen."
}

snapshot_db() {
    local version="$1"
    local out="${SNAPSHOT_DIR}/after-${version}.sql.gz"
    log "Snimam snapshot → $(basename "$out")"
    mysqldump -h "${DB_HOST}" -u"${DB_USER}" -p"${DB_PASS}" --single-transaction "${DB_DATABASE}" | gzip > "$out"
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
    count=$(mysql -h "${DB_HOST}" -u"${DB_USER}" -p"${DB_PASS}" -sN "${DB_DATABASE}" \
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
    local to_ver php_bin
    read -r to_ver php_bin <<< "$1"

    log "================================================================"
    log "STEPENICA  → ${to_ver}   [${php_bin}]"
    log "================================================================"

    local cur_ver
    cur_ver=$(get_file_version)
    if [[ -n "$cur_ver" && "$cur_ver" == "$to_ver" ]]; then
        log "Već na ${to_ver} — preskačem."; return 0
    fi

    extract_version_folder "$to_ver"
    set_version "$to_ver"
    run_upgrade "$php_bin" "$to_ver"
    snapshot_db "$to_ver"
    smoke_test "$to_ver"
}

# ---------------------------------------------------------------------------
# Glavna petlja — stepenice
# ---------------------------------------------------------------------------
if [[ $SKIP_STEPS -eq 0 && ${#STEPS[@]} -gt 0 ]]; then
    log "Pokretam migraciju: $(get_file_version) → latest"
    for (( i = START_IDX; i < ${#STEPS[@]}; i++ )); do
        run_step "${STEPS[$i]}"
    done
fi

# ---------------------------------------------------------------------------
# Finalni upgrade — php tasks/activecollab-cli.php upgrade (bez --dont-download-latest)
# Ista komanda koja se pokreće na korisnikovom serveru
# ---------------------------------------------------------------------------
log "================================================================"
log "FINALNI UPGRADE  [${FINAL_PHP}]"
log "================================================================"

cur_ver=$(get_file_version)
log "Trenutna verzija: ${cur_ver:-nepoznato} — pokrećem finalni upgrade..."

run_final_upgrade "$FINAL_PHP" "latest"
actual_ver=$(get_file_version)
snapshot_db "${actual_ver:-final}"
smoke_test "${actual_ver:-final}"

log "================================================================"
log "Migracija završena! AC ${actual_ver:-latest}"
log "Snapshotovi: ${SNAPSHOT_DIR}/"
log "Log: ${LOG_FILE}"
log "================================================================"
