#! /bin/bash

set -e

path=$(readlink -f "$0")
owndir=$(dirname $path)

customer_name=$1
mqtt_port=$2
domain=$3

[ -n "$customer_name" ] || { echo "No customer name given."; exit -1; }
[ -n "$mqtt_port" ] || { echo "No MQTT port given."; exit -1; }

cd "$owndir"

[ -e hosts ] || { echo "localhost" > hosts; }

git pull

[ -z "$domain" ] || { extra="$extra le_domain=$domain"; echo "Using custom domain $domain, make sure to use it on delete."; }

ansible-playbook -i hosts -e "customer_name=$customer_name mqtt_port=$mqtt_port $extra" create-container.yaml

echo $customer_name-svr >> hosts

ansible-playbook -i hosts -e "target=$customer_name-svr customer_name=$customer_name $extra" provision-container.yaml
