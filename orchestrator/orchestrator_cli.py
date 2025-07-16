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
import re
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

from pyosmorch import DBConnectionOrchestrator, DBConnectionPowerDNS  # type: ignore


CONFIG_FILE = "config.yaml"
DOMAIN_PARTS = ("", "-chirpstack", "-influx", "-mqtt")
DEVTANK_WD = "/srv/osm-lxc/orchestrator"


parser = argparse.ArgumentParser(description="OSM Servers Orchestrator")
parser.add_argument(
    "-v", "--verbose", help="Info log information", action="store_true"
)
parser.add_argument(
    "-d", "--debug", help="Debug log information", action="store_true"
)
parser.add_argument(
    "command", type=str, help="command followed by arguments.", nargs="*"
)


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

    @property
    def name(self):
        if not self._name:
            self._name = self.db.get_host_name_by_id(self.id)
            if self._name:
                self.logger = logging.getLogger("HOST:" + self._name)
        return self._name

    @property
    def ip_addr(self):
        if not self._ip_addr:
            self._ip_addr = self.db.get_hosts_ipaddr(self.id)
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
            self._capacity = self.db.get_host_capacity_by_id(self.id)
        return self._capacity

    @property
    def customers(self):
        rows = self.db.get_customers(self.id)
        return [row[0] for row in rows]

    def _find_free_mqtt_port(self, customer_name: str) -> int:
        ports = self.db.get_free_mqtt_port(self.id)
        port = 8883 + crc8_func(customer_name.encode())
        while port in ports:
            port += 1
        return port

    def _add_customer_to_database(
        self, customer_name: str, mqtt_port: int
    ) -> None:
        self.db.add_customer(self.id, customer_name, mqtt_port)
        domain_id = self.config["pdns_domain_id"]
        domain = self.config["pdns_domain"]

        for d in DOMAIN_PARTS:
            self.pdns_db.add_customer(
                domain_id, f"{customer_name}{d}.{domain}", self.dns_entry
            )

    def _add_customer_secrets_to_database(
        self, name: str, key: str, secrets: str
    ) -> None:
        customer_id = self.db.get_customer_id(name)
        self.db.add_customer_secret_key(customer_id, key)
        self.db.add_customer_secrets(customer_id, secrets)

    def _del_customer_to_database(self, customer_name: str) -> None:
        customer_id = self.db.get_customer_id(customer_name)
        self.db.del_customer(customer_name, self.id)
        domain_id = self.config["pdns_domain_id"]
        domain = self.config["pdns_domain"]

        parts = ("", "-chirpstack", "-influx", "-mqtt")
        for d in parts:
            self.pdns_db.del_customer(
                domain_id, f"{customer_name}{d}.{domain}", self.dns_entry
            )
        self.db.del_customer_secrets(customer_id)
        self.db.del_customer_secret_key(customer_id)

    # def can_ping_customer_container(self, customer_name: str) -> bool:
    #     return self.ssh_command(f"ping -c1 {customer_name}-svr")

    # def can_ping_customer_grafana(self, customer_name: str) -> bool:
    #     domain = self.config["pdns_domain"]
    #     return self.ssh_command(f"ping -c1 {customer_name}.{domain}")

    # def clone_container(self, customer_name: str) -> bool:
    #     cmd = "sudo /srv/osm-lxc/ansible/do-clone-container.bash"
    #     return self.ssh_command(f"{cmd} {customer_name}")

    # def move_osm_customer(
    #     self, customer_name: str, src: "osm_host_t", dst: "osm_host_t"
    # ) -> bool:
    #     if not src.upgrade_osm_customers():
    #         return False

    #     if not src.ssh_command(
    #         "sudo /srv/osm-lxc/ansible/do-move-container.bash "
    #         f"{customer_name} {dst.ip_addr}"
    #     ):
    #         self.logger.error("Container moving failed")
    #         return False
    #     mqtt_port = self.db.get_customer_port(customer_name)

    #     # get current CNAME to restore it in case of failure
    #     domain = self.config["pdns_domain"]
    #     parts = ("", "-chirpstack", "-influx", "-mqtt")
    #     for d in parts:
    #         self.pdns_db.update_record(
    #             f"{customer_name}{d}.{domain}", dst.dns_entry
    #         )

    #     if not dst.ssh_command(
    #         "sudo /srv/osm-lxc/ansible/do-start-new-container.bash "
    #         f"{customer_name} {mqtt_port}"
    #     ):
    #         self.logger.error("Failed to start new container")
    #         # restore records
    #         for d in parts:
    #             self.pdns_db.update_record(
    #                 f"{customer_name}{d}.{domain}", src.dns_entry
    #             )

    #         return False
    #     if not src.ssh_command(
    #         "sudo /srv/osm-lxc/ansible/do-delete-container.sh "
    #         f'"{customer_name}"'
    #     ):
    #         self.logger.error(
    #             "Unable to delete container '%s' on the host '%s",
    #             customer_name,
    #             src.name,
    #         )
    #         return False

    #     dst_id = self.db.get_host_by_customer(customer_name)
    #     return self.db.update_customer_host(customer_name, dst_id)

    # def upgrade_osm_customers(self) -> bool:
    #     upgrade_cmd = "sudo /srv/osm-lxc/ansible/do-upgrade-container.bash"
    #     lxc_dir = "/srv/osm-lxc/lxc/containers"
    #     os_base_dir = "/srv/osm-lxc/lxc/os-bases"
    #     duphash = "/root/dedup.hash"
    #     dedup_cmd = (
    #         "sudo /usr/local/bin/duperemove -rhd --hashfile="
    #         f"{duphash} {lxc_dir} {os_base_dir}"
    #     )
    #     # upgrade base container
    #     if self.ssh_command(f"{upgrade_cmd} 'base-os'", True):
    #         # upgrade customers containers
    #         for customer in self.customers:
    #             self.logger.info("Upgrade '%s' customer container", customer)
    #             if not self.ssh_command(f"{upgrade_cmd} {customer}", True):
    #                 self.logger.error(
    #                     "The customer '%s' was not upgraded", customer
    #                 )
    #                 return False
    #         return self.ssh_command(dedup_cmd)
    #         return True

    #     self.logger.error("The base container was not upgraded")
    #     return False

    def get_osm_customer_mqtt_port(self, customer_name: str):
        return self.db.get_customer_port(customer_name)

    def get_osm_customer_domains(self, customer_name: str):
        rx = "("
        for d in DOMAIN_PARTS:
            rx += customer_name + d + "|"
        rx = rx[:-1] + ")\\..*"
        rows = self.pdns_db.get_customer_record(rx)
        if rows:
            return [row[0] for row in rows]

    def get_osm_customer_passwords(self, customer_name) -> dict:
        def walk_encrypted_dict(d: dict, crypt: Fernet, key: str) -> None:
            if isinstance(d, dict):
                for k, v in d.items():
                    if isinstance(v, str):
                        msg = v.encode(self.encoding)
                        d[k] = crypt.decrypt(msg).decode(self.encoding)
                    else:
                        walk_encrypted_dict(v, crypt, key)

        customer_id = self.db.get_customer_id(customer_name)
        k = self.db.get_customer_secret_key(customer_id)
        passwords: dict = {}

        if not k:
            self.logger.error("Unable to get customer key")
            return passwords

        k = base64.b64decode(k.encode(self.encoding))
        print(f"{k=}")
        k = Fernet(self._orchestrator.master_key).decrypt(k)
        print(f"{k=}")
        crypt = Fernet(k)
        secrets = self.db.get_customer_secrets(customer_id)

        try:
            passwords = json.loads(secrets)
        except json.JSONDecodeError as err:
            self.logger.error("Invalid JSON: ", err)
            return passwords
        else:
            walk_encrypted_dict(passwords, crypt, k)

        return passwords


class osm_orchestrator_t:
    MASTER_FILE = "master.key"

    def __init__(self, config):
        self.config = config
        orch_config = self.config["orchestrator"]
        self._db = DBConnectionOrchestrator(
            **{
                "drivername": "mysql+pymysql",
                "username": orch_config["user"],
                "password": orch_config["password"],
                "host": orch_config["host"],
                "database": orch_config["database"],
            }
        )
        pdns_config = self.config["pdns"]
        self._pdns_db = DBConnectionPowerDNS(
            **{
                "drivername": "mysql+pymysql",
                "username": pdns_config["user"],
                "password": pdns_config["password"],
                "host": pdns_config["host"],
                "database": pdns_config["database"],
            }
        )
        self.logger = logging.getLogger("OSMORCH")
        self._ipaddr = None
        self._master_key = None

    @property
    def ipaddr(self) -> Union[str, None]:
        """get IP address of orchestrator host. (not reliable)"""
        if not self._ipaddr:
            interface = None
            for ni in socket.if_nameindex():
                if ni[1].startswith("en"):
                    # potentially it is what we need
                    interface = ni[1]
                    break

            if interface is None:
                self.logger.error("Unable to find appopriate network interface")
                return None

            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._ipaddr = socket.inet_ntoa(
                fcntl.ioctl(
                    sock.fileno(),
                    0x8915,  # SIOCGIFADDR
                    struct.pack("256s", interface[:15].encode("utf-8")),
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
        self._pdns_db.add_host(domain_id, f"{osm_host}.{domain}", ip_addr)

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

    def find_osm_host_of(self, customer_name: str) -> Union[osm_host_t, None]:
        row = self.db.get_host_by_customer(customer_name)
        return osm_host_t(self, row) if row else None

    def find_osm_host(self, name: str) -> Union[osm_host_t, None]:
        row = self.db.get_host(name)
        return osm_host_t(self, row[0]) if row else None

    def find_osm_host_by_addr(self, ip_addr):
        return self.db.get_host_by_ip(ip_addr)

    def list_hosts(self):
        rows = self.db.get_all_hosts()
        return [osm_host_t(self, row[0]) for row in rows]

    def add_osm_customer(self, customer_name: str) -> bool:
        ansible_cmd = [
            "ansible-playbook",
            "-i", f"localhost,{customer_name},",
            "-e", f"customer_name={customer_name}",
            f"{DEVTANK_WD}/env/ansible/add_customer.yaml",
        ]
        ansible_proc = subprocess.run(ansible_cmd)
        return ansible_proc.returncode == 0

    def add_osm_alerts_contact(self, customer_name: str, email: str) -> bool:
        return self._db.add_contact_point(customer_name, email) is not None

    def list_osm_alerts_contacts(self):
        return self._db.query_contact_points()

    def del_osm_customer(self, customer_name: str) -> bool:
        ansible_cmd = [
            "ansible-playbook",
            "-i", "localhost,",
            "-e", f"customer_name={customer_name}",
            f"{DEVTANK_WD}/env/ansible/del_customer.yaml",
        ]
        ansible_proc = subprocess.run(ansible_cmd)
        return ansible_proc.returncode == 0

    def clone_container(
            self, customer_name: str, target: str = "", public: bool = False
    ) -> bool:
        if not self.db.get_customer_id(customer_name):
            self.logger.error(
                "ERROR: Unable to find customer '%s' in the database",
                customer_name
            )
            return False

        def instance_cmd(
                cmd: str, customer_name: str, extra_args: list = []
        ) -> bool:
            if cmd not in ("start", "stop", "copy"):
                self.logger.error("Only 'start' or 'stop' command is supported")
                return False
            try:
                proc = subprocess.run(
                    ["incus", cmd, customer_name] + extra_args, check=True
                )
            except subprocess.CalledProcessError as err:
                self.logger.error(err)
                return False

            return proc.returncode == 0

        # current OSM host
        target_id = self.db.get_host_by_customer(customer_name)
        target_ip = self.db.get_hosts_ipaddr(target_id)

        if not instance_cmd("stop", customer_name):
            return False

        extra_args = [f"{customer_name}-clone", "--instance-only"]
        if target:
            target_ip = self.db.get_host(target).ip_addr
        else:
            target = self.db.get_host_name_by_id(target_id)

        extra_args += ["--target", target]

        if (not instance_cmd("copy", customer_name, extra_args) or
            not instance_cmd("start", customer_name) or
            not instance_cmd("start", f"{customer_name}-clone")):
            return False

        ret = True

        if public:
            ret = False
            mqtt_port = self._db.get_max_mqtt_port() + 1
            alias = self.pdns_db.get_customer_record(customer_name)[0][0]
            domain_pattern = re.compile(r".*?\.(?P<domain>-?.*)")
            domain_match = domain_pattern.search(alias)
            if not domain_match:
                self.logger.error("Unable to get domain from '%s' alias", alias)
                return False
            domain = domain_match.group("domain")

            target_id = self.db.get_host_by_ip(target_ip)[0]
            target_name = self.db.get_host_name_by_id(target_id)
            wg_ipaddr = self.db.get_wireguard_info(target_id).ip_addr

            # prepare OSM host for a new customer
            ansible_cmd = [
                "ansible-playbook",
                "-v",
                "-i", f"{target_ip},",
                "-e", f"customer_name={customer_name}-clone",
                "-e", f"mqtt_port={mqtt_port}",
                "-e", f"wg_ipaddr={wg_ipaddr}",
                "-e", f"osm_host={target_name}",
                "-e", f"osm_id={target_id}",
                "-e", f"osm_ip={target_ip}",
                "-e", f"target_domain={domain}",
                f"{DEVTANK_WD}/env/ansible/clone_customer.yaml",
            ]
            try:
                ansible_proc = subprocess.run(ansible_cmd, check=True)
            except subprocess.CalledProcessError as err:
                self.logger.error(err)
                return False
            else:
                ret = ansible_proc.returncode == 0
        return ret

    def move_osm_customer(self, customer_name: str, target_host: str) -> bool:
        ansible_cmd = [
            "ansible-playbook",
            "-i", "localhost,",
            "-e", f"customer_name={customer_name}",
            "-e", f"target_host={target_host}",
            f"{DEVTANK_WD}/env/ansible/mv_customer.yaml"
        ]
        ansible_proc = subprocess.run(ansible_cmd)
        return ansible_proc.returncode == 0

    def upgrade_osm_customers(self, host_name: str) -> bool:
        raise Exception("Not implemented")

    def add_osm_host(self, host_name: str, ip_addr: str, capacity: int) -> int:
        raise Exception("Not implemented")

    def del_osm_host(self, host_name):
        raise Exception("Not implemented")

    def get_customer_passwords(self, customer_name):
        if osm_host := self.find_osm_host_of(customer_name):
            return osm_host.get_osm_customer_passwords(customer_name)
        return {}

    def get_wg_info(self, host_name: str) -> Dict[str, str]:
        try:
            osm_host_id = self.db.get_host(host_name)[0]
        except TypeError:
            return {}

        if osm_host_id:
            wg_key, wg_ipaddr = self.db.get_wireguard_info(osm_host_id)
            return {"wg_key": wg_key, "wg_ipaddr": wg_ipaddr}
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

    def add_osm_alerts_contact(self, customer_name: str, email: str) -> int:
        return (
            os.EX_OK
            if self._osm_orch.add_osm_alerts_contact(customer_name, email)
            else os.EX_UNAVAILABLE
        )

    def list_osm_alerts_contacts(self):
        contacts = self._osm_orch.list_osm_alerts_contacts()
        # header
        print(f"{'Customer':<20} | {'E-mail':<40} | {'UUID':<36}")
        print(f"{'-'*20}-+-{'-'*40}-+-{'-'*36}")
        for contact in contacts:
            name, uuid, email = contact
            print(f"{name:<20} | {email:<40} | {uuid:<36}")

    def clone_osm_container(
        self, src: str, target: Union[str, None] = None, pub: str = "",
     ) -> int:
        if target and self.test_osm_host(target) > os.EX_OK:
            return os.EX_CONFIG

        return os.EX_OK if self._osm_orch.clone_container(
            src, target, True if pub.lower() in ("yes", "y",) else False
        ) else os.EX_UNAVAILABLE

    def move_osm_customer(self, customer_name: str, host_name: str) -> int:
        if self._osm_orch.move_osm_customer(customer_name, host_name):
            return os.EX_OK
        else:
            return os.EX_UNAVAILABLE

    def upgrade_osm_customers(self, host_name: str) -> int:
        if self._osm_orch.upgrade_osm_customers(host_name):
            return os.EX_OK
        return os.EX_UNAVAILABLE

    def add_osm_host(self, host_name):
        raise Exception("Not implemented")

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

    def test_osm_host(self, host_name) -> int:
        cmd = ["incus", "cluster", "show", host_name]
        incus_proc = subprocess.run(
            cmd,
            capture_output=True,
            text = True
        )
        if incus_proc.returncode != 0:
            self.logger.error(incus_proc.stderr.strip())
            return os.EX_CONFIG

        url_pattern = re.compile(r"(\w?http[s]?:\/\/)(.*)(:\d+)")
        status = {}
        targets = ("status", "message", "url")
        for line in incus_proc.stdout.splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                if k in targets:
                    if k == "url":
                        v = re.sub(url_pattern, r'\2', v)
                    status[k.strip()]=v.strip()

        print(
            f"{host_name} [{status['url']}]: {status['status']} "
            f"({status['message']})"
        )
        return os.EX_OK if status['status'] == "Online" else os.EX_CONFIG

    def list_hosts(self):
        osm_hosts = self._osm_orch.list_hosts()
        print("Hosts:")
        for osm_host in osm_hosts:
            print(
                f"\tHost: {osm_host.name}: capacity: "
                f"{len(osm_host.customers)}/{osm_host.capacity}"
            )
        return os.EX_OK

    def list_host_customers(self, host_name):
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
            port = self._osm_orch.db.get_customer_port(customer)
            print(f"\tCustomer: {customer} (MQTT:{port})")
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
        if wg_info := self._osm_orch.get_wg_info(host_name):
            key_len = len(wg_info['wg_key'])
            addr_len = len(wg_info['wg_ipaddr'])
            print(f"{'Public Key': <{key_len}} | {'IP address': <{addr_len}}")
            print(f"{'-' * key_len}-+-{'-' * addr_len}")
            print(f"{wg_info['wg_key']} | {wg_info['wg_ipaddr']}")
            return os.EX_OK
        self.logger.warning(f"Unable to get WG info for host {host_name}")
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
        grafana_exists = osm_host.ssh_command(
            f"ping -c1 {db_config['grafana_url']}"
        )
        if not grafana_exists:
            print("Cannot ping domain. Exiting")
            return os.EX_CONFIG
        return os.EX_OK

    def add_dashboards(
        self, customer_name: str, config: str, cert: Union[str, None] = None
    ) -> int:
        if self._validate_grafana_config(customer_name, config) == os.EX_OK:
            grafana_cmd = [
                "python3",
                "/srv/osm-lxc/lib/grafana_api_client/grafana_api_client.py",
                "add",
                config,
            ]
            if cert:
                grafana_cmd += ["-c", cert]
            grafana_proc = subprocess.Popen(
                grafana_cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE
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

    def del_dashboards(
        self, customer_name: str, config: str, cert: Union[str, None] = None
    ) -> int:
        if self._validate_grafana_config(customer_name, config) == os.EX_OK:
            grafana_cmd = [
                "python3",
                "/srv/osm-lxc/lib/grafana_api_client/grafana_api_client.py",
                "delete",
                config,
            ]
            if cert:
                grafana_cmd += ["-c", cert]
            grafana_proc = subprocess.Popen(
                grafana_cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE
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

    def _transfer_files(
            self, cmd: str, customer_name: str, src: str, dst: str
    ) -> bool:
        if not cmd in ("pull", "push"):
            self.logger.error("Unsupported command given: '%s'", cmd)
            return False

        if cmd == "pull":
            tmp = src
            src = dst
            dst = tmp

        flags = ["-p", "-r"]
        incus_cmd = ["incus", "file", cmd]
        target = [src, f"{customer_name}/{dst}"]
        incus_cmd += target if cmd == "push" else target[::-1]
        incus_cmd += flags

        incus_proc = subprocess.run(incus_cmd)
        return incus_proc.returncode == 0

    def push_file_or_directory(
        self, customer_name: str, src: str, dest: str
    ) -> int:
        return os.EX_OK if self._transfer_files(
            "push", customer_name, src, dest
        ) else os.EX_CONFIG


    def pull_file_or_directory(
        self, customer_name: str, src: str, dest: str
    ) -> int:
        return os.EX_OK if self._transfer_files(
            "pull", customer_name, src, dest
        ) else os.EX_CONFIG

    def get_mosquitto_sub_cmd(self, customer_name: str):
        osm_host = self._osm_orch.find_osm_host_of(customer_name)
        if not osm_host:
            self.logger.warning(f'No osm host for customer "{customer_name}"')
            return os.EX_CONFIG
        mqtt_port = osm_host.get_osm_customer_mqtt_port(customer_name)
        domains = osm_host.get_osm_customer_domains(customer_name)
        pws = osm_host.get_osm_customer_passwords(customer_name)
        mqtt_domain = None
        for domain in domains:
            if domain.find("-mqtt.") != -1:
                mqtt_domain = domain
                break
        if not mqtt_domain:
            self.logger.warning(
                f'No mqtt domain found for customer "{customer_name}"'
            )
            return os.EX_CONFIG
        mqtt_login = pws.get("Mosquitto")
        if not mqtt_login:
            self.logger.warning(
                f'No mqtt login found for customer "{customer_name}"'
            )
            return os.EX_CONFIG
        user, pw = list(mqtt_login.items())[0]
        print(
            "mosquitto_sub --cafile /etc/ssl/certs/ca-certificates.crt -h "
            f"{mqtt_domain} -p {mqtt_port} -t 'osm/#' -u {user} -P '{pw}'"
        )
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
            logging.error(
                "Error position: %s:%s", mark.line + 1, mark.column + 1
            )

    osm_orch = osm_orchestrator_t(config)
    cli_obj = cli_osm_orchestrator_t(osm_orch)

    cmd_entry = namedtuple("cmd_entry", ["help", "func"])

    commands = {
        "add_host": cmd_entry(
            "add_host <name> <ip_addr> <capacity> : Add host to OSM system",
            cli_obj.add_osm_host,
        ),
        "del_host": cmd_entry(
            "del_host <name> : Remove host from OSM system",
            cli_obj.del_osm_host,
        ),
        "find_host": cmd_entry(
            "find_host <name> : Find host of given customer in OSM system",
            cli_obj.find_osm_host_of,
        ),
        "test_host": cmd_entry(
            "test_host <name> : Test access to OSM Host", cli_obj.test_osm_host
        ),
        "add_customer": cmd_entry(
            "add_customer <name> : Add customer to OSM system",
            cli_obj.add_osm_customer,
        ),
        "del_customer": cmd_entry(
            "del_customer <name> : Remove customer from OSM system",
            cli_obj.del_osm_customer,
        ),
        "add_alerts_contact": cmd_entry(
            "add_alerts_contact <custome name> <email>: "
            "Add customer contact for alerts",
            cli_obj.add_osm_alerts_contact,
        ),
        "list_alerts_contacts": cmd_entry(
            "list_alerts_contacts: Print existing customer contacts",
            cli_obj.list_osm_alerts_contacts
        ),
        "clone_container": cmd_entry(
            "clone_container <name> [<target>] [<public>]: "
            "Create container <name> copy <name>-clone on [<target>] OSM host. "
            "If [public] is set to '[<yes|y>]', the nginx configuration is "
            "generated",
            cli_obj.clone_osm_container,
        ),
        "mv_customer": cmd_entry(
            "mv_customer <customer name> <host name>: "
            "Move customer to OSM host",
            cli_obj.move_osm_customer,
        ),
        "upgrade_customers": cmd_entry(
            "upgrade_customers <host name>: Upgrade existing customers on the "
            "OSM host",
            cli_obj.upgrade_osm_customers,
        ),
        "list_hosts": cmd_entry(
            "list_hosts : Lists OSM Hosts in system", cli_obj.list_hosts
        ),
        "list_host_customers": cmd_entry(
            "list_host_customers <name> : Lists customers on OSM Host",
            cli_obj.list_host_customers,
        ),
        "list_customers": cmd_entry(
            "list_customers : Lists all customers on all OSM Hosts",
            cli_obj.list_customers,
        ),
        "get_customer_passwords": cmd_entry(
            "get_customer_passwords <name>: "
            "Return dictionary of passwords for a specified customer",
            cli_obj.customer_passwords,
        ),
        "get_wg_info": cmd_entry(
            "get_wg_info <name> : Get WireGuard key and IP address",
            cli_obj.wg_info,
        ),
        "push_file_or_directory": cmd_entry(
            "push_file_or_directory <customer> <source> <destination>: "
            "Push a file or a directory to a specified destination on a "
            "customer container",
            cli_obj.push_file_or_directory,
        ),
        "pull_file_or_directory": cmd_entry(
            "pull_file_or_directory <customer> <source> <destination>: "
            "Pull a file or a directory to a specified destination from a "
            "customer container",
            cli_obj.pull_file_or_directory,
        ),
        "add_dashboards": cmd_entry(
            "add_dashboards <customer_name> <config> <cert>: Creates "
            "Grafana dashboard solution for customer with optional cert",
            cli_obj.add_dashboards,
        ),
        "del_dashboards": cmd_entry(
            "del_dashboards <customer_name> <config> <cert>: Deletes "
            "Grafana dashboard solution for customer with optional cert",
            cli_obj.del_dashboards,
        ),
        "mqtt_listener": cmd_entry(
            "mqtt_listener <customer_name>: Get MQTT listener cmd "
            "Returns bash line of mosquitto_sub to listen to customer",
            cli_obj.get_mosquitto_sub_cmd,
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
                if (
                    filename == "__init__.py"
                    or filename.endswith("base.py")
                    or not filename.endswith(".py")
                ):
                    continue
                module_path = os.path.join(path_to_plugin, filename)
                spec = importlib.util.spec_from_file_location(
                    filename, module_path
                )
                try:
                    module = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(module)
                except Exception as e:
                    print(
                        f"Error importing module {filename} with \
                        error {e}"
                    )
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
                    print(
                        f"Could not get plugin API version with \
                        error: {e}"
                    )
                if ver and ver == 1:
                    try:
                        cmds = cls.get_commands()
                        commands.update(cmds)
                    except Exception as e:
                        print(
                            f"Could not import commands from {cls} \
                            with error: {e}"
                        )
                else:
                    print(
                        f"Unsupported plugin version: {ver} from \
                        plugin {cls}"
                    )

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
        f"Command: {args.command[0]} : "
        f'Result: {"FAILED" if exit_code else "SUCCESS"}'
    )
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
