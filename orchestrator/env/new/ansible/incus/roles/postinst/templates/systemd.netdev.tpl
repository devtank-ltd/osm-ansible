[NeteDev]
Name=wg0
Kind=wireguard
Description=WireGuard tunnel wg0

[WireGuard]
{% if inventory_hostname == "vosmhost0" %}
ListenPort={{ wireguard.port }}
{% endif %}
PrivateKey={{ wireguard_priv_key.stdout }}

{% if inventory_hostname == "vosmhost0" %}

{% for peer in groups['all'] %}

[WireGuardPeer]
PublicKey={{ hostvars[peer].wireguard_pub_key.stdout }}
AllowedIPs={{ '.'.join(wireguard.ipaddr.split(".")[-3]) + ".0" }}/32
{% if peer == inventory_hostname %}
Endpoint={{ wireguard.ipaddr }}:{{ wireguard.port}}
{% endif %}
PersistentKeepalive=25
{% endfor %}
{% endif %}
