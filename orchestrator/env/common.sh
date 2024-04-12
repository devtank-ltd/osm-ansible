
OVMF_VARS_ORIG="/usr/share/OVMF/OVMF_VARS_4M.fd"

HOSTS_DIR=hosts

if [ -z "$OSMHOST" ]; then OSMHOST=osmhostv; fi
HOST_DIR=$HOSTS_DIR/$OSMHOST

mkdir -p $HOST_DIR

if [ -z "$DEBDISK" ]; then DEBDISK=$HOST_DIR/disk.qcow; fi
if [ -z "$DEBBIOSMEM" ]; then DEBBIOSMEM=$HOST_DIR/ovmf_vars.fd; fi

if [ -z "$PRESEED" ]; then PRESEED=preseed.cfg; fi
