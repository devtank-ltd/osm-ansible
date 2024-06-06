test -r /dev/kvm || { echo "User doesn't have KVM access."; exit -1; }
[ -n "$(groups | grep netdev)" ] || { echo "User doesn't have netdev access."; exit -1; }

OVMF_VARS_ORIG="/usr/share/OVMF/OVMF_VARS_4M.fd"

[ -n "$VOSM_HOSTBR" ] || VOSM_HOSTBR=vosmhostbr0

[ -n "$HOSTS_DIR" ] || HOSTS_DIR=hosts

[ -n "$OSM_HOST" ] || OSM_HOST=vosmhost0

if [ -e /sys/class/net/$VOSM_HOSTBR ]
then
  osm_bridge_ip=$(ip addr show $VOSM_HOSTBR | awk -F '[[:blank:]/]+' '/inet / { print $3}')
  osm_bridge_range=$(echo $osm_bridge_ip | awk -F'.' '{print $1"."$2"."$3}')
else
  osm_bridge_range=192.168.5
fi

[ -n "$OSM_SUBNET" ] || OSM_SUBNET=$osm_bridge_range

HOST_DIR=$HOSTS_DIR/$OSM_HOST

mkdir -p $HOST_DIR

DEBDISK=$HOST_DIR/disk.qcow
DEBBIOSMEM=$HOST_DIR/ovmf_vars.fd

if [ -f "$HOST_DIR/mac" ]
then
  OSM_HOSTMAC=$(cat $HOST_DIR/mac)
else
  while
    OSM_HOSTMAC=$(printf '52:54:00:%02x:%02x:%02x' $[RANDOM%256] $[RANDOM%256] $[RANDOM%256])
    grep "$OSM_HOSTMAC" $HOSTS_DIR/*/mac 2>/dev/null # Hide errors
    [ "$?" == "0" ]
  do true; done
  echo "$OSM_HOSTMAC" > "$HOST_DIR/mac"
fi

[ -n "$PRESEED" ] || PRESEED=preseed-btrfs.cfg

[ -n "$OSM_DOMAIN" ] || OSM_DOMAIN=osmm.fake.co.uk

[ -n "$ANSIBLE_HOSTS" ] || ANSIBLE_HOSTS=/tmp/$USER.hosts

echo "OSM HOST: $OSM_HOST"
echo "OSM HOST DIR: $HOST_DIR"
echo "OSM HOST MAC: $OSM_HOSTMAC"
echo "OSM DOMAIN: $OSM_DOMAIN"
echo "OSM SUBNET: $OSM_SUBNET"
