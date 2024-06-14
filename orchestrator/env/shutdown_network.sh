#! /bin/bash

[ -z "$1" ] || HOSTS_DIR=$1
[ -n "$HOSTS_DIR" ] || { echo "Not given a hosts dir as argument or env var."; exit -1; }

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

pids=$(cat "$HOSTS_DIR"/*/pid)

waiting=1
while [ $waiting != 0 ]
do
  waiting=0
  for pid in $pids
  do
    [ ! -e /proc/$pid ] || waiting=1
  done
  [ $waiting = 0 ] || sleep 1
done

./net_ctrl.sh close $VOSM_HOSTBR $HOSTS_DIR $OSM_SUBNET $OSM_DOMAIN
