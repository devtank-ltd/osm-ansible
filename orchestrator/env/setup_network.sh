#! /bin/bash

[ -n "$VOSM_HOSTBR" ] || VOSM_HOSTBR=vosmhostbr0
[ -n "$HOSTS_DIR" ] || HOSTS_DIR=hosts
[ -n "$OSM_HOST_COUNT" ] || OSM_HOST_COUNT=2
[ -n "$OSMCUSTOMER_COUNT" ] || OSMCUSTOMER_COUNT=7
[ -n "$OSM_SUBNET" ] || OSM_SUBNET=192.168.5

echo "Creating OSM Orchestrator"
./setup_orchestrator.sh

echo "========================================="
echo "Creating virtual OSM_HOSTs"
OSM_HOST=vosmhost0 ./setup_from_btrfs.sh
OSM_HOST_MAX=$(($OSM_HOST_COUNT - 1))
for n in `seq 1 $OSM_HOST_MAX`
do
  ./copy_osmhost.sh vosmhost0 vosmhost$n
done

. run_network.sh

echo "========================================="
echo "Network started, adding OSM HOSTs to Orchestrator"

orchestrator_ip=$(./get_active_ip_of.sh orchestrator $OSM_SUBNET.1)

ssh-keygen -f ~/.ssh/known_hosts -R $orchestrator_ip
ssh-keyscan -H $orchestrator_ip >> ~/.ssh/known_hosts

ssh root@$orchestrator_ip "ssh-keygen -q  -t rsa -N '' -f /root/.ssh/id_rsa"
orchestrator_pub=$(ssh root@$orchestrator_ip "cat /root/.ssh/id_rsa.pub")

for n in `seq 0 $OSM_HOST_MAX`
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
