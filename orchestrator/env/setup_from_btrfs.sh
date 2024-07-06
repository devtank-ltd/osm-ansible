#! /bin/bash

echo "Applying OSM Host Ansible"

PRESEED=preseed-btrfs.cfg
ansible_args="osm_host_name=$OSM_HOST osm_domain=$OSM_DOMAIN fake_osm_host=True"
ansible_file=osmhost_from_btrfs.yaml

source setup_common.sh
