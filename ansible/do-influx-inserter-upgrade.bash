#!/usr/bin/env bash

die() {
    echo "$*" >&2
    exit 1
}

container_name() {
    local name="$1"
    lxc-ls --filter=^"$name".* -1 # | sed -e 's/[[:blank:]]*$//'
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

main() {
    local name="$1"
    local container_name

    [[ -z "$name" ]] && die "No container name is given"
    printf -v container_name '%s' "$(container_name "$name")"
    [[ ! -v container_name ]] && die "The container '$container_name' does not exist"

    lxc_do "$container_name" cp /etc/mqtt-influx-inserter/mqtt-influx-inserter.yaml /tmp/mqtt-influx-inserter.yaml.bkup
    lxc_do "$container_name" apt purge mqtt-influx-inserter
    lxc_do "$container_name" deluser --system influx-inserter
    lxc_do "$container_name" mkdir -p /tmp/debs/upgr
    lxc_do "$container_name" wget https://cloud.devtank.co.uk/debs/mqtt-influx-inserter_0.1.1-1_all.deb -P /tmp/debs/upgr
    lxc_do "$container_name" apt install /tmp/debs/upgr/mqtt-influx-inserter_0.1.1-1_all.deb
    lxc_do "$container_name" mv /tmp/mqtt-influx-inserter.yaml.bkup /etc/mqtt-influx-inserter/mqtt-influx-inserter.yaml
    lxc_do "$container_name" systemctl restart mqtt-influx-inserter
}

main "$@"
