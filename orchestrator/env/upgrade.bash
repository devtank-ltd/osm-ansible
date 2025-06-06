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

readonly LOG_TFMT="%F %T"
readonly FILE_TFMT="%F_%H_%M_%S"
WORK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd )"
readonly WORK_DIR


t() {
    local fmt="$1"
    printf '%('"$fmt"')T' -1
}

die() {
    log "FATAL: $*" >&2
    exit 1
}

log() {
    printf '%s: %s\n' "[$(t "$LOG_TFMT")]" "$*"
}

instance_check() {
    local instance="$1"
    if ! out="$(incus exec "$instance" -- true 2>&1)"; then
        log "$out"
        return 1
    fi
}

clone_instance() {
    local instance="$1"
    local clone_name="${instance}-clone"

    log "Create '$instance' snapshot"
    incus snapshot create "$instance" "$clone_name" --reuse || \
        die "Unable to create snapshot for '$instance' instance"

    log "Copy '$instance' snapshot to '$clone_name' instance"
    incus copy "${instance}/${clone_name}" "$clone_name" || \
        die "Unable to copy snapshot for '$instance' instance"

    log "Start '$clone_name' instance" || \
        die "Unable to start '$clone_name' instance"
    incus start "$clone_name"

    if ! instance_check "$clone_name"; then
    die "Check '$clone_name' instance"
    fi
}

create_upgrade_instance() {
    local name="$1"
    local instance="${name}-upgrade"

    log "Create '$instance' for upgrade"
    incus init devtank:"$BASE_IMAGE_ALIAS" "$instance" || \
        die "Unable to create '$instance' instance"

    log "Start '$instance'"
    incus start "$instance" || die "Unable to start '$instance' instance"
    log "Preload timescaledb extension"
    incus exec "$instance" -- \
          sed -i '$ashared_preload_libraries = '\'timescaledb''\''' \
          "/etc/postgresql/${PGSQL_VER}/main/postgresql.conf"
    incus restart "$instance"

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

    incus exec "$instance" -- systemctl restart postgresql
    incus exec "$instance" "${incus_dump_cmd[@]}" pg_dumpall --globals-only -f globals.sql

    for db in "${databases[@]}"; do
    log "Dump '$db' database on '$instance' instance"
    incus exec "$instance" "${incus_dump_cmd[@]}" pg_dump -Fc -d "$db" -f "${db}.sql" || \
    die "Error: dump '$db' dabases"
    done

    databases+=(globals)

    for db in "${databases[@]}"; do
    log "Pull '${db}.sql' file from '$instance' instance"
    incus file pull "${instance}/tmp/${db}.sql" "$dl_dir" || \
    die "Error: pull '${db}.sql' file from '$instance' instance"
    done
}

_backup_grafana() {
    local instance="$1"
    local dl_dir="$2"
    for file in "${GRAFANA_FILES[@]}"; do
        log "Pull '$file' from 'instance' instance"
        incus file pull "${instance}/${file}" "$dl_dir" --recursive || \
            die "Error: pull '${file}' file from '$instance' instance"
    done
}

_restore_postgres() {
    local instance="$1"
    local dl_dir="$2"
    local uid
    uid="$(incus exec "$instance" -- id -u postgres)"
    local incus_db_cmd=(incus exec "$instance" --cwd /tmp --user "$uid" --)
    local files=( "${DATABASES[@]}" globals)

    for file in "${files[@]}"; do
        incus file push "${dl_dir}/${file}.sql" "${instance}/tmp/" || \
            die "Error: push '${dl_dir}/${file}' to '$instance' instance"
    done

    "${incus_db_cmd[@]}" psql -d postgres -f globals.sql

    for db in "${DATABASES[@]}"; do
        "${incus_db_cmd[@]}" psql -c "CREATE DATABASE $db" || \
            die "Database '$db' creation failed on '$instance' instance"

        if [[ "$db" == "osm.sql" ]]; then
            "${incus_db_cmd[@]}" psql -d "$db" -c "CREATE EXTENSION IF NOT EXISTS timescaledb"
            "${incus_db_cmd[@]}" psql -d "$db" -c "SELECT timescaledb_pre_restore()"

        fi
        "${incus_db_cmd[@]}" pg_restore -d "$db" -Fc "${db}.sql"
        if [[ "$db" == "osm.sql" ]]; then
            "${incus_db_cmd[@]}" psql -d "$db" -c "SELECT timescaledb_post_restore()"
        fi
    done
}

_restore_grafana() {
    :
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
}


main() {
    local customer_name="$1"

    if ! instance_check "$customer_name"; then
        die "Check incus instance"
    fi

    local _start_gap_t="$EPOCHREALTIME"

    log "Upgrading '$customer_name' instance on '$BASE_IMAGE_ALIAS' base image"
    LOG_FILE="${WORK_DIR}/upgrade_${customer_name}_$(t "$FILE_TFMT").log"
    DL_DIR="$(mktemp -d --suffix="___${customer_name}" -p "$WORK_DIR")"
    # exec 3>&1 1>>"$LOG_FILE" 2>&1
    exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

    clone_instance "$customer_name"
    create_upgrade_instance "$customer_name"
    do_backup "$customer_name" "$DL_DIR"
    do_restore "$customer_name" "$DL_DIR"

}

main "$@"
