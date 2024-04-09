#! /bin/bash

[ $(id -u) == 0 ] || exec sudo -- "$0" "$@"

if [ -e /srv ]
then
  srv_fs=$(df /srv -T | awk '/dev/ { print $2 }')
  if [ srv_fs != 'btrfs' ]
  then
    echo "Require btrfs /srv"
    exit -1
  fi
else
  root_fs=$(df / -T | awk '/dev/ { print $2 }')
  if [ root_fs != 'btrfs' ]
  then
    echo "Require btrfs root or /srv"
    exit -1
  fi
  mkdir  -v -p -m 0755 -p /srv
fi

apt install btrfs-progs snapper nginx certbot ansible git rsync lxc

git clone https://git.devtank.co.uk/Devtank/osm-ansible.git /srv/osm-lxc
rsync -a /srv/osm-lxc/root_overlay/ /
lxc-create -t debian -n base-os -- bookworm
ssh-keygen -q  -t rsa -N '' -f /root/.ssh/id_rsa
mkdir -p /var/lib/lxc/base-os/rootfs/root/.ssh
cat /root/.ssh/id_rsa.pub >> /var/lib/lxc/base-os/rootfs/root/.ssh/authorized_keys
