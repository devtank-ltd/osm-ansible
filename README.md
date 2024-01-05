---
  <style>
    body {
      font-family: sans-serif;
    }
  </style>
---
# Devtank Open Smart Monitor Hosting

## Overview

A OpenSmartMonitor (OSM) device sends data to a OSM customers container. The data is sent over MQTT over SSL encryption.

Different OSM customers containers are running on different servers. We call these servers OSM Hosts.
The domains of the address of the OSM customers is handled by a Devtank DNS server.
This will return the right server for the customer.

Each customer container may multiple domains to access different services.
Generally, these are:

- customer.opensmartmonitor.devtank.co.uk
- customer-influx.opensmartmonitor.devtank.co.uk
- customer-chirpstack.opensmartmonitor.devtank.co.uk

Where *customer* is the chosen customer name.
These domains correspond to the Grafana, InfluxDB2 and Chirpstack web interfaces respectively.
The convention is to use a dash where a space would naturally be.

So first there is a DNS lookup for which OSM Host the *customer* container is on:
<br><img src="dns.png" width="200"/>

Then that OSM Host machine for that *customer* is connected to and the connection is sent on to the *customer* container.
<br><img src="osm-architecture.png" width="750"/>


## Using Orchestrator

The Orchestrator talks to the databases which tracks which OSM Host is used for which customer. These keeps the DNS updated and ensures OSM customers are spread across OSM Hosts according to the OSM Hosts capacity.

### Using Orchestrator

The orchestrator is used in the shell and used from within its folder.
You will need a "config.yaml" file setup for the MySQL of the PDNS and Orchestrator databases.
It is the format:

    {
        "orchestrator":
        {
            "user": "some_user",
            "password": "some_password",
            "host": "some_host",
            "database": "some_db"
        },
        "pdns":
        {
            "user": "some_user",
            "password": "some_password.",
            "host": "some_host",
            "database": "some_db"
        },
        "pdns_domain" : "osmm.some-domain.co.uk",
        "pdns_domain_id" : 1
    }

Once you have the config file in the orchestrator folder, you can see the comands with:

```sh
cd orchestrator
./orchestrator_cli.py
```

### Adding a customer with orchestrator

The orchestrator will deal with finding a OSM host with spare space, calling Ansible and updating the PDNS database.

```sh
cd orchestrator
./orchestrator_cli.py add_customer somecustomer
```

### Removing a customer with orchestrator

The orchestrator will deal with finding which OSM host the customer is on, and calling Ansible and updating the PDNS database.
```sh
cd orchestrator
./orchestrator_cli.py del_customer somecustomer
```

