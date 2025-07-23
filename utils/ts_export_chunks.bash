#!/usr/bin/env bash

# example usage:
# ./ts_export_chunks.bash 2025-07-01 2025-07-07

set -o errexit
set -o nounset
set -o pipefail

readonly DB_NAME="osm"
readonly DB_USER="devtank"
readonly DB_HOST="localhost"
readonly DB_PORT=5432
readonly -a TABLES=(
    "pg_sf"
    "pg_sf_ds"
    "pg_sf_ds_text"
    "kwh"
    "plscnt"
    "scaled_current"
)

do_export() {
    local t_from="$1"
    local t_to="$2"
    local file=""

    local pg_args=(
        -U "$DB_USER"
        -h "$DB_HOST"
        -p "$DB_PORT"
        -d "$DB_NAME"
    )

    for tbl in "${TABLES[@]}"; do
        local column="_time"
        if [[ "$tbl" =~ ^(pg_sf_ds|pg_sf_ds_text|kwh|plscnt|scaled_current)$ ]]; then
            column="bucket"
        fi

        file="${tbl}_${t_from}_${t_to}.csv"
        printf "!!! exporting '%s' to '%s'... " "$tbl" "$file"
        psql "${pg_args[@]}" --command "\COPY (
            SELECT * FROM $tbl
            WHERE $column >= '$t_from' AND $column < '$t_to'
        ) TO '$file' WITH CSV HEADER"
        echo "done"
    done
}

do_export "$@"
