#! /bin/bash

[ -n "$(which qemu-system-x86_64)" ] || { echo "Press install qemu-system-x86"; exit -1; }
[ -e "/usr/share/OVMF/OVMF_CODE_4M.fd" ] || { echo "Press install ovmf"; exit -1; }
[ -n "$(which isoinfo)" ] || { echo "Press install isoinfo"; exit -1; }

DEBISO=hosts/debian-12.5.0-amd64-netinst.iso

if [ ! -e "$DEBISO" ]
then
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


[ -n "$DEFAULT_KEY_LOCATION" ] || DEFAULT_KEY_LOCATION=~/.ssh/id_rsa.pub

ssh_key_name=$(basename $DEFAULT_KEY_LOCATION)

[ -n "$ssh_key_name" ] || { echo "No SSH key found."; exit -1; }

. common.sh

./net_ctrl.sh open

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

[ -e "$HOST_DIR/ssh_key_name"] || echo $ssh_key_name > $HOST_DIR/ssh_key_name
[ -e "$HOST_DIR/$ssh_key_name" ] || ln -s $DEFAULT_KEY_LOCATION $HOST_DIR/$ssh_key_name


qemu-system-x86_64                 \
   -no-reboot                      \
   -enable-kvm                     \
   -nographic                      \
   -serial mon:stdio               \
   -m 4G                           \
   -device virtio-scsi-pci,id=scsi \
   -device virtio-serial-pci       \
   -nic bridge,br=vosmhostnet,model=virtio-net-pci \
   -drive file="$DEBISO",format=raw,if=virtio,media=cdrom \
   -drive file="$DEBDISK",format=qcow2,if=virtio \
   -drive "if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.fd,readonly=on" \
   -drive "if=pflash,format=raw,unit=1,file=$DEBBIOSMEM" \
   -kernel $HOST_DIR/boot/vmlinuz \
   -initrd $HOST_DIR/boot/initrd.gz \
   -append "console=ttyS0 priority=critical auto=true DEBIAN_FRONTEND=text hostname=$OSMHOST domain=osmm log_host=192.168.5.1 log_port=10514 url=http://192.168.5.1:8000/preseed.cfg"

rc=$?
kill $websvr $logsvr

if [ "$rc" = "0" ]
then
  echo "Install complete."
else
  echo "QEmu died."
  exit -1
fi
