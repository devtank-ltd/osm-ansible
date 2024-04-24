#! /bin/bash

[ -n "$VOSMHOSTBR" ] || VOSMHOSTBR=vosmhostbr0
[ -n "$HOSTS_DIR" ] || HOSTS_DIR=hosts
[ -n "$OSMHOST_COUNT" ] || OSMHOST_COUNT=4

OSMHOST_MAX=$(($OSMHOST_COUNT - 1))

echo "========================================="
echo "Starting network"

OSMHOST=orchestrator ./run.sh&
orchestrator_pid=$!
orchestrator_mac=$(cat $HOSTS_DIR/orchestrator/mac)

for n in `seq 0 $OSMHOST_MAX`
do
  echo "Starting OSM HOST: vosmhost$n"
  OSMHOST="vosmhost$n" ./run.sh&
  host_pid[$n]=$!
  host_mac[$n]=$(cat $HOSTS_DIR/vosmhost$n/mac)
  echo "OSM HOST: vosmhost$n  PID:${host_pid[$n]} MAC:${host_mac[$n]}"
  sleep 0.1 # Give it a little time to acturally start.
done

echo "========================================="
echo "Waiting on network"

count=0
while [ -z "$orchestrator_ip" -o $count != $OSMHOST_COUNT ]
do
  sleep 0.25
  if [ -z "$orchestrator_ip" ]
  then
    orchestrator_ip=$(./get_active_ip_of_mac.sh orchestrator)
    [ -z "$orchestrator_ip" ] || echo "Orchestrator : $orchestrator_ip"
  fi
  for n in `seq 0 $OSMHOST_MAX`
  do
    if [ -z "${host_ip[$n]}" ]
    then
      name=vosmhost$n
      ip_addr=$(./get_active_ip_of_mac.sh $name)
      [ -z "$ip_addr" ] || { echo "vosmhost$n : $ip_addr"; host_ip[$n]=$ip_addr; }
    fi
  done
  count=0
  for n in `seq 0 $OSMHOST_MAX`
  do
    [ -z "${host_ip[$n]}" ] || count=$(($count + 1))
  done
done
