#!/usr/bin/env bash

source functions.sh
source setup_start.sh

echo "========================================="
info "Creating OSM Orchestrator"
source setup_orchestrator.sh

echo "========================================="
info "Creating virtual OSM_HOSTs"
OSM_HOST="vosmhost0"

info "Creating template OSM Host, $OSM_HOST"
source setup_from_btrfs.sh
OSM_HOST_MAX=$(( OSM_HOST_COUNT - 1 ))

for n in $(seq 1 $OSM_HOST_MAX); do
   echo "Copy OSM Host $OSM_HOST to vosmhost$n"
  ./copy_osmhost.sh vosmhost0 vosmhost"$n"
done

echo "========================================="
info "Start network"
source run_network.sh

echo "========================================="
info "Network started, adding OSM HOSTs to Orchestrator"

orchestrator_ip="$(./get_active_ip_of.sh orchestrator "$OSM_SUBNET".1)"

ssh-keygen -f ~/.ssh/known_hosts -R "$orchestrator_ip"
ssh-keyscan -H "$orchestrator_ip" >> ~/.ssh/known_hosts

ssh root@"$orchestrator_ip" "ssh-keygen -q  -t rsa -N '' -f /root/.ssh/id_rsa"
orchestrator_pub="$(ssh root@"$orchestrator_ip" "cat /root/.ssh/id_rsa.pub")"

info "Start Pebble ACME"
ansible-playbook \
    -v \
    -u root \
    -e target="$orchestrator_ip" -i "${orchestrator_ip}," \
    --tags "pebble" osmhost_orchestrator.yaml

for n in $(seq 0 ${#host_name[@]}); do
    name=${host_name[$n]}
    if [[ -n "$name" && "$name" != "orchestrator" ]]; then
        ip_addr="${host_ip[$n]}"
        ssh-keygen -f ~/.ssh/known_hosts -R "$ip_addr"
        ssh-keyscan -H "$ip_addr" >> ~/.ssh/known_hosts

        info "Copy Orchestrator SSH public key to $name $ip_addr"
        ssh root@"$ip_addr" 'mkdir -p /home/osm_orchestrator/.ssh'
        ssh root@"$ip_addr" "echo $orchestrator_pub >> /home/osm_orchestrator/.ssh/authorized_keys"

        REQ_PEBBLE_CRT_ARGS=(
            certonly
            --standalone
            -d "${name}.${OSM_DOMAIN}"
            --server "https://${orchestrator_ip}:14000/dir"
            --agree-tos
            --no-verify-ssl
            --http-01-port=5002
            --register-unsafely-without-email
            --quiet
        )
        ssh root@"$ip_addr" "echo $orchestrator_pub >> /root/.ssh/authorized_keys"
        info "Request certificate from $orchestrator_ip for ${name}.${OSM_DOMAIN} domain."
        ssh root@"$ip_addr" "REQUESTS_CA_BUNDLE=devtank.minica.pem certbot ${REQ_PEBBLE_CRT_ARGS[*]}"

        info "Put $name SSH host keys to Orchestrator"
        ssh root@"$orchestrator_ip" "ssh-keyscan -H $ip_addr >> /root/.ssh/known_hosts"
        ssh root@"$orchestrator_ip" "/srv/osm-lxc/orchestrator/orchestrator_cli.py add_host $name $ip_addr 4"
        info "Adjust nginx config for"
        ansible-playbook \
            -v -u root -e "target=${ip_addr} osm_host_name=${name} osm_domain=${OSM_DOMAIN}" \
            -i "${ip_addr}," \
            --tags "pebble" osmhost_from_btrfs.yaml
    fi
done

echo "========================================="
info "Network started, adding OSM customers to Orchestrator"

for n in $(seq 1 "$OSMCUSTOMER_COUNT"); do
    customer_name="customer${n}"
    ssh root@"$orchestrator_ip" "/srv/osm-lxc/orchestrator/orchestrator_cli.py add_customer $customer_name"
done

print_hosts_lease "$HOSTS_DIR"
