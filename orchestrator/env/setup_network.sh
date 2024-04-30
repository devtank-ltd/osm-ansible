#! /bin/bash

[ -n "$VOSMHOSTBR" ] || VOSMHOSTBR=vosmhostbr0
[ -n "$HOSTS_DIR" ] || HOSTS_DIR=hosts
[ -n "$OSMHOST_COUNT" ] || OSMHOST_COUNT=2
[ -n "$OSMCUSTOMER_COUNT" ] || OSMCUSTOMER_COUNT=7

echo "Creating OSM Orchestrator"
./setup_orchestrator.sh

export OSMORCHESTRATOR=$(cat "$HOSTS_DIR/orchestrator_ip")

echo "========================================="
echo "Creating virtual OSMHOSTs"
OSMHOST_MAX=$(($OSMHOST_COUNT - 1))
for n in `seq 0 $OSMHOST_MAX`
do
  OSMHOST=vosmhost$n ./setup_from_btrfs.sh
done

. run_network.sh

echo "========================================="
echo "Network started, adding OSM HOSTs to Orchestrator"

ssh-keygen -f ~/.ssh/known_hosts -R $orchestrator_ip
ssh-keyscan -H $orchestrator_ip >> ~/.ssh/known_hosts

ssh root@$orchestrator_ip "ssh-keygen -q  -t rsa -N '' -f /root/.ssh/id_rsa"
orchestrator_pub=$(ssh root@$orchestrator_ip "cat /root/.ssh/id_rsa.pub")

for n in `seq 0 $OSMHOST_MAX`
do
  name=vosmhost$n
  ip_addr=${host_ip[$n]}

  ssh-keygen -f ~/.ssh/known_hosts -R $ip_addr
  ssh-keyscan -H $ip_addr >> ~/.ssh/known_hosts

  ssh root@$ip_addr 'mkdir -p /home/osm_orchestrator/.ssh'
  ssh root@$ip_addr "echo $orchestrator_pub >> /home/osm_orchestrator/.ssh/authorized_keys"
  ssh root@$orchestrator_ip "ssh-keyscan -H $ip_addr >> /root/.ssh/known_hosts"
  ssh root@$orchestrator_ip "/srv/osm-lxc/orchestrator/orchestrator_cli.py add_host $name $ip_addr 4"
done

echo "========================================="
echo "Network started, adding OSM customers to Orchestrator"

for n in `seq 1 $OSMCUSTOMER_COUNT`
do
  customer_name="customer$n"
  ssh root@$orchestrator_ip "/srv/osm-lxc/orchestrator/orchestrator_cli.py add_customer $customer_name"
done
