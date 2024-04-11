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

DEBISO=debian-12.5.0-amd64-netinst.iso

if [ ! -e "$DEBISO" ]
then
   wget "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/$DEBISO"
   wget "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA512SUMS"
   grep "$(sha512sum "$DEBISO")" SHA512SUMS
   if [ "$?" != "0" ]
   then
     echo "ISO verification failed."
     rm "$DEBISO" SHA512SUMS
     exit -1
   fi
fi


if [ -n "$DEFAULT_KEY_LOCATION" ]; then DEFAULT_KEY_LOCATION=~/.ssh/id_rsa.pub; fi

. common.sh

if [ ! -e "$DEBBIOSMEM" ]
then
    cp "$OVMF_VARS_ORIG" "$DEBBIOSMEM"
fi


# To give our own preseed, we need to boot QEMU with the kernel and init ram disk so we can gives arguments.
mkdir -p boot
isoinfo -J -i "$DEBISO" -x /install.amd/vmlinuz > boot/vmlinuz
isoinfo -J -i "$DEBISO" -x /install.amd/initrd.gz > boot/initrd.gz

rm -rf "$DEBDISK"
qemu-img create -f qcow2 "$DEBDISK" 16G

IP_ADDR=$(ip route | awk '{print $9}' | head -n 1)

python -m http.server -b $IP_ADDR&
websvr=$!

nc -u -l 10514 > install_log&
logsvr=$!

sed "s|IPADDR|$IP_ADDR|g" "$PRESEED" > preseed.generated.cfg
sed "s|IPADDR|$IP_ADDR|g" "raw.postinstall.sh" > postinstall.sh
sed -i "s|OSMHOST|$OSMHOST|g" postinstall.sh

ln -s $DEFAULT_KEY_LOCATION

basename $DEFAULT_KEY_LOCATION > ssh_key_name


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
   -kernel boot/vmlinuz \
   -initrd boot/initrd.gz \
   -append "console=ttyS0 priority=critical auto=true DEBIAN_FRONTEND=text log_host=$IP_ADDR log_port=10514 url=http://$IP_ADDR:8000/preseed.generated.cfg"

kill $websvr $logsvr
echo "Install complete."

./run.sh &

while [ -z "$vm_ip" ]
do
  sleep 0.25
  vm_ip=$(awk '/osmhostv/ {print $3}' /tmp/vosmhostnet.leasefile)
done

echo "VM booted and taken IP address $vm_ip"

echo "$vm_ip
[all:vars]
ansible_connection=ssh
ansible_user=root
" > /tmp/hosts

ansible-playbook -e "target=$vm_ip" -i /tmp/hosts osmhost_setup.yaml
