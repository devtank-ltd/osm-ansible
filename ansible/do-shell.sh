#!/usr/bin/env bash

set -e

shell_cmd="$1"

[[ -n "$shell_cmd" ]] || { echo "No shell command provided." >&2; exit 1; }

eval "$shell_cmd"
