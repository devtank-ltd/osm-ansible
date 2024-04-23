#! /bin/bash

[ -n "$VOSMHOSTBR" ] || VOSMHOSTBR=vosmhostbr0
[ -n "$HOSTS_DIR" ] || HOSTS_DIR=hosts

echo "Creating OSM Orchestrator"
./setup_orchestrator.sh

echo "========================================="
echo "Creating first virtual OSMHOST"
OSMHOST=vosmhost0 ./setup_from_btrfs.sh

[ -n "$OSMHOST_COUNT" ] || OSMHOST_COUNT=3

OSMHOST_CLONES=$(($OSMHOST_COUNT - 1))
echo "========================================="
echo "Cloning $OSMHOST_CLONES virtual OSMHOSTS"
for n in `seq $OSMHOST_CLONES`
do
  echo "Cloning $n"
  ./copy_osmhost.sh vosmhost0 vosmhost$n
done

. run_network.sh

echo "========================================="
echo "Network started, adding OSM HOSTs to Orchestrator"

for n in `seq 0 $OSMHOST_COUNT`
do
  ssh root@$orchestrator_ip "/srv/osm-lxc/orchestrator/orchestrator_cli.py add_host vosmhost$n ${host_ip[$n]} 4"
done
