#! /bin/bash

wget http://IPADDR:8000/osmhost_setup.sh -O /root/osmhost_setup.sh;
chmod +x /root/osmhost_setup.sh;

ssh_key_name=$(wget http://IPADDR:8000/ssh_key_name -O -)
mkdir -p /root/.ssh
wget http://IPADDR:8000/$ssh_key_name -O - >> /root/.ssh/authorized_keys

mkdir -p /etc/letsencrypt/live/OSMHOST.osmm.co.uk
