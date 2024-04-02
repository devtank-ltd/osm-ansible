#! /bin/bash

set -e

[ -n "$(which btrfs)" ] || { echo "Install btrfs-progs"; exit -1; }
[ -n "$(which kexec)" ] || { echo "Install kexec-tools"; exit -1; }

set -- $(df / -T | awk '/dev/ { print $1,$2 }')
root_dev=$1
root_fs=$2
srv_dev=$(df /srv -T | awk '/dev/ { print $1 }')

[ -z "$srv_dev" -o "$root_dev" == "$srv_dev" ] || { echo "/srv on own device"; exit -1; }

boot_dev=$(df /boot -T | awk '/dev/ { print $1 }')
efi_dev=$(df /boot/efi -T | awk '/dev/ { print $1 }')

[ "${root_fs#btrfs}" == "${root_fs}" ] || { echo "Already btrfs."; exit 0; }
[ "${root_fs#ext}" != "${root_fs}" ] || { echo "Unsupported rootfs to start with."; exit -1; }

mkdir -p base/etc

echo "Warning, going to make ${root_dev} btrfs"
echo "root_dev=$root_dev" > base/etc/disks
[ "$root_dev" == "$boot_dev" ] || echo "boot_dev=$boot_dev" >> base/etc/disks 
[ -z "$efi_dev" ] || echo "efi_dev=$efi_dev" >> base/etc/disks
./mk_initrc/make_ram_disk.sh make_btrfs
echo "If you are really sure you want to do this, now do: ./mk_initrc/kexec.sh make_btrfs.cpio.gz"
