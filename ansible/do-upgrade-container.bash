#!/usr/bin/env bash

set -o errexit                  # exit when command fails
set -o nounset                  # error when expanding unset var
set -o pipefail                 # do not hide error(s) in pipes

readonly DEVTANK_DIR="/srv/osm-lxc"
readonly BASE_CONTAINER="base-os"
readonly BASE_IP="10.0.3.2"
readonly BASETREE_DIR="${DEVTANK_DIR}/lxc/os-bases/"
readonly LXC_PATH="${DEVTANK_DIR}/lxc/containers"
readonly RDUP_HASH="/root/dedup.hash"

die() {
    echo "$*" >&2
    exit 1
}

container_state() {
    local name="$1"
    lxc-info -s -n "$name" | sed -rn 's/.*:[[:blank:]]*([[:alpha:]])/\1/p' || :
}

container_name() {
    local name="$1"
    lxc-ls --filter=^"$name"-svr$ | sed -e 's/[[:blank:]]*$//'
}

container() {
    local action="$1"
    local name="$2"
    local config="${LXC_PATH}/${name}/lxc.container.conf"

    case "$action" in
        start)
            [[ "$(container_state "$name")" == "RUNNING" ]] && return
            echo "Starting container '$name'"
            if [[ "$name" == "$BASE_CONTAINER" ]]; then
                config="/srv/osm-lxc/lxc/os-bases/base-os-lxc.conf"
            fi
            lxc-start --name="$name" --rcfile="$config"
            ;;
        stop)
            state="$(container_state "$name")"
            [[ "$state" == "STOPPED" || -z "$state" ]] && return
            echo "Stopping container '$name'"
            lxc-stop --name="$name"
            ;;
        *)
            echo "Unknown action"
            return
    esac
}

lxc_do() {
    local name="$1"; shift
    if [[ "$name" == "$BASE_CONTAINER" ]]; then
        name="root@${BASE_IP}"
    fi
    echo "'$name': '$*'"
    ssh "$name" ''"$*"''
}


main() {
    local customer_name="$1"
    local container bases_lst latest_base new_base

    if [[ -z "$customer_name" ]]; then
        die "No customer name given"
    else
        printf -v container '%s' "$(container_name "$customer_name")"
        [[ ! -v container ]] && die "The container for customer '$name' does not exist."
    fi

    # upgrade lower directory tree
    container "start" "$BASE_CONTAINER"
    lxc_do "$BASE_CONTAINER" "apt update"
    lxc_do "$BASE_CONTAINER" "apt upgrade -y"
    container "stop" "$BASE_CONTAINER"

    # create new OS base
    # TODO: should we switch all customers to the lower directory tree?
    mapfile bases_lst -t < <(find "$BASETREE_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -n)
    latest_base="${bases_lst[-1]}"
    local ver="${latest_base%%-*}"
    printf -v ver '%03d' $(( ver + 1 ))
    new_base="${ver}-bookworm-$(date +%d-%m-%Y)"
    new_base="${BASETREE_DIR}/${new_base}"
    cp -r /var/lib/lxc/base-os/rootfs "$new_base"

    container "stop" "$container"
    sed -ri \
        's#(overlayfs.*:).*(:/srv/osm-lxc/lxc/*)#\1'"${new_base}"'\2#p' \
        "${LXC_PATH}/${container}/lxc.container.conf"
    container "start" "$container"

    lxc_do "$container" "apt update"
    lxc_do "$container" "apt upgrade -y"

    # dedup
    duperemove -rhd --hashfile="$RDUP_HASH" "$BASETREE_DIR" "$LXC_PATH"
}

main "$@"
