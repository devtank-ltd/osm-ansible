echo "Running installed system"

export OSMHOST

. common.sh

./run.sh &
run_pid=$!

echo "Waiting for MAC $OSMHOSTMAC to have IP."
while [ -z "$vm_ip" ]
do
  sleep 0.25
  [ -e /proc/$run_pid ] || { echo "QEmu dead"; exit -1; }
  vm_ip=$(./get_active_ip_of_mac.sh $VOSMHOSTBR $OSMHOSTMAC)
done

echo "VM booted and taken IP address $vm_ip"

mkdir -p ~/.ssh

# Sort out ssh host key
ssh-keygen -f ~/.ssh/known_hosts -R $vm_ip
ssh-keyscan -H $vm_ip >> ~/.ssh/known_hosts

ssh root@$vm_ip exit
[ "$?" = "0" ] || { echo "SSH access setup failed."; kill $run_pid; exit -1; }
