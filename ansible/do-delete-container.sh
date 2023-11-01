#! /bin/sh

path=$(readlink -f "$0")
owndir=$(dirname $path)

customer_name=$1
mqtt_port=$2

cd "$owndir"

ansible-playbook -i hosts -e 'container_hostname=$customer_name-svr' delete-container.yaml
