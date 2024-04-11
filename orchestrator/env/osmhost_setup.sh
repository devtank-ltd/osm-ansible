#! /bin/bash

[ $(id -u) == 0 ] || exec sudo -- "$0" "$@"

if [ -e /srv ]
then
  srv_fs=$(df /srv -T | awk '/dev/ { print $2 }')
  if [ "$srv_fs" != 'btrfs' ]
  then
    echo "Requires btrfs /srv"
    exit -1
  fi
else
  root_fs=$(df / -T | awk '/dev/ { print $2 }')
  if [ "$root_fs" != 'btrfs' ]
  then
    echo "Requires btrfs root or /srv"
    exit -1
  fi
  mkdir  -v -p -m 0755 -p /srv
fi

apt install btrfs-progs snapper nginx certbot ansible git rsync lxc ufw

# NOTE (TODO) : branch dev_test_env is just for development.
git clone https://git.devtank.co.uk/Devtank/osm-ansible.git -b dev_test_env /srv/osm-lxc
rsync -a /srv/osm-lxc/root_overlay/ /
lxc-create -t debian -n base-os -- bookworm
ssh-keygen -q  -t rsa -N '' -f /root/.ssh/id_rsa
mkdir -p /var/lib/lxc/base-os/rootfs/root/.ssh
cat /root/.ssh/id_rsa.pub >> /var/lib/lxc/base-os/rootfs/root/.ssh/authorized_keys


echo '
LXC_BRIDGE="lxcbr0"
LXC_ADDR="10.0.3.1"
LXC_NETMASK="255.255.255.0"
LXC_NETWORK="10.0.3.0/24"
LXC_DHCP_RANGE="10.0.3.2,10.0.3.254"
LXC_DHCP_MAX="253"
LXC_DHCP_CONFILE=/etc/lxc/dnsmasq.conf
LXC_DOMAIN="lxc"' >> /etc/default/lxc-net

mac_addr=$(awk -F ' = ' '/lxc.net.0.hwaddr/ {print $2}' /var/lib/lxc/base-os/config)

echo "dhcp-host=$mac_addr,10.0.3.2" > /etc/lxc/dnsmasq.conf

systemctl restart lxc-net
lxc-start base-os

# Required for Ansible
lxc-attach -n base-os -- apt install -y python3 wget

ssh-keyscan -H 10.0.3.2 > /root/.ssh/known_hosts

echo 10.0.3.2 > /tmp/hosts

cd /srv/osm-lxc/ansible/
ansible-playbook -e "target=10.0.3.2" -i /tmp/hosts setup-base-os.yaml

lxc-stop base-os

mkdir -p /srv/osm-lxc/lxc/os-bases

mv /var/lib/lxc/base-os/rootfs /srv/osm-lxc/lxc/os-bases/001-bookworm-$(date "+%d-%m-%Y")
rm -rf /var/lib/lxc/base-os/config
