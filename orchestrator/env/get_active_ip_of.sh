#! /bin/bash

osm_host=$1
dns_server=$2

vm_ip=$(dig @$dns_server $osm_host +short)
if [ -n "$vm_ip" ]
then
  ping -c1 -W1 $vm_ip >/dev/null
  if [ "$?" == "0" ]
  then
    name_check=$(dig @$dns_server -x $vm_ip +short)
    [ "$name_check" != "$osm_host." ] || echo $vm_ip
  fi
fi
