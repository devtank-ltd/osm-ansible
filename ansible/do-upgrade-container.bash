#!/usr/bin/env bash

set -o errexit                  # exit when command fails
set -o nounset                  # error when expanding unset var
set -o pipefail                 # do not hide error(s) in pipes

readonly DEVTANK_DIR="/srv/osm-lxc"
readonly BASE_CONTAINER="base-os"
readonly BASETREE_DIR="${DEVTANK_DIR}/lxc/os-bases"
readonly CONTAINERS_PATH="${DEVTANK_DIR}/lxc/containers"
readonly RDUP_HASH="/root/dedup.hash"

die() {
    echo "$*" >&2
    exit 1
}

container_state() {
    local name="$1"
    # lxc-info -s -n "$name" | sed -rn 's/.*:[[:blank:]]*([[:alpha:]])/\1/p' || :
    lxc-ls --filter=^"$name".* -1 -FSTATE -f | sed '1d'
}

container_ip() {
    local name="$1"
    lxc-ls --filter=^"$name".* -1 -FIPV4 -f | sed '1d'
}


container_name() {
    local name="$1"
    lxc-ls --filter=^"$name".* -1 # | sed -e 's/[[:blank:]]*$//'
}

container() {
    local action="$1"
    local name="$2"
    local config="${CONTAINERS_PATH}/${name}/lxc.container.conf"

    case "$action" in
        start)
            [[ "$(container_state "$name")" == "RUNNING" ]] && return
            echo "Starting container '$name'"
            if [[ "$name" == "$BASE_CONTAINER" ]]; then
                config="/srv/osm-lxc/lxc/os-bases/base-os-lxc.conf"
            fi
            lxc-start --name="$name" --rcfile="$config" || die "Unable to start container '$name'"
            ;;
        stop)
            state="$(container_state "$name")"
            [[ "$state" == "STOPPED" || -z "$state" ]] && return
            echo "Stopping container '$name'"
            lxc-stop --name="$name" || die "Unable to stop container '$name'"
            ;;
        *)
            echo "Unknown action"
            return
    esac
}

lxc_do() {
    # execute "cmd" command in lxc container "name"
    local name="$1"; shift
    local cmd=( "$@" )
    local config="${CONTAINERS_PATH}/${name}/lxc.container.conf"


    if [[ "$name" == "$BASE_CONTAINER" ]]; then
        config="/srv/osm-lxc/lxc/os-bases/base-os-lxc.conf"
    fi

    lxc-attach -n "$name" \
               -f "$config" \
               -- "${cmd[@]}" || \
        die "The '${cmd[*]}' command execution is failed on container '$name'"
}

lxc_upgrade() {
    local name="$1"
    lxc_do "$container_name" apt update
    lxc_do "$container_name" apt upgrade -y
}

main() {
    local name="$1"
    local container_name

    [[ -z "$name" ]] && die "No container name is given"
    printf -v container_name '%s' "$(container_name "$name")"
    [[ ! -v container_name ]] && die "The container '$container_name' does not exist"

    if [[ "$container_name" == "base-os" ]]; then
        echo "Upgrade base os container"
        if [[ "$(container_state "$container_name")" =~ ^STOPPED ]]; then
            container "start" "$container_name"
            echo "container is started"
        fi
        lxc_upgrade "$container_name"
        container "stop" "$container_name"

        # create new OS base
        mapfile bases_lst -t < <(find "$BASETREE_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%P\n' | sort -n)
        latest_base="${bases_lst[-1]}"
        local ver="${latest_base%%-*}"
        printf -v ver '%03d' $(( 10#$ver + 1 ))
        new_base="${ver}-bookworm-$(date +%d-%m-%Y)"
        new_base="${BASETREE_DIR}/${new_base}"
        rsync -hiva --numeric-ids /var/lib/lxc/base-os/rootfs/ "$new_base"
    else
        echo "Upgrade cusomer container '$name'"
        mapfile bases_lst -t < <(find "$BASETREE_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%P\n' | sort -n)
        latest_base="${bases_lst[-1]}"
        latest_base="${latest_base/$'\n'}"

        lxc_upgrade "$container_name" apt update
        container "stop" "$container_name"
        sed -ri \
            's#(overlayfs.*:).*(:/srv/osm-lxc/lxc/*)#\1'"${BASETREE_DIR}/${latest_base}"'\2#' \
            "${CONTAINERS_PATH}/${container_name}/lxc.container.conf"
        container "start" "$container_name"
    fi
}

main "$@"
