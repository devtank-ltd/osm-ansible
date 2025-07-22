#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

HOSTS_CONF="/etc/hosts"
DNSMASQ_CONF="/etc/lxc/dnsmasq.conf"
LXC_DIR="/srv/osm-lxc/lxc"
CONT_DIR="${LXC_DIR}/containers"
NGINX_DIR="/etc/nginx/devtank"

msg() {
    echo "$*"
}

die() {
    msg "FATAL: $*" 1>&2
    exit 1
}

remove_dir() {
    dirname="$1"

    if rm -r "$dirname" ; then
        echo "${dirname} removed"
    else
        echo "Failed to remove ${dirname}"
    fi
}


do_swap() {
    local cont="$1"
    local conf="${cont}-clone-svr/lxc.container.conf"
    local archive_dir="${LXC_DIR}/archive"

    hwaddr=$(awk -F'= *' '/^lxc\.net\.0\.hwaddr/ {print $2}' "$conf")

    clone_ipv4="$(lxc-ls -f ${cont}-clone-svr -F IPV4 | tail -n 1)"

    echo "${clone_ipv4}${cont}-clone-svr" >> $HOSTS_CONF

    echo "dhcp-host=${hwaddr},${clone_ipv4}" >> $DNSMASQ_CONF

    swap_nginx_conf "$cont"

    lxc-stop "${cont}-svr"

    pushd "${CONT_DIR}" >/dev/null 2>&1
    remove_dir "${cont}-clone-svr/.snapshots"

    snapper -c "${cont}-clone-svr" create-config "${cont}-clone-svr"

    snapper -c "${cont}-svr" delete-config

    mkdir -p "${archive_dir}"

    mv "${cont}-svr" "${archive_dir}"
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
        die "Invalid nginx config"
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

    pushd "$CONT_DIR" >/dev/null 2>&1
    do_swap "${src}"
    popd >/dev/null 2>&1
}

main "$@"
