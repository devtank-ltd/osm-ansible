#!/bin/bash

containers=(/srv/osm-lxc/lxc/containers/*)
for container in "${containers[@]}"; do
	lxc-ls | grep -q "$(basename $container)" && continue
	lxc-start -n "$(basename $container)" -f "$container/lxc.container.conf" && \
		echo "Container $container started" || \
		echo "Error starting container $container"
done


