#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

readonly DEVTANK_DIR="/srv/osm-lxc"
readonly LXC_PATH="${DEVTANK_DIR}/lxc"
readonly BASE_PATH="${LXC_PATH}/os-bases"
readonly CONTAINERS_PATH="${LXC_PATH}/containers"

die() {
    echo "$*" >&2
    exit 1
}

main() {
    local name="$1"
    local lower latest_base base
    local -a bases_lst
    local -i ver

    name="${name}-svr"

    pushd "$BASE_PATH" > /dev/null 2>&1
    lower="$(find . -maxdepth 1 -name '*-bookworm-*.tar.xz' -type f -printf '%f')"
    [[ -z "$lower" ]] && die "Unable to find base tarball"
    mapfile bases_lst -t  < <(find . -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -n)
    latest_base="${bases_lst[-1]}"
    printf -v ver '%03d' $(( 10#${latest_base%%-*} + 1 ))
    base="${BASE_PATH}/${ver}-bookworm-$(date +%d-%m-%Y)"
    mkdir -p "$base"
    tar -xpf "$lower" -C "$base" || die "Failed to unpack '$lower'"
    unlink "$lower"
    popd >/dev/null 2>&1

    pushd "$CONTAINERS_PATH" > /dev/null 2>&1
    [[ -f "${name}.tar.xz" ]] || die "There is no tarball for '$name'"
    mkdir -p "${CONTAINERS_PATH}/${name}"
    tar -xpf "${name}.tar.xz" -C "${CONTAINERS_PATH}/${name}" || \
        die "Failed to unpack '$name'"
    sed -Ei 's,(:)/.*(:.*),\1'"$base"'\2,' "${CONTAINERS_PATH}/${name}/lxc.container.conf"
    lxc-start -n "${name}" -f "${CONTAINERS_PATH}/${name}/lxc.container.conf" || \
        die "Unable to start '$name' container"
    unlink "${name}.tar.xz"
    popd >/dev/null 2>&1
}

main "$@"
