#! /bin/bash

. common.sh

echo "Creating OSM Orchestrator"
./setup_orchestrator.sh

echo "Creating first virtual OSMHOST"
OSMHOST=vosmhost0 ./setup_from_btrfs.sh

[ -n "$OSMHOST_COUNT" ] || OSMHOST_COUNT=3

OSMHOST_CLONES=$(($OSMHOST_COUNT - 1))
echo "Cloning $OSMHOST_CLONES virtual OSMHOSTS"
for n in `seq $OSMHOST_CLONES`
do
  echo "Cloning $n"
  ./copy_osmhost.sh vosmhost0 vosmhost$n
done

echo "Starting network"

OSMHOST=orchestrator ./run.sh&
orchestrator_pid=$!
orchestrator_mac=$(cat $HOST_DIR/orchestrator/mac)

for n in `seq 0 $OSMHOST_COUNT`
do 
  OSMHOST=vosmhost$n ./run.sh&
  host_pid[$n]=$1
  host_mac[$n]=$(cat $HOST_DIR/vosmhost1/mac)
done


while [ -z "$orchestrator_ip" -a $count = $OSMHOST_COUNT ]
do
  sleep 0.25
  [ -n "$orchestrator_ip" ] || orchestrator_ip=$(./get_active_ip_of_mac.sh $VOSMHOSTBR $OSMHOSTMAC)
  for n in `seq 0 $OSMHOST_COUNT`
  do
    [ -n "${host_ip[$n]}" ] || host_ip[$n]=$(./get_active_ip_of_mac.sh $VOSMHOSTBR ${host_mac[$n]})
  done
  count=0
  for n in `seq 0 $OSMHOST_COUNT`
  do
    [ -z "${host_ip[$n]}" ] || count=$(($count + 1))
  done
done

echo "Network started"

for n in `seq 0 $OSMHOST_COUNT`
do
  ssh root@$orchestrator_ip "/srv/osm-lxc/orchestrator/orchestrator_cli.py add_host vosmhost$n ${host_ip[$n]} 4"
done
