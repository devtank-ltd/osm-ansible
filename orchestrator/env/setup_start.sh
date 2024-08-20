config=$1

# Reset arguments
set --

if [ -f "$config" ]
then
  echo "Loading : $config"
  source "$config"
else
  echo "No config given."
  exit -1
fi

mkdir -p "$HOSTS_DIR"

[ -n "$VOSM_HOSTBR" ] || { echo VOSM_HOSTBR not set; exit -1; }
[ -n "$HOSTS_DIR" ] || { echo HOSTS_DIR not set; exit -1; }
[ -n "$OSM_HOST_COUNT" ] || { echo OSM_HOST_COUNT not set; exit -1; }
[ -n "$OSMCUSTOMER_COUNT" ] || { echo OSMCUSTOMER_COUNT not set; exit -1; }
[ -n "$OSM_SUBNET" ] || { echo OSM_SUBNET is not set; exit -1; }

source env_common.sh

echo "========================================="
echo "Save environment"
save_env
