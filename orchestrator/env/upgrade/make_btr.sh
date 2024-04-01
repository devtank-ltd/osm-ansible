#! /bin/bash

set -- $(df /srv -T | awk '/dev/ { print $1,$2 }')
srv_dev=$1
srv_fs=$2
root_dev=$(df / -T | awk '/dev/ { print $1,$2 }')
boot_dev=$(df /boot -T | awk '/dev/ { print $1,$2 }')
efi_dev=$(df /boot/efi -T | awk '/dev/ { print $1,$2 }')

[ "${root_fs#btrfs}" == "${root_fs}" ] || (echo "Already btrfs." && exit 0)
[ "${srv_fs#ext}" != "${srv_fs}" ] || (echo "Unsupported rootfs to start with." && exit -1)
[ "$root_dev" == "$srv_dev" ] || (echo "/srv on own device" && exit -1)

echo "Warning, going to make ${root_dev} btrfs"
echo "root_dev=$root_dev" > base/etc/disks
[ "$root_dev" == "$boot_dev" ] || echo "boot_dev=$boot_dev" >> base/etc/disks 
[ -z "$efi_dev" ] || echo "efi_dev=$efi_dev" >> base/etc/disks
./mk_initrc/make_ram_disk.sh make_btrfs
