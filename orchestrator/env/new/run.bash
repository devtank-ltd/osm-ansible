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
    source "${INC}/functions"

    declare -gA ARGS=([action]="" [config]="")
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
    init "$@"

    if [[ "${ARGS[action]}" == "setup" ]]; then
        build_env "${ARGS[config]}"
        do_setup
        do_start_hosts OSM_HOSTS
        do_post_setup
        print_status
    elif [[ "${ARGS[action]}" == "shutdown" ]]; then
        do_shutdown_environment
    fi
}

main "$@"
