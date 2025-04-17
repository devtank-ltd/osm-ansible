#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# TODO: fix path
# shellcheck source=/dev/null
source inc/functions

main() {
    declare -A ARGS=([action]="" [config]="")
    process_args "$@"

    if [[ ! -v STY || -z "$STY" ]]; then
        warn "Not running in GNU Screen"
        yesno "Continue?"
    fi

    declare -A base_hosts=(
        [orchestrator]="preseed-ext4.cfg"
        ["${VOSM_HOST}0"]="preseed-btrfs.cfg"
    )
    declare -A osm_hosts

    if [[ "${ARGS[action]}" == "setup" ]]; then
        build_env "${ARGS[config]}"
        get_debian_iso

        if ! setup_bridge; then
            die "Bridge setup"
        fi

        # TODO: parallel?
        # Install base debian distribution for orchestrator and osm host
        for host in "${!base_hosts[@]}"; do
            prepare_base_host "$host" "$OSM_DOMAIN" "${base_hosts[$host]}"
            osm_hosts["$host"]=""
        done

        for host in "${!osm_hosts[@]}"; do
            run_qemu "$host" "$VOSM_HOSTBR"
            osm_hosts["$host"]="$(wait_for_ip "$host" "${OSM_SUBNET}.1")"
            setup_ssh "${osm_hosts[$host]}"

            if ! grep -q "${osm_hosts[$host]}" "$ANSIBLE_HOSTS"; then
                # shellcheck disable=SC1003
                sed -i '1 i\'"${host} ansible_host=${osm_hosts[$host]}"'' "$ANSIBLE_HOSTS"
            fi
            run_ansible_early "$host" "${osm_hosts[$host]}"
        done

        for i in $(seq 1 $(( OSM_HOST_COUNT - 1 ))); do
            clone_host "${VOSM_HOST}0" "${VOSM_HOST}${i}"
            sed -i '1 i\'"${VOSM_HOST}${i} ansible_host="'' "$ANSIBLE_HOSTS"
            osm_hosts["${VOSM_HOST}${i}"]=""
        done

        start_hosts osm_hosts

        local orch_pub orch_ip
        orch_pub="$(gen_remote_ssh "${osm_hosts[orchestrator]}")"
        orch_ip="${osm_hosts[orchestrator]}"

        for host in "${!osm_hosts[@]}"; do
            local ipaddr="${osm_hosts[$host]}"
            # update hosts for ansible
            sed -ri 's/^'"$host"'.*=$/&'"$ipaddr"'/' "${HOSTS_DIR}/hosts"

            if [[ "$host" != "orchestrator" ]]; then
                setup_ssh "$ipaddr"
                info "Copy orchestrator ssh public key to '${host}'[${ipaddr}]"
                # shellcheck disable=SC2087
                ssh root@"$ipaddr" /bin/bash <<-EOF
			mkdir -p /home/osm_orchestrator/.ssh
			echo $orch_pub >> /home/osm_orchestrator/.ssh/authorized_keys
EOF
                # TODO: request certs
                # request_pebble_cert "$host" "${osm_hosts[orchestrator]}"
                # shellcheck disable=SC2029
                ssh root@"$orch_ip" "ssh-keyscan -H $ipaddr >> /root/.ssh/known_hosts" >/dev/null 2>&1
                # shellcheck disable=SC2029
                # ssh root@"$orch_ip" "/srv/osm-lxc/orchestrator/orchestrator_cli.py add_host $host $ipaddr 4"
                # TODO: adjust nginx for pebble
                # TODO: exchenge ssh keys
                # TODO: add customers
            fi
        done

        deploy_incus

    elif [[ "${ARGS[action]}" == "shutdown" ]]; then
        hosts_dir="${ARGS[hosts_dir]}"
        warn "shutting down '$hosts_dir' environment"
        if [[ ! -e "${hosts_dir}/env" ]]; then
            die "Unable to get environment settings"
        else
            # shellcheck source=/dev/null
            source "${hosts_dir}/env"
        fi
        close_bridge
        warn "Stop all VMs in located in '$hosts_dir'"
        find "$hosts_dir" -name "qemu.pid" -type f -print -exec pkill -15 -F {} \;
        pkill -15 -F "${hosts_dir}/${VOSM_HOSTBR}.pid"
    fi
}

main "$@"
