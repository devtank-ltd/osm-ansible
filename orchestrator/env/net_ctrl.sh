#! /bin/bash

set -e

main_ip=$(ip route | awk '/default/ { print $9 ; exit}')

VOSMHOSTBR=$2
OSM_DNS=$3

[ -n "$HOSTS_DIR" ] || HOSTS_DIR=hosts
[ -n "$OSM_DOMAIN" ] || OSM_DOMAIN=osmm.fake.co.uk

HOSTS_DIR=$(readlink -f "$HOSTS_DIR")

case "$1" in
  "open")
    [ ! -e "/sys/class/net/$VOSMHOSTBR" ] || { echo "$VOSMHOSTBR already open."; exit -1; }

    [ $(id -u) == 0 ] || exec sudo -- "$0" "$@"

    c=$(stat /usr/lib/qemu/qemu-bridge-helper -c  %a%G)
    [ "$c" = "4750netdev" ] || { chgrp netdev /usr/lib/qemu/qemu-bridge-helper; chmod 4750 /usr/lib/qemu/qemu-bridge-helper;}

    [ -d /etc/qemu ] || mkdir /etc/qemu
    [ -e /etc/qemu/bridge.conf ] || { touch /etc/qemu/bridge.conf; chmod 640 /etc/qemu/bridge.conf; chown root:netdev /etc/qemu/bridge.conf; }
    [ -n "$(grep $VOSMHOSTBR /etc/qemu/bridge.conf)" ] || echo "allow $VOSMHOSTBR" >> /etc/qemu/bridge.conf

    ip link add "$VOSMHOSTBR" type bridge
    ip addr add 192.168.5.1/24 dev "$VOSMHOSTBR"
    ip link set up dev "$VOSMHOSTBR"

    iptables -t nat -A POSTROUTING ! -d 192.168.5.0/24 -s 192.168.5.0/24 -j SNAT --to-source $main_ip

    mkdir -p $HOSTS_DIR

    if [ -e "$HOSTS_DIR/orchestrator/mac" ]
    then
      OSM_ORCHESTRATOR_MAC=$(cat "$HOSTS_DIR/orchestrator/mac")
    else
      OSM_ORCHESTRATOR_MAC=$(printf '52:54:00:%02x:%02x:%02x' $[RANDOM%256] $[RANDOM%256] $[RANDOM%256])
      mkdir -p "$HOSTS_DIR/orchestrator"
      chmod 777 "$HOSTS_DIR/orchestrator"
      echo $OSM_ORCHESTRATOR_MAC > "$HOSTS_DIR/orchestrator/mac"
    fi

    echo "Orchestrator MAC:" $OSM_ORCHESTRATOR_MAC

    [ ! -e "$HOSTS_DIR/$VOSMHOSTBR.leasefile" ] || sed -i '/192.168.5.2/d' "$HOSTS_DIR/$VOSMHOSTBR.leasefile"

    dnsmasq --pid-file="$HOSTS_DIR/$VOSMHOSTBR.pid" --dhcp-leasefile="$HOSTS_DIR/$VOSMHOSTBR.leasefile" --interface="$VOSMHOSTBR" --except-interface=lo --bind-interfaces --dhcp-range=192.168.5.2,192.168.5.255  --dhcp-host=$OSM_ORCHESTRATOR_MAC,192.168.5.2  --server=/$OSM_DOMAIN/192.168.5.2

    resolvectl domain $VOSMHOSTBR ~$OSM_DOMAIN
    resolvectl dns $VOSMHOSTBR 192.168.5.2
  ;;
  "close")
    [ -e "/sys/class/net/$VOSMHOSTBR" ] || { echo "$VOSMHOSTBR already closed."; exit -1; }

    [ $(id -u) == 0 ] || exec sudo -- "$0" "$@"

    iptables -t nat -D POSTROUTING ! -d 192.168.5.0/24 -s 192.168.5.0/24 -j SNAT --to-source $main_ip

    kill -9 $(cat "$HOSTS_DIR/$VOSMHOSTBR.pid")

    ip link set down dev "$VOSMHOSTBR"
    ip addr del 192.168.5.1/24 dev "$VOSMHOSTBR"
    ip link del "$VOSMHOSTBR" type bridge
  ;;
  *)
    echo "Unknown operation, options are: open, close"
  ;;
esac
