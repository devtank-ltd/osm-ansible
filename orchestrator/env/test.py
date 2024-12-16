#!/usr/bin/env python3

import pexpect
import re
import argparse
import logging
import sys

import time

from pathlib import Path

log = logging.getLogger(__name__)
logging.basicConfig(format='%(levelname)s: %(message)s', level=logging.DEBUG)

parser = argparse.ArgumentParser()
parser.add_argument("-c", "--config", help="Network configuration")


if __name__ == "__main__":

    args = parser.parse_args()
    if not args.config:
        log.error("The network configuration config file is not set")
        sys.exit(1)

    config = Path(args.config)
    if not config.exists():
        log.error(f"Unable to find network configuration file '{config.name}'")
        sys.exit(1)

    e = pexpect.spawn("/bin/bash", ["setup_network.sh", str(config.resolve())])
    while True:
        log.debug("BEFORE: %s", e.before)
        n = e.expect([".*Continue?.*", ".*proceed?.*", ".*correct?.*", "GET /preseed.cfg.*\r\n"])
        if n == 0 or n == 1 or n == 2:
            e.sendline("y")
        log.debug("AFTER: %s", e.after)
        if n == 3:
            log.debug("Web server spawned. Breaking...")
            break

    stages = [
        ".*Creating OSM Orchestrator\r\n",
        ".*Creating virtual OSM_HOSTs\r\n",
        ".*Creating template OSM Host,.*\r\n",
        ".*Copy OSM Host.*to.*\r\n",
        ".*Start network\r\n",
        ".*Network started, adding OSM HOSTs to Orchestrator\r\n",
        ".*Start Pebble ACME\r\n",
        ".*Network started, adding OSM customers to Orchestrator\r\n",
        ".*"
    ]
    while True:
        e.expect(stages, timeout=1200)
        if n >= 0 or n < 7:
            log.debug(stages[n])

        if n == 7:
            log.debug(stages[n])
            break

    # while True:
    #     print(f"<<<<<<<<<< {e.before}")
    #     e.expect(".*")
    #     print(f">>>>>>>>>> {e.after}")
    #     time.sleep(5)


    e.expect(pexpect.EOF)
    print(e.before)
