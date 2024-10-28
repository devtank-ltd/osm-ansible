#!/usr/bin/env bash

set -e

readonly PROGS=(
    btrfs
    kexec
    busybox
    fsck.vfat
)

for p in "${PROGS[@]}"; do
    if ! command -v "$p" >/dev/null 2>&1; then
        echo "Install '$p'"
        exit 1
    fi
done

set -- "$(df --output=source,fstype / | sed '/^F/d')"
root_dev="$1"
root_fs="$2"
srv_dev="$(df --output=source /srv | sed '/^F/d')"

if [[ -z "$srv_dev" || "$root_dev" == "$srv_dev" ]]; then
    echo "/srv on own device"
    exit 1
fi

boot_dev="$(df --output=source /boot | sed '/^F/d')"
efi_dev="$(df --output=source /boot/efi | sed '/^F/d')"

[[ "${root_fs#btrfs}" == "${root_fs}" ]] || {
    echo "Already btrfs."
    exit 0
}
[[ "${root_fs#ext}" != "${root_fs}" ]] || {
    echo "Unsupported rootfs to start with."
    exit 1
}

mkdir -p base/etc

echo "Warning, going to make ${root_dev} btrfs"
echo "root_dev=${root_dev}" > base/etc/disks
[[ "$root_dev" == "$boot_dev" ]] || echo "boot_dev=$boot_dev" >> base/etc/disks
[[ -z "$efi_dev" ]] || echo "efi_dev=$efi_dev" >> base/etc/disks
./mk_initrc/make_ram_disk.sh make_btrfs
echo "If you are really sure you want to do this, now do: ./mk_initrc/kexec.sh make_btrfs.cpio.gz"
