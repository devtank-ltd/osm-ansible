[Match]
Name=wg0

[Network]
Address={{ wg_ip }}/{{ wireguard.mask }}
{% if inventory_hostname == "vosmhost0" %}
# IPMasquerade=both
{% endif %}
