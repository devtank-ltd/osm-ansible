# -*- mode: sh; sh-shell: bash; -*-

readonly DEB_CD_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
# 12.6.0 is absent
# readonly ISO_NAME="debian-12.6.0-amd64-netinst.iso"
readonly ISO_NAME="debian-12.7.0-amd64-netinst.iso"

source functions.sh
source common.sh

readonly DEBISO="${HOSTS_DIR}/${ISO_NAME}"

if [[ ! -e "${DEBISO}" ]]; then
    pushd "$HOSTS_DIR" >/dev/null 2>&1
    edo curl -OL "${DEB_CD_URL}/${ISO_NAME}"
    edo curl -OL "${DEB_CD_URL}/SHA512SUMS"
    sed -i.backup '/'"${ISO_NAME}"'/!d' SHA512SUMS
    if ! sha512sum -c SHA512SUMS >/dev/null 2>&1; then
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
isoinfo -J -i "$DEBISO" -x /install.amd/vmlinuz > $HOST_DIR/boot/vmlinuz
isoinfo -J -i "$DEBISO" -x /install.amd/initrd.gz > $HOST_DIR/boot/initrd.gz

rm -rf "$DEBDISK"
qemu-img create -f qcow2 "$DEBDISK" 16G

python3 -m http.server -d $HOST_DIR -b $OSM_SUBNET.1&
websvr=$!

nc -u -l $OSM_SUBNET.1 10514 > $HOST_DIR/install_log&
logsvr=$!

[ -e "$HOST_DIR/preseed.cfg" ] || sed "s|OSM_SUBNET|$OSM_SUBNET|g" "$PRESEED" > $HOST_DIR/preseed.cfg

[ -e "$HOST_DIR/ssh_key_name" ] || echo $ssh_key_name > $HOST_DIR/ssh_key_name
[ -e "$HOST_DIR/$ssh_key_name" ] || ln -s $DEFAULT_KEY_LOCATION $HOST_DIR/$ssh_key_name

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

ssh root@$vm_ip exit
[ "$?" = "0" ] || { echo "SSH access setup failed."; kill $run_pid; exit -1; }

# ssh root@"$vm_ip" "exit" >/dev/null 2>&1 || kill "$run_pid"; die "SSH access setup failed."

[[ -e "$ANSIBLE_HOSTS" ]] || cat <<-EOF > "$ANSIBLE_HOSTS"
	[all:vars]
	ansible_connection=ssh
	ansible_user=root
EOF

[ -n "$(grep "$vm_ip" "$ANSIBLE_HOSTS")" ] || printf "$vm_ip\n$(cat "$ANSIBLE_HOSTS")" > "$ANSIBLE_HOSTS"

edo ansible-playbook -v -e target="$vm_ip $ansible_args" -i "$ANSIBLE_HOSTS" "$ansible_file"

ssh root@"$vm_ip" 'ls /srv/osm-lxc/ansible' 2>&1 > /dev/null
rc=$?

[ -n "$POWER_ON" ] || { ssh root@$vm_ip "poweroff"; wait $run_pid; }

[ "$rc" = 0 ] || { echo 'Failed.'; exit -1; }
