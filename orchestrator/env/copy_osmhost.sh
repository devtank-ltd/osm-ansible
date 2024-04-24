#! /bin/bash

src=$1
dst=$2

[ -n "$HOSTS_DIR" ] || HOSTS_DIR=hosts

if [ ! -e "$HOSTS_DIR/$src" ]
then
  echo "Source host "$src" does not exist"
  exit -1
fi

mkdir "$HOSTS_DIR/$dst"

cp -v "$HOSTS_DIR/$src/"{disk.qcow,ovmf_vars.fd} "$HOSTS_DIR/$dst/"

OSMHOST=$dst ./run.sh &
run_pid=$!

echo "Waiting for old name $src to have IP."
while [ -z "$vm_ip" ]
do
  sleep 0.25
  [ -e /proc/$run_pid ] || { echo "QEmu dead"; exit -1; }
  vm_ip=$(./get_active_ip_of.sh $src)
done

echo "VM booted and taken IP address $vm_ip"

mkdir -p ~/.ssh

# Sort out ssh host key
ssh-keygen -f ~/.ssh/known_hosts -R $vm_ip
ssh-keyscan -H $vm_ip >> ~/.ssh/known_hosts

ssh root@$vm_ip exit
[ "$?" = "0" ] || { echo "SSH access setup failed."; kill $run_pid; exit -1; }

ssh root@$vm_ip "sed -i \"s|$src|$dst|g\" /etc/{hosts,hostname}; hostname $dst"
ssh root@$vm_ip "rm /etc/ssh/ssh_host_*; dpkg-reconfigure openssh-server; systemctl restart ssh"

ssh-keygen -f ~/.ssh/known_hosts -R $vm_ip
ssh-keyscan -H $vm_ip >> ~/.ssh/known_hosts

ssh root@$vm_ip "poweroff"

echo "Waiting for new clone to shutdown"

while [ -e /proc/$run_pid ]
do
  sleep 0.25
done

echo "Clone shutdown"
