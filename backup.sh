#!/bin/sh

[ -d backups ] || mkdir backups
sudo tar -Ipigz --exclude=backups --exclude image/image.tar.gz -cf "backups/$(date +%Y-%m-%d-%H-%M-%S).tar.gz" debian-rootfs
