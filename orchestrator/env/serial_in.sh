#! /bin/bash

. common.sh

socat STDIO,cfmakeraw UNIX:$HOST_DIR/console.sock
