#! /bin/bash

PRESEED=preseed-ext4.cfg

[ -n "$OSMHOST" ] || OSMHOST=ext4deb

. setup_common.sh

ansible-playbook -v -e "target=$vm_ip osm_host_name=$OSMHOST osm_domain=$OSM_DOMAIN fake_osm_host=True" -i "$ANSIBLE_HOSTS" osmhost_from_ext4.yaml

[ -n "$POWER_ON" ] || ssh root@$vm_ip "poweroff"
