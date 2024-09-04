#!/usr/bin/env bash

# TODO: nounset fails on OSM_HOST
#       how does this variable pass here?
# set -o errexit
# set -o nounset
# set -o pipefail

[[ -n "$OSM_HOST" ]] || OSM_HOST="orchestrator"

info "Applying Orchestrator Ansible"

PRESEED="preseed-ext4.cfg"
ansible_args="osm_host_name=${OSM_HOST} osm_domain=${OSM_DOMAIN} osm_dns=${vm_ip}"
ansible_file="osmhost_orchestrator.yaml"

source setup_common.sh
