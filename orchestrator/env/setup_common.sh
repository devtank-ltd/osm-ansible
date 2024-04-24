[ -n "$(which ansible-playbook)" ] || { echo "Install ansible"; exit -1; }
[ -n "$(which qemu-system-x86_64)" ] || { echo "Press install qemu-system-x86"; exit -1; }
[ -e "/usr/share/OVMF/OVMF_CODE_4M.fd" ] || { echo "Press install ovmf"; exit -1; }
[ -n "$(which isoinfo)" ] || { echo "Press install isoinfo"; exit -1; }

DEBISO=hosts/debian-12.5.0-amd64-netinst.iso

if [ ! -e "$DEBISO" ]
then
   mkdir -p hosts
   iso_name=$(basename $DEBISO)
   wget "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$iso_name" -O "$DEBISO"
   wget "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA512SUMS" -O hosts/SHA512SUMS
   grep "$(sha512sum "$DEBISO" | awk '{print $1}')" hosts/SHA512SUMS
   if [ "$?" != "0" ]
   then
     echo "ISO verification failed."
     exit -1
   fi
fi

. common.sh

[ -n "$DEFAULT_KEY_LOCATION" ] || DEFAULT_KEY_LOCATION=~/.ssh/id_rsa.pub

[ -e "$DEFAULT_KEY_LOCATION" ] || { echo "Missing public key"; exit -1; }

ssh_key_name=$(basename $DEFAULT_KEY_LOCATION)

[ -n "$ssh_key_name" ] || { echo "No SSH key found."; exit -1; }

echo $ssh_key_name > $HOST_DIR/ssh_key_name

[ -f "$HOST_DIR/$ssh_key_name" ] || ln -s $DEFAULT_KEY_LOCATION $HOST_DIR/$ssh_key_name

./net_ctrl.sh open $VOSMHOSTBR

[ -e "$DEBBIOSMEM" ] || cp "$OVMF_VARS_ORIG" "$DEBBIOSMEM"


# To give our own preseed, we need to boot QEMU with the kernel and init ram disk so we can gives arguments.
mkdir -p $HOST_DIR/boot
isoinfo -J -i "$DEBISO" -x /install.amd/vmlinuz > $HOST_DIR/boot/vmlinuz
isoinfo -J -i "$DEBISO" -x /install.amd/initrd.gz > $HOST_DIR/boot/initrd.gz

rm -rf "$DEBDISK"
qemu-img create -f qcow2 "$DEBDISK" 16G

python3 -m http.server -d $HOST_DIR -b 192.168.5.1&
websvr=$!

nc -u -l 192.168.5.1 10514 > $HOST_DIR/install_log&
logsvr=$!

[ -e "$HOST_DIR/preseed.cfg" ] || ln -s "$(readlink -f "$PRESEED")" $HOST_DIR/preseed.cfg

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
   -nic bridge,br="$VOSMHOSTBR",model=virtio-net-pci,mac=$OSMHOSTMAC \
   -drive file="$DEBISO",format=raw,if=virtio,media=cdrom \
   -drive file="$DEBDISK",format=qcow2,if=virtio \
   -drive "if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.fd,readonly=on" \
   -drive "if=pflash,format=raw,unit=1,file=$DEBBIOSMEM" \
   -kernel $HOST_DIR/boot/vmlinuz \
   -initrd $HOST_DIR/boot/initrd.gz \
   -append "console=ttyS0 priority=critical auto=true DEBIAN_FRONTEND=text hostname=$OSMHOST domain=$OSM_DOMAIN log_host=192.168.5.1 log_port=10514 url=http://192.168.5.1:8000/preseed.cfg" \
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

./run.sh &
run_pid=$!

echo "Waiting for $OSMHOST to have IP."
while [ -z "$vm_ip" ]
do
  sleep 0.25
  [ -e /proc/$run_pid ] || { echo "QEmu dead"; exit -1; }
  vm_ip=$(./get_active_ip_of_mac.sh $OSMHOST)
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
