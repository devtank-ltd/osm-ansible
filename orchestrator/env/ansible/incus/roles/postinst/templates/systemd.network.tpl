[Match]
Name={{ item.name }}

[Network]
{% if item.dhcp %}
DHCP=yes

[DHCP]
ClientIdentifier=mac
SendHostname=yes
Hostname={{ ansible_hostname }}
{% else %}
Address={{ item.address }}
DNS={{ item.dns1 }}
DNS={{ item.dns2 }}
{% endif %}
