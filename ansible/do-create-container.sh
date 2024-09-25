#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash; -*-

set -e

path="$(readlink -f "$0")"
owndir="$(dirname "$path")"

customer_name="$1"
mqtt_port="$2"
domain="$3"

[[ -n "$customer_name" ]] || { echo "No customer name given."; exit 1; }
[[ -n "$mqtt_port" ]] || { echo "No MQTT port given."; exit 1; }

cd "$owndir"

[[ -e hosts ]] || { echo "localhost" > hosts; }

git pull

le_cert_name=$(ls /etc/letsencrypt/live/ | grep -v README | head -n 1)

[[ -z "$domain" || -e "custom_domain" ]] || echo "$domain" > "custom_domain"
[[ ! -e "custom_domain" ]] || domain=$(< "custom_domain")
[[ -n "$domain" ]] || domain=$(echo $le_cert_name | awk -F '.' 'BEGIN { OFS="."}; {$1=""; print substr($0, 2)}')

ansible-playbook -i hosts -e "customer_name=${customer_name} mqtt_port=${mqtt_port} le_domain=${domain}" create-container.yaml

echo "${customer_name}-svr" >> hosts
customer_domain="${customer_name}.${domain}"

ansible-playbook -i hosts -e "target=${customer_name}-svr customer_name=${customer_name} customer_domain=${customer_domain} le_domain=${domain}" provision-container.yaml
