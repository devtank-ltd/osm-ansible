#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

readonly DB_NAME="osm"
readonly DB_USER="devtank"
readonly DB_HOST="localhost"
readonly DB_PORT=5432

declare -A TABLE_KEYS=(
    [pg_sf]="_time, osm_id"
    [pg_sf_ds]="bucket, name, osm_name"
    [pg_sf_ds_text]="bucket, name, osm_name"
    [kwh]="bucket, name, osm_name"
    [plscnt]="bucket, name, osm_name"
    [scaled_current]="bucket, name, osm_name"
)

# TODO: look at "upsert_into_main_tables" notes
# declare -A UPDATE_FIELDS=(
#     [pg_sf]="_value = EXCLUDED._value, _value_text = EXCLUDED._value_text"
#     [pg_sf_ds]="ds_val = EXCLUDED.ds_val"
#     [pg_sf_ds_text]="ds_val = EXCLUDED.ds_val"
#     [kwh]="kwh_val = EXCLUDED.kwh_val"
#     [plscnt]="psum = EXCLUDED.psum"
#     [scaled_current]="scaled_cc = EXCLUDED.scaled_cc"
# )

readonly PG_ARGS=(-U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -d "$DB_NAME")

create_staging_tables() {
    for table in "${!TABLE_KEYS[@]}"; do
        local staging="${table}_staging"
        echo "Creating staging table: $staging"
        psql "${PG_ARGS[@]}" -c "CREATE TABLE IF NOT EXISTS $staging (LIKE $table INCLUDING ALL);"
        psql "${PG_ARGS[@]}" -c "TRUNCATE $staging;"
    done
}

import_csv_to_staging() {
    local data_dir="$1"

    for file in "$data_dir"/*.csv; do
        [[ ! -e "$file" ]] && continue
        local base
        base=$(basename "$file")
        local table="${base%%_[0-9]*}"
        local staging="${table}_staging"

        [[ -z "${TABLE_KEYS[$table]:-}" ]] && {
            echo "Skipping unknown or raw table: $table"
            continue
        }

        echo "Importing $file into $staging"
        psql "${PG_ARGS[@]}" -c "\COPY $staging FROM '$file' WITH CSV HEADER"
    done
}

# TODO:
# Error on importing, but "pg_sf" table has no unique constraint on (_time, osm_id)
# according tho schema:
#   Upserting pg_sf_staging into pg_sf
#   Password for user devtank:
#   ERROR:  there is no unique or exclusion constraint matching the ON CONFLICT specification

# FIXME: possible fix
# psql -> ALTER TABLE pg_sf ADD CONSTRAINT pg_sf_unique_time_osm UNIQUE (_time, osm_id);

# upsert_into_main_tables() {
#     for table in "${!TABLE_KEYS[@]}"; do
#         local staging="${table}_staging"
#         local keys="${TABLE_KEYS[$table]}"
#         local update="${UPDATE_FIELDS[$table]}"

#         echo "Upserting $staging into $table"
#         psql "${PG_ARGS[@]}" -c "
#             INSERT INTO $table
#             SELECT * FROM $staging
#             ON CONFLICT ($keys)
#             DO UPDATE SET $update;
#         "
#     done
# }

insert_into_main_tables() {
    for table in "${!TABLE_KEYS[@]}"; do
        local staging="${table}_staging"
        local keys="${TABLE_KEYS[$table]}"

        # convert CSV keys into SQL conditions for WHERE NOT EXISTS
        local conditions=""
        local distinct_cols=""
        IFS=',' read -ra cols <<< "$keys"
        for col in "${cols[@]}"; do
            col=$(echo "$col" | xargs)  # trim spaces
            if [[ -n "$conditions" ]]; then
                conditions+=" AND "
                distinct_cols+=", "
            else
                distinct_cols+=""
            fi
            conditions+="m.$col = s.$col"
            distinct_cols+="$col"
        done

        echo "Inserting from $staging into $table (deduplicated, skip existing)"
        psql "${PG_ARGS[@]}" -c "
            INSERT INTO $table
            SELECT DISTINCT ON ($distinct_cols) *
            FROM $staging s
            WHERE NOT EXISTS (
                SELECT 1
                FROM $table m
                WHERE $conditions
            )
            ORDER BY $distinct_cols;
        "
    done
}

cleanup_staging() {
    for table in "${!TABLE_KEYS[@]}"; do
        local staging="${table}_staging"
        echo "Cleaning up staging table: $staging"
        psql "${PG_ARGS[@]}" -c "TRUNCATE $staging;"
    done
}

main() {
    local data_dir="$1"

    create_staging_tables
    import_csv_to_staging "$data_dir"
    # upsert_into_main_tables
    insert_into_main_tables
    cleanup_staging
}

main "$@"
