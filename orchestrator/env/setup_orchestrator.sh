#!/usr/bin/env bash

[[ -n "$OSM_HOST" ]] || OSM_HOST="orchestrator"

info "Applying Orchestrator Ansible"

PRESEED="preseed-ext4.cfg"
ansible_args="osm_host_name=${OSM_HOST} osm_domain=${OSM_DOMAIN} osm_dns=${vm_ip} smtp_host=${MAIL_SMTP_HOST} smtp_user=${MAIL_SMTP_USER} smtp_password=${MAIL_SMTP_PASSWORD} mail_recipients=${MAIL_RECIPIENTS}"
ansible_file="osmhost_orchestrator.yaml"

source setup_common.sh
