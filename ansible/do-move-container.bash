#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

readonly DEVTANK_DIR="/srv/osm-lxc"
readonly LXC_PATH="${DEVTANK_DIR}/lxc/containers"

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

send() {
    local out="$1"
    local dst_host="$2"
    local dst_path="$3"

    out="${out}.tar.xz"

    tar --numeric-owner -cJf "$out" --exclude="$out" ./*
    if ! rsync -azP -e "ssh -o StrictHostKeyChecking=no" "$out" "${dst_host}:${dst_path}/"; then
        die "rsync failed for ${out}.tar.xz"
    fi
    echo "The '$out' has been successfully transfered to '${dst_host}:${dst_path}'"
    unlink "$out"
}

main() {
    local name="$1"
    local dst="$2"
    local base

    if [[ -n "$name" ]]; then
        name="$(container_name "$name")"
    else
        die "No such customer name"
    fi

    container "stop" "${name}"
    pushd "${LXC_PATH}/${name}" >/dev/null 2>&1
    base="$(sed -rn 's|.*overlayfs:(.*):.*|\1|p' lxc.container.conf)"
    echo "$base"

    echo "Move container '$name'"
    send "$name" "$dst" "$LXC_PATH"
    popd >/dev/null 2>&1

    pushd "$base" >/dev/null 2>&1
    echo "Move lower directory structure '${base##*/}'"
    send "${base##*/}" "$dst" "${LXC_PATH%/*}/os-bases"
    popd >/dev/null 2>&1
}

main "$@"
