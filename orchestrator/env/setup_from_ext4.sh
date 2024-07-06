#! /bin/bash


[ -n "$OSM_HOST" ] || OSM_HOST=ext4deb

echo "Applying From Ext4 OSM Host Ansible"

PRESEED=preseed-ext4.cfg
ansible_args="osm_host_name=$OSM_HOST osm_domain=$OSM_DOMAIN fake_osm_host=True"
ansible_file=osmhost_from_ext4.yaml

source setup_common.sh
