# OSM Host
Each OSM host is a member of [Incus cluster](https://linuxcontainers.org/incus/docs/main/explanation/clustering/) containing customer instances (containers)

##
### Introduction

Incus is a system container manager which provides a user experience similar to that of a public cloud.
It is image based and provides flexibility and scalability for various use cases, with support for different storage backends and network types.

A *customer* container is a BTRFS subvolume, descendant of the toplevel base image.
This reduces resource use and means backups are purely *customer* data and configuration, not a whole OS.

```bash
# incus image ls -c fd
+--------------+--------------------------------------+
| FINGERPRINT  |             DESCRIPTION              |
+--------------+--------------------------------------+
| 22dfc1dfdb1a | debian bookworm amd64 (202507281337) |
+--------------+--------------------------------------+

# btrfs sub show /srv/osm-lxc/incus/images/22dfc1dfdb1af8b4ae131e32a7e4145c759eb9e2762684c37b58e0551e0e5fc4/ | sed -rn '3p'
        UUID:                   6e99d69a-befd-5c4a-9f1f-29a97b2ec209

# btrfs sub show /srv/osm-lxc/incus/containers/customer/ | sed -rn '/Parent UUID:/p'
        Parent UUID:            6e99d69a-befd-5c4a-9f1f-29a97b2ec209
```


All commands in this tutorial are assumed to be run as root.

To view the running containers and its brief information, run the following command:
```bash
# incus ls
+------+---------+-------------------+------+-----------+-----------+-----------+
| NAME |  STATE  |       IPV4        | IPV6 |   TYPE    | SNAPSHOTS | LOCATION  |
+------+---------+-------------------+------+-----------+-----------+-----------+
| foo  | RUNNING | 10.0.5.230 (eth0) |      | CONTAINER | 0         | vosmhost2 |
+------+---------+-------------------+------+-----------+-----------+-----------+
| bar  | RUNNING | 10.0.5.20 (eth0)  |      | CONTAINER | 1         | vosmhost0 |
+------+---------+-------------------+------+-----------+-----------+-----------+
```

### Networking

All containers are running in the same private bridged network managed by incus.
Internet access from containers is achieved via NAT.

```bash
# incus network ls devtank
+---------+--------+---------+-------------+------+-------------------------+---------+---------+
|  NAME   |  TYPE  | MANAGED |    IPV4     | IPV6 |       DESCRIPTION       | USED BY |  STATE  |
+---------+--------+---------+-------------+------+-------------------------+---------+---------+
| devtank | bridge | YES     | 10.0.5.1/24 | none | Devtank bridged network | 3       | CREATED |
+---------+--------+---------+-------------+------+-------------------------+---------+---------+
# incus network show devtank
config:
  ipv4.address: 10.0.5.1/24
  ipv4.firewall: "true"
  ipv4.nat: "true"
  ipv6.address: none
description: Devtank bridged network
name: devtank
type: bridge
used_by:
- /1.0/instances/foo
- /1.0/instances/bar
- /1.0/profiles/default
managed: true
status: Created
locations:
- vosmhost1
- vosmhost0
- vosmhost2
project: default
```
For more information refer to [incus networking](https://linuxcontainers.org/incus/docs/main/explanation/networks/) documentation.

NGINX uses these internal addresses to pass traffic to the containers.
UFW is used on the host for the firewall. Ports must be opened with UFW when defining a new MQTT endpoint etc.

### Storage
Incus stores data (base images, containers, snapshots, etc ) in storage pools.
Run `incus storage ls` and `incus storage info <name>` commands to get storage information.
```bash
# incus storage ls
+---------+--------+----------------------+---------+---------+
|  NAME   | DRIVER |     DESCRIPTION      | USED BY |  STATE  |
+---------+--------+----------------------+---------+---------+
| devtank | btrfs  | Devtank storage pool | 12      | CREATED |
+---------+--------+----------------------+---------+---------+
# incus storage info devtank
info:
  description: Devtank storage pool
  driver: btrfs
  name: devtank
  space used: 19.44GiB
  total space: 31.05GiB
used by:
  images:
  - 22dfc1dfdb1af8b4ae131e32a7e4145c759eb9e2762684c37b58e0551e0e5fc4 (location "vosmhost0")
  - 22dfc1dfdb1af8b4ae131e32a7e4145c759eb9e2762684c37b58e0551e0e5fc4 (location "vosmhost1")
  - 22dfc1dfdb1af8b4ae131e32a7e4145c759eb9e2762684c37b58e0551e0e5fc4 (location "vosmhost2")
  instances:
  - foo
  - bar
  profiles:
  - default
  volumes:
  - 0e68db47b667391c9b7bfab1652496fedece01c6af79dbfd76459e0f49138b94 (location "vosmhost1")
  - 0e68db47b667391c9b7bfab1652496fedece01c6af79dbfd76459e0f49138b94 (location "vosmhost2")
  - bfc060a407260cd9044ffe9cc682b56a6e157eb98ce55c50c0fd1324b15de8c2 (location "vosmhost1")
  - bfc060a407260cd9044ffe9cc682b56a6e157eb98ce55c50c0fd1324b15de8c2 (location "vosmhost2")
  - ce47e5453881a0c0ae90dc298210656a68caf7dc75e6aa55674a6449b6a0ef46 (location "vosmhost0")
  - ce47e5453881a0c0ae90dc298210656a68caf7dc75e6aa55674a6449b6a0ef46 (location "vosmhost2")
```

The `/srv/osm-lxc/incus/containers/<name>/rootfs` directory contains container root filesystem. The `images` and `containers-snapshots` directories contain base images and container snapshots accordingly.

```bash
# find /srv/osm-lxc/incus/ -maxdepth 1
/srv/osm-lxc/incus/
/srv/osm-lxc/incus/buckets
/srv/osm-lxc/incus/custom
/srv/osm-lxc/incus/custom-snapshots
/srv/osm-lxc/incus/images
/srv/osm-lxc/incus/containers
/srv/osm-lxc/incus/containers-snapshots
/srv/osm-lxc/incus/virtual-machines
/srv/osm-lxc/incus/virtual-machines-snapshots
```

The images names are SHA256 hash which can be found by executing the `incus image ls -cFd` command.
```bash
# incus image ls -cFd
+------------------------------------------------------------------+--------------------------------------+
|                           FINGERPRINT                            |             DESCRIPTION              |
+------------------------------------------------------------------+--------------------------------------+
| 22dfc1dfdb1af8b4ae131e32a7e4145c759eb9e2762684c37b58e0551e0e5fc4 | debian bookworm amd64 (202507281337) |
+------------------------------------------------------------------+--------------------------------------+
# cd images/
# find -maxdepth 1
.
./22dfc1dfdb1af8b4ae131e32a7e4145c759eb9e2762684c37b58e0551e0e5fc4
```
For more information refer to [incus storage](https://linuxcontainers.org/incus/docs/main/explanation/storage/)  and [incus images](https://linuxcontainers.org/incus/docs/main/image-handling/) documentation.

### Snapshots
BTRFS snapshot is a subvolume that shares its data and metadata with another subvolume using BTRFS [copy-on-write](https://en.wikipedia.org/wiki/Copy-on-write) capabilities.

To create a snapshot use the following command `incus snapshot create <container name> <snapshot name>`
```bash
# incus ls foo
+------+---------+------------------+------+-----------+-----------+-----------+
| NAME |  STATE  |       IPV4       | IPV6 |   TYPE    | SNAPSHOTS | LOCATION  |
+------+---------+------------------+------+-----------+-----------+-----------+
| foo  | RUNNING | 10.0.5.62 (eth0) |      | CONTAINER | 0         | vosmhost1 |
+------+---------+------------------+------+-----------+-----------+-----------+
# incus snapshot create foo foo-snapshot
# incus ls foo
+------+---------+------------------+------+-----------+-----------+-----------+
| NAME |  STATE  |       IPV4       | IPV6 |   TYPE    | SNAPSHOTS | LOCATION  |
+------+---------+------------------+------+-----------+-----------+-----------+
| foo  | RUNNING | 10.0.5.62 (eth0) |      | CONTAINER | 1         | vosmhost1 |
+------+---------+------------------+------+-----------+-----------+-----------+
# btrfs sub show /srv/osm-lxc/incus/containers/foo | sed -rn '/UUID:/p'
        UUID:                   df733823-4f48-2741-a730-0625d8ac98c7
# btrfs sub show /srv/osm-lxc/incus/containers-snapshots/foo/foo-snapshot | sed -rn '/Parent UUID/p'
        Parent UUID:            df733823-4f48-2741-a730-0625d8ac98c7
```

To get a list of shapshots for a container, use the `incus info <container name>` command:
```bash
# incus info foo | sed -rn '/Snapshots/,$ p'
Snapshots:
+--------------+----------------------+------------+----------+
|     NAME     |       TAKEN AT       | EXPIRES AT | STATEFUL |
+--------------+----------------------+------------+----------+
| foo-snapshot | 2025/07/29 13:00 BST |            | NO       |
+--------------+----------------------+------------+----------+
```
To delete a snapshot, use the `incus snapshot delete <container name> <snapshot name>` command:
```bash
# incus snapshot delete foo foo-snapshot
# incus info foo | sed -rn '/Snapshots/,$ p'
#
# find /srv/osm-lxc/incus/containers-snapshots/
/srv/osm-lxc/incus/containers-snapshots/
```

Refer to the [incus snapshots](https://linuxcontainers.org/incus/docs/main/howto/instances_backup/#instances-snapshots) documentation for more information

### Customer container
To create and delete customer container `/srv/osm-lxc/orchestrator/orchechestrator_cli.py` python script must be used.

For more commands use `/srv/osm-lxc/orchestrator/orchestrator_cli.py` command without arguments
```bash
# /srv/osm-lxc/orchestrator/orchestrator_cli.py
No command given, commands are:
        add_host <name> <ip_addr> <capacity> : Add host to OSM system
        del_host <name> : Remove host from OSM system
        find_host <name> : Find host of given customer in OSM system
        test_host <name> : Test access to OSM Host
        add_customer <name> : Add customer to OSM system
        del_customer <name> : Remove customer from OSM system
        add_alerts_contact <custome name> <email>: Add customer contact for alerts
        list_alerts_contacts: Print existing customer contacts
        clone_container <name> [<target>] [<public>]: Create container <name> copy <name>-clone on [<target>] OSM host. If [public] is set to '[<yes|y>]', the nginx configuration is generated
        mv_customer <customer name> <host name>: Move customer to OSM host
        upgrade_customers <host name>: Upgrade existing customers on the OSM host
        list_hosts : Lists OSM Hosts in system
        list_host_customers <name> : Lists customers on OSM Host
        list_customers : Lists all customers on all OSM Hosts
        get_customer_passwords <name>: Return dictionary of passwords for a specified customer
        get_wg_info <name> : Get WireGuard key and IP address
        push_file_or_directory <customer> <source> <destination>: Push a file or a directory to a specified destination on a customer container
        pull_file_or_directory <customer> <source> <destination>: Pull a file or a directory to a specified destination from a customer container
        add_dashboards <customer_name> <config> <cert>: Creates Grafana dashboard solution for customer with optional cert
        del_dashboards <customer_name> <config> <cert>: Deletes Grafana dashboard solution for customer with optional cert
        mqtt_listener <customer_name>: Get MQTT listener cmd Returns bash line of mosquitto_sub to listen to customer
        example_imported_cmd <arg> : call example function with argument
```

#### Create container
To create customer container, run the `/srv/osm-lxc/orchestrator/orchestrator_cli.py add_customer <name>` command:
```bash
# /srv/osm-lxc/orchestrator/orchestrator_cli.py add_customer foo
No config file found; using defaults

PLAY [Create devtank customer]
...
foo                        : ok=100  changed=44   unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
localhost                  : ok=44   changed=23   unreachable=0    failed=0    skipped=5    rescued=0    ignored=0

Command: add_customer : Result: SUCCESS
# incus ls foo
+------+---------+-------------------+------+-----------+-----------+-----------+
| NAME |  STATE  |       IPV4        | IPV6 |   TYPE    | SNAPSHOTS | LOCATION  |
+------+---------+-------------------+------+-----------+-----------+-----------+
| foo  | RUNNING | 10.0.5.166 (eth0) |      | CONTAINER | 0         | vosmhost1 |
+------+---------+-------------------+------+-----------+-----------+-----------+
```
It creates incus container and configures Devtank services.

#### Remove container
To delete customer container, run the `/srv/osm-lxc/orchestrator/orchestrator_cli.py del_customer <name>` command:
```bash
# /srv/osm-lxc/orchestrator/orchestrator_cli.py del_customer foo
...
Command: del_customer : Result: SUCCESS
# incus ls foo
+------+-------+------+------+------+-----------+----------+
| NAME | STATE | IPV4 | IPV6 | TYPE | SNAPSHOTS | LOCATION |
+------+-------+------+------+------+-----------+----------+
```

## NGINX

### Configuration

In root_overlay there is a template of `/etc/nginx/nginx.conf` where OSM_HOST_NAME is replaced with the hostname used under the DNS system.
Copy all of `root_overlay/etc/nginx` over the hosting machines `/etc/nginx` and replace the OSM_HOST_NAME in `/etc/nginx/nginx.conf`, but leave the TEMPLATE named files as they are as they as used by the Ansible scripts.

## Backups

Server backups are hosted on an "osmbackup" container in the Devtank office.
Every night, a cron job defined in `/etc/cron.d/osm-backup` on the OSM server runs an rsync backup (which will be replaced by `btrfs send` and `btrfs receive`) to `/srv/backups/lxc/` on the backup server and logs the job to `/var/log/osm-backup`.
