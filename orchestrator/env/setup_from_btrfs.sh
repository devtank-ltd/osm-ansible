#! /bin/bash

. setup_common.sh

ansible-playbook -e "target=$vm_ip osm_host_name=$OSMHOST osm_domain=$OSM_DOMAIN fake_osm_host=True" -i /tmp/hosts osmhost_from_btrfs.yaml

ssh root@$vm_ip "poweroff"
