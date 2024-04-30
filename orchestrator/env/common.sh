test -r /dev/kvm || { echo "User doesn't have KVM access."; exit -1; }
[ -n "$(groups | grep netdev)" ] || { echo "User doesn't have netdev access."; exit -1; }

OVMF_VARS_ORIG="/usr/share/OVMF/OVMF_VARS_4M.fd"

[ -n "$VOSMHOSTBR" ] || VOSMHOSTBR=vosmhostbr0

[ -n "$HOSTS_DIR" ] || HOSTS_DIR=hosts

[ -n "$OSMHOST" ] || OSMHOST=vosmhost0
HOST_DIR=$HOSTS_DIR/$OSMHOST

mkdir -p $HOST_DIR

DEBDISK=$HOST_DIR/disk.qcow
DEBBIOSMEM=$HOST_DIR/ovmf_vars.fd

if [ -f "$HOST_DIR/mac" ]
then
  OSMHOSTMAC=$(cat $HOST_DIR/mac)
else
  while
    OSMHOSTMAC=$(printf '52:54:00:%02x:%02x:%02x' $[RANDOM%256] $[RANDOM%256] $[RANDOM%256])
    grep "$OSMHOSTMAC" $HOSTS_DIR/*/mac 2>/dev/null # Hide errors
    [ "$?" == "0" ]
  do true; done
  echo "$OSMHOSTMAC" > "$HOST_DIR/mac"
fi

[ -n "$PRESEED" ] || PRESEED=preseed-btrfs.cfg

[ -n "$OSM_DOMAIN" ] || OSM_DOMAIN=osmm.fake.co.uk

[ -n "$ANSIBLE_HOSTS" ] || ANSIBLE_HOSTS=/tmp/$USER.hosts

echo "OSM HOST: $OSMHOST"
echo "OSM HOST DIR: $HOST_DIR"
echo "OSM HOST MAC: $OSMHOSTMAC"
echo "OSM DOMAIN: $OSM_DOMAIN"
