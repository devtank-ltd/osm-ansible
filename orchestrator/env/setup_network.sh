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
echo "Start network"
source run_network.sh

echo "========================================="
echo "Network started, adding OSM HOSTs to Orchestrator"

orchestrator_ip="$(./get_active_ip_of.sh orchestrator "$OSM_SUBNET".1)"

ssh-keygen -f ~/.ssh/known_hosts -R "$orchestrator_ip"
ssh-keyscan -H "$orchestrator_ip" >> ~/.ssh/known_hosts

ssh root@"$orchestrator_ip" "ssh-keygen -q  -t rsa -N '' -f /root/.ssh/id_rsa"
orchestrator_pub="$(ssh root@"$orchestrator_ip" "cat /root/.ssh/id_rsa.pub")"

for n in $(seq 0 ${#host_name[@]}); do
    name=${host_name[$n]}
    if [[ -n "$name" && "$name" != "orchestrator" ]]; then
        ip_addr="${host_ip[$n]}"

        ssh-keygen -f ~/.ssh/known_hosts -R $ip_addr
        ssh-keyscan -H $ip_addr >> ~/.ssh/known_hosts

        echo "Copy Orchestrator SSH public key to $name $ip_addr"
        ssh root@"$ip_addr" 'mkdir -p /home/osm_orchestrator/.ssh'
        ssh root@"$ip_addr" "echo $orchestrator_pub >> /home/osm_orchestrator/.ssh/authorized_keys"
        echo "Put $name SSH host keys to Orchestrator"
        ssh root@"$orchestrator_ip" "ssh-keyscan -H $ip_addr >> /root/.ssh/known_hosts"
        ssh root@"$orchestrator_ip" "/srv/osm-lxc/orchestrator/orchestrator_cli.py add_host $name $ip_addr 4"
    fi
done

echo "========================================="
echo "Network started, adding OSM customers to Orchestrator"

for n in $(seq 1 "$OSMCUSTOMER_COUNT"); do
    customer_name="customer${n}"
    ssh root@$orchestrator_ip "/srv/osm-lxc/orchestrator/orchestrator_cli.py add_customer $customer_name"
done

# TODO: move to appropriate place
ORCHESTRATOR_DIR="${HOSTS_DIR}/orchestrator"
TEMP_PROMETHEUS_PLAYBOOK="$(mktemp -p "$ORCHESTRATOR_DIR" --suffix=_ansible.yaml)"
TEMP_ORCHESTRATOR_HOSTS="vosmhosts"
PROMETHEUS_TEMPLATE="../../templates/prometheus/prometheus.yml.j2"
PROMETHEUS_RULES="../../templates/prometheus/prometheus.rules"

awk '{print $3 ":" $4}' "${HOSTS_DIR}/${VOSM_HOSTBR}.leasefile" > "$TEMP_ORCHESTRATOR_HOSTS"
cat <<-EOF > "${TEMP_PROMETHEUS_PLAYBOOK}"
	---
	- hosts: "{{ target }}"
	  tasks:
	    - name: "Lookup vosm hosts to list"
	      set_fact:
	        hosts: "{{ lookup('ansible.builtin.file', '${TEMP_ORCHESTRATOR_HOSTS}').splitlines() }}"

	    - name: Apply prometheus configuration file
	      template:
	        src: ${PROMETHEUS_TEMPLATE}
	        dest: /etc/prometheus/prometheus.yml

	    - name: Apply prometheus alert rules
	      copy:
	        src: $PROMETHEUS_RULES
	        dest: /etc/prometheus/prometheus.rules

	    - name: Restart prometheus
	      ansible.builtin.service:
	        name: prometheus
	        state: restarted
EOF

edo ansible-playbook -v -u root -e "target=$orchestrator_ip" -i "$orchestrator_ip", "$TEMP_PROMETHEUS_PLAYBOOK"
