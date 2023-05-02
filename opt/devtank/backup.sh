#!/bin/bash

echo "Backup started $(date)"

while IFS=',' read -r name path; do

	latest_snap="$(snapper --machine-readable=csv -c "${name}" list | \
		tail -n1 | \
		awk -F, '{ print $3 }'
	)"
	echo "Backing up ${name}"
	rsync --delete -a "${path}/.snapshots/${latest_snap}/snapshot/" "osmbackup:/srv/backups/lxc/$(basename ${path})/" || \
		echo "Error backing up ${name}"

done < <(snapper --machine-readable=csv list-configs | tail -n+2)

echo "Backup finished $(date)"
