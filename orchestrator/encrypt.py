#!/usr/bin/env python
# coding: utf-8

import argparse
from crypt import MasterCrypt

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    excl_grp = parser.add_mutually_exclusive_group()
    parser.add_argument("string", type=str, help="String to (de/en)crypt")
    excl_grp.add_argument(
        "-d", "--decrypt", action="store_true", help="decrypt string"
    )
    excl_grp.add_argument(
        "-e", "--encrypt", action="store_true", help="encrypt string"
    )
    parser.add_argument(
        "-p",
        "--password",
        type=str,
        required=True,
        help="password",
    )
    parser.add_argument(
        "-k",
        "--private-key",
        type=str,
        required=True,
        help="private key",
    )
    parser.add_argument(
        "-v",
        "--initialization-vector",
        type=str,
        required=True,
        help="Initialization vector",
    )
    parser.add_argument(
        "-s",
        "--salt",
        type=str,
        required=True,
        help="salt",
    )

    args = parser.parse_args()
    data = (
        f'{{"password": "{args.password}", "priv key": "{args.private_key}", '
        f'"iv": "{args.initialization_vector}", "salt": "{args.salt}"}}'
    )
    crypt = MasterCrypt(data)
    if args.encrypt:
        print(crypt.encrypt(args.string))
    elif args.decrypt:
        print(crypt.decrypt(args.string))
