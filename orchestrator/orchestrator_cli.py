#!/usr/bin/env python3
# coding: utf-8

import argparse
import base64
import crcmod  # type: ignore
import fcntl
import importlib.util
import json
import logging
import os
import paramiko
import pymysql
import select
import socket
import struct
import subprocess
import sys
import time
import weakref
import yaml

from collections import namedtuple
from cryptography.fernet import Fernet
from pathlib import Path
from typing import Union, Dict


CONFIG_FILE = "config.yaml"
WG_CONF_FILE = "/etc/wireguard/wg0.conf"
PROMETHEUS_CONF_FILE = "/etc/prometheus/prometheus.yml"
WG_PEER_TMPL = """
# ----- {host_name} peer -----
[Peer]
PublicKey = {pub_key}
AllowedIPs = {ip_addr}/32

"""
PROMETHEUS_HOST_TMPL = """
  # ----- {host_name} -----
  - job_name: "{host_name}"
    static_configs:
      - targets: ["{wg_ipaddr}:9100"]

  - job_name: "{host_name}-lxc"
    metrics_path: "/api/v1/allmetrics?format=prometheus&help=yes"
    honor_labels: true
    static_configs:
      - targets: ["{wg_ipaddr}:19999"]
"""

SQL_ADD_HOST = """
INSERT INTO osm_hosts
(name, ip_addr, capacity, active_since)
VALUES(%s, %s, %s, UNIX_TIMESTAMP())
"""
SQL_DEL_HOST = "UPDATE osm_hosts SET active_before=UNIX_TIMESTAMP() WHERE id=%s"
SQL_GET_HOST = "SELECT id FROM osm_hosts WHERE name=%s AND active_before IS NULL"
SQL_GET_HOST_ID_IPADDR = """
SELECT id, ip_addr FROM osm_hosts WHERE name = %s AND active_before IS NULL
"""
SQL_GET_HOST_BY_ADDR = """
SELECT id FROM osm_hosts WHERE ip_addr=%s AND active_before IS NULL
"""
SQL_LIST_HOSTS = "SELECT id, name FROM osm_hosts WHERE active_before IS NULL"
SQL_GET_WG_SRV_KEY = "SELECT public_key FROM osm_wireguard WHERE id = %s"
SQL_ADD_WG_HOST = """
INSERT INTO osm_wireguard
(osm_hosts_id, public_key, private_key, ip_addr)
VALUES(%s, %s, %s, %s)
"""
SQL_GET_WG_INFO = """
SELECT public_key, ip_addr FROM osm_wireguard WHERE osm_hosts_id=%s
"""

SQL_GET_HOST_BY_CUSTOMER = """
SELECT osm_customers.osm_hosts_id
FROM osm_customers WHERE name=%s AND active_before IS NULL
"""

SQL_HOST_GET_NAME = "SELECT name FROM osm_hosts WHERE id=%s"
SQL_HOST_GET_IP_ADDR = "SELECT ip_addr FROM osm_hosts WHERE id=%s"
SQL_HOST_GET_CAPACITY = "SELECT capacity FROM osm_hosts WHERE id=%s"

SQL_HOST_GET_USED_MQTT_PORTS = "SELECT host_mqtt_port FROM osm_customers WHERE osm_hosts_id=%s"
SQL_HOST_GET_CUSTOMERS = "SELECT name FROM osm_customers WHERE osm_hosts_id=%s AND active_before is NULL"

SQL_GET_CUSTOMER_PORT = "SELECT host_mqtt_port FROM osm_customers WHERE name=%s AND active_before IS NULL"

SQL_ADD_CUSTOMER = "INSERT INTO osm_customers (osm_hosts_id, name, host_mqtt_port, active_since) VALUES(%s, %s, %s, UNIX_TIMESTAMP())"
SQL_DEL_CUSTOMER = "UPDATE osm_customers SET active_before=UNIX_TIMESTAMP() WHERE osm_hosts_id=%s AND name=%s"
SQL_ADD_CUSTOMER_KEY = """
INSERT INTO osm_keys (osm_customer_id, customer_key)
VALUES (%s, %s)
"""
SQL_ADD_CUSTOMER_SECRETS = "INSERT INTO osm_secrets (osm_customer_id, secrets) VALUES (%s, %s)"
SQL_DEL_CUSTOMER_SECRETS = "DELETE FROM osm_secrets WHERE osm_customer_id=%s"
SQL_GET_CUSTOMER_SECRETS = "SELECT secrets FROM osm_secrets WHERE osm_customer_id=%s"
SQL_ADD_CUSTOMER_KEY = "INSERT INTO osm_keys (osm_customer_id, customer_key) VALUES (%s, %s)"
SQL_DEL_CUSTOMER_KEY = "DELETE FROM osm_keys WHERE osm_customer_id=%s"
SQL_GET_CUSTOMER_KEY = "SELECT customer_key FROM osm_keys WHERE osm_customer_id=%s"
SQL_GET_CUSTOMER_ID = "SELECT id FROM osm_customers WHERE name=%s AND active_before is NULL"
SQL_GET_FREEST_HOST = """
SELECT id, (
(SELECT COUNT(osm_customers.id) FROM osm_customers WHERE active_before IS NULL AND osm_hosts_id = osm_hosts.id) / capacity
) AS utilization FROM osm_hosts
ORDER BY utilization ASC LIMIT 1
"""

SQL_PDNS_ADD_HOST = """
INSERT INTO records
(domain_id, name, content, type, ttl, prio)
VALUES(%s, %s, %s, 'A', 1800, 0)
"""

SQL_PDNS_ADD_CUSTOMER = """
INSERT INTO records
(domain_id, name, content, type, ttl, prio)
VALUES(%s, %s, %s, 'CNAME', 1800, 0)
"""

SQL_PDNS_DEL_HOST = """
DELETE FROM records WHERE domain_id=%s AND name=%s AND content=%s
"""

SQL_PDNS_DEL_CUSTOMER = """
DELETE FROM records WHERE domain_id=%s AND name=%s AND content=%s
"""


parser = argparse.ArgumentParser(description='OSM Servers Orchestrator')
parser.add_argument(
    '-v', '--verbose',
    help='Info log information', action='store_true'
)
parser.add_argument(
    '-d', '--debug',
    help='Debug log information', action='store_true'
)
parser.add_argument(
    'command', type=str, help='command followed by arguments.', nargs='*'
)

crc8_func = crcmod.predefined.mkCrcFun('crc-8')


def do_db_query(db, cmd, args):
    with db.cursor() as c:
        full_cmd = c.mogrify(cmd, args)
        c.execute(full_cmd)
        logging.debug(full_cmd)
        return c.fetchall()


def do_db_single_query(db, cmd, args):
    with db.cursor() as c:
        full_cmd = c.mogrify(cmd, args)
        c.execute(full_cmd)
        logging.debug(full_cmd)
        return c.fetchone()


def do_db_update(db, cmd, args):
    with db.cursor() as c:
        full_cmd = c.mogrify(cmd, args)
        c.execute(full_cmd)
        logging.debug(full_cmd)
    db.commit()


def do_db_insert(db, cmd, args):
    with db.cursor() as c:
        full_cmd = c.mogrify(cmd, args)
        c.execute(full_cmd)
        logging.debug(full_cmd)
        row_id = c.lastrowid
    db.commit()
    return row_id


class SSHException(Exception):
    pass


class osm_host_t:
    def __init__(
            self, orchestrator, db_id, name=None, ip_addr=None, capacity=None
    ):
        self._orchestrator = orchestrator
        self.id = db_id
        self._name = name
        self._ip_addr = ip_addr
        self._capacity = capacity
        self._ssh_ref = None
        self._dns_entry = None
        self.logger = logging.getLogger(self.name)
        self.encoding = "utf-8"


    @property
    def db(self):
        return self._orchestrator.db

    @property
    def pdns_db(self):
        return self._orchestrator.pdns_db

    @property
    def config(self):
        return self._orchestrator.config

    def _look_by_id(self, cmd):
        return do_db_single_query(self.db, cmd, (self.id,))[0]

    @property
    def name(self):
        if not self._name:
            self._name = self._look_by_id(SQL_HOST_GET_NAME)
            if self._name:
                self.logger = logging.getLogger("HOST:" + self._name)
        return self._name

    @property
    def ip_addr(self):
        if not self._ip_addr:
            self._ip_addr = self._look_by_id(SQL_HOST_GET_IP_ADDR)
        return self._ip_addr

    @property
    def dns_entry(self):
        if not self._dns_entry:
            domain = self.config["pdns_domain"]
            self._dns_entry = "%s.%s" % (self.name, domain)
        return self._dns_entry

    @property
    def capacity(self):
        if not self._capacity:
            self._capacity = self._look_by_id(SQL_HOST_GET_CAPACITY)
        return self._capacity

    @property
    def customers(self):
        rows = do_db_query(self.db, SQL_HOST_GET_CUSTOMERS, (self.id,))
        return [row[0] for row in rows]

    def _find_free_mqtt_port(self, customer_name: str) -> int:
        rows = do_db_query(self.db, SQL_HOST_GET_USED_MQTT_PORTS, (self.id,))
        ports = [row[0] for row in rows]
        port = 8883 + crc8_func(customer_name.encode())
        while port in ports:
            port += 1
        return port

    def _add_customer_to_database(
            self, customer_name: str,
            mqtt_port: int
    ) -> None:
        do_db_insert(
            self.db, SQL_ADD_CUSTOMER, (self.id, customer_name, mqtt_port)
        )
        domain_id = self.config["pdns_domain_id"]
        domain = self.config["pdns_domain"]
        parts = ("", "-chirpstack", "-influx", "-mqtt")

        for d in parts:
            do_db_insert(
                self.pdns_db,
                SQL_PDNS_ADD_CUSTOMER,
                (domain_id, f"{customer_name}{d}.{domain}", self.dns_entry)
            )

    def _add_customer_secrets_to_database(
            self, name: str, key: str, secrets: str
    ) -> None:
        customer_id = do_db_single_query(
            self.db, SQL_GET_CUSTOMER_ID, (name)
        )[0]
        do_db_insert(self.db, SQL_ADD_CUSTOMER_KEY, (customer_id, key))
        do_db_insert(self.db, SQL_ADD_CUSTOMER_SECRETS, (customer_id, secrets))

    def _del_customer_to_database(self, customer_name: str) -> None:
        customer_id = do_db_single_query(
            self.db, SQL_GET_CUSTOMER_ID, (customer_name)
        )[0]
        do_db_update(self.db, SQL_DEL_CUSTOMER, (self.id, customer_name))
        domain_id = self.config["pdns_domain_id"]
        domain = self.config["pdns_domain"]

        parts = ("", "-chirpstack", "-influx", "-mqtt")
        for d in parts:
            do_db_update(
                self.pdns_db, SQL_PDNS_DEL_CUSTOMER,
                (domain_id, f"{customer_name}{d}.{domain}", self.dns_entry)
            )
        do_db_update(self.db, SQL_DEL_CUSTOMER_SECRETS, (customer_id))
        do_db_update(self.db, SQL_DEL_CUSTOMER_KEY, (customer_id))

    def get_ssh(self) -> Union[paramiko.SSHClient, None]:
        if self._ssh_ref:
            current = self._ssh_ref()
            if current:
                return current
        ssh = paramiko.SSHClient()
        known_hosts = os.environ["HOME"] + '/.ssh/known_hosts'

        if not os.path.exists(known_hosts):
            self.logger.error("No known_hosts files.")
            return None
        ssh.load_host_keys(known_hosts)

        try:
            ssh.connect(self.ip_addr, username="osm_orchestrator", timeout=2)
        except TimeoutError:
            self.logger.error(
                f"Timeout connecting to {self.name} ({self.ip_addr})."
            )
            return None
        except paramiko.ssh_exception.AuthenticationException as e:
            self.logger.error(
                f"Authentication fail connecting to {self.name} "
                f"({self.ip_addr}): {e}"
            )
            return None
        except OSError as e:
            self.logger.error(
                f"OS Error connecting to {self.name} ({self.ip_addr}): {e}"
            )
            return None

        self._ssh_ref = weakref.ref(ssh)
        return ssh

    def ssh_command(self, cmd: str, pty: bool = False) -> bool:
        ssh = self.get_ssh()
        if not ssh:
            return False
        try:
            ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command(
                cmd, get_pty=pty
            )
        except SSHException as err:
            self.logger.error(err)
            return False

        for line in ssh_stdout:
            self.logger.debug(line.rstrip())

        error_code = ssh_stdout.channel.recv_exit_status()

        if error_code:
            self.logger.error(
                f"Command '{cmd}' failed : "
                f"{error_code}:{os.strerror(error_code)}"
            )
            for line in ssh_stderr:
                self.logger.error(line.rstrip())
            return False
        ssh.close()
        return True

    def ssh_pull_file_or_directory(
            self, customer_name: str, src: str, dst: str
    ) -> bool:
        path = Path(src)
        if not (ssh := self.get_ssh()):
            return False
        parent = path.parent.absolute()
        basename = path.name
        remote_tar_cmd = (
            f"sudo /srv/osm-lxc/ansible/do-shell.sh '{customer_name}-svr' "
            f"'tar -C {parent} -Jc {basename}'"
        )
        ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command(remote_tar_cmd)
        local_extract_cmd = ['tar', '-Jx', '-C', '{dst}']

        with subprocess.Popen(
                local_extract_cmd, shell=True,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE
        ) as tar_process:
            try:
                if tar_process.stdin is not None:
                    for chunk in iter(lambda: ssh_stdout.read(4096), b''):
                        tar_process.stdin.write(chunk)
                    tar_process.stdin.close()
                tar_process.wait()
                if tar_process.returncode != 0:
                    print(
                        "Error: Local tar extraction failed with code "
                        f"{tar_process.returncode}"
                    )
                    return False
                ssh_error = ssh_stderr.read().decode()
                if ssh_error:
                    print(
                        f"Error: SSH command failed with message: {ssh_error}"
                    )
                    return False
            except Exception as e:
                print(f"Error occurred during file transfer: {e}")
                return False
        return True

    def ssh_push_file_or_directory(self, customer_name, src, dst):
        path = Path(src)
        dstpath = Path(dst)
        ssh = self.get_ssh()
        if not ssh:
            return False
        if not os.path.exists(path):
            self.logger.error(f"Cannot find path to {src}")
            return False
        parent = path.parent.absolute()
        basename = os.path.basename(src)
        tar_cmd = f'tar -C {parent} -Jc {basename}'
        if not os.path.isdir(path):
            dst = dstpath.parent.absolute()
        ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command(f"sudo /srv/osm-lxc/ansible/do-shell.sh '{customer_name}-svr' 'tar -Jx -C {dst}'")

        with subprocess.Popen(tar_cmd, shell=True, stdout=subprocess.PIPE) as tar_process:
            try:
                for chunk in iter(lambda: tar_process.stdout.read(4096), b''):
                    ssh_stdin.write(chunk)
                ssh_stdin.close()
            except Exception as e:
                print(f"Error occurred: {e}")
                return False
        error_code = ssh_stdout.channel.recv_exit_status()
        if error_code:
            self.logger.error(f"Push failed : {error_code}:{os.strerror(error_code)}")
            for line in ssh_stderr:
                self.logger.error(line.rstrip())
            return False
        return True

    def ssh_read_command(self, cmd: str) -> list:
        if not (ssh := self.get_ssh()):
            print("Unable to get SSH")
            raise SSHException("Unable to get ssh")

        ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command(cmd, timeout=10)
        stdout_r: list[str] = []
        error_code = ssh_stdout.channel.recv_exit_status()

        if error_code:
            self.logger.error(
                "Command '%s' failed : %s:%s" % cmd, error_code, os.strerror(
                    error_code
                )
            )
            for line in ssh_stderr:
                self.logger.error(line.rstrip())
            return stdout_r

        for line in ssh_stdout:
            stdout_r += [line.rstrip()]

        return stdout_r

    def can_ping_customer_container(self, customer_name: str) -> bool:
        return self.ssh_command(f"ping -c1 {customer_name}-svr")

    def can_ping_customer_grafana(self, customer_name: str) -> bool:
        domain = self.config["pdns_domain"]
        return self.ssh_command(f"ping -c1 {customer_name}.{domain}")

    def add_osm_customer(self, customer_name: str, timeout: int = 4) -> bool:
        if len(self.customers) >= self.capacity:
            return False
        mqtt_port = self._find_free_mqtt_port(customer_name)

        if not mqtt_port:
            self.logger.error("No free MQTT found.")
            return False

        # Needs DNS entry before Anisble called, for LetsEncrypt
        self._add_customer_to_database(customer_name, mqtt_port)

        found = False
        start_end = time.monotonic() + timeout
        while time.monotonic() < start_end:
            if self.can_ping_customer_grafana(customer_name):
                found = True

        if not found:
            self.logger.error("Container DNS failed")
            self._del_customer_to_database(customer_name)
            return False

        failed = True
        customer_key = Fernet.generate_key()
        enc_customer_key = Fernet(
            self._orchestrator.master_key
        ).encrypt(customer_key)

        if self.ssh_command(
                'sudo /srv/osm-lxc/ansible/do-create-container.sh '
                f'"{customer_name}" {mqtt_port} "" '
                f'"{customer_key.decode(self.encoding)}"'
        ):
            start_end = time.monotonic() + timeout
            while time.monotonic() < start_end:
                if self.can_ping_customer_container(customer_name):
                    failed = False
            if failed:
                self.logger.error("Container creation ping")
            else:
                out = self.ssh_read_command(
                    'sudo /srv/osm-lxc/ansible/do-shell.sh '
                    f'"{customer_name}-svr" '
                    "'cat /root/passwords-v2.json'"
                )
                try:
                    customer_pwds = json.loads(''.join(out))
                except json.JSONDecodeError as err:
                    self.logger.error("Not valid JSON: %s" % err)
                    return False
                else:
                    self._add_customer_secrets_to_database(
                        customer_name,
                        base64.b64encode(enc_customer_key).decode(
                            self.encoding
                        ),
                        json.dumps(customer_pwds)
                    )
        else:
            self.logger.error("Container creation failed")

        if failed:
            self._del_customer_to_database(customer_name)
            self.ssh_command(
                'sudo /srv/osm-lxc/ansible/do-delete-container.sh '
                f'"{customer_name}"'
            )
            return False
        return True

    def del_osm_customer(self, customer_name: str, timeout: int = 4) -> bool:

        if not self.ssh_command(
                'sudo /srv/osm-lxc/ansible/do-delete-container.sh '
                f'"{customer_name}"'
        ):
            self.logger.error("Container creation failed")
            return False

        start_end = time.monotonic() + timeout

        while time.monotonic() < start_end:
            if not self.can_ping_customer_container(customer_name):
                self._del_customer_to_database(customer_name)

                return True

        self.logger.error(
            f'Unable to delete customer "{customer_name} from OSM-Host". '
            f'Please debug OSM-Host {self.name}.'
        )
        return False

    def move_osm_customer(
            self, customer_name: str, src: "osm_host_t", dst: "osm_host_t"
    ) -> bool:
        if not src.upgrade_osm_customers():
            return False

        if not src.ssh_command(
                'sudo /srv/osm-lxc/ansible/do-move-container.bash '
                f"{customer_name} {dst.ip_addr}"
        ):
            self.logger.error("Container moving failed")
            return False
        mqtt_port = do_db_single_query(
            self.db,
            "SELECT host_mqtt_port FROM osm_customers WHERE name=%s AND "
            "active_before IS NULL",
            customer_name
        )[0]

        if not dst.ssh_command(
                'sudo /srv/osm-lxc/ansible/do-start-new-container.bash '
                f"{customer_name} {mqtt_port}"
        ):
            self.logger.error("Failed to start new container")
            return False
        if not src.ssh_command(
                'sudo /srv/osm-lxc/ansible/do-delete-container.sh '
                f'"{customer_name}"'
        ):
            self.logger.error(
                "Unable to delete container '%s' on the host '%s",
                customer_name, src.name
            )
            return False
        return True

    def upgrade_osm_customers(self) -> bool:
        upgrade_cmd = "sudo /srv/osm-lxc/ansible/do-upgrade-container.bash"
        lxc_dir = "/srv/osm-lxc/lxc/containers"
        os_base_dir = "/srv/osm-lxc/lxc/os-bases"
        duphash = "/root/dedup.hash"
        dedup_cmd = (
            "sudo /usr/local/bin/duperemove -rhd --hashfile="
            f"{duphash} {lxc_dir} {os_base_dir}"
        )
        # upgrade base container
        if self.ssh_command(f"{upgrade_cmd} 'base-os'", True):
            # upgrade customers containers
            for customer in self.customers:
                self.logger.info("Upgrade '%s' customer container", customer)
                if not self.ssh_command(f"{upgrade_cmd} {customer}", True):
                    self.logger.error(
                        "The customer '%s' was not upgraded", customer
                    )
                    return False
            return self.ssh_command(dedup_cmd)
            return True

        self.logger.error("The base container was not upgraded")
        return False

    def get_osm_customer_passwords(self, customer_name) -> dict:
        def walk_encrypted_dict(d: dict, crypt: Fernet, key: str) -> None:
            if isinstance(d, dict):
                for k, v in d.items():
                    if isinstance(v, str):
                        msg = v.encode(self.encoding)
                        d[k] = crypt.decrypt(msg).decode(self.encoding)
                    else:
                        walk_encrypted_dict(v, crypt, key)

        customer_id = do_db_single_query(
            self.db, SQL_GET_CUSTOMER_ID, (customer_name)
        )
        k = do_db_single_query(self.db, SQL_GET_CUSTOMER_KEY, (customer_id))[0]
        passwords: dict = {}

        if not k:
            self.logger.error("Unable to get customer key")
            return passwords

        k = k.encode(self.encoding)
        k = base64.b64decode(k)
        k = Fernet(self._orchestrator.master_key).decrypt(k)
        crypt = Fernet(k)
        secrets = do_db_single_query(
            self.db, SQL_GET_CUSTOMER_SECRETS, (customer_id)
        )[0]

        try:
            passwords = json.loads(secrets)
        except json.JSONDecodeError as err:
            self.logger.error("Invalid JSON: ", err)
            return passwords
        else:
            walk_encrypted_dict(passwords, crypt, k)

        return passwords

    def upgrade_influx_inserter(self) -> bool:
        cmd = "sudo /srv/osm-lxc/ansible/do-influx-inserter-upgrade.bash"
        for customer in self.customers:
            self.logger.info("Upgrade '%s' influx inserter service",
                customer)
            if not self.ssh_command(f"{cmd} {customer}", True):
                self.logger.error(
                    "Service for '%s' was not upgraded", customer
                )
                return False
        return True
        self.logger.error("Influx inserter was not upgraded")
        return False


class osm_orchestrator_t:
    MASTER_FILE = "master.key"

    def __init__(self, config):
        self.config = config
        orch_config = self.config["orchestrator"]
        self._db = pymysql.connect(**orch_config, connect_timeout=10)
        pdns_config = self.config["pdns"]
        self._pdns_db = pymysql.connect(**pdns_config, connect_timeout=10)
        self.logger = logging.getLogger("OSMORCH")
        self._ipaddr = None
        self._master_key = None

    @property
    def ipaddr(self) -> Union[str, None]:
        """ get IP address of orchestrator host. (not reliable)"""
        if not self._ipaddr:
            interface = None
            for ni in socket.if_nameindex():
                if ni[1].startswith('en'):
                    # potentially it is what we need
                    interface = ni[1]
                    break

            if interface is None:
                self.logger.error(
                    "Unable to find appopriate network interface"
                )
                return None

            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._ipaddr = socket.inet_ntoa(
                fcntl.ioctl(
                    sock.fileno(),
                    0x8915,  # SIOCGIFADDR
                    struct.pack("256s", interface[:15].encode("utf-8"))
                )[20:24]
            )

        return self._ipaddr

    @property
    def db(self):
        return self._db

    @property
    def pdns_db(self):
        return self._pdns_db

    def add_dns_host(self, osm_host, ip_addr):
        domain_id = self.config["pdns_domain_id"]
        domain = self.config["pdns_domain"]
        do_db_update(
            self._pdns_db, SQL_PDNS_ADD_HOST,
            (domain_id, "%s.%s" % (osm_host, domain),
             ip_addr)
        )

    @property
    def master_key(self) -> bytes:
        key_file = Path(self.MASTER_FILE)
        key_file = Path(__file__).parent / key_file
        if key_file.exists():
            self._master_key = key_file.read_bytes()
        else:
            key_file.touch(mode=0o600)
            key = Fernet.generate_key()
            key_file.write_bytes(key)
            self._master_key = key
        return self._master_key

    def _delete_from_config(self, config_file: str, host_name: str) -> None:
        stop_copy = False
        marker = "# ----- "
        conf = Path(config_file)
        tmp_conf = Path(f"{conf}.tmp")
        conf_dir = conf.parent

        with open(conf) as src, open(tmp_conf, "w") as dst:
            while line := src.readline():
                if f"{marker}{host_name}" in line:
                    stop_copy = True
                    continue

                if marker in line:
                    stop_copy = False

                if not stop_copy and not stop_copy:
                    dst.write(line)

        tmp_conf.rename(conf_dir / tmp_conf.stem)

    def find_free_osm_host(self):
        row = do_db_single_query(self.db, SQL_GET_FREEST_HOST, tuple())
        if row:
            osm_host = osm_host_t(self, row[0])
            if osm_host:
                utilization = row[1]
                used = int(utilization * osm_host.capacity)
                if used < osm_host.capacity:
                    return osm_host

    def find_osm_host_of(self, customer_name: str) -> Union[osm_host_t, None]:
        row = do_db_single_query(
            self.db, SQL_GET_HOST_BY_CUSTOMER, (customer_name,)
        )
        return osm_host_t(self, row[0]) if row else None

    def _restart_systemd_service(self, service_name: str) -> bool:
        proc = subprocess.run(
            ['systemctl', 'restart', f'{service_name}.service']
        )
        return proc.returncode == 0

    def find_osm_host(self, name: str) -> Union[osm_host_t, None]:
        row = do_db_single_query(self.db, SQL_GET_HOST, (name,))
        return osm_host_t(self, row[0]) if row else None

    def find_osm_host_by_addr(self, ip_addr):
        row = do_db_single_query(self.db, SQL_GET_HOST_BY_ADDR, (ip_addr,))
        if row:
            return osm_host_t(self, row[0])

    def list_hosts(self):
        rows = do_db_query(self.db, SQL_LIST_HOSTS, ())
        return [osm_host_t(self, row[0]) for row in rows]

    def add_osm_customer(self, customer_name: str) -> int:
        osm_host = self.find_osm_host_of(customer_name)
        if osm_host:
            self.logger.warning(f'Already customer "{customer_name}"')
            return False

        osm_host = self.find_free_osm_host()

        if not osm_host:
            self.logger.error(f"No free OSM host for customer {customer_name}")
            return False

        if osm_host.add_osm_customer(customer_name):
            return True

        return False

    def del_osm_customer(self, customer_name: str) -> bool:
        osm_host = self.find_osm_host_of(customer_name)
        if not osm_host:
            self.logger.warning(f'No customer "{customer_name}"')
            return False
        return osm_host.del_osm_customer(customer_name)

    def move_osm_customer(self, customer_name: str, host_name: str) -> bool:
        current_osm_host = self.find_osm_host_of(customer_name)

        if not current_osm_host:
            self.logger.warning(f"No customer '{customer_name}'")
            return False

        if current_osm_host == host_name:
            self.logger.info(
                "The host '%s' alraedy has customer '%s'",
                host_name, customer_name
            )
            return True

        new_osm_host = self.find_osm_host(host_name)
        if not new_osm_host:
            self.logger.warning("No host '%s' found", host_name)
            return False

        cust_num = do_db_single_query(
            self.db,
            "SELECT count(*) osm_hosts_id FROM osm_customers WHERE osm_hosts_id=%s AND active_before is null",
            new_osm_host.id
            )[0]

        if new_osm_host.capacity == cust_num:
            self.logger.error(
                "No space left for customer on host '%s': %d/%d", host_name,
                cust_num, new_osm_host.capacity
            )
            return False

        if new_osm_host.move_osm_customer(
            customer_name, current_osm_host, new_osm_host
        ):
            do_db_update(
                self.db,
                "UPDATE osm_customers SET osm_hosts_id=%s WHERE name=%s",
                (new_osm_host.id, customer_name)
            )
            return True

        return False

    def upgrade_osm_customers(self, host_name: str) -> bool:
        if (osm_host := self.find_osm_host(host_name)):
            return osm_host.upgrade_osm_customers()
        self.logger.error(f"The OSM host '{host_name}' is not found")
        return False

    def upgrade_influx_inserter(self, host_name: str) -> bool:
        if (osm_host := self.find_osm_host(host_name)):
            return osm_host.upgrade_influx_inserter()
        self.logger.error(f"The OSM host '{host_name}' is not found")
        return False

    def generate_wg_keys(self) -> tuple:
        """generate wireguard private and public key pairs"""
        priv_key = subprocess.run(
            ["wg", "genkey"],
            capture_output=True, text=True
        ).stdout.strip('\n')

        pub_key_proc = subprocess.Popen(
            ['echo', priv_key], stdout=subprocess.PIPE
        )
        pub_key_proc = subprocess.Popen(
            ["wg", "pubkey"],
            stdin=pub_key_proc.stdout,
            stdout=subprocess.PIPE,
        )
        stdout, stderr = pub_key_proc.communicate()
        pub_key = stdout.decode("utf-8").rstrip("\n")

        return priv_key, pub_key

    def add_wg_peer(
            self, osm_host_name: str, osm_pub_key: str, osm_ipaddr: str
    ) -> bool:
        # TODO: add verifications
        with open(WG_CONF_FILE, "a") as wg_conf:
            wg_conf.write(
                WG_PEER_TMPL.format(
                    host_name=osm_host_name,
                    pub_key=osm_pub_key,
                    ip_addr=osm_ipaddr
                )
            )

        # TODO: should we restart it via dbus API
        return self._restart_systemd_service("wg-quick@wg0")

    def add_prometheus_host(self, host_name: str, osm_ipaddr: str) -> bool:
        with open(PROMETHEUS_CONF_FILE, "a") as prometheus_conf:
            prometheus_conf.write(
                PROMETHEUS_HOST_TMPL.format(
                    host_name=host_name,
                    wg_ipaddr=osm_ipaddr
                )
            )

        # TODO: should we restart it via dbus API
        return self._restart_systemd_service("prometheus")

    def add_osm_host(self, host_name: str, ip_addr: str, capcaity: int) -> int:
        # TODO: make it configurable via config.yaml file
        WG_IPADDR = "10.10.1."

        try:
            capcaity = int(capcaity)
        except ValueError:
            self.logger.error(f'Invalid number "{capcaity}" for capcaity')
            return False

        if capcaity < 1:
            self.logger.error(f'Invalid number "{capcaity}" for capcaity')
            return False

        osm_host = self.find_osm_host(host_name)
        if osm_host:
            self.logger.warning(f'Already osm host of name "{host_name}"')
            return False

        osm_host = self.find_osm_host_by_addr(ip_addr)
        if osm_host:
            self.logger.warning(
                f'Already osm host "{host_name}" of addr {ip_addr}'
            )
            return False

        osm_host = osm_host_t(self, 0, host_name, ip_addr, capcaity)

        if not osm_host.get_ssh():
            return False

        if not osm_host.ssh_command('ls /srv/osm-lxc/ansible/'):
            self.logger.error("Unable to find expected ansible tools.")
            return False

        do_db_insert(self.db, SQL_ADD_HOST, (host_name, ip_addr, capcaity))

        host_id, host_ipaddr = do_db_single_query(
            self.db, SQL_GET_HOST_ID_IPADDR, (host_name)
        )

        self.logger.info(f"Generate wg config for host '{host_ipaddr}'")
        srv_pub_key = do_db_single_query(self.db, SQL_GET_WG_SRV_KEY, (1))[0]
        osm_ipaddr = f"{WG_IPADDR}{host_id + 1}"
        osm_priv_key, osm_pub_key = self.generate_wg_keys()

        do_db_insert(
            self.db,
            SQL_ADD_WG_HOST,
            (host_id, osm_pub_key, osm_priv_key, osm_ipaddr)
        )

        # configure wg peer
        ansible_vars = (
            f"target={host_ipaddr} osm_priv_key={osm_priv_key} "
            f"osm_pub_key={osm_pub_key} srv_key={srv_pub_key} "
            f"srv_ip={self.ipaddr} osm_ipaddr={osm_ipaddr}"
        )

        ansible_cmd = [
            "/usr/bin/ansible-playbook", "-v",
            f"-i {host_ipaddr},", "-e",
            ansible_vars,
            "/srv/osm-lxc/orchestrator/env/templates/osm_wireguard.yaml",
        ]

        ansible_proc = subprocess.Popen(
            ansible_cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )

        try:
            out, err = ansible_proc.communicate()
            self.logger.info(out.decode().split('\n'))
        except subprocess.SubprocessError as errs:
            ansible_proc.kill()
            self.logger.error(errs)

        self.add_wg_peer(host_name, osm_pub_key, osm_ipaddr)
        self.add_prometheus_host(host_name, osm_ipaddr)

        self.add_dns_host(host_name, ip_addr)
        return True

    def del_wg_peer(self, conf_file: str, host_name: str) -> None:
        """delete WireGuard peer"""

        self._delete_from_config(conf_file, host_name)
        self._restart_systemd_service("wg-quick@wg0")

    def del_prometheus_host(self, conf_file: str, host_name: str) -> None:
        self._delete_from_config(conf_file, host_name)
        self._restart_systemd_service("prometheus")

    def del_osm_host(self, host_name):
        osm_host = self.find_osm_host(host_name)
        if not osm_host:
            self.logger.warning(f'No osm host of name "{host_name}"')
            return False

        customers = osm_host.customers
        if customers:
            customers = ",".join(customers)
            self.logger.warning(
                f'Host of name "{host_name}" has '
                f'active customers: {customers}'
            )
            return False

        domain_id = self.config["pdns_domain_id"]
        do_db_single_query(
            self.db,
            f"DELETE FROM osm_wireguard WHERE osm_hosts_id = {osm_host.id}",
            ()
        )

        self.del_wg_peer(WG_CONF_FILE, host_name)
        self.del_prometheus_host(PROMETHEUS_CONF_FILE, host_name)

        do_db_update(self.db, SQL_DEL_HOST, (osm_host.id))
        do_db_update(
            self.pdns_db, SQL_PDNS_DEL_HOST,
            (domain_id, osm_host.dns_entry, osm_host.ip_addr)
        )
        return True

    def get_customer_passwords(self, customer_name):
        if (osm_host := self.find_osm_host_of(customer_name)):
            return osm_host.get_osm_customer_passwords(customer_name)
        return {}

    def get_wg_info(self, host_name: str) -> Dict[str, str]:
        try:
            osm_host_id = do_db_single_query(
                self.db, SQL_GET_HOST, (host_name,)
            )[0]
        except TypeError:
            return {}

        if osm_host_id:
            wg_key, wg_ipaddr = do_db_single_query(
                self.db, SQL_GET_WG_INFO, (osm_host_id,)
            )
            return {'wg_key': wg_key, 'wg_ipaddr': wg_ipaddr}
        return {}


class cli_osm_orchestrator_t:
    def __init__(self, osm_orch):
        self._osm_orch = osm_orch
        self.logger = logging.getLogger("ORCHESTRATOR CLI")

    def add_osm_customer(self, customer_name: str) -> int:
        if self._osm_orch.add_osm_customer(customer_name):
            return os.EX_OK
        else:
            return os.EX_UNAVAILABLE

    def del_osm_customer(self, customer_name: str) -> int:
        if self._osm_orch.del_osm_customer(customer_name):
            return os.EX_OK
        else:
            return os.EX_UNAVAILABLE

    def move_osm_customer(self, customer_name: str, host_name: str) -> int:
        if self._osm_orch.move_osm_customer(customer_name, host_name):
            return os.EX_OK
        else:
            return os.EX_UNAVAILABLE

    def upgrade_osm_customers(self, host_name: str) -> int:
        if self._osm_orch.upgrade_osm_customers(host_name):
            return os.EX_OK
        return os.EX_UNAVAILABLE

    def add_osm_host(self, host_name: str, ip_addr: str, capcaity: str) -> int:
        if self._osm_orch.add_osm_host(host_name, ip_addr, capcaity):
            return os.EX_OK
        return os.EX_CONFIG

    def del_osm_host(self, host_name):
        if self._osm_orch.del_osm_host(host_name):
            return os.EX_OK
        return os.EX_CONFIG

    def find_osm_host_of(self, customer_name):
        osm_host = self._osm_orch.find_osm_host_of(customer_name)
        if osm_host:
            print("Found on host : %s" % osm_host.name)
            return os.EX_OK
        else:
            self.logger.warning(f'No customer "{customer_name}"')
            return os.EX_CONFIG

    def test_osm_host(self, host_name):
        osm_host = self._osm_orch.find_osm_host(host_name)
        if not osm_host:
            self.logger.warning(f'No osm host of name "{host_name}"')
            return os.EX_CONFIG

        if not osm_host.get_ssh():
            return os.EX_CONFIG

    def list_hosts(self):
        osm_hosts = self._osm_orch.list_hosts()
        print("Hosts:")
        for osm_host in osm_hosts:
            print(
                f"\tHost: {osm_host.name}: capacity: "
                f"{len(osm_host.customers)}/{osm_host.capacity}"
            )
        return os.EX_OK

    def list_host_customers(self,  host_name):
        osm_host = self._osm_orch.find_osm_host(host_name)
        if not osm_host:
            self.logger.warning(f'No osm host of name "{host_name}"')
            return os.EX_CONFIG
        customers = osm_host.customers
        print(
            f"Host: {host_name}: capacity: "
            f"{len(customers)}/{osm_host.capacity}"
        )
        for customer in customers:
            row = do_db_single_query(
                self.db, SQL_GET_CUSTOMER_PORT, (customer,)
            )
            print(f"\tCustomer: {customer} (MQTT:{row[0]})")
        return os.EX_OK

    def list_customers(self):
        osm_hosts = self._osm_orch.list_hosts()
        print("Hosts:")
        for osm_host in osm_hosts:
            customers = osm_host.customers
            print(
                f"Host: {osm_host.name}: capacity: "
                f"{len(customers)}/{osm_host.capacity}"
            )
            for customer in customers:
                print(f"\tCustomer: {customer}")
        return os.EX_OK

    def customer_passwords(self, customer_name):
        pws = self._osm_orch.get_customer_passwords(customer_name)
        if pws:
            print(json.dumps(pws, indent=4))
            return os.EX_OK
        self.logger.warning(f'No passwords for "{customer_name}"')
        return os.EX_CONFIG

    def wg_info(self, host_name: str) -> int:
        if (wg_info := self._osm_orch.get_wg_info(host_name)):
            print(
                f"pubkey: {wg_info['wg_key']} IP: {wg_info['wg_ipaddr']}"
            )
            return os.EX_OK
        self.logger.warning(f'Unable to get WG info for host {host_name}')
        return os.EX_CONFIG

    def _validate_grafana_config(self, customer_name: str, config: str) -> int:
        try:
            with open(config) as f:
                db_config = json.load(f)
        except Exception as e:
            print(f"Invalid config file. Exiting")
            return os.EX_CONFIG
        osm_host = self._osm_orch.find_osm_host_of(customer_name)
        if not osm_host:
            print(f"Could not find host with customer: {customer_name}")
            return os.EX_CONFIG
        grafana_exists = osm_host.ssh_command(f"ping -c1 {db_config['grafana_url']}")
        if not grafana_exists:
            print("Cannot ping domain. Exiting")
            return os.EX_CONFIG
        return os.EX_OK

    def add_dashboards(self, customer_name: str, config: str, cert: Union[str, None]=None) -> int:
        if self._validate_grafana_config(customer_name, config) == os.EX_OK:
            grafana_cmd = [
                'python3',
                '/srv/osm-lxc/lib/grafana_api_client/grafana_api_client.py',
                'add',
                config
            ]
            if cert:
                grafana_cmd += ['-c', cert]
            grafana_proc = subprocess.Popen(
                grafana_cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE
            )
            try:
                out, err = grafana_proc.communicate()
            except subprocess.SubprocessError as errs:
                grafana_proc.kill()
                self.logger.error(errs)
                return os.EX_CONFIG
            if grafana_proc.returncode:
                return os.EX_CONFIG
            return os.EX_OK
        print("Validate grafana config failed.")
        return os.EX_CONFIG

    def del_dashboards(self, customer_name: str, config: str, cert: Union[str, None]=None) -> int:
        if self._validate_grafana_config(customer_name, config) == os.EX_OK:
            grafana_cmd = [
                'python3',
                '/srv/osm-lxc/lib/grafana_api_client/grafana_api_client.py',
                'delete',
                config
            ]
            if cert:
                grafana_cmd += ['-c', cert]
            grafana_proc = subprocess.Popen(
                grafana_cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE
            )
            try:
                out, err = grafana_proc.communicate()
            except subprocess.SubprocessError as errs:
                grafana_proc.kill()
                self.logger.error(errs)
                return os.EX_CONFIG
            if grafana_proc.returncode:
                return os.EX_CONFIG
            return os.EX_OK
        print("Validate grafana config failed.")
        return os.EX_CONFIG

    def push_file_or_directory(self, customer_name: str, src: str, dest: str) -> int:
        osm_host = self._osm_orch.find_osm_host_of(customer_name)
        if not osm_host:
            self.logger.warning(f'No osm host for customer "{customer_name}"')
            return os.EX_CONFIG
        do_push = osm_host.ssh_push_file_or_directory(customer_name, src, dest)
        if not do_push:
            return os.EX_CONFIG
        return os.EX_OK

    def pull_file_or_directory(self, customer_name: str, src: str, dest: str) -> int:
        osm_host = self._osm_orch.find_osm_host_of(customer_name)
        if not osm_host:
            self.logger.warning(f'No osm host for customer "{customer_name}"')
            return os.EX_CONFIG
        do_pull = osm_host.ssh_pull_file_or_directory(customer_name, src, dest)
        if not do_pull:
            return os.EX_CONFIG
        return os.EX_OK


def main():
    self_path = os.path.abspath(__file__)
    os.chdir(os.path.dirname(self_path))

    config = Path("config.yaml")
    if config.exists():
        config = config.resolve(strict=True)
    else:
        logging.error("No config.yaml found.")
        sys.exit(os.EX_UNAVAILABLE)

    try:
        config = yaml.safe_load(open("config.yaml"))
    except yaml.YAMLError as err:
        logging.error(err)
        if hasattr(err, "problem_mark"):
            mark = err.problem_mark
            logging.error("Error position: %s:%s", mark.line+1, mark.column+1)

    osm_orch = osm_orchestrator_t(config)
    cli_obj = cli_osm_orchestrator_t(osm_orch)

    cmd_entry = namedtuple("cmd_entry", ["help", "func"])

    commands = {
        "add_host": cmd_entry(
            "add_host <name> <ip_addr> <capacity> : Add host to OSM system",
            cli_obj.add_osm_host
        ),
        "del_host": cmd_entry(
            "del_host <name> : Remove host from OSM system",
            cli_obj.del_osm_host
        ),
        "find_host": cmd_entry(
            "find_host <name> : Find host of given customer in OSM system",
            cli_obj.find_osm_host_of
        ),
        "test_host": cmd_entry(
            "test_host <name> : Test access to OSM Host",
            cli_obj.test_osm_host
        ),
        "add_customer": cmd_entry(
            "add_customer <name> : Add customer to OSM system",
            cli_obj.add_osm_customer
        ),
        "del_customer": cmd_entry(
            "del_customer <name> : Remove customer from OSM system",
            cli_obj.del_osm_customer
        ),
        "mv_customer": cmd_entry(
            "mv_customer <customer name> <host name>: "
            "Move customer to OSM host",
            cli_obj.move_osm_customer
        ),
        "upgrade_customers": cmd_entry(
            "upgrade_customers <host name>: Upgrade existing customers on the "
            "OSM host",
            cli_obj.upgrade_osm_customers
        ),
        "list_hosts": cmd_entry(
            "list_hosts : Lists OSM Hosts in system",
            cli_obj.list_hosts
        ),
        "list_host_customers": cmd_entry(
            "list_host_customers <name> : Lists customers on OSM Host",
            cli_obj.list_host_customers
        ),
        "list_customers": cmd_entry(
            "list_customers : Lists all customers on all OSM Hosts",
            cli_obj.list_customers
        ),
        "get_customer_passwords": cmd_entry(
            "get_customer_passwords <name>: "
            "Return dictionary of passwords for a specified customer",
            cli_obj.customer_passwords
        ),
        "get_wg_info": cmd_entry(
            "get_wg_info <name> : Get WireGuard key and IP address",
            cli_obj.wg_info
        ),
        "push_file_or_directory": cmd_entry(
            "push_file_or_directory <customer> <source> <destination>: "
            "Push a file or a directory to a specified destination on a "
            "customer container",
            cli_obj.push_file_or_directory
        ),
        "pull_file_or_directory": cmd_entry(
            "pull_file_or_directory <customer> <source> <destination>: "
            "Pull a file or a directory to a specified destination from a "
            "customer container",
            cli_obj.pull_file_or_directory
        ),
        "add_dashboards" : cmd_entry(
            "add_dashboards <customer_name> <config> <cert>: Creates "
            "Grafana dashboard solution for customer with optional cert",
            cli_obj.add_dashboards
        ),
        "del_dashboards" : cmd_entry(
            "del_dashboards <customer_name> <config> <cert>: Deletes "
            "Grafana dashboard solution for customer with optional cert",
            cli_obj.del_dashboards
        ),
        "upgrade_influx_inserter" : cmd_entry(
            "upgrade_influx_inserter <host_name>: Upgrades mqtt influx "
            "inserter for all customers on host",
            cli_obj.upgrade_influx_inserter
        ),
    }

    directory = config["plugin_dir"]
    if directory and os.path.exists(directory):
        for plugin in os.listdir(directory):
            if plugin.endswith(".py"):
                continue
            path_to_plugin = os.path.join(directory, plugin)
            files = os.listdir(path_to_plugin)
            for filename in files:
                if filename == '__init__.py' \
                or filename.endswith('base.py') \
                or not filename.endswith(".py"):
                    continue
                module_path = os.path.join(path_to_plugin, filename)
                spec = importlib.util.spec_from_file_location(filename,
                 module_path)
                try:
                    module = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(module)
                except Exception as e:
                    print(f"Error importing module {filename} with \
                        error {e}")
                    continue
                try:
                    cls = module.init_plugin(osm_orch)
                except Exception as e:
                    print(f"Could not init plugin: {e}")
                    continue
                ver = None
                try:
                    ver = cls.api_version
                except Exception as e:
                    print(f"Could not get plugin API version with \
                        error: {e}")
                if ver and ver == 1:
                    try:
                        cmds = cls.get_commands()
                        commands.update(cmds)
                    except Exception as e:
                        print(f"Could not import commands from {cls} \
                            with error: {e}")
                else:
                    print(f"Unsupported plugin version: {ver} from \
                        plugin {cls}")

    args = parser.parse_args()

    if args.verbose:
        logging.basicConfig(level=logging.INFO)

    if args.debug:
        logging.basicConfig(level=logging.DEBUG)

    if not args.command or args.command[0] not in commands:
        print("No command given, commands are:")
        for cmd in commands.values():
            print(f"\t{cmd.help}")
        sys.exit(os.EX_USAGE)

    cmd_func = commands[args.command[0]].func
    func_args = args.command[1:]
    exit_code = cmd_func(*func_args)
    print(
        f'Command: {args.command[0]} : '
        f'Result: {"FAILED" if exit_code else "SUCCESS"}'
    )
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
