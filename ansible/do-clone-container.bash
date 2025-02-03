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
    local subvols=()

    subvol_cmd "snapshot" "-r" "${container}" "${container}-ro"
    subvol_cmd "create" "$CLONE_DIR"

    btrfs send "${container}-ro" | btrfs receive "$CLONE_DIR" || \
        die "send / recieve"

    subvol_cmd "snapshot" "${CLONE_DIR}/${container}-ro" "${container}-clone"

    subvols+=("${container}-ro" "${CLONE_DIR}/${container}-ro" "${CLONE_DIR}")
    for sub in "${subvols[@]}"; do
        subvol_cmd "delete" "$sub"
    done
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
