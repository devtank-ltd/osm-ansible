[Match]
Name=wg0

[Network]
Address={{ '.'.join(wireguard.ipaddr.split(".")[:3]) + '.' + ansible_default_ipv4.address.split(".")[-1] }}/{{ wireguard.mask }}
