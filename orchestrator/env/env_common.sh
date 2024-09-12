declare -Ar PACKAGES=(
    ["ansible"]="ansible-playbook"
    ["qemu-system-x86"]="qemu-system-x86_64"
    ["ovmf"]="/usr/share/OVMF/OVMF_CODE_4M.fd"
    ["isoinfo"]="isoinfo"
    ["systemd-resolved"]="resolvectl"
    ["dig (bind9-dnsutils)"]="dig"
    ["openssh"]="ssh-keygen"
    ["dnsmasq"]="dnsmasq"
    ["iptables"]="iptables"
)

# verify whethe needed packages are installed
for p in "${!PACKAGES[@]}"; do
    [[ "$p" == "ovmf" && ! -e "${PACKAGES[$p]}" ]] && {
        die "Please install '$p'"
    } || continue
    command -v "${PACKAGES[$p]}" >/dev/null 2>&1 || die "Please install '$p'"
done

# verify that user has kvm and netdev access
[[ -r /dev/kvm ]] || die "User doesn't have KVM access."
if ! grep -q "netdev" < <(groups) >/dev/null 2>&1; then
    die "User doesn't have netdev access."
fi
[[ -n "$HOSTS_DIR" ]] || HOSTS_DIR="hosts"
[[ -d "$HOSTS_DIR" ]] || die "Hosts folder doesn't exit."

info "HOSTS_DIR: $HOSTS_DIR"
export HOSTS_DIR
mkdir -p "$HOSTS_DIR"

[[ ! -e "$HOSTS_DIR/env" ]] || source "${HOSTS_DIR}/env"

save_env () {
    cat <<- EOF > "${HOSTS_DIR}/env"
	VOSM_HOSTBR="$VOSM_HOSTBR"
	HOSTS_DIR="$HOSTS_DIR"
	OSM_SUBNET="$OSM_SUBNET"
	OSM_DOMAIN="$OSM_DOMAIN"
EOF
}

[[ -n "$VOSM_HOSTBR" ]] || VOSM_HOSTBR="vosmhostbr0"
export VOSM_HOSTBR

if [[ -e "/sys/class/net/${VOSM_HOSTBR}" ]]; then
    osm_bridge_ip="$(get_ip4_addr "$VOSM_HOSTBR")"
    osm_bridge_range="${osm_bridge_ip%.*}"
else
    osm_bridge_range="192.168.5"
fi

[[ -n "$OSM_SUBNET" ]] || OSM_SUBNET="$osm_bridge_range"
export OSM_SUBNET

[[ -n "$OSM_DOMAIN" ]] || OSM_DOMAIN="osmm.fake.co.uk"
export OSM_DOMAIN

ANSIBLE_HOSTS="${HOSTS_DIR}/hosts"
export ANSIBLE_HOSTS

info "OSM DOMAIN: $OSM_DOMAIN"
info "OSM SUBNET: $OSM_SUBNET"
