. env_common.sh

OVMF_VARS_ORIG="/usr/share/OVMF/OVMF_VARS_4M.fd"

[ -n "$OSM_HOST" ] || OSM_HOST=vosmhost0

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

echo "OSM HOST: $OSM_HOST"
echo "OSM HOST DIR: $HOST_DIR"
echo "OSM HOST MAC: $OSM_HOSTMAC"
