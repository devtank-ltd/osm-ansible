[Interface]
Address = {{ main.wireguard.ipaddr }}/24
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o {{ wg_if }} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o {{ wg_if }} -j MASQUERADE
ListenPort = {{ main.wireguard.port }}
PrivateKey = {{ wg_priv_key.stdout }}
MTU = 1400
