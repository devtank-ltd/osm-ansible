#! /bin/bash

src=$1
dst=$2

. env_common.sh

dns_server=$OSM_SUBNET.1

if [ ! -e "$HOSTS_DIR/$src" ]
then
  echo "Source host "$src" does not exist"
  exit -1
fi

mkdir "$HOSTS_DIR/$dst"

cp -v "$HOSTS_DIR/$src/"{disk.qcow,ovmf_vars.fd} "$HOSTS_DIR/$dst/"

OSM_HOST=$dst ./run.sh &
run_pid=$!
vm_ip=""

echo "Waiting for old name $src to have IP."
while [ -z "$vm_ip" ]
do
  sleep 0.25
  [ -e /proc/$run_pid ] || { echo "QEmu dead"; exit -1; }
  vm_ip=$(./get_active_ip_of.sh $src $dns_server)
done

echo "VM booted and taken IP address $vm_ip"

mkdir -p ~/.ssh

# Sort out ssh host key
ssh-keygen -f ~/.ssh/known_hosts -R $vm_ip
ssh-keyscan -H $vm_ip >> ~/.ssh/known_hosts

ssh root@$vm_ip exit
[ "$?" = "0" ] || { echo "SSH access setup failed."; kill $run_pid; exit -1; }

ssh root@$vm_ip "sed -i \"s|$src|$dst|g\" /etc/{hosts,hostname}; hostname $dst"
ssh root@$vm_ip "rm /etc/ssh/ssh_host_*; dpkg-reconfigure openssh-server; poweroff"

echo "Waiting for new clone to shutdown"

wait $run_pid

echo "Clone shutdown"
