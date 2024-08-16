#! /usr/bin/env python3
import paramiko
import argparse
import weakref
import logging
import pymysql
import crcmod
import time
import yaml
import sys
import os
from collections import namedtuple


SQL_ADD_HOST = "INSERT INTO osm_hosts (name, ip_addr, capacity, active_since) VALUES(%s, %s, %s, UNIX_TIMESTAMP())"
SQL_DEL_HOST = "UPDATE osm_hosts SET active_before=UNIX_TIMESTAMP() WHERE id=%s"
SQL_GET_HOST = "SELECT id FROM osm_hosts WHERE name=%s AND active_before IS NULL"
SQL_LIST_HOSTS = "SELECT id, name FROM osm_hosts WHERE active_before IS NULL"

SQL_GET_HOST_BY_CUSTOMER = "SELECT osm_customers.osm_hosts_id FROM osm_customers WHERE name=%s AND active_before IS NULL"

SQL_HOST_GET_NAME     = "SELECT name FROM osm_hosts WHERE id=%s"
SQL_HOST_GET_IP_ADDR  = "SELECT ip_addr FROM osm_hosts WHERE id=%s"
SQL_HOST_GET_CAPACITY = "SELECT capacity FROM osm_hosts WHERE id=%s"

SQL_HOST_GET_USED_MQTT_PORTS = "SELECT host_mqtt_port FROM osm_customers WHERE osm_hosts_id=%s"
SQL_HOST_GET_CUSTOMERS = "SELECT name FROM osm_customers WHERE osm_hosts_id=%s AND active_before is NULL"

SQL_ADD_CUSTOMER = "INSERT INTO osm_customers (osm_hosts_id, name, host_mqtt_port, active_since) VALUES(%s, %s, %s, UNIX_TIMESTAMP())"
SQL_DEL_CUSTOMER = "UPDATE osm_customers SET active_before=UNIX_TIMESTAMP() WHERE osm_hosts_id=%s AND name=%s"

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
parser.add_argument('-v','--verbose', help='Info log information', action='store_true')
parser.add_argument('-d','--debug', help='Debug log information', action='store_true')
parser.add_argument('command', type=str, help='command followed by arguments.', nargs='*')


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



class osm_host_t(object):
    def __init__(self, orchestrator, db_id, name=None, ip_addr=None, capacity=None):
        self._orchestrator = orchestrator
        self.id = db_id
        self._name = name
        self._ip_addr = ip_addr
        self._capacity = capacity
        self._ssh_ref = None
        self._dns_entry = None
        self.logger = logging.getLogger(self.name)

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

    def _find_free_mqtt_port(self, customer_name):
        rows = do_db_query(self.db, SQL_HOST_GET_USED_MQTT_PORTS, (self.id,))
        ports = [ row[0] for row in rows ]
        port = 8883 + crc8_func(customer_name.encode())
        while port in ports:
            port += 1
        return port

    def _add_customer_to_database(self, customer_name, mqtt_port):
        do_db_insert(self.db, SQL_ADD_CUSTOMER, (self.id, customer_name, mqtt_port))
        domain_id = self.config["pdns_domain_id"]
        domain = self.config["pdns_domain"]

        do_db_insert(self.pdns_db, SQL_PDNS_ADD_CUSTOMER,
                     (domain_id, "%s.%s" % (customer_name, domain), self.dns_entry))
        do_db_insert(self.pdns_db, SQL_PDNS_ADD_CUSTOMER,
                     (domain_id, "%s-chirpstack.%s" % (customer_name, domain), self.dns_entry))
        do_db_insert(self.pdns_db, SQL_PDNS_ADD_CUSTOMER,
                     (domain_id, "%s-influx.%s" % (customer_name, domain), self.dns_entry))
        do_db_insert(self.pdns_db, SQL_PDNS_ADD_CUSTOMER,
                     (domain_id, "%s-mqtt.%s" % (customer_name, domain), self.dns_entry))

    def _del_customer_to_database(self, customer_name):
        do_db_update(self.db, SQL_DEL_CUSTOMER, (self.id, customer_name))
        domain_id = self.config["pdns_domain_id"]
        domain = self.config["pdns_domain"]

        do_db_update(self.pdns_db, SQL_PDNS_DEL_CUSTOMER,
                     (domain_id, "%s.%s" % (customer_name, domain), self.dns_entry))
        do_db_update(self.pdns_db, SQL_PDNS_DEL_CUSTOMER,
                     (domain_id, "%s-chirpstack.%s" % (customer_name, domain), self.dns_entry))
        do_db_update(self.pdns_db, SQL_PDNS_DEL_CUSTOMER,
                     (domain_id, "%s-influx.%s" % (customer_name, domain), self.dns_entry))
        do_db_update(self.pdns_db, SQL_PDNS_DEL_CUSTOMER,
                     (domain_id, "%s-mqtt.%s" % (customer_name, domain), self.dns_entry))

    def get_ssh(self):
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
            self.logger.error(f"Timeout connecting to {self.name} ({self.ip_addr}).")
            ssh = None
        except paramiko.ssh_exception.AuthenticationException as e:
            self.logger.error(f"Authentication fail connecting to {self.name} ({self.ip_addr}): {e}")
            ssh = None
        except OSError as e:
            self.logger.error(f"OS Error connecting to {self.name} ({self.ip_addr}): {e}")
            ssh = None
        if not ssh:
            return None
        self._ssh_ref = weakref.ref(ssh)
        return ssh

    def ssh_command(self, cmd):
        ssh = self.get_ssh()
        if not ssh:
            return False
        ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command(cmd)
        for line in ssh_stdout:
            self.logger.debug(line.rstrip())
        error_code = ssh_stdout.channel.recv_exit_status()
        if error_code:
            self.logger.error(f"Command '{cmd}' failed : {error_code}:{os.strerror(error_code)}")
            for line in ssh_stderr:
                self.logger.error(line.rstrip())
            return False
        return True

    def can_ping_customer_container(self, customer_name):
        return self.ssh_command(f"ping -c1 {customer_name}-svr")

    def can_ping_customer_grafana(self, customer_name):
        domain = self.config["pdns_domain"]
        return self.ssh_command(f"ping -c1 {customer_name}.{domain}")

    def add_osm_customer(self, customer_name, timeout=4):

        mqtt_port = self._find_free_mqtt_port(customer_name)

        if not mqtt_port:
            self.logger.error("No free MQTT found.")
            return False

        self._add_customer_to_database(customer_name, mqtt_port) # Needs DNS entry before Anisble called, for LetsEncrypt

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
        if self.ssh_command(f'sudo /srv/osm-lxc/ansible/do-create-container.sh "{customer_name}" {mqtt_port}'):
            start_end = time.monotonic() + timeout
            while time.monotonic() < start_end:
                if self.can_ping_customer_container(customer_name):
                    failed = False
            if failed:
                self.logger.error("Container creation ping")
        else:
            self.logger.error("Container creation failed")

        if failed:
            self._del_customer_to_database(customer_name)
            self.ssh_command(f'sudo /srv/osm-lxc/ansible/do-delete-container.sh "{customer_name}" {mqtt_port}')
            return False
        return True


    def del_osm_customer(self, customer_name, timeout=4):

        if not self.ssh_command(f'sudo /srv/osm-lxc/ansible/do-delete-container.sh "{customer_name}"'):
            self.logger.error(f"Container creation failed")
            return False

        start_end = time.monotonic() + timeout

        while time.monotonic() < start_end:
            if not self.can_ping_customer_container(customer_name):
                self._del_customer_to_database(customer_name)
                return True

        self.logger.error(f'Unable to delete customer "{customer_name} from OSM-Host". Please debug OSM-Host {self.name}.')
        return False

    @property
    def customers(self):
        rows = do_db_query(self.db, SQL_HOST_GET_CUSTOMERS, (self.id,))
        return [row[0] for row in rows]



class osm_orchestrator_t(object):
    def __init__(self, config):
        self.config = config
        orch_config = self.config["orchestrator"]
        self._db = pymysql.connect(**orch_config, connect_timeout=10)
        pdns_config = self.config["pdns"]
        self._pdns_db = pymysql.connect(**pdns_config, connect_timeout=10)
        self.logger = logging.getLogger("OSMORCH")

    @property
    def db(self):
        return self._db

    @property
    def pdns_db(self):
        return self._pdns_db

    def add_dns_host(self, osm_host, ip_addr):
        domain_id = self.config["pdns_domain_id"]
        domain = self.config["pdns_domain"]
        do_db_update(self._pdns_db, SQL_PDNS_ADD_HOST, (domain_id, "%s.%s" % (osm_host, domain), ip_addr))

    def _find_free_osm_host(self):
        row = do_db_single_query(self.db, SQL_GET_FREEST_HOST, tuple())
        if row:
            osm_host = osm_host_t(self, row[0])
            if osm_host:
                utilization = row[1]
                used = int(utilization * osm_host.capacity)
                if used < osm_host.capacity:
                    return osm_host

    def _find_osm_host_of(self, customer_name):
        row = do_db_single_query(self.db, SQL_GET_HOST_BY_CUSTOMER, (customer_name,))
        if row:
            return osm_host_t(self, row[0])

    def find_osm_host(self, name):
        row = do_db_single_query(self.db, SQL_GET_HOST, (name,))
        if row:
            return osm_host_t(self, row[0])

    def add_osm_customer(self, customer_name):
        osm_host = self._find_osm_host_of(customer_name)
        if osm_host:
            self.logger.warning(f'Already customer "{customer_name}"')
            return os.EX_CONFIG

        osm_host = self._find_free_osm_host()
        if not osm_host:
            self.logger.error(f"No free OSM host for customer {customer_name}")
            return os.EX_UNAVAILABLE
        if osm_host.add_osm_customer(customer_name):
            return os.EX_OK
        else:
            return os.EX_UNAVAILABLE

    def del_osm_customer(self, customer_name):
        osm_host = self._find_osm_host_of(customer_name)
        if not osm_host:
            self.logger.warning(f'No customer "{customer_name}"')
            return os.EX_UNAVAILABLE
        if osm_host.del_osm_customer(customer_name):
            return os.EX_OK
        else:
            return os.EX_UNAVAILABLE

    def add_osm_host(self, host_name, ip_addr, capcaity):
        try:
            capcaity = int(capcaity)
        except ValueError:
            self.logger.error(f'Invalid number "{capcaity}" for capcaity')
            return os.EX_CONFIG

        if capcaity < 1:
            self.logger.error(f'Invalid number "{capcaity}" for capcaity')
            return os.EX_CONFIG

        osm_host = self.find_osm_host(host_name)
        if osm_host:
            self.logger.warning(f'Already osm host of name "{host_name}"')
            return os.EX_CONFIG

        osm_host = osm_host_t(self, 0, host_name, ip_addr, capcaity)

        if not osm_host.get_ssh():
            self.logger.error(f"Unable to ssh in as osm_orchestrator to host {host_name}.")
            return os.EX_CONFIG

        if not osm_host.ssh_command('ls /srv/osm-lxc/ansible/'):
            self.logger.error(f"Unable to find expected ansible tools.")
            return os.EX_CONFIG

        do_db_insert(self.db, SQL_ADD_HOST, (host_name, ip_addr, capcaity))
        self.add_dns_host(host_name, ip_addr)
        return os.EX_OK

    def del_osm_host(self, host_name):
        osm_host = self.find_osm_host(host_name)
        if not osm_host:
            self.logger.warning(f'No osm host of name "{host_name}"')
            return os.EX_CONFIG

        customers = osm_host.customers
        if customers:
            customers = ",".join(customers)
            self.logger.warning(f'Host of name "{host_name}" has active customers: {customers}')
            return os.EX_CONFIG

        domain_id = self.config["pdns_domain_id"]
        do_db_update(self.db, SQL_DEL_HOST, (osm_host.id))
        do_db_update(self.pdns_db, SQL_PDNS_DEL_HOST,
             (domain_id, osm_host.dns_entry, osm_host.ip_addr))
        return os.EX_OK

    def find_osm_host_of(self, customer_name):
        osm_host = self._find_osm_host_of(customer_name)
        if osm_host:
            print("Found on host : %s" % osm_host.name)
            return os.EX_OK
        else:
            self.logger.warning(f'No customer "{customer_name}"')
            return os.EX_CONFIG

    def list_hosts(self):
        rows = do_db_query(self.db, SQL_LIST_HOSTS, ())
        print("Hosts:")
        for row in rows:
            osm_host = osm_host_t(self, row[0])
            print(f"\tHost: {osm_host.name}: capacity: {len(osm_host.customers)}/{osm_host.capacity}")

    def list_host_customers(self,  host_name):
        osm_host = self.find_osm_host(host_name)
        if not osm_host:
            self.logger.warning(f'No osm host of name "{host_name}"')
            return os.EX_CONFIG
        customers = osm_host.customers
        print(f"Host: {host_name}: capacity: {len(customers)}/{osm_host.capacity}")
        for customer in customers:
            print(f"\tCustomer: {customer}")


def main():
    self_path = os.path.abspath(__file__)
    os.chdir(os.path.dirname(self_path))

    if not os.path.exists("config.yaml"):
        logging.error("No config.yaml found.")
        sys.exit(os.EX_UNAVAILABLE)

    config = yaml.safe_load(open("config.yaml"))

    osm_orch = osm_orchestrator_t(config)

    cmd_entry = namedtuple("cmd_entry", ["help", "func"])

    commands = {"add_host" : cmd_entry("add_host <name> <ip_addr> <capacity> : Add host to OSM system", osm_orch.add_osm_host),
                "del_host" : cmd_entry("del_host <name> : Remove host from OSM system", osm_orch.del_osm_host),
                "find_host" : cmd_entry("find_host <name> : Find host of given customer in OSM system", osm_orch.find_osm_host_of),
                "add_customer" : cmd_entry("add_customer <name> : Add customer to OSM system", osm_orch.add_osm_customer),
                "del_customer" : cmd_entry("del_customer <name> : Remove customer from OSM system", osm_orch.del_osm_customer),
                "list_hosts" : cmd_entry("list_hosts : Lists OSM Hosts in system", osm_orch.list_hosts),
                "list_host_customers" : cmd_entry("list_host_customers <name> : Lists customers on OSM Host", osm_orch.list_host_customers)
                }

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
    print("Command: %s : Result: %s" % (args.command[0], "FAILED" if exit_code else "SUCCESS"))
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
