#! /bin/bash

PRESEED=preseed-plain.cfg

[ -n "$OSMHOST" ] || OSMHOST=debian

. setup_common.sh

ansible-playbook -v -e "target=$vm_ip osm_host_name=$OSMHOST fake_osm_host=True" -i /tmp/hosts osmhost_from_ext4.yaml

ssh root@$vm_ip "poweroff"
