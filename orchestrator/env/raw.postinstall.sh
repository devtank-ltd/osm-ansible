#! /bin/bash

# Setup SSH access
ssh_key_name=$(wget http://IPADDR:8000/ssh_key_name -O -)
mkdir -p /root/.ssh
wget http://IPADDR:8000/$ssh_key_name -O - >> /root/.ssh/authorized_keys

# Fake up LetsEncrypt
mkdir -p /etc/letsencrypt/live/OSMHOST.osmm.devtank.co.uk
openssl req -x509 -nodes -newkey rsa:4096 -days 1\
    -keyout "/etc/letsencrypt/live/OSM_HOST_NAME.osmm.devtank.co.uk/privkey.pem" \
    -out "/etc/letsencrypt/live/OSM_HOST_NAME.osmm.devtank.co.uk/fullchain.pem" \
    -subj '/CN=localhost'

echo "export SKIP_LETS_ENCRYPT=1" >> /root/.bashrc
