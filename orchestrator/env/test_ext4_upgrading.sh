#! /bin/bash

source setup_start.sh

[ -n "$OSM_HOST" ] || OSM_HOST=ext4deb

echo "Upgrade ext4 install to btrfs install"
PRESEED=preseed-ext4.cfg
ansible_file=upgrade/ext4_to_btrfs.yaml

export POWER_ON=1 # Don't turn off after first ansible run, as we are going again.

source setup_common.sh

ansible-playbook -v -e "target=$vm_ip osm_host_name=$OSM_HOST osm_domain=$OSM_DOMAIN fake_osm_host=True osm_ansible_branch=$git_branch" -i "$ANSIBLE_HOSTS" osmhost_from_btrfs.yaml

ssh root@$vm_ip "poweroff"
wait $run_pid
