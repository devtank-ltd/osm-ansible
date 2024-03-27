#! /bin/bash

[ $(id -u) == 0 ] || exec sudo -- "$0" "$@"

if [ -z "$(which qemu-system-x86_64)" ]
then
   echo "Press install qemu-system-x86"
   exit -1
fi

if [ -e "/usr/share/OVMF/OVMF_CODE_4M.fd" ]
then
   echo "Press install ovmf"
   exit -1
fi

DEBISO=debian-12.5.0-amd64-netinst.iso
DEBDISK=disk.qcow

mkdir -p mnt
mount $DEBISO mnt
mkdir -p boot
cp -r mnt/install.amd boot/
umount mnt

qemu-img create -f qcow2 "$DEBDISK" 16G

chmod 666 "$DEBDISK"

IP_ADDR=$(ip route | awk '{print $9}' | head -n 1)

python -m http.server -b $IP_ADDR&
websvr=$!

nc -u -l 10514 > log&
logsvr=$!

qemu-system-x86_64                 \
   -enable-kvm                     \
   -nographic                      \
   -serial mon:stdio               \
   -m 4G                           \
   -device virtio-scsi-pci,id=scsi \
   -device virtio-serial-pci       \
   -nic user,model=virtio-net-pci \
   -drive file="$DEBISO",format=raw,if=virtio,media=cdrom \
   -drive file="$DEBDISK",format=qcow2,if=virtio \
   -drive "if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.fd,readonly=on" \
   -kernel boot/install.amd/vmlinuz \
   -initrd boot/install.amd/initrd.gz \
   -append "console=ttyS0 priority=critical auto=true DEBIAN_FRONTEND=text log_host=$IP_ADDR log_port=10514 url=http://$IP_ADDR:8000/preseed.cfg"

kill $websvr $logsvr
