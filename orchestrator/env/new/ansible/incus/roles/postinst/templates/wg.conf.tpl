[Interface]
Address = {{ wireguard.ipaddr }}/{{ wireguard.mask }}
{% if inventory_hostname == "vosmhost0" %}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o {{ ansible_default_ipv4.interface }} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o {{ ansible_default_ipv4.interface }} -j MASQUERADE
ListenPort = {{ wireguard.port }}
{% endif %}
PrivateKey = {{ hostvars[inventory_hostname].wireguard_priv_key.stdout}}
{% if inventory_hostname == "vosmhost0" %}
MTU = 1400
{% endif %}

{% if inventory_hostname == "vosmhost0" %}
{% for peer in groups['all'] %}
{% if peer != "vosmhost0" %}
# ----- {{ peer }} peer -----
[Peer]
PublicKey={{ hostvars[peer].wireguard_pub_key.stdout }}
AllowedIPs={{ ".".join(wireguard.ipaddr.split(".")[:3]) + "." + hostvars[peer].ansible_host.split(".")[-1] }}/32
{% endif %}
{% endfor %}
{% else %}
[Peer]
PublicKey={{ hostvars["vosmhost0"].wireguard_pub_key.stdout }}
AllowedIPs={{ ".".join(wireguard.ipaddr.split(".")[:3]) + ".0"}}/{{ wireguard.mask }}
Endpoint = {{ hostvars["vosmhost0"].ansible_host }}:{{ wireguard.port }}
PersistentKeepalive = 20
{% endif %}
