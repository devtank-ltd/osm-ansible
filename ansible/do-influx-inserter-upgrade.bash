#!/usr/bin/env bash

set -o errexit                  # exit when command fails
set -o nounset                  # error when expanding unset var
set -o pipefail                 # do not hide error(s) in pipes

readonly DEVTANK_DIR="/srv/osm-lxc"
readonly CONTAINERS_PATH="${DEVTANK_DIR}/lxc/containers"

die() {
    echo "$*" >&2
    exit 1
}

container_name() {
    local name="$1"
    lxc-ls --filter=^"$name".* -1 # | sed -e 's/[[:blank:]]*$//'
}

lxc_do() {
    local name="$1"; shift
    local cmd=( "$@" )
    local config="${CONTAINERS_PATH}/${name}/lxc.container.conf"

    lxc-attach -n "$name" \
               -f "$config" \
               -- "${cmd[@]}" || \
        die "The '${cmd[*]}' command execution is failed on container '$name'"
}

main() {
    local name="$1"
    local container_name
    local backup="/root/mqtt-influx-inserter.yaml.bkup"
    local target="/etc/mqtt-influx-inserter/mqtt-influx-inserter.yaml"
    local content='''
    prometheus:
      orch_wg_ip: 10.10.1.1
      push_gateway_port: 9091
    '''

    [[ -z "$name" ]] && die "No container name is given"
    printf -v container_name '%s' "$(container_name "$name")"
    [[ ! -v container_name ]] && die "The container '$container_name' does not exist"

    lxc_do "$container_name" mv "$target" "$backup"
    lxc_do "$container_name" apt purge mqtt-influx-inserter -y
    lxc_do "$container_name" deluser --system influx-inserter
    lxc_do "$container_name" mkdir -p /tmp/debs/upgr
    lxc_do "$container_name" wget https://cloud.devtank.co.uk/debs/mqtt-influx-inserter_0.1.1-1_all.deb -P /tmp/debs/upgr
    lxc_do "$container_name" apt install /tmp/debs/upgr/mqtt-influx-inserter_0.1.1-1_all.deb
    lxc_do "$container_name" echo "$content" >> "$backup"
    lxc_do "$container_name" mv "$backup" "$target"
    lxc_do "$container_name" systemctl restart mqtt-influx-inserter
}

main "$@"
