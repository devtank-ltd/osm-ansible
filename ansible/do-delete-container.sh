#! /bin/bash

set -e

path=$(readlink -f "$0")
owndir=$(dirname $path)

customer_name=$1
mqtt_port=$2

cd "$owndir"

git pull

ansible-playbook -i hosts -e "customer_name=$customer_name" delete-container.yaml

sed -i "/$customer_name-svr/d" hosts
