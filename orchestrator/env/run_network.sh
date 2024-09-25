#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash; -*-

# TODO:
# set -o errexit
# set -o pipefail
# set -o nounset

source functions.sh

[[ -z "$1" ]] || HOSTS_DIR="$1"
[[ -n "$HOSTS_DIR" ]] || die "Not given a hosts dir as argument or env var."

source env_common.sh

./net_ctrl.sh open "$VOSM_HOSTBR" "$HOSTS_DIR" "$OSM_SUBNET" "$OSM_DOMAIN"
(( $? == 0 )) || die "Failed to setup bridge"

declare -i count=0
declare -i host_count=0
declare -a machines

mapfile -t machines < <(find ./hosts -name "mac" -exec dirname {} \;)

# DEBUG
declare -p machines

echo "========================================="
info "Starting network"

for host in "${machines[@]}"; do
    # clean up the host name
    host="${host##*/}"
    info "Starting OSM HOST: $host"
    OSM_HOST="$host" ./run.sh&
    pid=$!
    host_name[host_count]="$host"
    host_pid[host_count]=$pid
    echo $pid > "${HOSTS_DIR}/${host}/pid"
    host_mac[host_count]=$(< "${HOSTS_DIR}/${host}/mac")
    info "OSM HOST: $host  PID:${host_pid[host_count]} MAC:${host_mac[host_count]}"
    host_count=$(( host_count + 1 ))
done

echo "========================================="
info "Waiting on network of $host_count"

while (( count != host_count )); do
    for n in $(seq 0 $(( host_count - 1 ))); do
        name=${host_name[$n]}
        if [[ -z "${host_ip[$n]}" ]]; then
            ip_addr=$(./get_active_ip_of.sh "$name" "${OSM_SUBNET}.1")
            if [[ -n "$ip_addr" ]]; then
                info "$name : $ip_addr"
                host_ip[n]="$ip_addr"
            fi
        fi
    done

    count=0
    for n in $(seq 0 $host_count); do
        [[ -n "${host_ip[$n]}" ]] && count=$(( count + 1 ))
    done
done
