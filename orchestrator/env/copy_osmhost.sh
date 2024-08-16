#! /bin/bash

src=$1
dst=$2

source env_common.sh

dns_server=$OSM_SUBNET.1

if [ ! -e "$HOSTS_DIR/$src" ]
then
  echo "Source host "$src" does not exist"
  exit -1
fi

mkdir "$HOSTS_DIR/$dst"

cp -v "$HOSTS_DIR/$src/"{disk.qcow,ovmf_vars.fd} "$HOSTS_DIR/$dst/"

source do_run.sh

ssh root@$vm_ip "sed -i \"s|$src|$dst|g\" /etc/{hosts,hostname}; hostname $dst"
ssh root@$vm_ip "rm /etc/ssh/ssh_host_*; dpkg-reconfigure openssh-server; poweroff"

echo "Waiting for new clone to shutdown"

wait $run_pid

echo "Clone shutdown"
