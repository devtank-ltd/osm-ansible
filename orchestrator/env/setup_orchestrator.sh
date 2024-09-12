#!/usr/bin/env bash

[[ -n "$OSM_HOST" ]] || OSM_HOST="orchestrator"

info "Applying Orchestrator Ansible"

PRESEED="preseed-ext4.cfg"
ansible_args="osm_host_name=${OSM_HOST} osm_domain=${OSM_DOMAIN} osm_dns=${vm_ip}"
ansible_file="osmhost_orchestrator.yaml"

source setup_common.sh
