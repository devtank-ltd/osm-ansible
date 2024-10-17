#!/usr/bin/env python
# coding: utf-8

import base64
import hashlib
import json
import logging
import secrets
import sys

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Union

PASSWORD_LEN = 32
MASTER_ENCR_FILE = "master.json"

logging.basicConfig(
    format='%(name)s: %(asctime)s: %(message)s',
    # level=logging.DEBUG
)
log = logging.getLogger("crypt")


@dataclass
class CryptData():
    salt: bytes
    password: str
    key: bytes
    iv: bytes


@dataclass
class Passwords():
    influx: Dict[str, str] = field(default_factory=lambda: {})
    influx_token: str = field(default="")
    postgres: str = field(default="")
    mosquitto: Dict[str, str] = field(default_factory=lambda: {})
    grafana: Dict[str, str] = field(default_factory=lambda: {})


class Crypt:
    ENCODING = "utf-8"

    def __init__(
            self, password: str, priv_key: Union[bytes, str] = "",
            iv: Union[bytes, str] = "", salt: Union[bytes, str] = ""
    ):
        # self.pwds = Passwords()
        # TODO: should we generate it by ourselves?
        self.password = password
        self._salt = base64.b64decode(salt) or \
            self._gen_rand_bytes(algorithms.AES.block_size)
        self._init_vector = base64.b64decode(iv) or \
            self._gen_rand_bytes(16)
        self._priv_key = base64.b64decode(priv_key) or hashlib.scrypt(
            self.password.encode(self.ENCODING), salt=self._salt, n=2**14, r=8,
            p=1, dklen=32
        )
        self.data = CryptData(
            self._salt, self.password, self._priv_key, self._init_vector
        )
        self.cipher = Cipher(
            algorithms.AES(self._priv_key),
            modes.CBC(self._init_vector)
        )

    @property
    def encryption_data(self) -> Dict[str, str]:
        return {
            "salt": base64.b64encode(self.data.salt).decode(self.ENCODING),
            "iv": base64.b64encode(self.data.iv).decode(self.ENCODING),
            "priv key": base64.b64encode(self.data.key).decode(self.ENCODING),
            "password": self.password
        }

    def _pad_string(self, string: str) -> str:
        # create 16 bytes block container
        bs = 16
        padding = bs - len(string) % bs
        return string + padding * " "

    def _unpad_string(self, string: str) -> str:
        return string.rstrip()

    def _gen_rand_bytes(self, size: int = 16) -> bytes:
        return secrets.token_bytes(size)

    def encrypt(self, text: str) -> str:
        t = self._pad_string(text).encode(self.ENCODING)
        et = base64.b64encode(
            self.cipher.encryptor().update(t)
        ).decode(self.ENCODING)
        log.debug("%s -> %s" % (text, et))
        return et

    def decrypt(self, text: str) -> str:
        t = base64.b64decode(text.encode(self.ENCODING))
        t = self.cipher.decryptor().update(t)
        dt = self._unpad_string(t.decode(self.ENCODING))
        log.debug("%s -> %s" % (text, dt))
        return dt


class MasterCrypt(Crypt):
    def __init__(self, data: str):
        if Path(data).exists():
            with open(data, "r") as df:
                self.crypt_data = json.load(df)
        else:
            log.info("Assuming that JSON passed as string")
            try:
                self.crypt_data = json.loads(data)
            except json.JSONDecodeError as err:
                log.error(f"Unable to parse JSON data: {err}")
                sys.exit(1)

        super().__init__(
            self.crypt_data["password"],
            self.crypt_data["priv key"],
            self.crypt_data["iv"],
            self.crypt_data["salt"]
        )


if __name__ == "__main__":
    # make master encryption data or print if it was created previously
    master_password = secrets.token_urlsafe(PASSWORD_LEN)
    crypt = Crypt(master_password)
    master_data = crypt.encryption_data
    master_file = Path(MASTER_ENCR_FILE)

    if master_file.exists():
        print(f"The file '{master_file}' exits:")
        contents = master_file.read_text()
        print(contents)

    with open(master_file, "w", encoding=crypt.ENCODING) as f:
        json.dump(master_data, f, ensure_ascii=False, indent=4)
