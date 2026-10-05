#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

dump_databases() {
    local database database_index=0 archive
    rm -rf -- "$STAGING_DIR/dumps"
    mkdir -m 700 -- "$STAGING_DIR/dumps"
    pg_dumpall --no-password --roles-only --quote-all-identifiers --file="$STAGING_DIR/dumps/roles.sql"
    psql -X --no-password --set=ON_ERROR_STOP=1 --no-align --tuples-only --record-separator-zero \
        --command='SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY oid' \
        > "$STAGING_DIR/dumps/database-names.bin"
    printf 'archive,database\n' > "$STAGING_DIR/dumps/databases.csv"
    printf 'cluster=%s\nstarted_at=%s\n' "$CLUSTER_NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$STAGING_DIR/dumps/metadata.txt"
    while IFS= read -r -d '' database; do
        database_index=$((database_index + 1))
        printf -v archive 'database-%04d' "$database_index"
        printf '%s.dump,"%s"\n' "$archive" "${database//\"/\"\"}" >> "$STAGING_DIR/dumps/databases.csv"
        PGDATABASE="$database" pg_dump --no-password --format=custom --create --quote-all-identifiers --no-tablespaces \
            --file="$STAGING_DIR/dumps/$archive.dump"
        PGDATABASE="$database" psql -X --no-password --set=ON_ERROR_STOP=1 --csv \
            --command='SELECT extname, extversion FROM pg_extension ORDER BY extname' \
            > "$STAGING_DIR/dumps/$archive.extensions.csv"
    done < "$STAGING_DIR/dumps/database-names.bin"
    [[ "$database_index" -gt 0 ]] || die 'No databases were dumped; refusing to upload.'
    printf 'completed_at=%s\ndatabases=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$database_index" \
        >> "$STAGING_DIR/dumps/metadata.txt"
    (cd -- "$STAGING_DIR/dumps" && sha256sum -- * > SHA256SUMS)
}

prepare_dump() {
    : "${CLUSTER_NAME:?}" "${BACKUP_TOKEN:?}"
    STAGING_DIR=${STAGING_DIR:-/staging}
    [[ "$BACKUP_TOKEN" =~ ^[a-zA-Z0-9-]+$ ]] || die 'Invalid backup token.'
    exec 9> "$STAGING_DIR/.backup.lock"
    flock --nonblock 9 || die 'Another backup job holds the staging lock.'
    if [[ -f "$STAGING_DIR/dump-complete" ]]; then
        [[ "$(< "$STAGING_DIR/dump-complete")" == "$BACKUP_TOKEN" ]] || die 'Staging belongs to another backup.'
        printf 'Reusing the completed dump for %s\n' "$BACKUP_TOKEN"
        return
    fi
    dump_databases
    printf '%s\n' "$BACKUP_TOKEN" > "$STAGING_DIR/dump-complete.tmp"
    mv -- "$STAGING_DIR/dump-complete.tmp" "$STAGING_DIR/dump-complete"
}

main() {
    prepare_dump
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
