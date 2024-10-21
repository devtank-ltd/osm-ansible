#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash; -*-

set -e

path="$(readlink -f "$0")"
owndir="$(dirname "$path")"

customer_name="$1"
mqtt_port="$2"
domain="$3"
priv_key="$4"

[[ -n "$customer_name" ]] || { echo "No customer name given."; exit 1; }
[[ -n "$mqtt_port" ]] || { echo "No MQTT port given."; exit 1; }

cd "$owndir"

[[ -e hosts ]] || { echo "localhost" > hosts; }

git pull

le_cert_name=$(ls /etc/letsencrypt/live/ | grep -v README | head -n 1)

[[ -z "$domain" || -e "custom_domain" ]] || echo "$domain" > "custom_domain"
[[ ! -e "custom_domain" ]] || domain=$(< "custom_domain")
[[ -n "$domain" ]] || domain=$(echo $le_cert_name | awk -F '.' 'BEGIN { OFS="."}; {$1=""; print substr($0, 2)}')

if [[ -z "$priv_key" ]]; then
    echo "The private key is missing"
    exit 1
fi

ansible-playbook \
    -v -i hosts \
    -e "customer_name=${customer_name} mqtt_port=${mqtt_port} le_domain=${domain}" \
    create-container.yaml

echo "${customer_name}-svr" >> hosts

ansible-playbook \
    -v -i hosts \
    -e "target=${customer_name}-svr customer_name=${customer_name} le_domain=${domain} priv_key=${priv_key}" \
    provision-container.yaml
