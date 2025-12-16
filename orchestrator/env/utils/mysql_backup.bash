#!/usr/bin/env bash

# Create SQL dump for databases specified in <DATABASES> array to
# <BACKUP_DIR>. Dumps created after <RETAIN_PERIOD> are deleted automatically.
# Sync files in <BACKUP_DIR> with <REMOTE_HOST> <REMOTE_DIR>

set -o errexit
set -o nounset
set -o pipefail

# ---------- config ----------
readonly -a DATABASES=(
    osm_orchestrator
    pdns
)
readonly RETAIN_PERIOD=30
readonly BACKUP_DIR="/root/backups/devtank/"
readonly REMOTE_HOST="osmbackup"
readonly REMOTE_DIR="/srv/backups/database"
# ----------------------------

print_date() {
    printf '%(%Y-%m-%d_%H-%M-%S)T\n' -1
}

post_cleanup() {
    find "$BACKUP_DIR" -type f -name '*.sql' -mtime +$RETAIN_PERIOD -delete
}

make_dump() {
    local dir="${1:-.}/"
    local name="${2:-backup}"
    local dump_args=(
        --user root
        --opt
        --skip-lock-tables
        --verbose
        --result-file="${dir}/${name}.sql"
        --databases "${DATABASES[@]}"
    )

    [[ ! -d "$dir" ]] &&  mkdir --parents "$dir"
    mysqldump "${dump_args[@]}"
}

sync_files() {
    rsync -avh --delete "$BACKUP_DIR" "${REMOTE_HOST}:${REMOTE_DIR}"
}

main() {
    make_dump "$BACKUP_DIR" "devtank_$(print_date)"
    post_cleanup
    sync_files
}

main "$@"
