#!/usr/bin/env bash

set -e

container="$1"
shell_cmd="$2"

[[ -n "$container" ]] || { echo "No container provided." >&2; exit 1; }
[[ -n "$shell_cmd" ]] || { echo "No shell command provided." >&2; exit 1; }

lxc-attach -n "$container" -- bash -c "$shell_cmd"
