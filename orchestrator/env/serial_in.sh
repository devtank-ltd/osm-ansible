#! /bin/bash

. common.sh

socat STDIO,cfmakeraw UNIX:$OSMHOST.console.sock
