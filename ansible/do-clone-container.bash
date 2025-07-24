#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

LXC_DIR="/srv/osm-lxc/lxc/containers"

msg() {
    echo "$*"
}

die() {
    msg "FATAL: $*" 1>&2
    exit 1
}

subvol_cmd() {
    local args=("$@")
    btrfs subvolume "${args[@]}" || die "btrfs subvolume ${args[*]}"
}

gen_hwaddr() {
    local hwaddr="00:c1"

    for _ in $(seq 4); do
        hwaddr+="$(printf ':%02x' $((RANDOM%256)) )"
    done
    echo "$hwaddr"
}

do_clone() {
    local container="$1"
    local conf="${container}-clone-svr/lxc.container.conf"

    subvol_cmd "snapshot" "${container}-svr" "${container}-clone-svr"

    new_mac="$(gen_hwaddr)"
    sed -i -r "s|${container}-svr|${container}-clone-svr|" "$conf"
    sed -i -r "s|([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}|$new_mac|g" "$conf"

    /opt/devtank/restart-container.sh "${container}-clone-svr"
}

main() {
    local src="$1"
    local cont=""

    cont="$(lxc-ls -1 --filter=^"$src".*)"

    if [[ -z "$cont" ]]; then
        die "Container '$src' not found."
    fi

    if [[ -d "${src}-clone" || -d "${LXC_DIR}/${src}-clone" ]]; then
        die "Container clone '${src}-clone' exists."
    fi

    pushd "$LXC_DIR" >/dev/null 2>&1
    do_clone "${src}"
    popd >/dev/null 2>&1
}

main "$@"
