#! /bin/bash

src=$1
dst=$2

HOSTS_DIR=hosts

if [ ! -e "$HOSTS_DIR/$src" ]
then
  echo "Source host "$src" does not exist"
  exit -1
fi

mkdir "$HOSTS_DIR/$dst"

cp -v "$HOSTS_DIR/$src/"{disk.qcow,ovmf_vars.fd} "$HOSTS_DIR/$dst/"

OSMHOST=$dst
. async_run.sh

ssh root@$vm_ip "sed -i \"s|$src|$dst|g\" /etc/{hosts,hostname}"
ssh root@$vm_ip "rm /etc/ssh/ssh_host_*; dpkg-reconfigure openssh-server; systemctl restart ssh"

ssh-keygen -f ~/.ssh/known_hosts -R $vm_ip
ssh-keyscan -H $vm_ip >> ~/.ssh/known_hosts

ssh root@$vm_ip "poweroff"
