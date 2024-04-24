#! /bin/bash

osm_host=$1

vm_ip=$(dig @192.168.5.1 $osm_host +short)
if [ -n "$vm_ip" ]
then
  ping -c1 -W1 $vm_ip >/dev/null
  if [ "$?" == "0" ]
  then
    name_check=$(dig @192.168.5.1 -x $vm_ip +short)
    [ "$name_check" != "$osm_host." ] || echo $vm_ip
  fi
fi
