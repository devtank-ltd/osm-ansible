#! /usr/bin/env python3
import time
import ssl
import logging
import paho.mqtt as paho
import paho.mqtt.client as mqtt
import argparse
import logging
import asyncio
import random
import math
import json

parser = argparse.ArgumentParser(description="Fake OSM")
parser.add_argument("--url", help="Websocket url", type=str, required=True)
parser.add_argument("--user", help="Auth user", type=str, required=True)
parser.add_argument("--osm", help="OSM ID", type=str, default="FAKEOSM")
parser.add_argument(
    "--password", help="Auth password", type=str, required=True
)
parser.add_argument(
    "--count", help="Number of OSM to fake", type=int, default=1
)

logging.basicConfig(level=logging.INFO)

logger = logging.getLogger()

# Name : (Min, Max, noise)
VALUES = {"TMP5" : (20, 40, 4),
          "HUM2" : (20, 60, 4),
          "SND" : (0, 60, 4),
          "LGHT" : (0, 1000, 10),
          "PM25" : (0, 10, 1),
          "PM10": (0, 10, 1),
          "PM4" : (0, 10, 1),
          "PM1" : (0, 10, 1),
          "VOC" : (0, 500, 10),
          }

SEND_INTERVAL = 5
TEST_WAVE_PEROID = 60


class FakeOSM:
    def __init__(self, osm, url, user, password):
        assert url.startswith("wss://"), "Not a valid OSM MQTT URL"

        self._client = mqtt.Client(callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
                                   client_id=osm, transport = "websockets")

        self._client.enable_logger(logger)
        self._client.username_pw_set(user, password=password)
        self._client.on_connect = self._on_connect
        self._client.on_socket_open = self._on_socket_open
        self._client.on_socket_close = self._on_socket_close
        self._client.tls_set(cert_reqs=ssl.CERT_NONE)
        self._client.tls_insecure_set(True)
        self._url = url[len("wss://"):]

        self._test_wave_pos = 0

        self._name = osm
        self._topic = f"osm/{osm}/measurements"
        self._lastsent = 0
        self._connection = 0

    def connect(self):
        if not self._connection:
            logger.info(f"Connecting Fake OSM {self._name} to {self._url}")
            self._connection = 1
            self._client.connect(self._url, 443, 2)

    def _on_connect(self, client, userdata, flags, rc, *args):
        if rc == 0:
            logger.info(f"Connected Fake OSM {self._name}")
            self._connection = 2
        else:
            logger.warning(f"Failed to connect Fake OSM {self._name}")
            self._connection = 0

    def _on_socket_open(self, mqttc, userdata, sock):
        logger.info(f"Got socket for Fake OSM {self._name}")
        loop = asyncio.get_event_loop()
        loop.add_reader(sock, self.loop)

    def _on_socket_close(self, mqttc, userdata, sock):
        logger.info(f"Lost socket for Fake OSM {self._name}")
        loop = asyncio.get_event_loop()
        loop.remove_reader(sock)
        self._connection = 0

    def _send_update(self):

        test_wave = self._test_wave_pos % TEST_WAVE_PEROID
        test_wave = test_wave / TEST_WAVE_PEROID
        test_wave = math.sin(test_wave * math.pi)

        self._test_wave_pos += SEND_INTERVAL

        values = {}

        for k, v in VALUES.items():
            avg = v[0] + (v[1] - v[0]) * test_wave
            values[k] = avg
            values[k+"_min"] = avg - v[2] * random.random()
            values[k+"_max"] = avg + v[2] * random.random()

        payload = {
            "UNIX": int(time.time()),
            "VALUES": values,
            "NAME": self._name,
        }
        payload = json.dumps(payload).encode()
        self._client.publish(self._topic, payload)

    def loop(self):
        self.connect()
        self._client.loop()
        if self._connection > 1:
            now = time.monotonic()
            if now - self._lastsent > SEND_INTERVAL:
                self._lastsent = now
                self._send_update()

    async def run_forever(self):
        await asyncio.sleep(random.randint(0, 5))
        while True:
            self.loop()
            await asyncio.sleep(1)


async def main():
    args = parser.parse_args()

    loop = asyncio.get_running_loop()

    logger.info(f"Creating {args.count} fake OSMs")
    osms = [
        FakeOSM(
            args.osm + ("%02u" % n),
            args.url,
            args.user,
            args.password
        )
        for n in range(args.count)
    ]

    logger.info("Starting main loop")

    loops = [ osm.run_forever() for osm in osms ]
    await asyncio.gather(*loops)


if __name__ == "__main__":
    asyncio.run(main())
