#! /bin/bash

if [ -z "$(which qemu-system-x86_64)" ]
then
   echo "Press install qemu-system-x86"
   exit -1
fi

if [ ! -e "/usr/share/OVMF/OVMF_CODE_4M.fd" ]
then
   echo "Press install ovmf"
   exit -1
fi

if [ -z "$(which isoinfo)" ]
then
   echo "Press install isoinfo"
   exit -1
fi

DEBISO=hosts/debian-12.5.0-amd64-netinst.iso

if [ ! -e "$DEBISO" ]
then
   iso_name=$(basename $DEBISO)
   wget "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$iso_name" -O "$DEBISO"
   wget "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA512SUMS" -O hosts/SHA512SUMS
   grep "$(sha512sum "$DEBISO")" hosts/SHA512SUMS
   if [ "$?" != "0" ]
   then
     echo "ISO verification failed."
     rm "$DEBISO" hosts/SHA512SUMS
     exit -1
   fi
fi


if [ -z "$DEFAULT_KEY_LOCATION" ]; then DEFAULT_KEY_LOCATION=~/.ssh/id_rsa.pub; fi

ssh_key_name=$(basename $DEFAULT_KEY_LOCATION)

if [ -z "$ssh_key_name" ]
then
  echo "No SSH key found."
  exit -1
fi

. common.sh

./net_ctrl.sh open

if [ ! -e "$DEBBIOSMEM" ]
then
    cp "$OVMF_VARS_ORIG" "$DEBBIOSMEM"
fi


# To give our own preseed, we need to boot QEMU with the kernel and init ram disk so we can gives arguments.
mkdir -p $HOST_DIR/boot
isoinfo -J -i "$DEBISO" -x /install.amd/vmlinuz > $HOST_DIR/boot/vmlinuz
isoinfo -J -i "$DEBISO" -x /install.amd/initrd.gz > $HOST_DIR/boot/initrd.gz

rm -rf "$DEBDISK"
qemu-img create -f qcow2 "$DEBDISK" 16G

IP_ADDR=$(ip route | awk '{print $9}' | head -n 1)

python -m http.server -d $HOST_DIR -b $IP_ADDR&
websvr=$!

nc -u -l 10514 > $HOST_DIR/install_log&
logsvr=$!

sed "s|IPADDR|$IP_ADDR|g" "$PRESEED" > $HOST_DIR/preseed.generated.cfg
sed "s|IPADDR|$IP_ADDR|g" "raw.postinstall.sh" > $HOST_DIR/postinstall.sh
sed -i "s|OSM_HOST_NAME|$OSMHOST|g" $HOST_DIR/postinstall.sh


echo $ssh_key_name > $HOST_DIR/ssh_key_name

ln -s $HOST_DIR/$ssh_key_name $DEFAULT_KEY_LOCATION


qemu-system-x86_64                 \
   -enable-kvm                     \
   -nographic                      \
   -serial mon:stdio               \
   -m 4G                           \
   -device virtio-scsi-pci,id=scsi \
   -device virtio-serial-pci       \
   -nic user,model=virtio-net-pci,hostname=$OSMHOST \
   -drive file="$DEBISO",format=raw,if=virtio,media=cdrom \
   -drive file="$DEBDISK",format=qcow2,if=virtio \
   -drive "if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.fd,readonly=on" \
   -drive "if=pflash,format=raw,unit=1,file=$DEBBIOSMEM" \
   -kernel $HOST_DIR/boot/vmlinuz \
   -initrd $HOST_DIR/boot/initrd.gz \
   -append "console=ttyS0 priority=critical auto=true DEBIAN_FRONTEND=text log_host=$IP_ADDR log_port=10514 url=http://$IP_ADDR:8000/preseed.generated.cfg"

rc=$?
kill $websvr $logsvr

if [ $rc != 0 ]
then
  echo "QEmu died."
else
  echo "Install complete."
fi

exit $rc
