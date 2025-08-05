#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

init() {
    local SRC="${BASH_SOURCE[0]}"
    local INC

    INC="$(cd -P "$(dirname "$SRC")" >/dev/null 2>&1 && pwd)/inc"

    # shellcheck disable=SC1091
    source "${INC}/vars"
    # shellcheck disable=SC1091
    source "${INC}/functions.bash"
    # shellcheck disable=SC1091
    source "${INC}/print_functions.bash"
    # shellcheck disable=SC1091
    source "${INC}/network_functions.bash"
    # shellcheck disable=SC1091
    source "${INC}/ansible_functions.bash"

    declare -gA ARGS=([action]="" [config]="" [run_tests]="no")
    process_args "$@"

    if [[ ! -v STY || -z "$STY" ]]; then
        warn "Not running in GNU Screen"
        yesno "Continue?"
    fi

    declare -gA BASE_HOSTS=(
        # skip orchestrator as the vosmhost0 is the main host now
        # [orchestrator]="preseed-ext4.cfg"
        ["${VOSM_HOST}0"]="preseed-btrfs.cfg"
    )
    declare -gA OSM_HOSTS

    export BASE_HOSTS
    export OSM_HOSTS
}

main() {
    # store PIDs of nc and python webserver here
    pids="$(mktemp --suffix=-devtank)"

    init "$@"

    if [[ "${ARGS[action]}" == "setup" ]]; then
        build_env "${ARGS[config]}"
        trap 'mrproper' INT TERM ERR HUP EXIT
        trap 'handle_orphaned_vms' INT TERM ERR HUP
        do_setup "$pids"
        do_start_hosts OSM_HOSTS
        do_post_setup
        print_status
        [[ "${ARGS[run_tests]}" == "yes" ]] && run_tests
    elif [[ "${ARGS[action]}" == "run" ]]; then
        do_run_environment
    elif [[ "${ARGS[action]}" == "shutdown" ]]; then
        do_shutdown_environment
    fi
}

main "$@"
