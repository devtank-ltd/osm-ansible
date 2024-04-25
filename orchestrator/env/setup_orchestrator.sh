#! /bin/bash

PRESEED=preseed-ext4.cfg

[ -n "$OSMHOST" ] || OSMHOST=orchestrator

. setup_common.sh

echo "Applying Orchestrator Ansible"

ansible-playbook -v -e "target=$vm_ip osm_host_name=$OSMHOST osm_domain=$OSM_DOMAIN osm_dns=$vm_ip " -i "$ANSIBLE_HOSTS" osmhost_orchestrator.yaml

[ -n "$POWER_ON" ] || { ssh root@$vm_ip "poweroff"; wait $run_pid; }
