This is a test environment for the OSM backend.

It is a early implimentation.


On a Debian based system, the dependencies are installed with:

    sudo apt install bind9-dnsutils openssh-client libpython3-stdlib systemd-resolved qemu-system-x86 qemu-utils genisoimage ansible wget

The calling environment will need a SSH key setup, where the public and private keys existing ~/.ssh as per normal.



The most basic use is:

```
cp network.cfg.example network.cfg
./setup_network.sh network.cfg
```

It will take a long time to run through.

Once it is complete, on the machine you have run this on, you can look at the fake customers Grafana in your webbrowser.

For example:

https://customer0.osmm.fake.co.uk

The SSL certs are fake so you need to click through those warnings.

To shutdown the test environment, give the script shutdown_all.sh the folder of you environment.

For example:

```
./shutdown_network.sh hosts
```

To spin back up an existing environment you can do it by giving run_network.sh the folder of you environment.

```
./run_network.sh hosts
```

To spin up multiple environments:

Create a new network.cfg file e.g. networksequel.cfg

You will to need populate it with a different hosts folder, network bridge, sub network and domain.

```
touch networksequel.cfg
```
The contents of this could look something like:

HOSTS_DIR=hosts_sequel
OSM_HOST_COUNT=2
OSMCUSTOMER_COUNT=5
VOSM_HOSTBR="sequel_osm_br"
OSM_SUBNET="192.168.22"
OSM_DOMAIN="sequel_domain.fake.co.uk"


```
mkdir hosts_sequel
./setup_network.sh networksequel.cfg
```
