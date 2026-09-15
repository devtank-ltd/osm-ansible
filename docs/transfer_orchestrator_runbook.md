# Manual Orchestrator Transfer Runbook


The following document outlines how to spin up a VM, provision it as an
OSM host, then transfer everything from an existing OSM network over to
it. This includes migrating the orchestrator/PDNS data onto it, joining it
to the Incus cluster, and re-pointing the OSM host's DNS resolver at it.
Nothing on the old orchestrator host is ever touched or deleted.

---

## 0. Bring up the test environment and source the library. Stay with this terminal as it has the functions and variables now.

```bash
./run.bash -a setup -c network.cfg

cd orchestrator/env
source inc/vars
source inc/print_functions.bash
source inc/network_functions.bash
source inc/cloud-init_generators.bash
source inc/ansible_functions.bash
source inc/functions.bash
source hosts/env
```

```bash
ssh -i hosts/id_ed25519 root@$OSM_SUBNET.2 \
  "/srv/osm-lxc/orchestrator/orchestrator_cli.py -d add_customer a1"
```

## 1. Build the new host from a fresh ISO


```bash
mv -v "${DL_DIR}/${DEB_IMG}" "${DL_DIR}/neworch-base.qcow2"
qemu-img resize "${DL_DIR}/neworch-base.qcow2" "$DISK_SIZE"

gen_base_user_data "" "hosts/id_ed25519"
cloud-localds base-seed.iso cloud-init/base-user-data

run_qemu_base_init "${DL_DIR}/neworch-base.qcow2" base-seed.iso

mkdir -p hosts/neworch
cp "${DL_DIR}/neworch-base.qcow2" hosts/neworch/disk.qcow
gen_hwaddr > hosts/neworch/mac
```

## 2. Boot with cloud-init and get an IP

```bash
run_qemu_cloudinit "neworch" "$VOSM_HOSTBR"
ipaddr="$(wait_for_ip "neworch" "${OSM_SUBNET}.1")"
setup_ssh "$ipaddr"
```

## 3. Persist variables

```bash
OLD_ORCH_IP_VAL="$OSM_SUBNET.2"

cat > /tmp/transfer_vars.env <<EOF
export ipaddr
export OLD_ORCH_IP="${OLD_ORCH_IP_VAL}"
export NEW_ORCH_IP="${ipaddr}"
export TRANSFER_SSH_KEY="hosts/id_ed25519"
EOF

source /tmp/transfer_vars.env
echo "OLD=$OLD_ORCH_IP NEW=$NEW_ORCH_IP KEY=$TRANSFER_SSH_KEY DOMAIN=$OSM_DOMAIN"
```

---

## Phase 1 — Add the new host as a cluster member + OSM host

### 1.1 Build the Phase 1 inventory

```bash
cat > /tmp/phase1_inventory.ini <<EOF
vosmhost0 ansible_ssh_private_key_file=${TRANSFER_SSH_KEY} target_role=main ansible_host=${OLD_ORCH_IP}
neworch ansible_ssh_private_key_file=${TRANSFER_SSH_KEY} ansible_host=${NEW_ORCH_IP}
EOF
```


### 1.2 Provision as OSM host

```bash
ANSIBLE_LIBRARY=ansible/library \
ansible-playbook \
  -i /tmp/phase1_inventory.ini \
  --tags "osm_host,image_remote" \
  -e git_branch=$(git_branch) \
  -e osm_domain="$OSM_DOMAIN" \
  ansible/incus/deploy.yaml
```


### 1.3 Create the Incus storage subvolume

```bash
ssh -i "$TRANSFER_SSH_KEY" root@"$NEW_ORCH_IP" "btrfs subvolume create /srv/osm-lxc/incus"
```

### 1.4 Bring up WireGuard and request certificate

`neworch` needs its own wireguard interface before it can reach anything else.
This uses the `wireguard_dns` tag (this name is a little misleading as
it also covers keypair generation and interface bring-up

```bash
ANSIBLE_LIBRARY=ansible/library \
ansible-playbook \
  -i /tmp/phase1_inventory.ini \
  --tags "wireguard_dns" \
  -e osm_domain="$OSM_DOMAIN" \
  ansible/incus/deploy.yaml

request_pebble_cert "neworch" "$OLD_ORCH_IP" "$NEW_ORCH_IP"
```
Requires `devtank.minica.pem` in the current directory

Verify nginx is happy:
```bash
ssh -i "$TRANSFER_SSH_KEY" root@"$NEW_ORCH_IP" "nginx -t"
```

### 1.5 Join the Incus cluster

```bash
ANSIBLE_LIBRARY=ansible/library \
ansible-playbook \
  -i /tmp/phase1_inventory.ini \
  --tags "cluster_join" \
  -e osm_domain="$OSM_DOMAIN" \
  ansible/incus/deploy.yaml
```

Verify:
```bash
ssh -i "$TRANSFER_SSH_KEY" root@"$NEW_ORCH_IP" "incus cluster list"
```


### 1.6 Register the host and move customers

Register it in the old orchestrator's database

```bash
ssh -i "$TRANSFER_SSH_KEY" root@"$OLD_ORCH_IP" \
  "cd /srv/osm-lxc/orchestrator && ./orchestrator_cli.py add_host neworch $NEW_ORCH_IP 5"
```

Then move customers over with the orchestrator command

```bash
ssh -i "$TRANSFER_SSH_KEY" root@"$OLD_ORCH_IP" \
  "cd /srv/osm-lxc/orchestrator && ./orchestrator_cli.py mv_customer a1 neworch"
```

---



## Phase 2 — Transfer orchestrator


### 2.1 Provision the orchestrator-specific setup

```bash
ANSIBLE_LIBRARY=ansible/library \
ansible-playbook \
  -i "${NEW_ORCH_IP}," \
  -e ansible_ssh_private_key_file="$TRANSFER_SSH_KEY" \
  --tags "bootstrap" \
  --skip-tags "pebble" \
  -e target_role=main \
  -e git_branch=$(git_branch) \
  -e osm_dns="$NEW_ORCH_IP" \
  -e osm_domain="$OSM_DOMAIN" \
  -e smtp_host="$MAIL_SMTP_HOST" \
  -e smtp_user="$MAIL_SMTP_USER" \
  -e smtp_password="$MAIL_SMTP_PASSWORD" \
  -e mail_recipients="$MAIL_RECIPIENTS" \
  ansible/incus/deploy.yaml
```

### 2.2 Confirm the Incus version matches the existing cluster

```bash
ssh -i "$TRANSFER_SSH_KEY" root@"$OLD_ORCH_IP" "incus version"
ssh -i "$TRANSFER_SSH_KEY" root@"$NEW_ORCH_IP" "incus version"
```

### 2.3 Migrate the orchestrator/PDNS data

```bash
ssh -i "$TRANSFER_SSH_KEY" root@"$OLD_ORCH_IP" \
  "mysqldump --user root --opt --skip-lock-tables --databases osm_orchestrator pdns --result-file /tmp/orch_transfer.sql"

scp -i "$TRANSFER_SSH_KEY" root@"$OLD_ORCH_IP":/tmp/orch_transfer.sql .
scp -i "$TRANSFER_SSH_KEY" root@"$OLD_ORCH_IP":/srv/osm-lxc/orchestrator/config.yaml .
scp -i "$TRANSFER_SSH_KEY" root@"$OLD_ORCH_IP":/srv/osm-lxc/orchestrator/master.key .

scp -i "$TRANSFER_SSH_KEY" orch_transfer.sql root@"$NEW_ORCH_IP":/tmp/
scp -i "$TRANSFER_SSH_KEY" config.yaml root@"$NEW_ORCH_IP":/tmp/config.yaml.incoming
scp -i "$TRANSFER_SSH_KEY" master.key root@"$NEW_ORCH_IP":/tmp/master.key.incoming
```

Save off the user credentials

```bash
ORCH_USER=$(grep -A4 "^orchestrator:" config.yaml | grep "user:" | awk '{print $2}')
ORCH_PASS=$(grep -A4 "^orchestrator:" config.yaml | grep "password:" | awk '{print $2}')
ALERT_USER=$(grep -A4 "^customer_alerts:" config.yaml | grep "user:" | awk '{print $2}')
ALERT_PASS=$(grep -A4 "^customer_alerts:" config.yaml | grep "password:" | awk '{print $2}')
echo "$ORCH_USER / $ORCH_PASS / $ALERT_USER / $ALERT_PASS"
```

Restore, recreate users, swap in the real config/key, restart PDNS:

```bash
ssh -i "$TRANSFER_SSH_KEY" root@"$NEW_ORCH_IP" bash -s <<EOF
set -e
systemctl stop pdns.service
mysql -uroot -e "DROP DATABASE IF EXISTS osm_orchestrator; DROP DATABASE IF EXISTS pdns;"
mysql -uroot < /tmp/orch_transfer.sql
mysql -uroot -e "
    DROP USER IF EXISTS '${ORCH_USER}'@'localhost';
    CREATE USER '${ORCH_USER}'@'localhost' IDENTIFIED BY '${ORCH_PASS}';
    GRANT ALL ON osm_orchestrator.* TO '${ORCH_USER}'@'localhost';
    GRANT ALL ON pdns.records TO '${ORCH_USER}'@'localhost';
    DROP USER IF EXISTS '${ALERT_USER}'@'localhost';
    CREATE USER '${ALERT_USER}'@'localhost' IDENTIFIED BY '${ALERT_PASS}';
    GRANT SELECT ON osm_orchestrator.* TO '${ALERT_USER}'@'localhost';
    FLUSH PRIVILEGES;
"
cp /srv/osm-lxc/orchestrator/config.yaml /srv/osm-lxc/orchestrator/config.yaml.bak
cp /tmp/config.yaml.incoming /srv/osm-lxc/orchestrator/config.yaml
cp /tmp/master.key.incoming /srv/osm-lxc/orchestrator/master.key
chmod 600 /srv/osm-lxc/orchestrator/master.key
systemctl start pdns.service
EOF
```

Confirm the credentials actually match what's now in config.yaml

```bash
ssh -i "$TRANSFER_SSH_KEY" root@"$NEW_ORCH_IP" \
  "mysql -uosm_orchestrator -p'${ORCH_PASS}' osm_orchestrator -e 'SELECT 1;'"
```

### 2.4 Re-point every host's WireGuard DNS resolver at the new orchestrator

Build a fresh inventory for this step - `target_role=main` now moves to
`neworch`:

```bash
cat > /tmp/resync_inventory.ini <<EOF
vosmhost0 ansible_ssh_private_key_file=${TRANSFER_SSH_KEY} ansible_host=${OLD_ORCH_IP}
neworch ansible_ssh_private_key_file=${TRANSFER_SSH_KEY} target_role=main ansible_host=${NEW_ORCH_IP}
EOF
```

```bash
ANSIBLE_LIBRARY=ansible/library \
ansible-playbook \
  -i /tmp/resync_inventory.ini \
  --tags "wireguard_dns" \
  -e osm_domain="$OSM_DOMAIN" \
  ansible/incus/deploy.yaml
```


### 2.5 Verify end to end

```bash
ssh -i "$TRANSFER_SSH_KEY" root@"$NEW_ORCH_IP" \
  "cd /srv/osm-lxc/orchestrator && ./orchestrator_cli.py list_hosts"
```

```bash
ssh -i "$TRANSFER_SSH_KEY" root@"$NEW_ORCH_IP" \
  "cd /srv/osm-lxc/orchestrator && ./orchestrator_cli.py get_customer_passwords a1"
```


```bash
ssh -i "$TRANSFER_SSH_KEY" root@"$NEW_ORCH_IP" \
  "cd /srv/osm-lxc/orchestrator && ./orchestrator_cli.py -d add_customer test1"
```

```bash
ssh -i "$TRANSFER_SSH_KEY" root@"$OLD_ORCH_IP" "resolvectl dns wg0; resolvectl domain wg0"
```
Should now show `neworch`'s WireGuard IP, not the old orchestrator's.

---

Nothing on `vosmhost0` (the old orchestrator) is touched or deleted at any
point in this document.

---

## Tearing down the test host

To fully remove `neworch` after testing:

**1. Stop the VM**
```bash
echo "system_powerdown" | socat - unix-connect:hosts/neworch/monitor.sock 2>/dev/null
sleep 3
cat hosts/neworch/qemu.pid 2>/dev/null
ps -p "$(cat hosts/neworch/qemu.pid 2>/dev/null)" 2>/dev/null
```
If it's still running, force kill it:
```bash
kill -9 "$(cat hosts/neworch/qemu.pid 2>/dev/null)" 2>/dev/null
```

**2. Remove it from the Incus cluster**
```bash
ssh -i hosts/id_ed25519 root@"$OLD_ORCH_IP" "incus cluster remove neworch --force"
```

**3. Remove Ansible inventory entries**
```bash
sed -i '/^neworch /d' hosts/hosts
rm -f /tmp/resync_inventory.ini /tmp/phase1_inventory.ini
```

**4. Delete all its local files**:
```bash
rm -rf hosts/neworch
```

**5. Clean up the base image and seed files it was built from**
```bash
rm -f downloads/neworch-base.qcow2 base-seed.iso cloud-init/base-user-data
```

**6. Remove transferred files containing credentials:**
```bash
rm -f /tmp/transfer_vars.env /tmp/orch_transfer.sql /tmp/config.yaml.incoming /tmp/master.key.incoming
rm -f orch_transfer.sql config.yaml master.key
```

