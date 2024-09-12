# COLOURS
RED="$(tput setaf 9)"
GREEN="$(tput setaf 2)"
YELLOW="$(tput setaf 11)"
RESET="$(tput setaf 15)"

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
    # not implemented yet
    :
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
