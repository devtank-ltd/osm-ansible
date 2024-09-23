# -*- mode: sh; sh-shell: bash; -*-
config="$1"

parse_config "$config"

# Reset arguments
set --

# [[ -f "$config" ]] && {
#     info "Loading : $config"
#     source "$config"
# } || die "No config given."

edo mkdir -p "$HOSTS_DIR"


[[ -n "$VOSM_HOSTBR" ]] || die "VOSM_HOSTBR not set"
[[ -n "$HOSTS_DIR" ]] || die "HOSTS_DIR not set"
[[ -n "$OSM_HOST_COUNT" ]] || die "OSM_HOST_COUNT not set"
[[ -n "$OSMCUSTOMER_COUNT" ]] || die "OSMCUSTOMER_COUNT not set"
[[ -n "$OSM_SUBNET" ]] || die "OSM_SUBNET is not set"

source env_common.sh

echo "========================================="
info "Save environment"
save_env
