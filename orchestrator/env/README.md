This is a test environment for the OSM backend.

It is a early implimentation.

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
./shutdown_all.sh hosts
```

To spin back up an existing environment you can do it by giving run_network.sh the folder of you environment.

```
./run_network.sh hosts
```
