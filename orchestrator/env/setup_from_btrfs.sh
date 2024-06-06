#! /bin/bash

. setup_common.sh

echo "Applying OSM Host Ansible"

ansible-playbook -e "target=$vm_ip osm_host_name=$OSM_HOST osm_domain=$OSM_DOMAIN fake_osm_host=True" -i "$ANSIBLE_HOSTS" osmhost_from_btrfs.yaml

[ -n "$POWER_ON" ] || { ssh root@$vm_ip "poweroff"; wait $run_pid; }
