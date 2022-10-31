#!/usr/bin/env python3

"""
This script will extract Influx 1 data from two given points into a JSON file.
"""

import argparse
import json
import sys

from datetime import datetime
from influxdb import InfluxDBClient

# Define args
parser = argparse.ArgumentParser()

# Positionals
parser.add_argument("username")
parser.add_argument("password")
parser.add_argument("database")
parser.add_argument(
    "timestamp_from",
    help='Beginning of data in format YYYY-MM-DDTHH:MM:SSZ'
)
parser.add_argument(
    "timestamp_to",
    help='End of data in format YYYY-MM-DDTHH:MM:SSZ'
)
# Optionals
parser.add_argument(
    "--output", "-o",
    nargs='?',
    type=argparse.FileType('w'),
    default=sys.stdout,
    help="JSON output file. Defaults to stdout."
)
parser.add_argument(
    "--influx-host",
    "-n",
    default="localhost",
    help="Influx server hostname. Defaults to localhost."
)
parser.add_argument(
    "--influx-port",
    "-p",
    default=8086,
    help="Influx server port. Defaults to 8086."
)
parser.add_argument(
    "--ssl",
    "-s",
    default=False,
    help="Enable SSL. Default is false."
)
parser.add_argument(
    "--ssl-verify",
    "-v",
    default=False,
    help="Verify SSL. Default is false."
)
args = parser.parse_args()

# Parse given timestamps
time_fmt = "%Y-%m-%dT%H:%M:%SZ"
try:
    timestamp_from = datetime.strptime(args.timestamp_from, time_fmt)
    timestamp_to = datetime.strptime(args.timestamp_to, time_fmt)
except ValueError as e:
    print(f"Cannot parse timestamp: {e}", file=sys.stderr)
    sys.exit(-1)

# Connect to InfluxDB
client = InfluxDBClient(
    host=args.influx_host,
    port=args.influx_port,
    username=args.username,
    password=args.password,
    ssl=args.ssl,
    verify_ssl=args.ssl_verify
)

client.switch_database(args.database)
measurements = client.get_list_measurements()

# Loop through each table and export the time range to JSON
influxql_from = timestamp_from.strftime(time_fmt)
influxql_to = timestamp_to.strftime(time_fmt)

jsondata = []

for measurement in measurements:
    results = client.query(f"SELECT * FROM \"{measurement['name']}\" WHERE time >= '{influxql_from}' AND time <= '{influxql_to}';", epoch='ns')
    if "series" in results.raw.keys():
        jsondata.append(results.raw)

json.dump(jsondata, args.output)
