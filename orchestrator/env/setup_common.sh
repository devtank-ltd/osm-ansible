[ -n "$(which ansible-playbook)" ] || { echo "Install ansible"; exit -1; }
[ -n "$(which qemu-system-x86_64)" ] || { echo "Press install qemu-system-x86"; exit -1; }
[ -e "/usr/share/OVMF/OVMF_CODE_4M.fd" ] || { echo "Press install ovmf"; exit -1; }
[ -n "$(which isoinfo)" ] || { echo "Press install isoinfo"; exit -1; }
[ -n "$(which resolvectl)" ] || { echo "Please install systemd-resolved"; exit -1; }

source common.sh

DEBISO="$HOSTS_DIR"/debian-12.6.0-amd64-netinst.iso

if [ ! -e "$DEBISO" ]
then
   iso_name=$(basename $DEBISO)
   wget "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$iso_name" -O "$DEBISO"
   wget "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA512SUMS" -O "$HOSTS_DIR"/SHA512SUMS
   grep "$(sha512sum "$DEBISO" | awk '{print $1}')" "$HOSTS_DIR"/SHA512SUMS
   if [ "$?" != "0" ]
   then
     echo "ISO verification failed."
     exit -1
   fi
fi

[ -n "$DEFAULT_KEY_LOCATION" ] || DEFAULT_KEY_LOCATION=~/.ssh/id_rsa.pub

[ -e "$DEFAULT_KEY_LOCATION" ] || { echo "Missing public key"; exit -1; }

ssh_key_name=$(basename $DEFAULT_KEY_LOCATION)

[ -n "$ssh_key_name" ] || { echo "No SSH key found."; exit -1; }

echo $ssh_key_name > $HOST_DIR/ssh_key_name

[ -f "$HOST_DIR/$ssh_key_name" ] || ln -s $DEFAULT_KEY_LOCATION $HOST_DIR/$ssh_key_name

./net_ctrl.sh open $VOSM_HOSTBR $HOSTS_DIR $OSM_SUBNET $OSM_DOMAIN
[ "$?" = "0" ] || { echo "Failed to setup bridge"; exit -1; }

[ -e "$DEBBIOSMEM" ] || cp "$OVMF_VARS_ORIG" "$DEBBIOSMEM"


# To give our own preseed, we need to boot QEMU with the kernel and init ram disk so we can gives arguments.
mkdir -p $HOST_DIR/boot
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


qemu-system-x86_64                 \
   -no-reboot                      \
   -enable-kvm                     \
   -nographic                      \
   -m 4G                           \
   -monitor unix:$HOST_DIR/monitor.sock,server,nowait \
   -serial unix:$HOST_DIR/console.sock,server,nowait \
   -device virtio-scsi-pci,id=scsi \
   -device virtio-serial-pci       \
   -nic bridge,br="$VOSM_HOSTBR",model=virtio-net-pci,mac=$OSM_HOSTMAC \
   -drive file="$DEBISO",format=raw,if=virtio,media=cdrom \
   -drive file="$DEBDISK",format=qcow2,if=virtio \
   -drive "if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.fd,readonly=on" \
   -drive "if=pflash,format=raw,unit=1,file=$DEBBIOSMEM" \
   -kernel $HOST_DIR/boot/vmlinuz \
   -initrd $HOST_DIR/boot/initrd.gz \
   -append "console=ttyS0 priority=critical auto=true DEBIAN_FRONTEND=text hostname=$OSM_HOST domain=$OSM_DOMAIN log_host=$OSM_SUBNET.1 log_port=10514 url=http://$OSM_SUBNET.1:8000/preseed.cfg" \
   -cpu host

rc=$?
kill $websvr $logsvr

if [ "$rc" = "0" ]
then
  echo "Install complete."
else
  echo "QEmu died."
  exit -1
fi

[ -z "$DEV" ] || cp "$DEBDISK" "$DEBDISK.bckup"

OSM_HOST=$OSM_HOST ./run.sh &
run_pid=$!
vm_ip=""

echo "Waiting for $OSM_HOST to have IP."
while [ -z "$vm_ip" ]
do
  sleep 0.25
  [ -e /proc/$run_pid ] || { echo "QEmu dead"; exit -1; }
  vm_ip=$(./get_active_ip_of.sh $OSM_HOST $OSM_SUBNET.1)
done

echo "VM booted and taken IP address $vm_ip"

mkdir -p ~/.ssh

# Sort out ssh host key
ssh-keygen -f ~/.ssh/known_hosts -R $vm_ip
ssh-keyscan -H $vm_ip >> ~/.ssh/known_hosts

ssh root@$vm_ip exit
[ "$?" = "0" ] || { echo "SSH access setup failed."; kill $run_pid; exit -1; }


[ -e "$ANSIBLE_HOSTS" ] || printf "[all:vars]\n\
ansible_connection=ssh\n\
ansible_user=root\n\
" > "$ANSIBLE_HOSTS"

[ -n "$(grep "$vm_ip" "$ANSIBLE_HOSTS")" ] || printf "$vm_ip\n$(cat "$ANSIBLE_HOSTS")" > "$ANSIBLE_HOSTS"


ansible-playbook -v -e target="$vm_ip $ansible_args" -i "$ANSIBLE_HOSTS" "$ansible_file"

ssh root@$vm_ip 'ls /srv/osm-lxc/ansible' 2>&1 > /dev/null
rc=$?

[ -n "$POWER_ON" ] || { ssh root@$vm_ip "poweroff"; wait $run_pid; }

[ "$rc" = 0 ] || { echo 'Failed.'; exit -1; }
