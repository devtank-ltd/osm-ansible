#! /usr/bin/env python3
import paramiko
import argparse
import weakref
import logging
import pymysql
import yaml
import sys
import os
from collections import namedtuple


SQL_ADD_HOST = "INSERT INTO osm_hosts (name, ip_addr, username, capacity) VALUES(%s, %s, %s, %u)"
SQL_DEL_HOST = "DELETE FROM osm_hosts WHERE id=%u"
SQL_GET_HOST = "SELECT id FROM osm_hosts WHERE name=%s"

SQL_GET_HOST_BY_CUSTOMER = "SELECT osm_customers.osm_hosts_id FROM osm_customers WHERE name=%s"

SQL_HOST_GET_NAME     = "SELECT name FROM osm_hosts WHERE id=%u"
SQL_HOST_GET_IP_ADDR  = "SELECT ip_addr FROM osm_hosts WHERE id=%u"
SQL_HOST_GET_USERNAME = "SELECT username FROM osm_hosts WHERE id=%u"
SQL_HOST_GET_CAPACITY = "SELECT capacity FROM osm_hosts WHERE id=%u"

SQL_ADD_CUSTOMER = "INSERT INTO osm_customers (osm_hosts_id, name, host_mqtt_port, active_since) VALUES(%u, %s, %u, UNIX_TIMESTAMP())"
SQL_DEL_CUSTOMER = "UPDATE osm_customers SET active_before=UNIX_TIMESTAMP() WHERE osm_hosts_id=%u AND name=%s"

SQL_GET_FREEST_HOST = """
SELECT id, (
(SELECT COUNT(osm_customers.id) FROM osm_customers WHERE active_before IS NULL AND osm_hosts_id = osm_hosts.id) / capacity
) AS utilization FROM osm_hosts
ORDER BY utilization ASC LIMIT 1
"""


parser = argparse.ArgumentParser(description='OSM Servers Orchestrator')
parser.add_argument('-v','--verbose', help='Info log information', action='store_true')
parser.add_argument('-d','--debug', help='Debug log information', action='store_true')
parser.add_argument('command', type=str, help='command followed by arguments.', nargs='*')



def is_not_empty(f, msg):
    d = f.read()
    if len(d) != 0:
        logging.error(f"UNEXPECTED FILE DATA : {d}")
        return True


def get_ssh_connect(ip_addr, username):
    ssh = paramiko.SSHClient()
    ssh.load_host_keys(os.environ["HOME"] + '/.ssh/known_hosts')
    try:
        ssh.connect(ip_addr, username=username, timeout=2)
        return ssh
    except TimeoutError:
        return None
    except paramiko.ssh_exception.AuthenticationException:
        return None
    except OSError:
        return None


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
    def __init__(self, db, db_id):
        self.db = db
        self.id = db_id
        self._name = None
        self._ip_addr = None
        self._username = None
        self._capacity = None

    def _look_by_id(self, cmd):
        return do_db_single_query(self.db, cmd, (self.id,))

    @property
    def name(self):
        if self._name is None:
            self._name = self._look_by_id(SQL_HOST_GET_NAME)
        return self._name

    @property
    def username(self):
        if self._username is None:
            self._username = self._look_by_id(SQL_HOST_GET_USERNAME)
        return self._username

    @property
    def ip_addr(self):
        if self._ip_addr is None:
            self._ip_addr = self._look_by_id(SQL_HOST_GET_IP_ADDR)
        return self._ip_addr

    @property
    def capacity(self):
        if self._capacity is None:
            self._capacity = self._look_by_id(SQL_HOST_GET_CAPACITY)
        return self._capacity

    def find_free_mqtt_port(self):
        pass

    def _add_customer_to_database(self, customer_name, mqtt_port):
        do_db_insert(self.db, SQL_ADD_CUSTOMER, (self.id, customer_name, mqtt_port))

    def _del_customer_to_database(self, customer_name):
        do_db_update(self.db, SQL_DEL_CUSTOMER, (self.id, customer_name))

    def get_ssh(self):
        current = self._ssh_ref()
        if current:
            return current
        ssh = get_ssh_connect(self.ip_addr, self.username)
        self._ssh_ref = weakref.ref(ssh)
        return ssh

    def can_ping_customer(self, customer_name):
        ssh = self.get_ssh()
        ssh.exec_command(f"ping -c1 {customer_name}-svr")
        rc = ssh.recv_exit_status()
        return rc == 0


    def add_osm_customer(self, customer_name, timeout=4):

        mqtt_port = self.find_free_mqtt_port()

        ssh = self.get_ssh()

        ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command(f"echo {mqtt_port} >> ~/remote_requests/new_host/{customer_name}")
        if is_not_empty(ssh_stdout, "No stdout expected") or \
           is_not_empty(ssh_stderr, "No stderr expected"):
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

        ssh_stdin, ssh_stdout, ssh_stderr = ssh.exec_command(f"touch ~/remote_requests/del_host/{customer_name}")
        if is_not_empty(ssh_stdout, "No stdout expected") or \
           is_not_empty(ssh_stderr, "No stderr expected"):
               return False

        start_end = time.monotonic() + timeout

        while time.monotonic() < start_end:
            if not self.can_ping_customer(customer_name):
                self._del_customer_to_database(customer_name)
                return True

        logging.error(f'Unable to delete customer "{customer_name} from OSM-Host". Please debug OSM-Host {self.name}.')
        return False




class osm_orchestrator_t(object):
    def __init__(self, db):
        self.db = db

    def _find_free_osm_host(self):
        row = do_db_single_query(self.db, SQL_GET_FREEST_HOST, (customer_name,))
        if row:
            osm_host = osm_host_t(self.db, row[0])
            if osm_host:
                utilization = row[1]
                used = int(utilization * osm_host.capacity)
                if used < osm_host.capacity:
                    return osm_host

    def _find_osm_host_of(self, customer_name):
        row = do_db_single_query(self.db, SQL_GET_HOST_BY_CUSTOMER, (customer_name,))
        if row:
            return osm_host_t(self.db, row[0])

    def find_osm_host(self, name):
        row = do_db_single_query(self.db, SQL_GET_HOST, (name,))
        if row:
            return osm_host_t(self.db, row[0])

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

    def add_osm_host(self, host_name, ip_addr, username, capcaity):
        osm_host = self.find_osm_host(host_name)
        if osm_host:
            logging.warning(f'Already osm host of name "{host_name}"')
            return os.EX_CONFIG

        ssh = get_ssh_connect(ip_addr, username)
        if not ssh:
            logging.error("Unable to ssh in on given username.")
            return os.EX_CONFIG
        del ssh

        do_db_insert(self.db, SQL_ADD_HOST, (host_name, ip_addr, username, capcaity))

    def del_osm_host(self, host_name):
        osm_host = self.find_osm_host(host_name)
        if not osm_host:
            logging.warning(f'No osm host of name "{host_name}"')
            return os.EX_CONFIG

        do_db_update(self.db, SQL_DEL_HOST, (osm_host.id))



def main():
    config = yaml.safe_load(open("config.yaml"))

    db = pymysql.connect(database=config["dbname"],
                         user=config["user"],
                         password=config["password"],
                         host=config["host"],
                         port=config.get("port", 3306),
                         connect_timeout=10)

    osm_orch = osm_orchestrator_t(db)

    cmd_entry = namedtuple("cmd_entry", ["help", "func"])

    commands = {"add_host" : cmd_entry("add_host <name> <ip_addr> <username> <capacity> : Add host to OSM system", osm_orch.add_osm_host),
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



