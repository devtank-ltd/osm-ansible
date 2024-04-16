#! /bin/bash

set -e

main_ip=$(ip route | awk '/default/ { print $9 ; exit}')

case "$1" in
  "open")
    [ ! -e /sys/class/net/vosmhostnet ] || { echo "vosmhostnet already open."; exit -1; }

    [ $(id -u) == 0 ] || exec sudo -- "$0" "$@"

    c=$(stat /usr/lib/qemu/qemu-bridge-helper -c  %a%G)
    [ "$c" = "4750netdev" ] || { chgrp netdev /usr/lib/qemu/qemu-bridge-helper; chmod 4750 /usr/lib/qemu/qemu-bridge-helper;}

    [ -d /etc/qemu ] || mkdir /etc/qemu
    [ -e /etc/qemu/bridge.conf ] || { touch /etc/qemu/bridge.conf; chmod 640 /etc/qemu/bridge.conf; chown root:netdev /etc/qemu/bridge.conf; }
    [ -n "$(grep vosmhostnet /etc/qemu/bridge.conf)" ] || echo "allow vosmhostnet" >> /etc/qemu/bridge.conf

    ip link add vosmhostnet type bridge
    ip addr add 192.168.5.1/24 dev vosmhostnet
    ip link set up dev vosmhostnet

    iptables -t nat -A POSTROUTING -s 192.168.5.0/24 -j SNAT --to-source $main_ip

    dnsmasq --pid-file=/tmp/vosmhostnet.pid --dhcp-leasefile=/tmp/vosmhostnet.leasefile --interface=vosmhostnet --bind-interfaces --dhcp-range=192.168.5.2,192.168.5.255
  ;;
  "close")
    [ -e /sys/class/net/vosmhostnet ] || { echo "vosmhostnet already closed."; exit -1; }

    [ $(id -u) == 0 ] || exec sudo -- "$0" "$@"

    iptables -t nat -D POSTROUTING -s 192.168.5.0/24 -j SNAT --to-source $main_ip

    kill -9 $(cat /tmp/vosmhostnet.pid)

    ip link set down dev vosmhostnet
    ip addr del 192.168.5.1/24 dev vosmhostnet
    ip link del vosmhostnet type bridge
  ;;
  *)
    echo "Unknown operation, options are: open, close"
  ;;
esac
