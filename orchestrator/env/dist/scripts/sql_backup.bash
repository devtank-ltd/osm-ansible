#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# Configuration
readonly ROTN=7                 # rotation number (up to 99)
readonly DBS=(                  # DB to backup
    "osm_orchestrator"
    "pdns"
)
readonly BACKUP_DIR="/root/backups" # directory path to store backups
readonly ORCHESTRATOR_DIR="/srv/osm-lxc/orchestrator"
readonly -A HOSTS=(                 # list of the hosts to copy backups
    # ['osm-host1']="109.228.38.77"
    # ['osm-host3']="212.227.14.247"
    ['vosmhost0']="192.168.10.252"
)

copy() {
    local dst="$1"
    rsync -avihzP --delete "$BACKUP_DIR" root@"$dst":"${BACKUP_DIR%/*}"
}

make_backup() {
    local bkp_dir="$1"
    mkdir "$bkp_dir"
    pushd "$bkp_dir" >/dev/null 2>&1
    for db in "${DBS[@]}"; do
        echo "make '$db' dump"
        mysqldump -u root "$db" > "${db}.sql"
    done
    popd >/dev/null 2>&1

    cp -v "${ORCHESTRATOR_DIR}/config.yaml" "$bkp_dir"
    cp -v "${ORCHESTRATOR_DIR}/master.key" "$bkp_dir"

    for host in "${!HOSTS[@]}"; do
        echo "Copy backups to '${host}: [${HOSTS[$host]}]"
        copy "${HOSTS[$host]}"
    done
}

main() {
    declare -a stack=()
    local -i stack_size=0
    local -i i

    [[ ! -d "$BACKUP_DIR" ]] && mkdir "$BACKUP_DIR"
    pushd "$BACKUP_DIR" >/dev/null 2>&1

    mapfile -t stack < <(find . -maxdepth 1 -mindepth 1 -type d -printf '%P\n' | sort -n)
    stack_size=${#stack[@]}

    if (( stack_size > 0 )); then

        for (( i = stack_size - 1; i >= 0; i--)); do
            if (( i == ROTN - 1)) && [[ -v stack[i] ]]; then
                rm -rf "${stack[i]}"
                continue
            fi
            local dir="${stack[i]}"
            local prefix="${dir%%-*}"  # remove name
            local name="${dir#*-}"     # remove prefix
            printf -v prefix '%02d' $(( 10#$prefix + 1 ))
            mv "$dir" "${prefix}-${name}"
            stack[i+1]="${prefix}-${name}"
        done
    fi

    make_backup "01-$(date +%m-%d-%Y_%H-%M)"
    popd >/dev/null 2>&1
}

main "$@"
