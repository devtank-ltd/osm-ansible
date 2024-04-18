test -r /dev/kvm || { echo "User doesn't have KVM access."; exit -1; }
test -r /etc/qemu/bridge.conf || { echo "User doesn't have netdev access."; exit -1; }

OVMF_VARS_ORIG="/usr/share/OVMF/OVMF_VARS_4M.fd"

[ -n "$VOSMHOSTBR" ] || VOSMHOSTBR=vosmhostbr0

HOSTS_DIR=hosts

[ -n "$OSMHOST" ] || OSMHOST=btrfsdeb
HOST_DIR=$HOSTS_DIR/$OSMHOST

mkdir -p $HOST_DIR

DEBDISK=$HOST_DIR/disk.qcow
DEBBIOSMEM=$HOST_DIR/ovmf_vars.fd

[ -n "$PRESEED" ] || PRESEED=preseed-btrfs.cfg

[ -n "$OSM_DOMAIN" ] || OSM_DOMAIN=osmm.fake.co.uk

echo "OSM HOST: $OSMHOST"
echo "OSM HOST DIR: $HOST_DIR"
echo "OSM DOMAIN: $OSM_DOMAIN"
