#! /bin/bash

set -e

path=$(readlink -f "$0")
owndir=$(dirname $path)

customer_name=$1
mqtt_port=$2

cd "$owndir"

git pull

ansible-playbook -i hosts -e "container_hostname=$customer_name-svr mqtt_port=$mqtt_port" create-container.yaml
