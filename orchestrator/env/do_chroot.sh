#! /bin/bash

[ $(id -u) == 0 ] || exec sudo -- "$0" "$@"

if [ -z "$(which kpartx)" ]
then
   echo "Press install kpartx"
   exit -1
fi

DEBDISK=disk.qcow

mkdir -p mnt

modprobe nbd max_part=8
qemu-nbd --connect=/dev/nbd0 "$DEBDISK"
kpartx -a /dev/nbd0
mount /dev/mapper/nbd0p3 -o subvol=@rootfs mnt # Root partition
mount /dev/mapper/nbd0p2 mnt/boot # Boot partition
mount /dev/mapper/nbd0p1 mnt/boot/efi # EFI partition
mount --bind /proc mnt/proc
mount --bind /sys mnt/sys
mount --bind /dev mnt/dev
mount --bind /dev/pts mnt/dev/pts
chroot mnt/
