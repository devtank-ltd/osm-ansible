#!/bin/bash

cleanup(){

	[ -n "$md_gen" ] && rm "image/$md_gen"

}

set -e
trap cleanup EXIT
shopt -s extglob


md_gen="$(uuidgen)"
sed "s/TIMESTAMP/$(date +%s)/g" image/metadata.yaml > image/$md_gen

echo 'Tarballing rootfs...'
sudo tar -c \
	--transform 's/debian-rootfs/rootfs/g' \
	--transform "s/image\/$md_gen/metadata.yaml/g" \
	debian-rootfs \
	image/$md_gen | \
	pv -s $(sudo du -sb debian-rootfs | awk '{print $1}') | \
	gzip > image/image.tar.gz

echo 'Importing image into LXC...'
sudo lxc image import -v \
	image/image.tar.gz \
	--alias osm

read -p 'Launch container? (y/n) ' launch_input
[[ "${launch_input,,}" == y?(es) ]] || exit

temp_container="C$(uuidgen)"
lxc launch osm "$temp_container"
lxc config set "$temp_container" security.nesting true
lxc exec "$temp_container" '/bin/bash'

read -p 'Delete container? (y/n) ' del_input
[[ "${del_input,,}" == y?(es) ]] || exit
lxc delete --force "$temp_container"
