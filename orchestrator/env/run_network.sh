#! /bin/bash

[ -n "$OSM_HOST_COUNT" ] || OSM_HOST_COUNT=2

. common.sh

./net_ctrl.sh open $VOSM_HOSTBR $OSM_SUBNET
[ "$?" = "0" ] || { echo "Failed to setup bridge"; exit -1; }

OSM_HOST_MAX=$(($OSM_HOST_COUNT - 1))

echo "========================================="
echo "Starting network"

OSM_HOST=orchestrator ./run.sh&
orchestrator_pid=$!
orchestrator_mac=$(cat $HOSTS_DIR/orchestrator/mac)

for n in `seq 0 $OSM_HOST_MAX`
do
  echo "Starting OSM HOST: vosmhost$n"
  OSM_HOST="vosmhost$n" ./run.sh&
  host_pid[$n]=$!
  host_mac[$n]=$(cat $HOSTS_DIR/vosmhost$n/mac)
  echo "OSM HOST: vosmhost$n  PID:${host_pid[$n]} MAC:${host_mac[$n]}"
  sleep 0.1 # Give it a little time to acturally start.
done

echo "========================================="
echo "Waiting on network"

count=0
while [ -z "$orchestrator_ip" -o $count != $OSM_HOST_COUNT ]
do
  sleep 0.25
  if [ -z "$orchestrator_ip" ]
  then
    orchestrator_ip=$(./get_active_ip_of.sh orchestrator $OSM_SUBNET.1)
    [ -z "$orchestrator_ip" ] || echo "Orchestrator : $orchestrator_ip"
  fi
  for n in `seq 0 $OSM_HOST_MAX`
  do
    if [ -z "${host_ip[$n]}" ]
    then
      name=vosmhost$n
      ip_addr=$(./get_active_ip_of.sh $name $OSM_SUBNET.1)
      [ -z "$ip_addr" ] || { echo "vosmhost$n : $ip_addr"; host_ip[$n]=$ip_addr; }
    fi
  done
  count=0
  for n in `seq 0 $OSM_HOST_MAX`
  do
    [ -z "${host_ip[$n]}" ] || count=$(($count + 1))
  done
done
