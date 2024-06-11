#! /bin/bash

. env_common.sh

./net_ctrl.sh open $VOSM_HOSTBR $OSM_SUBNET
[ "$?" = "0" ] || { echo "Failed to setup bridge"; exit -1; }

machines=( $(while read line; do basename "$line"; done <<< $(find "$HOSTS_DIR" -name "mac" -exec dirname {} \;) ) )

echo "========================================="
echo "Starting network"

host_count=0
for host in ${machines[@]}
do
  echo "Starting OSM HOST: $host"
  OSM_HOST="$host" ./run.sh&
  host_name[$host_count]=$host
  host_pid[$host_count]=$!
  host_mac[$host_count]=$(cat $HOSTS_DIR/$host/mac)
  echo "OSM HOST:$host  PID:${host_pid[$host_count]} MAC:${host_mac[$host_count]}"
  host_count=$(($host_count + 1))
done

echo "========================================="
echo "Waiting on network of $host_count"

count=0
while [ $count != $host_count ]
do
  for n in `seq 0 $(($host_count - 1))`
  do
    name=${host_name[$n]}
    if [ -z "${host_ip[$n]}" ]
    then
      ip_addr=$(./get_active_ip_of.sh $name $OSM_SUBNET.1)
      [ -z "$ip_addr" ] || { echo "$name : $ip_addr"; host_ip[$n]=$ip_addr; }
    fi
  done
  count=0
  for n in `seq 0 $host_count`
  do
    [ -z "${host_ip[$n]}" ] || count=$(($count + 1))
  done
done
