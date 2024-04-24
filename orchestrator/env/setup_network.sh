#! /bin/bash

[ -n "$VOSMHOSTBR" ] || VOSMHOSTBR=vosmhostbr0
[ -n "$HOSTS_DIR" ] || HOSTS_DIR=hosts
[ -n "$OSMHOST_COUNT" ] || OSMHOST_COUNT=4
[ -n "$OSMCUSTOMER_COUNT" ] || OSMCUSTOMER_COUNT=10

echo "Creating OSM Orchestrator"
./setup_orchestrator.sh

echo "========================================="
echo "Creating first virtual OSMHOST"
OSMHOST=vosmhost0 ./setup_from_btrfs.sh


echo "========================================="
OSMHOST_MAX=$(($OSMHOST_COUNT - 1))
echo "Cloning $OSMHOST_MAX virtual OSMHOSTS"
for n in `seq $OSMHOST_MAX`
do
  echo "Cloning $n"
  ./copy_osmhost.sh vosmhost0 vosmhost$n
done

. run_network.sh

echo "========================================="
echo "Network started, adding OSM HOSTs to Orchestrator"

# Fix host0 keys as clone will have dirtied it's good name!
ssh-keygen -f ~/.ssh/known_hosts -R ${host_ip[0]}
ssh-keyscan -H ${host_ip[0]} >> ~/.ssh/known_hosts

ssh root@$orchestrator_ip "ssh-keygen -q  -t rsa -N '' -f /root/.ssh/id_rsa"
orchestrator_pub=$(ssh root@$orchestrator_ip "cat /root/.ssh/id_rsa.pub")

for n in `seq 0 $OSMHOST_MAX`
do
  name=vosmhost$n
  ip_addr=${host_ip[$n]}
  ssh root@$ip_addr 'mkdir -p /home/osm_orchestrator/.ssh'
  ssh root@$ip_addr "echo $orchestrator_pub >> /home/osm_orchestrator/.ssh/authorized_keys"
  ssh root@$orchestrator_ip "ssh-keyscan -H $ip_addr >> /root/.ssh/known_hosts"
  ssh root@$orchestrator_ip "/srv/osm-lxc/orchestrator/orchestrator_cli.py add_host $name $ip_addr 4"
done


for n in `seq 0 $OSMCUSTOMER_COUNT`
do
  customer_name="customer$n"
  ssh root@$orchestrator_ip "/srv/osm-lxc/orchestrator/orchestrator_cli.py add_customer $customer_name"
done
