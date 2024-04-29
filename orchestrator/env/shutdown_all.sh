#! /bin/bash

. common.sh

ips=($(awk '/192.168.5./ {print $3}' "$HOSTS_DIR/$VOSMHOSTBR.leasefile"))

for ip in ${ips[@]}
do
  echo "Closing down $ip"
  ssh root@ip poweroff
done
