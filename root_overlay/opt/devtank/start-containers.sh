#!/bin/bash

mkdir -p /srv/osm-lxc/lxc/logs

containers=(/srv/osm-lxc/lxc/containers/*)
for container in "${containers[@]}"; do
	name="$(basename "$container")"
	if [ ! -e "$container/lxc.container.conf" ]
	then
		continue
	fi
	lxc-ls | grep -q "$name" && continue
	lxc-start -n "$name" -l WARN -o "/srv/osm-lxc/lxc/logs/$name.log" -f "$container/lxc.container.conf" && \
		echo "Container $container started" || \
		echo "Error starting container $container"
done
