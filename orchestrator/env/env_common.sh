test -r /dev/kvm || { echo "User doesn't have KVM access."; exit -1; }
[ -n "$(groups | grep netdev)" ] || { echo "User doesn't have netdev access."; exit -1; }
[ -n "$(which resolvectl)" ] || { echo "Please install systemd-resolved"; exit -1; }
[ -n "$(which qemu-system-x86_64)" ] || { echo "Please install qemu-system-x86"; exit -1; }
[ -n "$(which dig)" ] || { echo "Please install dig (bind9-dnsutils)"; exit -1; }
[ -n "$(which isoinfo)" ] || { echo "Please install genisoimage"; exit -1; }
[ -n "$(which ssh-keygen)" ] || { echo "Please install OpenSSH client tools."; exit -1; }
[ -e "/usr/sbin/dnsmasq" ] || { echo "Please install dnsmasq"; exit -1; }
[ -e "/usr/sbin/iptables" ] || { echo "Please install iptables"; exit -1; }

[ -n "$HOSTS_DIR" ] || HOSTS_DIR=hosts
echo "HOSTS_DIR: $HOSTS_DIR"
export HOSTS_DIR
mkdir -p "$HOSTS_DIR"

[ ! -e  "$HOSTS_DIR/env" ] || source "$HOSTS_DIR/env"

save_env () {
  echo 'VOSM_HOSTBR="'$VOSM_HOSTBR'"
HOSTS_DIR="'$HOSTS_DIR'"
OSM_SUBNET="'$OSM_SUBNET'"
OSM_DOMAIN="'$OSM_DOMAIN'"' > "$HOSTS_DIR/env"
}

[ -n "$VOSM_HOSTBR" ] || VOSM_HOSTBR=vosmhostbr0
export VOSM_HOSTBR

if [ -e /sys/class/net/$VOSM_HOSTBR ]
then
  osm_bridge_ip=$(ip addr show $VOSM_HOSTBR | awk -F '[[:blank:]/]+' '/inet / { print $3}')
  osm_bridge_range=$(echo $osm_bridge_ip | awk -F'.' '{print $1"."$2"."$3}')
else
  osm_bridge_range=192.168.5
fi

[ -n "$OSM_SUBNET" ] || OSM_SUBNET=$osm_bridge_range
export OSM_SUBNET

[ -n "$OSM_DOMAIN" ] || OSM_DOMAIN=osmm.fake.co.uk
export OSM_DOMAIN

export ANSIBLE_HOSTS="$HOSTS_DIR/hosts"

echo "OSM DOMAIN: $OSM_DOMAIN"
echo "OSM SUBNET: $OSM_SUBNET"
