#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

init() {
    local INC
    INC="$(dirname "$(readlink -f "$0")")/inc"

    # shellcheck disable=SC1091
    source "${INC}/vars"
    # shellcheck disable=SC1091
    source "${INC}/cloud-init_generators.bash"
    # shellcheck disable=SC1091
    source "${INC}/functions.bash"
    # shellcheck disable=SC1091
    source "${INC}/print_functions.bash"
    # shellcheck disable=SC1091
    source "${INC}/network_functions.bash"
    # shellcheck disable=SC1091
    source "${INC}/ansible_functions.bash"

    declare -gA ARGS=([action]="" [config]="" [run_tests]="no" [hosts_dir]="")
    process_args "$@"

    if [[ ! -v STY || -z "$STY" ]]; then
        warn "Not running in GNU Screen"
        yesno "Continue?"
    fi

    for gr in "netdev" "kvm"; do
        if ! in_group "$gr"; then
            die "The user '${USER}' not in '${gr}' group. Unable to proceed"
        fi
    done

    declare -gA OSM_HOSTS
    export OSM_HOSTS
    check_pkgs
}

main() {
    init "$@"

    if [[ "${ARGS[action]}" == "setup" ]]; then
        build_env "${ARGS[config]}"
        trap 'mrproper' INT TERM ERR HUP EXIT
        trap 'handle_orphaned_vms' INT TERM ERR HUP
        do_setup
        do_post_setup
        print_status
    elif [[ "${ARGS[action]}" == "run" ]]; then
        do_run_environment
    elif [[ "${ARGS[action]}" == "shutdown" ]]; then
        do_shutdown_environment

    fi

    if [[ "${ARGS[run_tests]}" == "yes" && "${ARGS[action]}" != "shutdown" ]]; then
        if is_env_running; then
            run_tests
        else
            die "The OSM environment is not running. Please start or build it."
        fi
    fi
}

main "$@"
