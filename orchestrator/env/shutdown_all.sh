#! /bin/bash

. env_common.sh

ips=($(awk '/'$OSM_SUBNET'/ {print $3}' "$HOSTS_DIR/$VOSM_HOSTBR.leasefile"))

for ip in ${ips[@]}
do
  ping -c1 -W1 $ip >/dev/null
  if [ "$?" == "0" ]
  then
    echo "Closing down $ip"
    ssh root@$ip poweroff
  fi
done

./net_ctrl.sh close $VOSM_HOSTBR $HOSTS_DIR $OSM_SUBNET $OSM_DOMAIN
