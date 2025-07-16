#!/usr/bin/env bash

RED="$(tput setaf 1)"
GREEN="$(tput setaf 2)"
YELLOW="$(tput setaf 3)"
RESET="$(tput sgr0)"

readonly RED
readonly GREEN
readonly YELLOW
readonly RESET

die() {
    local msg="$1"
    echo "${RED}FATAL:${RESET} $msg" >&2 2>&1
    exit 1
}

info() {
    echo "${GREEN}INFO:${RESET} $*"
}

edo() {
    info "Run $*"
    "$@" || die "Command $* failed"
}

yesno() {
    [[ -t 0 ]] || return 0
    local resp
    read -r -p "$1 [y/N] " resp
    [[ "$resp" == [yY] ]] || exit 1
}

iface() {
    /bin/ip r get 1 | sed -rn 's|.*dev\s(.*)\ssrc.*|\1|p'
}

in_qemu_bridge() {
    local iface="$1"
    if grep -q "$1" /etc/qemu/bridge.conf; then
        return 0
    fi
    return 1
}

prep_net() {
    local br_if="$1"
    local subnet="$2"
    local leasefile="/tmp/osm-incus.leasefile"

    info "setup network"
    info "Enable IP forwarding..."
    edo sudo sysctl -w net.ipv4.ip_forward=1

    if ! ip -o l show qemu-br0 &>/dev/null; then
        edo sudo ip link add "$br_if" type bridge
        edo sudo ip addr add "${subnet}.1/24" dev "$br_if"
        edo sudo ip link set up dev "$br_if"
    fi

    if (( $(sudo nft list tables | grep -cE 'qemu-(nat|filter)') != 2 )); then
        info "Set NFT rules..."
        setup_nftables "$br_if"
    fi

    if [[ ! -f "$leasefile" ]]; then
        info "Run dnsmasq..."
        run_dnsmasq "$br_if" "$subnet"
    fi
}

setup_nftables() (
    info "nftables"
    local brif="$1"
    local iface


    iface="$(iface)"

    edo sudo nft add table inet incus-qemu-nat
    edo sudo nft add table inet incus-qemu-filter

    edo sudo nft add chain inet incus-qemu-nat postrouting '{ type nat hook postrouting priority srcnat ; }'
    edo sudo nft add chain inet incus-qemu-filter forward '{ type filter hook forward priority 0; policy drop; }'

    edo sudo nft add rule inet incus-qemu-nat postrouting oifname "$iface" masquerade
    edo sudo nft add rule inet incus-qemu-filter forward ct state related,established accept
    edo sudo nft add rule inet incus-qemu-filter forward iifname "$brif" oifname "$iface" accept
)

run_dnsmasq() {
    local br_if="$1"
    local subnet="$2"

    local args=(
        --except-interface=lo
        -C /dev/null
        --interface="$br_if"
        --bind-interfaces
        --dhcp-host=vosmhost0,"${subnet}.2"
        --dhcp-leasefile=/tmp/qemu.leasefile
        --dhcp-option=6,1.1.1.1,9.9.9.9
        --dhcp-range="${subnet}.2,${subnet}.254"
    )
    edo sudo dnsmasq "${args[@]}"
}

main() {
    local bridge_name="${1:-incusbr0}"
    local subnet="10.0.7"
    prep_net "$bridge_name" "$subnet"

}

main "$@"
