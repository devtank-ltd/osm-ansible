#! /bin/bash

. common.sh

if [ -z "$DEFAULT_KEY_LOCATION" ]; then DEFAULT_KEY_LOCATION=~/.ssh/id_rsa.pub; fi

ssh_key_name=$(basename $DEFAULT_KEY_LOCATION)

if [ -z "$ssh_key_name" ]
then
  echo "No SSH key found."
  exit -1
fi

echo $ssh_key_name > $HOST_DIR/ssh_key_name

ln -s $DEFAULT_KEY_LOCATION $HOST_DIR/$ssh_key_name

./setup_common.sh

if [ "$rc" != "0" ]
then
  echo "Setup failed"
  exit -1
fi

./run.sh &

while [ -z "$vm_ip" ]
do
  sleep 0.25
  vm_ip=$(awk "/$OSMHOST/ {print $3}" /tmp/vosmhostnet.leasefile)
done

echo "VM booted and taken IP address $vm_ip"

# Sort out ssh host key
ssh-keygen -f ~/.ssh/known_hosts -R $vm_ip
ssh-keyscan -H $vm_ip >> ~/.ssh/known_hosts

echo "$vm_ip
[all:vars]
ansible_connection=ssh
ansible_user=root
" > /tmp/hosts

ansible-playbook -e "target=$vm_ip osm_host_name=$OSMHOST" -i /tmp/hosts osmhost_setup.yaml

ssh root@$vm_ip "power off"
