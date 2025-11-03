#!/usr/bin/env bash

declare -A VMS
declare -a PIDS

has() {
    local want="$1"
    local x
    shift

    for x in "$@"; do
        [[ "$x" == "$want" ]] && return 0
    done
    return 1
}

for mon in $(find ~+ -type s -name "monitor.sock" -print); do
    name="${mon%%/monitor.sock}"
    name="${name##*/}"
    path="${mon%/*}"
    VMS["$name"]="$path"
done

mapfile -t PIDS < <(pgrep -U "$USER" qemu)

for name in "${!VMS[@]}"; do
    qemu_pid="${VMS[$name]}/qemu.pid"
    if [[ -e "$qemu_pid" ]]; then
        mapfile -t < "$qemu_pid" pid
        if has "$pid" "${PIDS[@]}"; then
            echo "'$name' VM [${pid}] is running..."
            kill -s SIGTERM "$pid"
        fi
    fi
done

wait_for=5
retries=3
counter=0

for name in "${!VMS[@]}"; do
    while [[ -u "${VMS[$name]}/qemu.pid" ]]; do
        mapfile -t < "$qemu_pid" pid
        sleep $wait_for
        counter=$(( counter + 1 ))
        if (( counter > retries )); then
            kill -s SIGKILL "$pid"
            if ps "$pid"; then
                echo "'$pid' is still running!"
                exit 1
            fi
        fi
    done
done

echo "clean up 'hosts' directory..."
rm -rf "${WORKSPACE}/orchestrator/env/hosts"
