#! /bin/bash

[ $(id -u) == 0 ] || exec sudo -- "$0" "$@"

umount mnt/boot/efi
umount mnt/boot
umount mnt/proc
umount mnt/sys
umount mnt/dev/pts
umount mnt/dev
umount mnt
kpartx -d /dev/nbd0
qemu-nbd --disconnect /dev/nbd0

