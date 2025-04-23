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
        [orchestrator]="preseed-ext4.cfg"
        ["${VOSM_HOST}0"]="preseed-btrfs.cfg"
    )
    declare -gA OSM_HOSTS

    export BASE_HOSTS
    export OSM_HOSTS
}

main() {
    init "$@"

    if [[ "${ARGS[action]}" == "setup" ]]; then
        do_setup "${ARGS[config]}"
        start_hosts OSM_HOSTS
        do_post_setup
    elif [[ "${ARGS[action]}" == "shutdown" ]]; then
        do_shutdown_environment
    fi
}

main "$@"
