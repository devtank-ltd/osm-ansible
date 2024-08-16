#! /bin/bash

source setup_start.sh

[ -n "$OSM_HOST" ] || OSM_HOST=ext4deb

echo "Upgrade ext4 install to btrfs install"
PRESEED=preseed-ext4.cfg
ansible_file=ext4_to_btrfs.yaml

source setup_common.sh

ansible-playbook -v -e "target=$vm_ip osm_host_name=$OSM_HOST osm_domain=$OSM_DOMAIN fake_osm_host=True" -i "$ANSIBLE_HOSTS" setup_from_btrfs.yaml
