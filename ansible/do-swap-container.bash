#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

HOSTS_CONF="/etc/hosts"
DNSMASQ_CONF="/etc/lxc/dnsmasq.conf"
LXC_DIR="/srv/osm-lxc/lxc/containers"
NGINX_DIR="/etc/nginx/devtank"

msg() {
    echo "$*"
}

die() {
    msg "FATAL: $*" 1>&2
    exit 1
}

do_swap() {
    local cont="$1"
    local conf="${cont}-clone-svr/lxc.container.conf"

    hwaddr=$(awk -F'= *' '/^lxc\.net\.0\.hwaddr/ {print $2}' "$conf")

    clone_ipv4="$(lxc-ls -f ${cont}-clone-svr -F IPV4 | tail -n 1)"

    echo "${clone_ipv4}${cont}-clone-svr" >> $HOSTS_CONF

    echo "dhcp-host=${hwaddr},${clone_ipv4}" >> $DNSMASQ_CONF

    swap_nginx_conf "$cont"
}

swap_nginx_conf() {
    local cont="$1"

    pushd "${NGINX_DIR}/customers.http.d" >/dev/null 2>&1
    sed -i "s|${cont}-svr|${cont}-clone-svr|g" "${cont}.conf"

    pushd "${NGINX_DIR}/customers.stream.d" >/dev/null 2>&1
    sed -i "s|${cont}-svr|${cont}-clone-svr|g" "${cont}.conf"
    popd >/dev/null 2>&1

    if nginx -t ; then
        nginx -s reload
    else
        echo "Invalid nginx config"
    fi
}

check_exists() {
    local src="$1"

    cont="$(lxc-ls -1 --filter=^"$src".*)"

    if [[ -z "$cont" ]]; then
        die "Container '$src' not found."
    fi
}

main() {
    local src="$1"

    check_exists "$src"
    check_exists "${src}-clone"

    pushd "$LXC_DIR" >/dev/null 2>&1
    do_swap "${src}"
    popd >/dev/null 2>&1
}

main "$@"
