#!/usr/bin/env python

import json
import logging

from argparse import ArgumentParser
from pathlib import Path

LOG = logging.getLogger(__name__)
logging.basicConfig(
    format="%(levelname)-7s %(filename)s: %(message)s", level=logging.DEBUG
)

try:
    from crypt import MasterCrypt
except ModuleNotFoundError as err:
    LOG.error("Unable to import module %s", err)


def encrypt_passwords(d: dict, crypt: MasterCrypt) -> None:
    if isinstance(d, dict):
        for key, val in d.items():
            if isinstance(val, str):
                d[key] = crypt.encrypt(val)
            else:
                encrypt_passwords(val, crypt)


def pwd_update(src: str, dst: str | None, crypt: MasterCrypt) -> None:
    src_file: Path = Path(src)
    dst_file: Path = Path(dst) if dst else Path(src)
    pwds: dict = {}

    if not src_file.exists():
        LOG.error(f"The source file {src} does not exist")
        return

    with open(src_file) as s:
        try:
            pwds = json.load(s)
        except json.JSONDecodeError as err:
            LOG.error("Not valid JSON file '%s': '%s'", src_file, err)
            return

    encrypt_passwords(pwds, crypt)

    with open(dst_file, "w", encoding="utf-8") as d:
        try:
            json.dump(pwds, d, indent=4)
        except json.JSONDecodeError as err:
            LOG.error("Something went wrong: %s", err)
            return


if __name__ == "__main__":
    parser = ArgumentParser(
        description="""
        Update plain passwords with encrypted ones in the source file and
        write them to the destination file.
        """
    )
    parser.add_argument(
        "-s", "--source", type=str, required=True, help="Source passwords file"
    )
    parser.add_argument(
        "-d", "--dest", type=str, help="Updated file with encrypted passwords"
    )
    parser.add_argument(
        "-p", "--password",
        type=str, required=True, help="password",
    )
    parser.add_argument(
        "-k", "--private-key", type=str, required=True, help="private key",
    )
    parser.add_argument(
        "-v", "--initialization-vector", type=str, required=True,
        help="Initialization vector",
    )
    parser.add_argument("-S", "--salt", type=str, required=True, help="salt")
    args = parser.parse_args()

    if not args.dest:
        LOG.warning(
            "The '%s' will be overwritten with encrypted passwords"
            % args.source
        )
    data = (
        f'{{"password": "{args.password}", "priv key": "{args.private_key}", '
        f'"iv": "{args.initialization_vector}", "salt": "{args.salt}"}}'
    )
    crypt = MasterCrypt(data)
    pwd_update(args.source, args.dest, crypt)
