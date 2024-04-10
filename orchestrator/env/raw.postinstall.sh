#! /bin/bash

wget http://IPADDR:8000/osmhost_setup.sh -O /root/osmhost_setup.sh;
chmod +x /root/osmhost_setup.sh;

mkdir -p /etc/letsencrypt/live/OSMHOST.osmm.co.uk
