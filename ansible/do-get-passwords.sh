#!/usr/bin/env bash

set -e

customer_name="$1"

[ -n "$customer_name" ] || { echo "No customer name given."; exit -1; }

lxc-attach -n ${customer_name}-svr -- bash -c 'cat /root/passwords.json' > /tmp/${customer_name}_passwords.json
