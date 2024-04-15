#! /bin/bash

PRESEED=preseed-ext4.cfg

[ -n "$OSMHOST" ] || OSMHOST=ext4deb

. setup_common.sh

ansible-playbook -e "target=$vm_ip osm_host_name=$OSMHOST fake_osm_host=True" -i /tmp/hosts osmhost_from_ext4.yaml

ssh root@$vm_ip "poweroff"
