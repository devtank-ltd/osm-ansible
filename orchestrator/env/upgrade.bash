#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail


readonly BASE_IMAGE_ALIAS="debian/trixie/default"
readonly DATABASES=(chirpstack_as chirpstack_ns osm)
readonly GRAFANA_FILES=(
    /var/lib/grafana/grafana.db
    /etc/grafana/grafana.ini
    /etc/grafana/provisioning
)
readonly PGSQL_VER=17

readonly CLI="/srv/osm-lxc/orchestrator/orchestrator_cli.py"
readonly LOG_TFMT="%F %T"
readonly FILE_TFMT="%F_%H_%M_%S"
readonly DB_TFMT="%Y-%m-%d %H:%M:%S" # $((10#$tm))""
WORK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd )"
readonly WORK_DIR


t() {
    local fmt="$1"
    printf '%('"$fmt"')T' -1
}

d() {
    local seconds="$1"
    printf '%(%Y-%m-%d %H:%M:%S)T' "$((10#$seconds))"
}

die() {
    log "FATAL: $*" >&2
    exit 1
}

log() {
    printf '%s: %s\n' "[$(t "$LOG_TFMT")]" "$*"
}

run() {
    log "$@" 1>&2
    "$@" || die "$* failed"
}

instance_check() {
    local instance="$1"
    if ! out="$(run incus exec "$instance" -- true 2>&1)"; then
        log "$out"
        return 1
    fi
}

location() {
    local instance="$1"
    while read -r line; do
        if  [[ "$line" =~ ^Location: ]]; then
            printf '%s' "${line##*: }"
            return
        fi
    done < <(incus info "$instance")
}

clone_instance() {
    local instance="$1"
    local target="$2"
    local clone_name="${instance}-clone"

    run incus snapshot create "$instance" "$clone_name" --reuse
    run incus copy "${instance}/${clone_name}" "$clone_name" --target "$target"
    run incus start "$clone_name"

    if ! instance_check "$clone_name"; then
    die "Check '$clone_name' instance"
    fi
}

create_upgrade_instance() {
    local name="$1"
    local target="$2"
    local instance="${name}-upgrade"

    run incus init devtank:"$BASE_IMAGE_ALIAS" "$instance" --target "$target"
    run incus start "$instance"
    run incus exec "$instance" -- \
          sed -i '$ashared_preload_libraries = '\'timescaledb''\''' \
          "/etc/postgresql/${PGSQL_VER}/main/postgresql.conf"
    run incus restart "$instance"

    if ! instance_check "$instance"; then
    die "Check '$instance' instance"
    fi
}

_dump_postgres() {
    local instance="$1"
    local dl_dir="$2"
    local uid
    uid="$(incus exec "$instance" -- id -u postgres)"
    local incus_dump_cmd=(--cwd /tmp --user "$uid" --)
    local databases=( "${DATABASES[@]}" )

    run incus exec "$instance" -- systemctl restart postgresql
    run incus exec "$instance" "${incus_dump_cmd[@]}" pg_dumpall --globals-only -f globals.sql

    for db in "${databases[@]}"; do
        run incus exec "$instance" "${incus_dump_cmd[@]}" pg_dump -Fc -d "$db" -f "${db}.sql"
    done

    databases+=(globals)

    for db in "${databases[@]}"; do
        run incus file pull "${instance}/tmp/${db}.sql" "$dl_dir"
    done
}

_backup_grafana() {
    local instance="$1"
    local dl_dir="$2"
    for file in "${GRAFANA_FILES[@]}"; do
        run incus file pull "${instance}/${file}" "$dl_dir" --recursive
    done
}

_restore_postgres() {
    local instance="$1"
    local dl_dir="$2"
    local uid
    uid="$(run incus exec "$instance" -- id -u postgres)"
    local incus_db_cmd=(run incus exec "$instance" --cwd /tmp --user "$uid" --)
    local files=( "${DATABASES[@]}" globals)

    for file in "${files[@]}"; do
        run incus file push "${dl_dir}/${file}.sql" "${instance}/tmp/"
    done

    "${incus_db_cmd[@]}" psql -d postgres -f globals.sql

    for db in "${DATABASES[@]}"; do
        "${incus_db_cmd[@]}" psql -c "CREATE DATABASE $db"

        if [[ "$db" == "osm" ]]; then
            "${incus_db_cmd[@]}" psql -d "$db" -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"

            log "WARNING: workaround for versions mismatch"
            "${incus_db_cmd[@]}" psql -d "$db" -c "DELETE from _timescaledb_catalog.metadata WHERE key = 'timescaledb_version' AND value = '2.19.3';"

            "${incus_db_cmd[@]}" psql -d "$db" -c "SELECT timescaledb_pre_restore();"
            "${incus_db_cmd[@]}" psql -d "$db" -c "alter extension timescaledb update to '2.19.3';"

        fi
        "${incus_db_cmd[@]}" pg_restore -d "$db" -Fc "${db}.sql"
        if [[ "$db" == "osm" ]]; then
            log "WARNING: workaround for versions mismatch"
            "${incus_db_cmd[@]}" psql -d "$db" -c "DELETE from _timescaledb_catalog.metadata WHERE key = 'timescaledb_version' AND value = '2.20.0';"

            "${incus_db_cmd[@]}" psql -d "$db" -c "SELECT timescaledb_post_restore();"
        fi
    done
}

_restore_grafana() {
    local instance="$1"
    local dl_dir="$2"
    local flags=()

    for path in "${GRAFANA_FILES[@]}"; do
        file="${path##*/}"
        [[ "provisioning" == "$file" ]] && flags=(--recursive)
        run incus file push "${dl_dir}/${file}" "${instance}/${path}" "${flags[@]}"
        flags=()
        run incus exec "$instance" -- chown -R grafana:grafana "$path"
    done
    run incus exec "$instance" -- systemctl restart grafana-server
}

do_backup() {
    local instance="$1"
    local dl_dir="$2"
    instance="${instance}-clone"

    if ! instance_check "$instance"; then
        die "Check '$instance' instance"
    fi

    _dump_postgres "$instance" "$dl_dir"
    _backup_grafana "$instance" "$dl_dir"
}

do_restore() {
    local instance="$1"
    local dl_dir="$2"
    instance="${instance}-upgrade"

    if ! instance_check "$instance"; then
        die "Check '$instance' instance"
    fi

    _restore_postgres "$instance" "$dl_dir"
    _restore_grafana "$instance" "$dl_dir"
}

passwd_from_file() {
    local customer="$1"
    incus exec "$customer" -- cat /root/passwords.json | \
        jq -r '.TImescaledb.devtank'
}

passwd_from_db() {
    local customer="$1"
    "$CLI" get_customer_passwords "$customer" | \
        sed -rn '/^\{/,/^}$/ p' | \
        jq -r '.TImescaledb.devtank'
}

dump_ranged_data() {
    local instance="$1"
    local dl_dir="$2"
    # local db_passwd="$3"
    local t_start="$3"
    local t_end="$4"

    local db_user="devtank"
    local tb="pg_sf"
    local out="tsdb_${t_start//[: ]/_}---${t_end//[: ]/_}.csv"
    local uid

    # local conn="postgres://${db_user}:${db_passwd}@localhost:5432/osm?sslmode=require"
    # local q="\COPY (SELECT * FROM ${tb} WHERE _time > '${t_start}' AND _time < '${t_end}') TO /tmp/${out} CSV"

    # for testing
    local q="\COPY (SELECT * FROM ${tb} WHERE _time > '2025-01-01 00:00:00' AND _time < '2025-01-07 00:00:00') TO /tmp/${out} CSV"

    uid="$(run incus exec "$instance" -- id -u postgres)"
    # run incus exec "$instance" --cwd /tmp --user "$uid" -- psql -d osm "$conn" -c "$q"
    run incus exec "$instance" --cwd /tmp --user "$uid" -- psql -d osm -c "$q"
    run incus file pull "${instance}/tmp/${out}" "$dl_dir"
}

restore_ranged_data() {
    local instance="$1"
    local dl_dir="$2"
    # local db_passwd="$3"
    local data_file="$3"

    local db_user="devtank"
    local uid
    # local conn="postgres://${db_user}:${db_passwd}@localhost:5432/osm?sslmode=require"
    # local q="\copy pg_sf FROM '${data_file}' WITH (FORMAT CSV)"

    uid="$(run incus exec "${instance}-upgrade" -- id -u postgres)"
    run incus file push "${dl_dir}/${data_file}" "${instance}-upgrade/tmp/"

    # FIXME: workaround
    # ERROR:  function "continuous_agg_invalidation_trigger" is not supported under the current "apache" license
    # HINT:  Upgrade your license to 'timescale' to use this free community feature.
    run incus exec "${instance}-upgrade" --cwd /tmp/ --user "$uid" -- psql -d osm -c \
        "CREATE TABLE pg_sf_staging (LIKE pg_sf INCLUDING ALL)"
    run incus exec "${instance}-upgrade" --cwd /tmp/ --user "$uid" -- psql -d osm -c \
        "\copy pg_sf_staging FROM '${data_file}' WITH (FORMAT CSV)"
    run incus exec "${instance}-upgrade" --cwd /tmp/ --user "$uid" -- psql -d osm -c \
        "INSERT INTO pg_sf SELECT * FROM pg_sf_staging"
    run incus exec "${instance}-upgrade" --cwd /tmp/ --user "$uid" -- psql -d osm -c \
        "DROP DATABASE pg_sf_staging"

    # run incus exec "${instance}-upgrade" --cwd /tmp/ --user "$uid" -- psql -d osm -c "$q"
}

swap_instances() {
    local instance="$1"
    run incus stop "$instance"
    run incus stop "${instance}-upgrade"
    run incus rename "${instance}-old"
    run incus rename "${instance}-upgrade" "$instance"
    run incus start "$instance"
}

main() {
    local customer_name="$1"

    if ! instance_check "$customer_name"; then
        die "Check incus instance"
    fi

    local _start_t="$EPOCHREALTIME"
    local _end_t=""
    local gap_dump=""

    log "Upgrading '$customer_name' instance on '$BASE_IMAGE_ALIAS' base image"
    LOG_FILE="${WORK_DIR}/upgrade_${customer_name}_$(t "$FILE_TFMT").log"
    DL_DIR="$(mktemp -d --suffix="___${customer_name}" -p "$WORK_DIR")"
    # exec 3>&1 1>>"$LOG_FILE" 2>&1
    exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

    target="$(location "$customer_name")"
    clone_instance "$customer_name" "$target"
    create_upgrade_instance "$customer_name" "$target"
    do_backup "$customer_name" "$DL_DIR"
    do_restore "$customer_name" "$DL_DIR"

    _start_t="$(d $(( ${_start_t/.*/} - 1 )))"
    _end_t="$(d $(( ${EPOCHREALTIME/.*/} + 1 )))"

    db_pswd="$(passwd_from_file "$customer_name")"
    # db_pswd="$(passwd_from_db "$customer_name")"
    # set explicitly "dump_ranged_data" routine
    gap_dump="tsdb_${_start_t//[: ]/_}---${_end_t//[: ]/_}.csv"

    dump_ranged_data "$customer_name" "$DL_DIR" "$_start_t" "$_end_t"
    restore_ranged_data "$customer_name" "$DL_DIR" "$gap_dump"

}

main "$@"
