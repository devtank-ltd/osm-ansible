#! /bin/bash

PRESEED=preseed-ext4.cfg

[ -n "$OSM_HOST" ] || OSM_HOST=ext4deb

. setup_common.sh

echo "Applying From Ext4 OSM Host Ansible"

ansible-playbook -v -e "target=$vm_ip osm_host_name=$OSM_HOST osm_domain=$OSM_DOMAIN fake_osm_host=True" -i "$ANSIBLE_HOSTS" osmhost_from_ext4.yaml

[ -n "$POWER_ON" ] || { ssh root@$vm_ip "poweroff"; wait $run_pid; }
