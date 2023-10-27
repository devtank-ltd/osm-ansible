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


parser = argparse.ArgumentParser(description='OSM Servers Orchestrator')
parser.add_argument('-v','--verbose', help='Info log information', action='store_true')
parser.add_argument('-d','--debug', help='Debug log information', action='store_true')
parser.add_argument('command', type=str, help='command followed by arguments.', nargs='*')



def is_not_empty(f, msg):
    d = f.read()
    if len(d) != 0:
        logging.error(f"UNEXPECTED FILE DATA : {d}")
        return True


class osm_host(object):
    def __init__(self, db, db_id):
        pass

    @property
    def name(self):
        pass

    @property
    def username(self):
        pass

    @property
    def ip_addr(self):
        pass

    def find_free_mqtt_port(self):
        pass

    def _add_customer_to_database(self, customer_name, mqtt_port):
        pass

    def _del_customer_to_database(self, customer_name):
        pass

    def get_ssh(self):
        current = self._ssh_ref()
        if current:
            return current
        ssh = paramiko.SSHClient()
        ssh.load_host_keys('~/.ssh/known_hosts')
        ssh.load_host_keys(os.environ["HOME"] + '/.ssh/known_hosts')
        ssh.connect(self.ip_addr, username=self.username)
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




class osm_orchestrator(object):
    def __init__(self, db):
        self.db = db

    def _find_free_osm_host(self):
        pass

    def _find_osm_host(self, customer_name):
        pass

    def add_osm_customer(self, customer_name):
        osm_host = self._find_osm_host(customer_name)
        if osm_host:
            logging.warning(f'Already customer "{customer_name}"')
            return os.EX_NOTFOUND

        osm_host = self.find_free_osm_host()
        if osm_host.add_osm_customer(customer_name):
            return os.EX_OK
        else:
            return os.EX_UNAVAILABLE

    def del_osm_customer(self, customer_name):
        osm_host = self._find_osm_host(customer_name)
        if not find_osm_host:
            logging.warning(f'No customer "{customer_name}"')
            return os.EX_NOTFOUND
        if osm_host.del_osm_customer(customer_name):
            return os.EX_OK
        else:
            return os.EX_UNAVAILABLE


def main():
    config = yaml.safe_load(open("config.yaml"))

    db = pymysql.connect(database=config["dbname"],
                         user=config["user"],
                         password=config["password"],
                         host=config["host"],
                         port=config.get("port", 3306),
                         connect_timeout=10)

    osm_orch = osm_orchestrator(db)

    cmd_entry = namedtuple("cmd_entry", ["help", "func"])

    commands = {"add" : cmd_entry("add <customer> : Add customer to OSM system", osm_orch.add_osm_customer),
                "del" : cmd_entry("del <customer> : Remove customer from OSM system", osm_orch.del_osm_customer)}

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
    sys.exit(cmd_func(args.command[1:]))


if __name__ == "__main__":
    main()



