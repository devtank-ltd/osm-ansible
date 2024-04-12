#! /bin/bash

PRESEED=preseed-plain.cfg

if [ -z "$OSMHOST" ]; then OSMHOST=debian; fi

./setup_common.sh
