#! /bin/bash

set -e

path=$(readlink -f "$0")
owndir=$(dirname $path)

customer_name=$1
mqtt_port=$2

[ -n "$customer_name" ] || { echo "No customer name given."; exit -1; }
[ -n "$mqtt_port" ] || { echo "No MQTT port given."; exit -1; }

cd "$owndir"

git pull

domain=$(ls /etc/letsencrypt/live/ | grep -v README | head -n 1 | awk -F '.' 'BEGIN { OFS="."}; {$1=""; print $0}')

ansible-playbook -i hosts -e "customer_name=$customer_name mqtt_port=$mqtt_port" create-container.yaml

echo $customer_name-svr >> hosts

ansible-playbook -i hosts -e "target=$customer_name-svr customer_name=$customer_name base_domain=$customer_name$domain" provision-container.yaml
