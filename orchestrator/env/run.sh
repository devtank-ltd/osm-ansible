#! /bin/bash

. common.sh

./net_ctrl.sh open $VOSM_HOSTBR $HOSTS_DIR $OSM_SUBNET $OSM_DOMAIN
[ "$?" = "0" ] || { echo "Failed to setup bridge"; exit -1; }

echo "Running: $OSM_HOST"

qemu-system-x86_64                 \
   -enable-kvm                     \
   -nographic                      \
   -m 4G                           \
   -monitor unix:$HOST_DIR/monitor.sock,server,nowait \
   -serial unix:$HOST_DIR/console.sock,server,nowait \
   -device virtio-scsi-pci,id=scsi \
   -nic bridge,br="$VOSM_HOSTBR",model=virtio-net-pci,mac=$OSM_HOSTMAC \
   -drive file="$DEBDISK",format=qcow2,if=virtio \
   -drive "if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.fd,readonly=on" \
   -drive "if=pflash,format=raw,unit=1,file=$DEBBIOSMEM" \
   -cpu host
