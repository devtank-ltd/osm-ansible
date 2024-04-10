#! /bin/bash

./net_ctrl.sh open

if [ -z "$DEBDISK" ]; then DEBDISK=disk.qcow; fi
DEBBIOSMEM=ovmf_vars.fd

qemu-system-x86_64                 \
   -enable-kvm                     \
   -nographic                      \
   -serial mon:stdio               \
   -m 4G                           \
   -device virtio-scsi-pci,id=scsi \
   -device virtio-serial-pci       \
   -nic bridge,br=vosmhostnet,model=virtio-net-pci \
   -drive file="$DEBDISK",format=qcow2,if=virtio \
   -drive "if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.fd,readonly=on" \
   -drive "if=pflash,format=raw,unit=1,file=$DEBBIOSMEM"

