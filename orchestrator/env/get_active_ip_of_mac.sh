#! /bin/bash

bridge_name=$1
mac_addres=$2

vm_ip=$(awk "/$mac_addres/ {print \$3}" "/tmp/$bridge_name.leasefile")
if [ -n "$vm_ip" ]
then
  ping -c1 -W1 $vm_ip
  if [ "$?" == "0" ]
  then
    echo $vm_ip
  fi
fi
