#! /usr/bin/env python3
import paramiko
import argparse
import weakref
import logging
import pymysql
import crcmod
import yaml
import sys
import os
from collections import namedtuple


SQL_ADD_HOST = "INSERT INTO osm_hosts (name, ip_addr, capacity, active_since) VALUES(%s, %s, %u, UNIX_TIMESTAMP())"
SQL_DEL_HOST = "UPDATE osm_hosts SET active_before=UNIX_TIMESTAMP() WHERE id=%u"
SQL_GET_HOST = "SELECT id FROM osm_hosts WHERE name=%s"

SQL_GET_HOST_BY_CUSTOMER = "SELECT osm_customers.osm_hosts_id FROM osm_customers WHERE name=%s"

SQL_HOST_GET_NAME     = "SELECT name FROM osm_hosts WHERE id=%u"
SQL_HOST_GET_IP_ADDR  = "SELECT ip_addr FROM osm_hosts WHERE id=%u"
SQL_HOST_GET_CAPACITY = "SELECT capacity FROM osm_hosts WHERE id=%u"

SQL_HOST_GET_USED_MQTT_PORTS = "SELECT host_mqtt_port FROM osm_customers WHERE osm_hosts_id=%u"
SQL_HOST_GET_CUSTOMERS = "SELECT name FROM osm_customers WHERE osm_hosts_id=%u AND active_before is NULL"

SQL_ADD_CUSTOMER = "INSERT INTO osm_customers (osm_hosts_id, name, host_mqtt_port, active_since) VALUES(%u, %s, %u, UNIX_TIMESTAMP())"
SQL_DEL_CUSTOMER = "UPDATE osm_customers SET active_before=UNIX_TIMESTAMP() WHERE osm_hosts_id=%u AND name=%s"

SQL_GET_FREEST_HOST = """
SELECT id, (
(SELECT COUNT(osm_customers.id) FROM osm_customers WHERE active_before IS NULL AND osm_hosts_id = osm_hosts.id) / capacity
) AS utilization FROM osm_hosts
ORDER BY utilization ASC LIMIT 1
"""

SQL_PDNS_ADD_CUSTOMER = """
INSERT INTO records
(domain_id, name, content, type, ttl, prio)
VALUES(%u, %s, %s, 'CNAME', 10800, 0)
"""

SQL_PDNS_DEL_CUSTOMER = """
DELETE FROM records WHERE domain_id=%u AND name=%s AND content=%s
"""


parser = argparse.ArgumentParser(description='OSM Servers Orchestrator')
parser.add_argument('-v','--verbose', help='Info log information', action='store_true')
parser.add_argument('-d','--debug', help='Debug log information', action='store_true')
parser.add_argument('command', type=str, help='command followed by arguments.', nargs='*')


crc8_func = crcmod.predefined.mkCrcFun('crc-8')


def is_not_empty(f, msg):
    d = f.read()
    if len(d) != 0:
        logging.error(f"UNEXPECTED FILE DATA : {d}")
        return True


def get_ssh_connect(ip_addr):
    ssh = paramiko.SSHClient()
    ssh.load_host_keys(os.environ["HOME"] + '/.ssh/known_hosts')
    try:
        ssh.connect(ip_addr, username="osm_orchestrator", timeout=2)
        return ssh
    except TimeoutError:
        return None
    except paramiko.ssh_exception.AuthenticationException:
        return None
    except OSError:
        return None


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
    def __init__(self, orchestrator, db_id):
        self._orchestrator = orchestrator
        self.db = orchestrator.db
        self.id = db_id
        self._name = None
        self._ip_addr = None
        self._capacity = None

    def _look_by_id(self, cmd):
        return do_db_single_query(self.db, cmd, (self.id,))

    @property
    def name(self):
        if not self._name:
            self._name = self._look_by_id(SQL_HOST_GET_NAME)
        return self._name

    @property
    def ip_addr(self):
        if not self._ip_addr:
            self._ip_addr = self._look_by_id(SQL_HOST_GET_IP_ADDR)
        return self._ip_addr

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
        self._orchestrator.add_dns_customer(self, customer_name)

    def _del_customer_to_database(self, customer_name):
        do_db_update(self.db, SQL_DEL_CUSTOMER, (self.id, customer_name))
        self._orchestrator.del_dns_customer(self, customer_name)

    def get_ssh(self):
        current = self._ssh_ref()
        if current:
            return current
        ssh = get_ssh_connect(self.ip_addr)
        self._ssh_ref = weakref.ref(ssh)
        return ssh

    def can_ping_customer(self, customer_name):
        ssh = self.get_ssh()
        ssh.exec_command(f"ping -c1 {customer_name}-svr")
        rc = ssh.recv_exit_status()
        return rc == 0


    def add_osm_customer(self, customer_name, timeout=4):

        mqtt_port = self._find_free_mqtt_port(customer_name)

        ssh = self.get_ssh()

        ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command(f'/srv/osm-lxc/ansible/do-create-container.sh "{customer_name}" {mqtt_port}')
        error_code = ssh.recv_exit_status()
        if error_code:
            logging.error(f"Container creation failed : {os.strerror(error_code)}")
            return False
        if is_not_empty(ssh_stderr, "No stderr expected"):
            return False

        start_end = time.monotonic() + timeout

        while time.monotonic() < start_end:
            if self.can_ping_customer(customer_name):
                self._add_customer_to_database(customer_name, mqtt_port)
                return True

        logging.error(f'Unable to create customer "{customer_name} on OSM-Host". Please debug OSM-Host {self.name}.')
        return False


    def del_osm_customer(self, customer_name, timeout=4):
        ssh = self.get_ssh()

        ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command(f'/srv/osm-lxc/ansible/do-delete-container.sh "{customer_name}"')
        error_code = ssh.recv_exit_status()
        if error_code:
            logging.error(f"Container creation failed : {os.strerror(error_code)}")
            return False
        if is_not_empty(ssh_stderr, "No stderr expected"):
            return False

        start_end = time.monotonic() + timeout

        while time.monotonic() < start_end:
            if not self.can_ping_customer(customer_name):
                self._del_customer_to_database(customer_name)
                return True

        logging.error(f'Unable to delete customer "{customer_name} from OSM-Host". Please debug OSM-Host {self.name}.')
        return False

    @property
    def customers(self):
        rows = do_db_query(self.db, SQL_HOST_GET_CUSTOMERS, (self.id,))
        return [row[0] for row in rows]



class osm_orchestrator_t(object):
    def __init__(self, config):
        self._config = config
        self._db = None
        self._pdns_db = None

    @property
    def db(self):
        if not self._db:
            orch_config = config["orchestrator"]
            self._db = pymysql.connect(**orch_config, connect_timeout=10)
        return self._db

    @property
    def pdns_db(self):
        if not self._pdns_db:
            pdns_config = config["pdns"]
            self._pdns_db = pymysql.connect(**pdns_config, connect_timeout=10)
        return self._pdns_db

    def add_dns_customer(self, osm_host, customer):
        domain_id = self._config["pdns_domain_id"]
        domain = self._config["pdns_domain"]

        do_db_insert(self._pdns_db, SQL_PDNS_ADD_CUSTOMER,
                     (domain_id, "%s.%s" % (customer, domain), osm_host.ip_addr))
        do_db_insert(self._pdns_db, SQL_PDNS_ADD_CUSTOMER,
                     (domain_id, "%s-chirpstack.%s" % (customer, domain), osm_host.ip_addr))
        do_db_insert(self._pdns_db, SQL_PDNS_ADD_CUSTOMER,
                     (domain_id, "%s-influx.%s" % (customer, domain), osm_host.ip_addr))

    def del_dns_customer(self, osm_host, customer):
        domain_id = self._config["pdns_domain_id"]
        domain = self._config["pdns_domain"]

        do_db_update(self._pdns_db, SQL_PDNS_DEL_CUSTOMER,
                     (domain_id, "%s.%s" % (customer, domain), osm_host.ip_addr))
        do_db_update(self._pdns_db, SQL_PDNS_DEL_CUSTOMER,
                     (domain_id, "%s-chirpstack.%s" % (customer, domain), osm_host.ip_addr))
        do_db_update(self._pdns_db, SQL_PDNS_DEL_CUSTOMER,
                     (domain_id, "%s-influx.%s" % (customer, domain), osm_host.ip_addr))

    def _find_free_osm_host(self):
        row = do_db_single_query(self.db, SQL_GET_FREEST_HOST, (customer_name,))
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
            logging.warning(f'Already customer "{customer_name}"')
            return os.EX_CONFIG

        osm_host = self.find_free_osm_host()
        if osm_host.add_osm_customer(customer_name):
            return os.EX_OK
        else:
            return os.EX_UNAVAILABLE

    def del_osm_customer(self, customer_name):
        osm_host = self._find_osm_host_of(customer_name)
        if not osm_host:
            logging.warning(f'No customer "{customer_name}"')
            return os.EX_NOTFOUND
        if osm_host.del_osm_customer(customer_name):
            return os.EX_OK
        else:
            return os.EX_UNAVAILABLE

    def add_osm_host(self, host_name, ip_addr, capcaity):
        osm_host = self.find_osm_host(host_name)
        if osm_host:
            logging.warning(f'Already osm host of name "{host_name}"')
            return os.EX_CONFIG

        ssh = get_ssh_connect(ip_addr)
        if not ssh:
            logging.error(f"Unable to ssh in as osmorchestrator to host {host_name}.")
            return os.EX_CONFIG

        ssh.exec_command(f'ls /srv/osm-lxc/ansible/')
        error_code = ssh.recv_exit_status()
        if error_code:
            logging.error(f"Unable to find expected ansible tools.")

        do_db_insert(self.db, SQL_ADD_HOST, (host_name, ip_addr, capcaity))

    def del_osm_host(self, host_name):
        osm_host = self.find_osm_host(host_name)
        if not osm_host:
            logging.warning(f'No osm host of name "{host_name}"')
            return os.EX_CONFIG

        customers = osm_host.customers
        if customers:
            customers = ",".join(customers)
            logging.warning(f'Host of name "{host_name}" has active customers: {customers}')
            return os.EX_CONFIG

        do_db_update(self.db, SQL_DEL_HOST, (osm_host.id))



def main():
    if not os.path.exists("config.yaml"):
        logging.error("No config.yaml found.")
        sys.exit(os.EX_NOTFOUND)

    config = yaml.safe_load(open("config.yaml"))

    osm_orch = osm_orchestrator_t(config)

    cmd_entry = namedtuple("cmd_entry", ["help", "func"])

    commands = {"add_host" : cmd_entry("add_host <name> <ip_addr> <capacity> : Add host to OSM system", osm_orch.add_osm_host),
                "del_host" : cmd_entry("del_host <name> : Remove host from OSM system", osm_orch.del_osm_host),
                "add_customer" : cmd_entry("add_customer <name> : Add customer to OSM system", osm_orch.add_osm_customer),
                "del_customer" : cmd_entry("del_customer <name> : Remove customer from OSM system", osm_orch.del_osm_customer)}

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
    sys.exit(cmd_func(*func_args))


if __name__ == "__main__":
    main()
