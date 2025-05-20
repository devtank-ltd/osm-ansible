[NetDev]
Name=wg0
Kind=wireguard
Description=WireGuard tunnel wg0

[WireGuard]
{% if inventory_hostname == "vosmhost0" %}
ListenPort={{ wireguard.port }}
{% endif %}
PrivateKey={{ wireguard_priv_key.stdout}}
{% for peer in groups['all'] %}
{% if inventory_hostname == "vosmhost0" and peer != "vosmhost0" %}

# ----- {{ peer }} -----
[WireGuardPeer]
PublicKey={{ hostvars[peer].wireguard_pub_key.stdout }}
AllowedIPs={{ '.'.join(wg_ip.split(".")[:3]) + "." + hostvars[peer].ansible_host.split(".")[-1] }}/32
{% endif %}
{% if peer == inventory_hostname and peer != "vosmhost0" %}
[WireGuardPeer]
PublicKey={{ hostvars["vosmhost0"].wireguard_pub_key.stdout }}
Endpoint={{ hostvars["vosmhost0"].ansible_host }}:{{ wireguard.port}}
AllowedIPs={{ '.'.join(wg_ip.split(".")[:3]) + ".0" }}/24
PersistentKeepalive=25
{% endif %}
{% endfor %}
