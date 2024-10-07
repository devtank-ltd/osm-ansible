# -*- mode: sh; sh-shell: bash; -*-

readonly DEB_ISO_ARCH="amd64"
readonly DEB_ISO_VER="12.7.0"
readonly DEB_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
readonly ISO_NAME="debian-${DEB_ISO_VER}-${DEB_ISO_ARCH}-netinst.iso"
readonly DEB_ISO_URL="${DEB_URL}/${ISO_NAME}"
readonly CHECKSUM_FILE="SHA512SUMS"

source functions.sh
source common.sh

git_branch=$(git branch --show-current)

readonly DEBISO="${HOSTS_DIR}/${ISO_NAME}"

if [[ ! -e "${DEBISO}" ]]; then
    pushd "$HOSTS_DIR" >/dev/null 2>&1
    download_file "${DEB_ISO_URL}" "."
    download_file "${DEB_URL}/${CHECKSUM_FILE}" "."
    sed -i.backup '/'"${ISO_NAME}"'/!d' "$CHECKSUM_FILE"
    if ! sha512sum -c "$CHECKSUM_FILE" >/dev/null 2>&1; then
        die "ISO file '${ISO_NAME}' verification failed."
    fi
    popd >/dev/null 2>&1
fi

[[ -n "$DEFAULT_KEY_LOCATION" ]] || mapfile -t ssh_keys < <(find ~/.ssh/ -type f -name 'id_*.pub')
if (( ${#ssh_keys[@]} > 1 )); then
    warn "There are several SSH public keys."
    PS3="Which key should be used? "
    select key in "${ssh_keys[@]}"; do
        [[ $key ]] || continue
        info "Set the '${key}' key"
        DEFAULT_KEY_LOCATION="$key"
        break
    done
else
    info "Set '${ssh_keys[0]}' public key."
    DEFAULT_KEY_LOCATION="${ssh_keys[0]}"
fi

[[ -e "$DEFAULT_KEY_LOCATION" ]] || die "Missing public key"

ssh_key_name="${DEFAULT_KEY_LOCATION##*/}"

[[ -n "$ssh_key_name" ]] || die "No SSH key found."

echo "$ssh_key_name" > "$HOST_DIR"/ssh_key_name

[ -f "$HOST_DIR/$ssh_key_name" ] || ln -s "$DEFAULT_KEY_LOCATION" "${HOST_DIR}/${ssh_key_name}"

./net_ctrl.sh "open" "$VOSM_HOSTBR" "$HOSTS_DIR" "$OSM_SUBNET" "$OSM_DOMAIN"
(( $? == 0 )) || die "Failed to setup bridge"

[[ -e "$DEBBIOSMEM" ]] || cp "$OVMF_VARS_ORIG" "$DEBBIOSMEM"

# To give our own preseed, we need to boot QEMU with the kernel and init ram disk so we can gives arguments.
mkdir -p "${HOST_DIR}/boot"
isoinfo -J -i "$DEBISO" -x /install.amd/vmlinuz > "$HOST_DIR"/boot/vmlinuz
isoinfo -J -i "$DEBISO" -x /install.amd/initrd.gz > "$HOST_DIR"/boot/initrd.gz

rm -rf "$DEBDISK"
qemu-img create -f qcow2 "$DEBDISK" 16G

python3 -m http.server -d "$HOST_DIR" -b "${OSM_SUBNET}.1"&
websvr=$!

nc -u -l "${OSM_SUBNET}.1" 10514 > "$HOST_DIR"/install_log&
logsvr=$!

[ -e "$HOST_DIR/preseed.cfg" ] || sed "s|OSM_SUBNET|$OSM_SUBNET|g" "$PRESEED" > "$HOST_DIR"/preseed.cfg

[ -e "$HOST_DIR/ssh_key_name" ] || echo "$ssh_key_name" > "$HOST_DIR"/ssh_key_name
[ -e "$HOST_DIR/$ssh_key_name" ] || ln -s "$DEFAULT_KEY_LOCATION" "${HOST_DIR}/${ssh_key_name}"

qemu_params=(
    -no-reboot
    -drive "file=${DEBISO},format=raw,if=virtio,media=cdrom"
    -kernel "${HOST_DIR}/boot/vmlinuz"
    -initrd "${HOST_DIR}/boot/initrd.gz"
    --append "console=ttyS0 priority=critical auto=true DEBIAN_FRONTEND=text hostname=$OSM_HOST domain=$OSM_DOMAIN log_host=${OSM_SUBNET}.1 log_port=10514 url=http://${OSM_SUBNET}.1:8000/preseed.cfg"
)
run_qemu_vm "$HOST_DIR" "$VOSM_HOSTBR" "$OSM_HOSTMAC" "$DEBDISK" "$DEBBIOSMEM" "${qemu_params[@]}"

rc=$?
kill "$websvr" "$logsvr"

(( rc == 0 )) && info "Install complete." || die "QEmu died."

[[ -z "$DEV" ]] || cp "$DEBDISK" "$DEBDISK.bckup"

OSM_HOST=$OSM_HOST ./run.sh &
run_pid=$!
vm_ip=""

echo "Waiting for $OSM_HOST to have IP."
while [ -z "$vm_ip" ]
do
  sleep 0.25
  [[ -e /proc/$run_pid ]] || die "QEmu dead"
  vm_ip=$(./get_active_ip_of.sh $OSM_HOST $OSM_SUBNET.1)
done

echo "VM booted and taken IP address $vm_ip"

mkdir -p ~/.ssh
# Sort out ssh host key
ssh-keygen -f ~/.ssh/known_hosts -R "$vm_ip"
ssh-keyscan -H "$vm_ip" >> ~/.ssh/known_hosts

ssh root@"$vm_ip" exit
(( $? == 0 )) || {
    kill $run_pid
    die "SSH access setup failed."
}

[[ -e "$ANSIBLE_HOSTS" ]] || cat <<-EOF > "$ANSIBLE_HOSTS"
	[all:vars]
	ansible_connection=ssh
	ansible_user=root
EOF

if ! grep -q "$vm_ip" "$ANSIBLE_HOSTS"; then
    sed -i '1 i\'"$vm_ip"'' "$ANSIBLE_HOSTS"
fi

if [[ "$OSM_HOST" == "orchestrator" ]]; then
    readonly ORCHESTRATOR_DIR="${HOSTS_DIR}/${OSM_HOST}"
    declare -a ORCHESTRATOR_PRIV_KEY
    declare -a ORCHESTRATOR_PUB_KEY

    pushd "$ORCHESTRATOR_DIR" >/dev/null 2>&1
    wg genkey | (umask 0077 && tee "$OSM_HOST".key) | wg pubkey > "$OSM_HOST".pub
    mapfile -t ORCHESTRATOR_PUB_KEY < "$OSM_HOST".pub
    mapfile -t ORCHESTRATOR_PRIV_KEY < "$OSM_HOST".key
    popd >/dev/null 2>&1

    ansible_args="${ansible_args} orchestrator_public_key=${ORCHESTRATOR_PUB_KEY[0]} orchestrator_private_key=${ORCHESTRATOR_PRIV_KEY[0]} wg_ipaddr=10.10.1.1 wg_port=51820"
fi

ansible-playbook \
    -v -e target="$vm_ip $ansible_args osm_ansible_branch=$git_branch" \
    -i "$ANSIBLE_HOSTS" "$ansible_file" \
    --skip-tags "pebble"

ssh root@"$vm_ip" 'ls /srv/osm-lxc/ansible' >/dev/null 2>&1
rc=$?

[[ -n "$POWER_ON" ]] || { ssh root@"$vm_ip" "poweroff"; wait $run_pid; }

(( rc == 0 )) || die "Failed."
