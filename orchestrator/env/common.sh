
OVMF_VARS_ORIG="/usr/share/OVMF/OVMF_VARS_4M.fd"

HOSTS_DIR=hosts

[ -n "$OSMHOST" ] || OSMHOST=osmhostv
HOST_DIR=$HOSTS_DIR/$OSMHOST

mkdir -p $HOST_DIR

DEBDISK=$HOST_DIR/disk.qcow
DEBBIOSMEM=$HOST_DIR/ovmf_vars.fd

[ -n "$PRESEED" ] || PRESEED=preseed.cfg
