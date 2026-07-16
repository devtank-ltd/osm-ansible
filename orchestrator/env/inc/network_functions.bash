gen_hwaddr() {
    local hwaddr="52:54:00:%02x:%02x:%02x"
    # shellcheck disable=SC2059
    printf "$hwaddr" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

main_ip() {
    sed -rn 's|.*src\s([0-9.]+).*|\1|p' < <(command -p ip -o r get 1)
}

main_iface() {
    sed -rn 's/.*dev\s([[:alnum:]]+)\ssrc.*/\1/p' < <(command -p ip -o -br -c=never r get 1)

}

dns_ip() {
    local ipaddr=""
    ipaddr="$(sed -rn 's/.*DNS Server: ([0-9.]+)$/\1/p' < <(command -p resolvectl status "$(main_iface)"))"
    if [[ -z "$ipaddr" ]]; then
        warn "Unable to get IPv4 DNS address"
        return
    fi
    echo "$ipaddr"
}

get_ip4_addr() {
    local iface="$1"
    local ipaddr=""

    ipaddr="$(ip -o -4 addr show dev "$iface" | sed -rn 's|.*inet (.*)\/.*|\1|p')"
    [[ -z "$ipaddr" ]] && die "Unable to get IP address for '$iface' interface"
    echo "$ipaddr"
}

setup_bridge() {
    local osm_br_addr
    local main_hwaddr
    local hosts_dir
    local dns_ip=""
    local brconf="/etc/qemu/bridge.conf"
    local iptables_args=(
        -t nat -A POSTROUTING ! -d "${OSM_SUBNET}.0/24"
        -s "${OSM_SUBNET}.0/24" -j SNAT --to-source "$(main_ip)"
    )
    local helper_path="/usr/lib/qemu/qemu-bridge-helper"

    hosts_dir="$(readlink -f "$HOSTS_DIR")"

    if [[ -e "/sys/class/net/${VOSM_HOSTBR}" ]]; then
        osm_br_addr="$(get_ip4_addr "$VOSM_HOSTBR")"
        if [[ "${OSM_SUBNET}.1" != "$osm_br_addr" ]]; then
            die "bridge IP address '${osm_br_addr}' doesn't match '${OSM_SUBNET}.1'"
        fi
        warn "${VOSM_HOSTBR} already open"
        return 0
    fi

    c="$(stat "$helper_path" -c  %a%G)"
    if [[ "$c" != "4750netdev" ]]; then
        sudo -s -- <<-EOF
		chgrp netdev "$helper_path"
		chmod 4750 "$helper_path"
EOF
    fi

    if [[ ! -e "$brconf" ]]; then
        sudo -- install -D -m 644 -o root -g netdev <(
            cat <<-EOF
	allow "$VOSM_HOSTBR"
EOF
        ) "$brconf"
    elif ! grep -q "$VOSM_HOSTBR" "$brconf"; then
        warn "The '$VOSM_HOSTBR' was not found in the '$brconf' file"
        echo "allow $VOSM_HOSTBR" | sudo tee -a "$brconf" >/dev/null
    fi

    sudo ip link add "$VOSM_HOSTBR" type bridge
    sudo ip addr add "${OSM_SUBNET}.1/24" dev "$VOSM_HOSTBR"
    sudo ip addr add "${OSM_SUBNET}.254/24" dev "$VOSM_HOSTBR"
    sudo ip link set up dev "$VOSM_HOSTBR"
    sudo iptables "${iptables_args[@]}"

    if [[ ! -e "${HOSTS_DIR}/${VOSM_HOST}0/mac" ]]; then
        install -d -m 777 "${hosts_dir}/${VOSM_HOST}0"
        main_hwaddr="$(gen_hwaddr)"
        echo "$main_hwaddr" > "${hosts_dir}/${VOSM_HOST}0/mac"
    else
        main_hwaddr="$(<"${hosts_dir}/${VOSM_HOST}0/mac")"
    fi

    info "Main host MAC: $main_hwaddr"

    if [[ -e "$hosts_dir/$VOSM_HOSTBR.leasefile" ]]; then
        sudo -- sed -i '/'"$OSM_SUBNET"'.2/d' "${hosts_dir}/${VOSM_HOSTBR}.leasefile"
    fi

    # generate mac addresses for OSM hosts in advance to use them in
    # dnsmasq configuration file
    for n in $(seq 0 $((OSM_HOST_COUNT - 1)) ); do
        mkdir -p "${HOSTS_DIR}/vosmhost${n}"
        if [[ ! -f "${HOSTS_DIR}/vosmhost${n}/mac" ]]; then
            gen_hwaddr > "${HOSTS_DIR}/vosmhost${n}/mac"
        fi
    done

    # Setup a socat to redirect from second bridge address to host own DNS server.
    sudo socat UDP-LISTEN:53,fork,reuseaddr,bind="${OSM_SUBNET}.254" UDP:127.0.0.53:53 &
    socat_pid=$!
    echo $socat_pid > "${HOSTS_DIR}/socat.pid"

    run_dnsmasq
    sudo resolvectl domain "$VOSM_HOSTBR" ~"$OSM_DOMAIN" || return 1
    sudo resolvectl dns "$VOSM_HOSTBR" "${OSM_SUBNET}.2" || return 1
}

close_bridge() {
    if [[ ! -e "/sys/class/net/$VOSM_HOSTBR" ]]; then
        warn "$VOSM_HOSTBR already closed"
        return
    fi

    warn "Remove iptables rule of subnet ${OSM_SUBNET}"
    rules=($(sudo iptables --line-num -n -t nat -L POSTROUTING | grep ${OSM_SUBNET} | cut -c1))
    for rule in ; do
        sudo iptables -t nat -D POSTROUTING $rule
    done
    warn "Kill dnsmasq"
    if [ -e "${HOSTS_DIR}/${VOSM_HOSTBR}.pid" ]; then
        pid=$(cat "${HOSTS_DIR}/${VOSM_HOSTBR}.pid")
        [ ! -e /proc/$pid/ ] || sudo kill -15 $pid
    fi
    if [ -e "${HOSTS_DIR}/socat.pid" ]; then
        pid=$(cat "${HOSTS_DIR}/socat.pid")
        [ ! -e /proc/$pid/ ] || sudo kill -15 $pid
    fi
    warn "Remove '$VOSM_HOSTBR' interface"
    sudo ip link set down dev "$VOSM_HOSTBR"
    sudo ip addr del "${OSM_SUBNET}.1/24" dev "$VOSM_HOSTBR"
    sudo ip link del "$VOSM_HOSTBR" type bridge
}
