# -*- mode: sh; sh-shell: bash; -*-

# COLOURS
RED="$(tput setaf 9)"
GREEN="$(tput setaf 2)"
YELLOW="$(tput setaf 11)"
RESET="$(tput setaf 15)"

# mandatory config variables
readonly CONF_VARS=(
    "HOSTS_DIR"
    "OSM_HOST_COUNT"
    "OSMCUSTOMER_COUNT"
    "VOSM_HOSTBR"
    "OSM_SUBNET"
    "OSM_DOMAIN"
    "MAIL_SMTP_HOST"
    "MAIL_SMTP_USER"
    "MAIL_SMTP_PASSWORD"
    "MAIL_RECIPIENTS"
)

die() {
    echo "${RED}FATAL:${RESET} $*"
    exit 1
}

msg() {
    echo "$*"
}

info() {
    echo "${GREEN}INFO:${RESET} $*"
}

warn() {
    echo "${YELLOW}WARN:${RESET} $*"
}

edo() {
    # TODO: add verbose flag
    echo "$@" 1>&2
    "$@" || exit 2
}

yesno() {
    [[ -t 0 ]] || return 0
    local resp
    read -r -p "$1 [y/N] " resp
    [[ "$resp" == [yY] ]] || exit 1
}

_check_osm_vars() {
    local -n ref=$1
    local var="$2"

    if [[ -v ref[$var] && -n "${ref[$var]}" ]]; then
        info "$var=${ref[$var]}"
        return
    else
        warn "The variable '$var' is not set"
        return 1
    fi
}

parse_config() {
    local conf_file=
    declare -A vars
    local OLD_IFS="$IFS"
    local pattern='^([^[:space:]]+)[[:space:]]*=[[:space:]]*"?([^"]+)"?$'

    conf_file="$1"
    [[ -z "$conf_file" ]] && die "No configuration file."
    [[ ! -f "$conf_file" ]] && die "The configuration file '$conf_file' does not exist."

    while IFS= read -r line; do
        if [[ "$line" =~ $pattern ]]; then
            vars[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
        fi
    done < "$conf_file"

    # restore IFS
    IFS="$OLD_IFS"

    # verify mandatory config variables
    for v in "${CONF_VARS[@]}"; do
        if ! _check_osm_vars vars "$v"; then
            die "Unable to proceed without 'HOSTS_DIR' variable"
        fi
    done

    yesno "Is configuration correct? "

    # make global variables
    for k in "${!vars[@]}"; do
        declare -g "$k"="${vars[$k]}"
    done
}

configure_qemu_vm() {
    :
}

configure_network() {
    :
}

get_ip4_addr() {
    local net_interface="$1"
    local ipaddr=""

    ipaddr="$(ip addr show dev "$net_interface" | sed -rn 's/.*inet (.*)\/.*/\1/p')"
    [[ -z "$ipaddr" ]] && die "Unable to get IP address for '$net_interface' interface"

    echo "$ipaddr"
}

download_file() {
    local src="$1"
    local dst="$2"

    pushd "$dst" >/dev/null 2>&1
    info "Downloading '${src}' to '${dst}'"
    edo curl -OL --retry 3 "$src"
    popd >/dev/null 2>&1
}

run_qemu_vm() {
    local host_dir="$1"; shift
    local bridge_name="$1"; shift
    local bridge_mac="$1"; shift
    local vm_disk="$1"; shift
    local bios_mem="$1"; shift
    local extra_args=( "$@" )

    [[ -z "$host_dir"  ]] && die "The host directory is missing."
    [[ -z "$bridge_name" ]] && die "The bridge name is missing."
    if [[ -z "$bridge_mac" ]]; then
        die "The bridge MAC address is missing."
    elif [[ ! "$bridge_mac" =~ ^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$ ]]; then
        die "Wrong bridge MAC address format."
    fi
    [[ -z "$vm_disk" ]] && die "The VM disk is missing."
    [[ -z "$bios_mem" ]] && die "The BIOS is missing."

    local qemu_params=(
        -enable-kvm
        -nographic
        -m 4G
        -cpu host
        -monitor "unix:${host_dir}/monitor.sock,server,nowait"
        -serial "unix:${host_dir}/console.sock,server,nowait"
        -device "virtio-scsi-pci,id=scsi"
        -nic "bridge,br=${bridge_name},model=virtio-net-pci,mac=$bridge_mac"
        -drive "file=${vm_disk},format=qcow2,if=virtio"
        -drive "if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.fd,readonly=on"
        -drive "if=pflash,format=raw,unit=1,file=${bios_mem}"
        "${extra_args[@]}"
    )
    info "Run QEMU Virtual machine"
    qemu-system-x86_64 "${qemu_params[@]}"
}

run_ansible() {
    :
}
