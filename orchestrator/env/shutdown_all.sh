#! /bin/bash

. common.sh

ips=($(awk '/'$OSM_SUBNET'/ {print $3}' "$HOSTS_DIR/$VOSM_HOSTBR.leasefile"))

for ip in ${ips[@]}
do
  echo "Closing down $ip"
  ssh root@$ip poweroff
done
