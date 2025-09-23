[Match]
Name={{ item.name }}

[Network]
{% if item.dhcp %}
DHCP=yes
DNS={{ item.dns1 }}
DNS={{ item.dns2 }}

[DHCP]
ClientIdentifier=mac
SendHostname=yes
Hostname={{ ansible_hostname }}
UseDNS=no
{% else %}
Address={{ item.address }}
DNS={{ item.dns1 }}
DNS={{ item.dns2 }}
Domains=~incus
{% endif %}
