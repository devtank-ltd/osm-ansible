#!/usr/bin/env python
# coding: utf-8

import argparse
from cryptography.fernet import Fernet

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
        "-k",
        "--private-key",
        type=str,
        required=True,
        help="private key",
    )
    args = parser.parse_args()
    key = args.private_key.encode("utf-8")
    msg = args.string.encode("utf-8")
    crypt = Fernet(key)
    if args.encrypt:
        print(crypt.encrypt(msg).decode("utf-8"))
    elif args.decrypt:
        print(crypt.decrypt(msg).decode("utf-8"))
