#!/bin/bash

name=$1

if [ -z "$name" ]
then
  echo "No name given"
  exit -1
fi

path=/srv/osm-lxc/lxc/containers/$name

if [ ! -e "$path" ]
then
  echo "Container given not found."
  exit -1
fi

echo "Stopping $name"

lxc-stop -n "$name"

lxc-start -n "$name" -l WARN -o "/srv/osm-lxc/lxc/logs/$name.log" -f "$path/lxc.container.conf" && \
	echo "Container $name started" || \
	echo "Error starting container $name"
