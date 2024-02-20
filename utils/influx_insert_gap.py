#!/usr/bin/env python3

"""
This script will insert JSON data extracted with influx_extract_gap.py into an Influx 2 database
"""

import argparse
import collections
import multiprocessing
import json
import numbers
import signal
import sys

from datetime import datetime
from influxdb_client import InfluxDBClient
from influxdb_client.client.exceptions import InfluxDBError

lck = multiprocessing.Lock()

# Thread-safe print
def print_ts(*args, **kwargs):
    lck.acquire()
    print(*args, **kwargs, flush=True)
    lck.release()

# Debugging decorator
def print_json_result(func):
    def wrapper(*args, **kwargs):
        output = func(*args, **kwargs)
        if cmd_args.debug_outfile is not None:
            print_ts(json.dumps(output), '\n' * 3, file=cmd_args.debug_outfile)
        return output
    return wrapper

""" Converts an Influx 1 JSON table to Influx 2 dictionary format """
@print_json_result
def convert_table_to_influx2(table):
    ret = []
    for measurement in table['series']:
        for x in measurement['values']:
            entry = collections.defaultdict(dict)
            entry['measurement'] = measurement['name']
            for column, value in zip(measurement['columns'], x):
                if isinstance(value, numbers.Number):
                    value = float(value)
                if column == 'time':
                    entry['time'] = int(value)
                elif column == 'value':
                    entry['fields']['value'] = value
                elif column == 'f_cnt':
                    entry['fields']['f_cnt'] = value
                else:
                    entry['tags'][column] = value
            ret.append(entry)

    return ret

def process_table(table):
    print_ts(f"Writing {table['series'][0]['name']}...")
    try:
        write_api.write(cmd_args.bucket, cmd_args.org, convert_table_to_influx2(table))
    except InfluxDBError as e:
        print_ts(f"ERROR writing table {table['series'][0]['name']}: {e}")
        return
    print_ts(f"Table {table['series'][0]['name']} written successfully")

def signal_handler(signum, frame):
    print_ts(f"Caught signal {signum} at frame {frame}.\nExiting...")
    sys.exit()


signal.signal(signal.SIGINT, signal_handler)

# Define args
parser = argparse.ArgumentParser()
parser.add_argument("token")
parser.add_argument("org")
parser.add_argument("bucket")

parser.add_argument(
    "--input", "-i",
    nargs='?',
    type=argparse.FileType('r'),
    default=sys.stdin,
    help="JSON input file. Defaults to stdin."
)

parser.add_argument(
    "--influx-url",
    "-n",
    default="http://localhost:8086",
    help="Influx server URL. Defaults to http://localhost:8086"
)

parser.add_argument(
    "--debug-outfile",
    "-d",
    type=argparse.FileType('w'),
    help="File to write debug info to"
)

cmd_args = parser.parse_args()

# Connect to InfluxDB
client = InfluxDBClient(
    url=cmd_args.influx_url,
    token=cmd_args.token,
    org=cmd_args.org
)

write_api = client.write_api()

print(f"Loading {cmd_args.input.name}...")
input_data = json.load(cmd_args.input)

with multiprocessing.Pool(processes=multiprocessing.cpu_count()) as pool:
    pool.map(process_table, input_data)

