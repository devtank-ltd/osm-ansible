#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

readonly DEVTANK_DIR="/srv/osm-lxc"
readonly LXC_PATH="${DEVTANK_DIR}/lxc"
readonly BASE_PATH="${LXC_PATH}/os-bases"
readonly CONTAINERS_PATH="${LXC_PATH}/containers"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

ip2i() {
    local a b c d old_ifs
    local -i n
    old_ifs="$IFS"
    IFS='.' read -r a b c d <<< "$1"
    IFS="$old_ifs"
    echo $(( (a << 24 ) + (b << 16) + ( c << 8) + d ))
}

i2ip() {
    local -i n=$1
    local -i disp=24
    local ip=""

    for (( ; disp >= 0; disp -= 8 )); do
        ip="${ip}$(( n >> disp & 255))."
    done
    echo "${ip::-1}"
}

setup_network() {
    local name="$1"
    local ipaddr macaddr
    local -i a b c d

    macaddr="$(sed -En 's/^lxc.net.0.hwaddr[[:space:]]=[[:space:]](.*)$/\1/p' "${CONTAINERS_PATH}/${name}/lxc.container.conf")"
    ipaddr="$(cut -d, -f2 /etc/lxc/dnsmasq.conf | sort -t . -k 3,3n -k 4,4n | tail -n1)"
    ipaddr="$(i2ip $(( $(ip2i "$ipaddr") + 1)) )"
    sed -i -e $'$a\\\ndhcp-host='"${macaddr},${ipaddr}"'' /etc/lxc/dnsmasq.conf
    sed -i -e $'$a\\\n'"${ipaddr} ${name}"'' /etc/hosts
    systemctl restart lxc-net.service || die "LXC network service was not restarted"
}

ansible_finalize() {
    customer="$1"
    mqtt_port="$2"

    domain="$(find /etc/letsencrypt/live/ -mindepth 1 -type d -printf '%f' -quit)"
    domain="${domain#*.}"

    ansible-playbook \
        "${DEVTANK_DIR}/ansible/create-container.yaml" \
        -e customer_name="$customer" \
        -e mqtt_port="$mqtt_port" \
        -e le_domain="$domain" \
        --tags=finalize
}

main() {
    local name="$1"
    local port="$2"
    local lower latest_base base ver
    local -a bases_lst

    name="${name}-svr"

    pushd "$BASE_PATH" > /dev/null 2>&1
    lower="$(find . -maxdepth 1 -name '*-bookworm-*.tar.xz' -type f -printf '%f')"
    [[ -z "$lower" ]] && die "Unable to find base tarball"
    mapfile bases_lst -t  < <(find . -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -n)
    latest_base="${bases_lst[-1]}"
    latest_base="${latest_base/$'\n'}"
    base_ver="${latest_base%%-*}"
    # remove leading zeros from version
    shopt -s extglob
    base_ver="${base_ver##+(0)}"
    shopt -u extglob
    printf -v ver '%03d' $(( 10#$base_ver + 1 ))
    base="${BASE_PATH}/${ver}-bookworm-$(date +%d-%m-%Y)"
    mkdir -p "$base"
    tar -xpf "$lower" -C "$base" || die "Failed to unpack '$lower'"
    popd >/dev/null 2>&1

    pushd "$CONTAINERS_PATH" > /dev/null 2>&1
    [[ -f "${name}.tar.xz" ]] || die "There is no tarball for '$name'"
    btrfs subvolume create "${name}" || die "Unable to create btrfs subvolume"
    tar -xpf "${name}.tar.xz" -C "${CONTAINERS_PATH}/${name}" || \
        die "Failed to unpack '$name'"
    sed -Ei 's,(:)/.*(:.*),\1'"$base"'\2,' "${CONTAINERS_PATH}/${name}/lxc.container.conf"
    setup_network "${name}"
    snapper -c "$name" create-config "${CONTAINERS_PATH}/${name}"
    lxc-start -n "${name}" -f "${CONTAINERS_PATH}/${name}/lxc.container.conf" || \
        die "Unable to start '$name' container"
    popd >/dev/null 2>&1

    if ansible_finalize "${name%-svr}" "$port"; then
        unlink "${BASE_PATH}/${lower}"
        unlink "${CONTAINERS_PATH}/${name}.tar.xz"
    fi
}

main "$@"
