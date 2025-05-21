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
    local hwaddr="c1:00"

    for _ in $(seq 4); do
        hwaddr+="$(printf ':%02x' $((RANDOM%256)) )"
    done
    echo "$hwaddr"
}

do_clone() {
    local container="$1"
    local conf="${container}-clone/lxc.container.conf"

    subvol_cmd "snapshot" "${container}" "${container}-clone"

    new_mac="$(gen_hwaddr)"
    sed -i "s|${container}/rootfs-layer|${container}-clone/rootfs-layer|g" "$conf"
    sed -i "s|([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}|$new_mac|g" "$conf"
    sed -i 's|^lxc\.uts\.name.*$|&-clone|' "$conf"
}

main() {
    local src="$1"
    local cont=""

    cont="$(lxc-ls -1 --filter=^"$src".*)"

    if [[ -z "$cont" ]]; then
        die "Container '$src' not found."
    fi

    if [[ -d "${cont}-clone" || -d "${LXC_DIR}/${cont}-clone" ]]; then
        die "Container clone '${cont}-clone' exists."
    fi

    pushd "$LXC_DIR" >/dev/null 2>&1
    do_clone "${cont}"
    popd >/dev/null 2>&1
}

main "$@"
