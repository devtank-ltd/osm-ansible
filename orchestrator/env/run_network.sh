#! /bin/bash

[ -n "$VOSMHOSTBR" ] || VOSMHOSTBR=vosmhostbr0
[ -n "$HOSTS_DIR" ] || HOSTS_DIR=hosts
[ -n "$OSMHOST_COUNT" ] || OSMHOST_COUNT=3

echo "========================================="
echo "Starting network"

OSMHOST=orchestrator ./run.sh&
orchestrator_pid=$!
orchestrator_mac=$(cat $HOSTS_DIR/orchestrator/mac)

for n in `seq 0 $OSMHOST_COUNT`
do
  echo "Starting OSM HOST: vosmhost$n"
  OSMHOST="vosmhost$n" ./run.sh&
  host_pid[$n]=$!
  host_mac[$n]=$(cat $HOSTS_DIR/vosmhost1/mac)
  echo "OSM HOST: vosmhost$n  PID:${host_pid[$n]} MAC:${host_mac[$n]}"
  sleep 0.1 # Give it a little time to acturally start.
done

echo "========================================="
echo "Waiting on network"

count=0
while [ -z "$orchestrator_ip" -a $count = $OSMHOST_COUNT ]
do
  sleep 0.25
  [ -n "$orchestrator_ip" ] || orchestrator_ip=$(./get_active_ip_of_mac.sh $VOSMHOSTBR $orchestrator_mac)
  for n in `seq 0 $OSMHOST_COUNT`
  do
    if [ -z "${host_ip[$n]}" ]
    then
      ip_addr=$(./get_active_ip_of_mac.sh $VOSMHOSTBR ${host_mac[$n]})
      [ -z "$ip_addr" ] || { echo "$name : $ip_addr"; host_ip[$n]=$ip_addr; }
    fi
  done
  count=0
  for n in `seq 0 $OSMHOST_COUNT`
  do
    [ -z "${host_ip[$n]}" ] || count=$(($count + 1))
  done
done
