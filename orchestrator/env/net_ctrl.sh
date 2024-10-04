#!/usr/bin/env bash

source functions.sh

main_ip="$(sed -nE 's|^.*src ([0-9.]*) .*$|\1|p' < <(ip r get 1))"

VOSM_HOSTBR="$2"
HOSTS_DIR="$3"
OSM_SUBNET="$4"
OSM_DOMAIN="$5"
HOSTS_DIR="$(readlink -f "$HOSTS_DIR")"

case "$1" in
    "open")
        set -e

        if [[ -e "/sys/class/net/${VOSM_HOSTBR}" ]]; then
            osm_bridge_ip="$(get_ip4_addr "$VOSM_HOSTBR")"
            [[ "${OSM_SUBNET}.1" = "$osm_bridge_ip" ]] || die "IP address of bridge $osm_bridge_ip doesn't match ${OSM_SUBNET}.1"
            warn "$VOSM_HOSTBR already open."
            exit 0
        fi

        (( EUID == 0 )) || exec sudo -- "$0" "$@"

        c="$(stat /usr/lib/qemu/qemu-bridge-helper -c  %a%G)"
        [ "$c" = "4750netdev" ] || {
            chgrp netdev /usr/lib/qemu/qemu-bridge-helper
            chmod 4750 /usr/lib/qemu/qemu-bridge-helper
        }

        [[ -d /etc/qemu ]] || mkdir /etc/qemu
        if [[ ! -e /etc/qemu/bridge.conf ]]; then
            install -m 644 -o root -g netdev <(
                cat <<-EOF
	allow "$VOSM_HOSTBR"
EOF
            ) /etc/qemu/bridge.conf
        elif ! grep -q "$VOSM_HOSTBR" /etc/qemu/bridge.conf; then
            echo "allow $VOSM_HOSTBR" >> /etc/qemu/bridge.conf
        fi

        ip link add "$VOSM_HOSTBR" type bridge
        ip addr add "${OSM_SUBNET}.1/24" dev "$VOSM_HOSTBR"
        ip link set up dev "$VOSM_HOSTBR"

        iptables_args=(
            -t nat -A POSTROUTING ! -d "${OSM_SUBNET}.0/24"
            -s "${OSM_SUBNET}.0/24" -j SNAT --to-source "$main_ip"
        )

        iptables "${iptables_args[@]}"

        mkdir -p "$HOSTS_DIR"

        if [[ -e "$HOSTS_DIR/orchestrator/mac" ]]; then
            OSM_ORCHESTRATOR_MAC=$(cat "$HOSTS_DIR/orchestrator/mac")
        else
            printf -v OSM_ORCHESTRATOR_MAC '52:54:00:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
            install -d -m 777 "${HOSTS_DIR}/orchestrator"
            echo "$OSM_ORCHESTRATOR_MAC" > "${HOSTS_DIR}/orchestrator/mac"
        fi

        info "Orchestrator MAC: $OSM_ORCHESTRATOR_MAC"

        [[ ! -e "$HOSTS_DIR/$VOSM_HOSTBR.leasefile" ]] || {
            sed -i "/${OSM_SUBNET}.2/d" "${HOSTS_DIR}/${VOSM_HOSTBR}.leasefile"
        }

        dnsmasq_params=(
            --pid-file="$HOSTS_DIR/$VOSM_HOSTBR.pid"
            --dhcp-leasefile="$HOSTS_DIR/$VOSM_HOSTBR.leasefile"
            --interface="$VOSM_HOSTBR"
            --except-interface=lo
            --bind-interfaces
            --dhcp-range="${OSM_SUBNET}.2,${OSM_SUBNET}.255"
            --dhcp-host="${OSM_ORCHESTRATOR_MAC},${OSM_SUBNET}.2"
            --server="/${OSM_DOMAIN}/${OSM_SUBNET}.2"
        )

        dnsmasq "${dnsmasq_params[@]}"
        resolvectl domain "$VOSM_HOSTBR" ~"$OSM_DOMAIN"
        resolvectl dns "$VOSM_HOSTBR" "${OSM_SUBNET}.2"
        ;;

    "close")
        [[ -e "/sys/class/net/$VOSM_HOSTBR" ]] || die "$VOSM_HOSTBR already closed."

        (( EUID == 0 )) || exec sudo -- "$0" "$@"

        iptables -t nat -D POSTROUTING ! -d "${OSM_SUBNET}.0/24" -s "${OSM_SUBNET}.0/24" -j SNAT --to-source "$main_ip"

        kill -9 "$(cat "$HOSTS_DIR/$VOSM_HOSTBR.pid")"

        ip link set down dev "$VOSM_HOSTBR"
        ip addr del "${OSM_SUBNET}.1/24" dev "$VOSM_HOSTBR"
        ip link del "$VOSM_HOSTBR" type bridge
        ;;
    *)
        warn "Unknown operation, options are: open, close"
        ;;
esac
