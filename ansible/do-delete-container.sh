#! /bin/bash

set -e

path=$(readlink -f "$0")
owndir=$(dirname $path)

customer_name=$1
mqtt_port=$2
domain=$3

cd "$owndir"

git pull

[ ! -e "custom_domain" ] || domain=$(cat "custom_domain")
[ -z "$domain" ] || { extra="$extra le_domain=$domain"; echo "Using custom domain $domain."; }

ansible-playbook -i hosts -e "customer_name=$customer_name $extra" delete-container.yaml

sed -i "/$customer_name-svr/d" hosts
