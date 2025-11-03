#!/usr/bin/env bash

DNSMASQ_CONF="/var/lib/jenkins/dnsmasq_incus_testing.conf"

mapfile -t macs < <(sed -rn 's/dhcp-host=(.*)$/\1/p' "$DNSMASQ_CONF")


for record in "${macs[@]}"; do
    host="${record##*,}"
    mac="${record%%,*}"
    n="${host##*.}"

    if (( ${#n} == 1 )); then
        name="vosmhost0"
    else
        name="vosmhost${n::-1}"
    fi

    mkdir -p "${WORKSPACE}/orchestrator/env/hosts/${name}"
    echo "$mac" > "${WORKSPACE}/orchestrator/env/hosts/${name}/mac"
done
