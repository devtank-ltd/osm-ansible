#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

LXC_DIR="/srv/osm-lxc/lxc/containers"
CLONE_DIR="${LXC_DIR}/clone"

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

do_clone() {
    local container="$1"

    subvol_cmd "snapshot" "${container}" "${container}-clone"

    new_mac=$(echo $RANDOM | md5sum |sed 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*$/02:\1:\2:\3:\4:\5/')
    sed -i "s|${container}/rootfs-layer|${container}-clone/rootfs-layer|g" "${container}-clone/lxc.container.conf"
    sed -i "s|lxc\.net\.0\.hwaddr.*$|lxc\.net\.0\.hwaddr = $new_mac|g" "${container}-clone/lxc.container.conf"
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
