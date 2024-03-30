#! /bin/bash
mkdir  -v -p -m 0755 -p /srv
git clone https://git.devtank.co.uk/Devtank/osm-ansible.git /srv/osm-lxc
rsync -a /srv/osm-lxc/root_overlay/ /
lxc-create -t debian -n base-os -- bookworm
