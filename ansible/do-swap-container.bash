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
    local dirname="$1"

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

    sed -E -i "s|([0-9]{1,3}\.){3}[0-9]{1,3} ${cont}-svr|${clone_ipv4}${cont}-svr|g" "$HOSTS_CONF"

    echo "dhcp-host=${hwaddr},${clone_ipv4}" >> $DNSMASQ_CONF

    lxc-stop "${cont}-svr"

    snapper -c "${cont}-svr" delete-config

    mkdir -p "${archive_dir}"

    mv "${cont}-svr" "${archive_dir}/${cont}-svr-old"

    sed -i "s|${cont}-clone-svr/rootfs-layer|${cont}-svr/rootfs-layer|g" "$conf"

    sed -i 's|lxc\.uts\.name = ${cont}-clone-svr|lxc\.uts\.name = ${cont}-svr|g' "$conf"

    mv "${CONT_DIR}/${cont}-clone-svr" "${CONT_DIR}/${cont}-svr"

    remove_dir "${cont}-svr/.snapshots"

    /opt/devtank/restart-container.sh "${cont}-svr"

    lxc-stop "${cont}-clone-svr"

    snapper -c "${cont}-svr" create-config "${cont}-svr"

    restart_nginx
}

restart_nginx() {
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
