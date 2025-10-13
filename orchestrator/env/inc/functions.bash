# shellcheck disable=SC2317

_check_osm_vars() {
    local -n ref=$1
    local var="$2"

    if [[ ! -v ref[$var] && -z "${ref[$var]}" ]]; then
        warn "The variable '$var' is not set"
        return 1
    fi
}

die() {
    msg "${RED}FATAL:${RESET} $*"
    exit 1
}

edo() {
    echo "${RED}>>>${RESET} $@" 1>&2
    "$@" || exit 2
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
            die "Unable to proceed without '$v' variable"
        elif [[ "${vars[$v]}" =~ \<.*\> ]]; then
            warn "It seems that variable '$v' has default value '${vars[$v]}'"
            yesno "Do you want to proceed? "
        fi
    done

    warn "The following configuration will be used:"
    for v in "${!vars[@]}"; do
        info "${v}=${vars[$v]}"
    done

    yesno "Is this correct? "

    # make global variables
    for k in "${!vars[@]}"; do
        declare -g "$k"="${vars[$k]}"
    done
}

process_args() {
    declare -n a=ARGS           # defined in main()
    local action config hosts_dir

    while (( $# > 0)); do
        case "$1" in
            -h|--help) print_usage ;;
            -a) action="${2:?action is needed}"; shift 2 ;;
            -c) config="${2:?config file is needed}"; shift 2 ;;
            -t|--run-tests) a[run_tests]="yes"; shift ;;
            -d) hosts_dir="${2:-}"; shift 2 ;;

            --action=*) action="${1#*=}"; shift ;;
            --config=*) config="${1#*=}"; shift ;;
            --hosts-dir=*) hosts_dir="${1#*=}"; shift ;;
            -*) die "Unknown option: $1" ;;
            *) echo "Handler: $1"; shift ;;

        esac
    done

    [[ ( ! -v action || -z "$action" ) && "${a[run_tests]}" == "no" ]] && print_usage

    if [[ -v action && ! "$action" =~ (setup|shutdown|run) ]]; then
        die "Only 'setup', 'run' and 'shutdown' actions are supported"
    fi

    a[action]="${action:-}"

    if [[ -v action && "$action" == "setup" ]]; then
        if [[ ! -v config || -z "$config" ]]; then
            die "Need a config file to proceed"
        fi
        [[ "${a[run_tests]}" == "yes" ]] && die "You need to build environment first"
        [[ ! -e "$config" ]] && die "Unable to find '$config' configuration file"
        a[config]="$config"
    fi

    if [[ -v action && "$action" =~ (shutdown|run) ]]; then
        if [[ ! -v hosts_dir || -z "$hosts_dir" ]]; then
            die "The 'hosts-dir' should be set for '$action' action"
        fi
        [[ ! -d "$hosts_dir" ]] && die "Unable to find '$hosts_dir' directory"
        a[hosts_dir]="$hosts_dir"
    fi

    if [[ "${a[run_tests]}" == "yes" ]]; then
        if [[ ! -v hosts_dir ]]; then
            die "The 'hosts-dir' must be specified to run tests"
        elif [[ ! -d "$hosts_dir" ]]; then
            die "Unable to find '$hosts_dir' directory. Check path"
        fi
        a[hosts_dir]="$hosts_dir"
    fi
}

check_pkgs() {
    local -a missing=()

    for bin in "${!PACKAGES[@]}"; do
        # sepcial case
        if [[ "$bin" =~ OVMF_CODE_4M.fd ]]; then
            if [[ ! -e "$bin" ]]; then
                missing+=("${PACKAGES[$bin]}")
                continue
            fi
        fi

        if ! command -v "$bin" >/dev/null 2>&1; then
            if [[ -v bins[$bin] && -n "${PACKAGES[$bin]}" ]]; then
                missing+=("${PACKAGES[$bin]}")
            else
                missing+=("$bin")
            fi
        fi
    done
    if (( ${#missing[@]} )); then
        error "The following packages are missing: ${missing[*]}"
        error "Please install them using the following command:"
        echo "sudo apt install -y ${missing[*]}"
        exit 1
    fi
}

check_kvm_access() {
    [[ -r /dev/kvm ]] || die "User doesn't have KVM access."
    if ! grep -q "netdev" < <(groups) >/dev/null 2>&1; then
        die "User doesn't have netdev access."
    fi
}

save_env() {
    info "Save environment to '${HOSTS_DIR}/env'"
    cat <<- EOF > "${HOSTS_DIR}/env"
	VOSM_HOSTBR="$VOSM_HOSTBR"
	HOSTS_DIR="$HOSTS_DIR"
	OSM_SUBNET="$OSM_SUBNET"
	OSM_DOMAIN="$OSM_DOMAIN"
	ANSIBLE_HOSTS="${HOSTS_DIR}/hosts"
EOF
}

build_env() {
    parse_config "$1"
    check_pkgs
    if [[ -d "$HOSTS_DIR" ]]; then
        warn "The hosts directory '$HOSTS_DIR' exists"
        yesno "Do you wish to continue?"
        if [[ -e "$HOSTS_DIR/env" ]]; then
            # shellcheck disable=SC1091
            source "${HOSTS_DIR}/env"
        else
            # For Jenkins testing:
            # dnsmasq with predefined MAC addresses is running already on jenkins hosts
            # and MAC addresses must be the same for non-spawned VMs but environment
            # file is not created yet
            save_env
            # shellcheck disable=SC1091
            source "${HOSTS_DIR}/env"
        fi
    else
        [[ ! -d "$HOSTS_DIR" ]] && mkdir "$HOSTS_DIR"
        save_env
        # shellcheck disable=SC1091
        source "${HOSTS_DIR}/env"
    fi

    if [[ ! -e "$ANSIBLE_HOSTS" ]]; then
        cat <<-EOF > "$ANSIBLE_HOSTS"
	[all:vars]
	ansible_connection=ssh
	ansible_user=root
EOF
    fi
}

download() {
    # download "src" to optional "dst"
    # if "dst" omitted then download to current dirctory
    local src="$1"
    local dst="${2:-.}"
    local file="${src##*/}"

    if [[ -e "${dst}/${file}" ]]; then
        warn "The '${dst}/${file}' exists"
        return
    fi

    curl -L -s --retry 3 --create-dirs --output-dir "$dst" -O "$src"
}

get_debian_iso() {
    # download dibian iso file and check SHA512 checksum
    # download bookworm iso instead of current if enviroment CODE_NAME variable
    # is set to "bookworm"
    local dl_dir="$HOSTS_DIR/downloads"
    local url="$DEB_URL"
    local sha_args=(--check --quiet --status --ignore-missing)

    local checksum name ver

    # Use fixed bookworm version 12.11.0 for old environment
    if [[ -v CODE_NAME && "$CODE_NAME" == "bookworm" ]]; then
        ver="12.11.0"
        url="https://get.debian.org/cdimage/archive/${ver}/${DEB_ISO_ARCH}/iso-cd"
    fi

    download "${url}/SHA512SUMS" "$dl_dir"
    pushd "$dl_dir" >/dev/null 2>&1 || true
    checksum="$(sed -rn '/debian-([0-9.]+).*/p' SHA512SUMS)"
    name="${checksum##* }"
    download "${url}/${name}"
    echo "$checksum" | sha512sum "${sha_args[@]}" || die "SHA512 check"
    popd >/dev/null 2>&1 || true

    ISO_NAME="$name"
}

do_setup() {
    local pids="$1"

    get_debian_iso

    if ! setup_bridge; then
        die "Bridge setup"
    fi

    # incus needs minimum 3 hosts to form a cluster.
    # The osm host #0 acts as main host (with devtank DB and pebble ACME installed).
    # Other osm hosts are cloned from the osm host #1
    OSM_HOSTS=(
        ["${VOSM_HOST}0"]=""
        ["${VOSM_HOST}1"]=""
    )

    # shellcheck disable=SC2153
    prepare_base_host "${VOSM_HOST}0" "$OSM_DOMAIN" "${BASE_HOSTS[${VOSM_HOST}0]}" "$pids"
    clone_host "${VOSM_HOST}0" "${VOSM_HOST}1"

    for host in "${!OSM_HOSTS[@]}"; do
        run_qemu "$host" "$VOSM_HOSTBR"
        OSM_HOSTS["$host"]="$(wait_for_ip "$host" "${OSM_SUBNET}.1")"
        setup_ssh "${OSM_HOSTS[$host]}"
        add_ansible_host "$host" "${OSM_HOSTS[$host]}"
    done

    run_ansible_early "${OSM_HOSTS[${VOSM_HOST}0]}"
    do_stop_hosts

    local base_host dest_host
    base_host="${VOSM_HOST}1"

    for i in $(seq 2 $(( OSM_HOST_COUNT - 1 ))); do
        dest_host="${VOSM_HOST}${i}"
        clone_host "$base_host" "$dest_host"
        OSM_HOSTS["$dest_host"]=""
    done
}

do_post_setup() {
    local host ipaddr main_ip main_pub main_ssh_dir pub_key
    local -i retries=3
    local -i delay=3
    local -i count=0

    main_pub="$(gen_remote_ssh "${OSM_HOSTS[${VOSM_HOST}0]}")"
    main_ip="${OSM_HOSTS[${VOSM_HOST}0]}"
    main_ssh_dir="/home/osm_orchestrator/.ssh"

    run_ansible_pebble "${VOSM_HOST}0"

    for host in "${!OSM_HOSTS[@]}"; do
        count=0
        ipaddr="${OSM_HOSTS[$host]}"
        # update hosts file for ansible
        sed -ri 's/^'"$host"'.*=$/&'"$ipaddr"'/' "${HOSTS_DIR}/hosts"

        if [[ "$host" != "${VOSM_HOST}0" ]]; then
            info "Copy '${VOSM_HOST}0' SSH pub key to '${host}'[${ipaddr}]"
            ssh root@"$ipaddr" /bin/bash <<-EOF
		mkdir -p "$main_ssh_dir"
		echo "$main_pub" >> "${main_ssh_dir}/authorized_keys"
EOF
        fi

        info "Put '${host}' SSH key to orchestrator"
        ssh root@"$ipaddr" "ssh-keygen -t ed25519 -C 'OSM dev env' -q -N '' -f ~/.ssh/id_ed25519"
        pub_key="$(ssh root@"$ipaddr" "cat ~/.ssh/id_ed25519.pub")"
        ssh root@"$main_ip" "echo $pub_key >> /root/.ssh/authorized_keys"

        request_pebble_cert "$host" "$main_ip"

        info "Populate known_hosts of ${main_ip} by ${ipaddr}"

        while (( count < retries )); do
            # shellcheck disable=SC2029
            if ! ssh root@"$main_ip" "ssh-keyscan -H $ipaddr | tee -a /root/.ssh/known_hosts &>/dev/null 2>&1"; then
                warn "Attempt $(( count + 1)) failed, retrying in ${delay} seconds..."
                sleep $delay
                (( count++ ))
            else
                break
            fi
        done

        (( count == retries )) && die "Failed to add '$ipaddr' to known_hosts on '${main_ip}'"

    done

    run_ansible_incus
    run_ansible_postinst
}

_check_hosts_dir() {
    local d="$1"
    if [[ ! -d "$d" ]]; then
        error "There is no '$d' directory"
        return 1
    fi
    if [[ ! -e "${d}/env" ]]; then
        error "Unable to find 'env' file in '$d' directory"
        return 1
    fi
}

do_run_environment() {
    local hosts_dir="${ARGS[hosts_dir]}"
    info "Run '$hosts_dir' environment"

    if ! _check_hosts_dir "$hosts_dir"; then
        die "Unable to proceed"
    fi

    # shellcheck source=/dev/null
    source "${hosts_dir}/env"

    if ! setup_bridge; then
        die "Bridge setup"
    fi

    # shellcheck disable=SC2044
    mapfile -t hosts < <(find . -name 'vosmhost*' -type d -print)

    for host in "${hosts[@]}"; do
        run_qemu "${host##*/}" "${VOSM_HOSTBR}"
    done

    for host in "${hosts[@]}"; do
        host="${host##*/}"
        info "Waiting for IP address assigned for '$host' host"
        wait_for_ip "$host" "${OSM_SUBNET}.1"
    done
}

do_shutdown_environment() {
    local hosts_dir="${ARGS[hosts_dir]}"
    warn "shutting down '$hosts_dir' environment"
    if [[ ! -e "${hosts_dir}/env" ]]; then
        die "Unable to get environment settings"
    else
        # shellcheck source=/dev/null
        source "${hosts_dir}/env"
    fi
    close_bridge
    warn "Stop all VMs in located in '$hosts_dir'"
    find "$hosts_dir" -name "qemu.pid" -type f -print -exec pkill -15 -F {} \;
    pkill -15 -F "${hosts_dir}/${VOSM_HOSTBR}.pid"
}

add_ansible_host() {
    local name="$1"
    local ipaddr="$2"

    [[ -z "$name" ]] && die "Th host name is missing"
    [[ -z "$ipaddr" ]] && die "The IP address is missing"

    if ! grep -q "${ipaddr}$" "$ANSIBLE_HOSTS"; then
        # shellcheck disable=SC1003
        sed -i '1 i\'"${name} ansible_host=${ipaddr}"'' "$ANSIBLE_HOSTS"
    fi
    warn "The host '$name': $ipaddr exists in $ANSIBLE_HOSTS"
}

# ---------- VM related functions ----------
get_vm_ip() {
    local host="$1"
    local dns_srv="$2"
    local ipaddr name

    ipaddr="$(dig @"$dns_srv" "$host" +short)"

    if [[ -v ipaddr && -n "$ipaddr" ]]; then
        info "Got '$host' IP address: $ipaddr" >&2
        if ping -c1 -W1 "$ipaddr" >/dev/null 2>&1; then
            name="$(dig @"$dns_srv" -x "$ipaddr" +short)"
            if [[ "$name" == "${host}." ]]; then
                echo "$ipaddr"
                return 0
            fi
        else
            warn "Ping '$ipaddr' failed" >&2
        fi
    fi
    return 1
}

wait_for_ip() {
    local host="$1"
    local subnet="$2"
    local ipaddr=""
    local -i timeout=180

    ipaddr="$(do_until $timeout get_vm_ip "$host" "$subnet")"
    if [[ -z "$ipaddr" ]]; then
        error "Unable to get IP address for '$host' host"
        [[ ! -e "${HOSTS_DIR}/${host}/qemu.pid" ]] && die "The '$host' VM is down"
    fi
    echo "$ipaddr"
    return 0
}

setup_ssh() {
    local ipaddr="$1"
    mkdir -p ~/.ssh
    ssh-keygen -q -f ~/.ssh/known_hosts -R "$ipaddr" &> /dev/null 2>&1
    ssh-keyscan -H "$ipaddr" | tee -a ~/.ssh/known_hosts &> /dev/null 2>&1
}

gen_remote_ssh() {
    local ipaddr="$1"
    local pub_key
    pub_key="$(ssh root@"$ipaddr" /bin/bash <<-EOF
	if [[ ! -e /root/.ssh/id_rsa ]]; then
	     ssh-keygen -q  -t rsa -N '' -f /root/.ssh/id_rsa
	fi
	cat /root/.ssh/id_rsa.pub
EOF
)"
    [[ ! -v pub_key || -z "$pub_key" ]] && die "ssh keys were not generated for the '$ipaddr' host"
    echo "$pub_key"
}

# ---------- VM functions ----------
prepare_base_host() {
    local name="$1"
    local domain="$2"
    local preseed_file="$3"
    local pids_file="$4"
    local no_output="${5:-}" # whatever value disables live logging

    local ipaddr=""
    local host_dir="${HOSTS_DIR}/${name}"
    local boot_dir="${host_dir}/boot"
    local qdisk="${host_dir}/disk.qcow"
    local biosmem="${host_dir}/ovmf_vars.fd"
    local hwaddr=""
    local iso="${HOSTS_DIR}/downloads/${ISO_NAME}"
    local boot_files=(vmlinuz initrd.gz)
    local websrv_pid
    local log_pid
    local log_file="${host_dir}/install.log"

    local cmdline_params=(
        console=ttyS0
        priority=critical
        auto=true
        DEBIAN_FRONTEND=text
        hostname="$name"
        domain="$domain"
        log_host="${OSM_SUBNET}.1"
        log_port=10514
        url="http://${OSM_SUBNET}.1:${HTTP_PORT}/preseed.cfg"
    )
    local qemu_args=(
        -no-reboot
        -drive "file=${iso},format=raw,if=virtio,media=cdrom"
        -kernel "${host_dir}/boot/vmlinuz"
        -initrd "${host_dir}/boot/initrd.gz"
        --append "${cmdline_params[*]}"
    )

    mkdir -p "$host_dir"

    # set mac address
    if [[ -f "${host_dir}/mac" ]]; then
        hwaddr="$(<"${host_dir}/mac")"
    else
        hwaddr="$(gen_hwaddr)"

        while grep -qs "$hwaddr" "${HOSTS_DIR}/*/mac"; do
            hwaddr="$(gen_hwaddr)"
        done
        echo "$hwaddr" > "${host_dir}/mac"
    fi

    set_ssh_key "$host_dir"

    [[ ! -e "$biosmem" ]] && cp "$OVMF_VARS" "$biosmem"

    mkdir -p "$boot_dir"
    for f in "${boot_files[@]}"; do
        isoinfo -J -i "$iso" -x "/install.amd/${f}" > "${boot_dir}/${f}"
    done

    [[ -e "$qdisk" ]] && rm -rf "$qdisk"
    qemu-img create -f qcow2 "$qdisk" "$DISK_SIZE" >/dev/null 2>&1

    if [[ ! -e "${host_dir}/preseed.cfg" ]]; then
        sed -e 's|OSM_SUBNET|'"$OSM_SUBNET"'|g' -e 's|HTTP_PORT|'"$HTTP_PORT"'|g' "conf/${preseed_file}" > "${host_dir}/preseed.cfg"
    fi

    local websrv_cmd='echo $$ ; exec >/dev/null 2>&1 ; exec python3 -m http.server -d '"$host_dir"' -b '"${OSM_SUBNET}.1"' '"${HTTP_PORT}"''
    local log_cmd='echo $$ ; exec > '"${log_file}"' 2>&1 ; exec nc -ul '"${OSM_SUBNET}.1"' 10514'
    websrv_pid="$(/bin/sh -c "$websrv_cmd" &)"
    log_pid="$(/bin/sh -c "$log_cmd" &)"

    [[ ! -f "$pids_file" ]] && die "The '$pids_file' file does not exist. Terminating..."

    echo "$websrv_pid" > "$pids_file"
    echo "$log_pid" >> "$pids_file"

    info "OSM HOST NAME: $name"
    info "OSM HOST DIR: $host_dir"
    info "OSM HOST MAC ADDRES: $hwaddr"

    if run_qemu "$name" "$VOSM_HOSTBR" "${qemu_args[@]}"; then
        exec 3< "$log_file"
        local sym='-\|/'
        local -i n=0
        local stage="Unknown"
        local -i start_time=$SECONDS
        local -i terminate_after=120
        local shutdown_pattern='init\:\ The\ system\ is\ going\ down\ NOW\!'

        while :; do
            if [[ -z "$no_output" ]]; then
                n=$(( (n + 1) % 4 ))
                printf '\rPlease wait [%s]: %s\r' "${sym:$n:1}" "$stage"
            fi

            if read -r -u 3 line; then
                if [[ "$line" =~ Menu\ item ]]; then
                    stage="$(sed -rn 's|.*item (.*) .*|\1|p' <<< "$line")"
                    tput el
                fi

                if [[ "$line" =~ $shutdown_pattern ]]; then
                    line="$(sed -rn 's|.*: (.*)|\1|p' <<< "$line")"
                    printf '\r'
                    info "$line"
                    break
                fi

                start_time=$SECONDS
                continue

            elif (( (SECONDS - start_time) >= terminate_after )); then
                warn "There is no any input from '$log_file'. "
                warn "Terminating as $terminate_after seconds exceeded"
                pushd "$host_dir" &>/dev/null || die "pushd to '${host_dir}'"
                if [[ -f qemu.pid ]];  then
                    error "Found qemu.pid file."
                    if [[ ! -e /proc/$(< qemu.pid) ]]; then
                        error "There is no PID in /proc directory"
                    else
                        pkill -15 -F qemu.pid
                    fi
                else
                    warn "qemu.pid file not found"
                fi
                die "Unable to proceed"
            fi
            sleep .2
        done
        exec 3<&-
    else
        # seems the VM is running
        pushd "$host_dir" &>/dev/null || die "pushd to '${host_dir}'"
        [[ ! -S "monitor.sock" ]] && die "There is no monitor socket. Unable to proceed"
        local status
        status="$(echo "info status" | socat - unix-connect:monitor.sock)"
        status="$(sed -r 's|\r$||' <<<"$status")"
        status="$(sed -rn 's|^VM status: (.*)|\1|p' <<<"$status")"
        if [[ "$status" == "running" ]]; then
            warn "The VM '$name' is $status"
            yesno "Do you want to shutdown VM and proceed? "
            echo "system_powerdown"| socat - unix-connect:monitor.sock >/dev/null 2>&1
        fi
        popd &>/dev/null || die "popd from '${host_dir}'"
    fi

    # wait for qemu shuts down
    pidwait -F "${host_dir}/qemu.pid"
    info "The '$name' is powered off"

    run_qemu "$name" "$VOSM_HOSTBR"
    ipaddr="$(wait_for_ip "$name" "${OSM_SUBNET}.1")"
    setup_ssh "$ipaddr"

    if ! ssh root@"$ipaddr" exit; then
        die "SSH access to '${name}:${ipaddr} failed."
    fi

    ssh root@"$ipaddr" poweroff || true
    pidwait -F "${host_dir}/qemu.pid"
    info "The '$name' is powered off"

    info "Backup '$qdisk'"
    cp "$qdisk" "${qdisk}_bkp"
}

mrproper() {
    if [[ -s "$pids" ]]; then
        warn "Cleaning... from '$pids'"
        xargs kill -TERM < "$pids"
        rm "$pids"
    fi
}

handle_orphaned_vms() {
    while IFS= read -r -d '' pid; do
        warn "Killing PID: $(<"$pid")"
        pkill -9 -F "$pid" || die "pkill error for file '$pid'"
    done < <(find . -type f -name 'qemu.pid' -print0)
}

run_qemu() {
    (( $# < 2 )) && die "At least work dir and bridge name must be passed"

    local workdir="$1"
    local brif="$2"
    shift 2
    local extra_args=( "$@" )
    local hwaddr disk biosmem
    local -a qemu_args
    workdir="${HOSTS_DIR}/${workdir}"

    [[ ! -d "$workdir" ]] && die "Unable to find '$workdir' directory"
    if ! ip -o -4 a s dev "$brif" &>/dev/null; then
        die "The bridge '$brif' does not exist"
    fi
    if [[ ! -e "${workdir}/${DISK_NAME}" ]]; then
        die "Unable to find '$DISK_NAME' in '$workdir' directory"
    fi
    if [[ ! -e "${workdir}/ovmf_vars.fd" ]]; then
        die "Unable to find 'ovmf_vars.fd' file in '$workdir' directory"
    fi

    hwaddr="$(<"${workdir}/mac")"
    disk="${workdir}/${DISK_NAME}"
    biosmem="${workdir}/ovmf_vars.fd"

    if [[ -z "$hwaddr" ]]; then
        die "MAC address is missing."
    elif [[ ! "$hwaddr" =~ ^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$ ]]; then
        die "Wrong MAC address format."
    fi

    qemu_args=(
        -enable-kvm
        -nographic
        -m 4G
        -cpu host
        -monitor "unix:${workdir}/monitor.sock,server,nowait"
        -serial "unix:${workdir}/console.sock,server,nowait"
        -device "virtio-scsi-pci,id=scsi"
        # TODO: https://gitlab.com/qemu-project/qemu/-/issues/2762
        # -nic "bridge,br=${brif},model=virtio-net-pci,mac=${hwaddr}"
        -nic "bridge,br=${brif},model=e1000,mac=${hwaddr}"
        -drive "file=${disk},format=qcow2,if=virtio"
        -device "virtio-balloon-pci,id=balloon0"
        -pidfile "${workdir}/qemu.pid"
        "${extra_args[@]}"
        -drive "if=pflash,format=raw,unit=0,file=${OVMF_CODE},readonly=on"
        -drive "if=pflash,format=raw,unit=1,file=${biosmem}"
    )
    info "Run '${workdir##*/}' QEMU Virtual machine"
    if [[ -e "${workdir}/qemu.pid" ]]; then
        warn "The PID file exists in '${workdir##*/}'"
        local qemu_pid
        qemu_pid=$(< "${workdir}/qemu.pid")

        if [[ -d "/proc/${qemu_pid}" ]]; then
            warn "Fround '$qemu_pid' in /proc directory."
            local cmdline
            local cmdline_regex="file=${workdir}"
            cmdline="$(xargs -0 printf '%s ' </proc/"$qemu_pid"/cmdline)"
            if [[
                   "$cmdline" =~ ^qemu-system-x86_64 &&
                   "$cmdline" =~ $cmdline_regex
               ]]; then
                warn "It seems that VM '${workdir##*/}' is running already"
                return 1
            else
                die "Wrong PID for VM '${workdir##*/}'. Unable to proceed"
            fi
        fi
    fi
    qemu-system-x86_64 "${qemu_args[@]}" &

    # wait for qemu pid
    # TODO: make function
    local -i st=$SECONDS
    local -i timeout=2
    while [[ ! -e "${workdir}/qemu.pid" ]]; do
        if (( (SECONDS - st) > timeout )); then
            die "Run '${workdir##*/}' failed"
        fi
    done
    info "The '${workdir##*/}' is running"
    return 0
}

clone_host() {
    # TODO: qemu snapshots?
    local base_name="$1"
    local target_name="$2"
    local hwaddr=
    local ipaddr=

    if [[ ! -d "${HOSTS_DIR}/${base_name}" ]]; then
        die "Unable to get '$base_name' to clone '$target_name"
    fi

    info "${HOSTS_DIR}/${base_name} -> ${HOSTS_DIR}/${target_name}"
    mv "${HOSTS_DIR}/${target_name}/"mac{,_orig}
    cp "${HOSTS_DIR}/${base_name}/"{disk.qcow,ovmf_vars.fd,mac} "${HOSTS_DIR}/${target_name}/"
    run_qemu "${target_name}" "$VOSM_HOSTBR"
    ipaddr="$(do_until 120 get_vm_ip "$base_name" "${OSM_SUBNET}.1")"

    # shellcheck disable=SC2087
    ssh root@"$ipaddr" bash <<-EOF || true
	sed -i 's|'"$base_name"'|'"$target_name"'|g' /etc/{hosts,hostname}
	hostname  "$target_name"
	rm /etc/ssh/ssh_host_*
	dpkg-reconfigure openssh-server &> /dev/null
	# systemctl --force poweroff
	exit
EOF
    shutdown_vm "${HOSTS_DIR}/${target_name}"
    mv "${HOSTS_DIR}/${target_name}/"mac{_orig,}
}

set_ssh_key() {
    local host_dir="$1"
    declare -a ssh_keys
    local ssh_key
    local -a ssh_keys

    if [[ -z  "$DEFAULT_SSH_KEY" ]]; then
        mapfile -t ssh_keys < <(find ~/.ssh/ -type f -name 'id_*.pub')
        (( ! ${#ssh_keys[@]} )) && die "Missing public key"

        if (( ${#ssh_keys[@]} > 1 )); then
            if [[ "$(hostname)" =~ jenkins ]]; then
                warn "Running on jenkins host? Use the first ssh key found"
                DEFAULT_SSH_KEY="${ssh_keys[0]}"
            else
                warn "Several SSH public keys are found."
                PS3="Which key should be used? "
                select key in "${ssh_keys[@]}"; do
                    [[ $key ]] || continue
                    info "Set the '$key' key"
                    DEFAULT_SSH_KEY="$key"
                    break
                done
            fi
        else
            info "Set '${ssh_keys[0]}' public key."
            DEFAULT_SSH_KEY="${ssh_keys[0]}"
        fi
    fi

    ssh_key="${DEFAULT_SSH_KEY##*/}"
    echo "$ssh_key" > "${host_dir}/ssh_key_name"
    if [[ ! -f "${host_dir}/${ssh_key}" ]]; then
        ln -s "$DEFAULT_SSH_KEY" "${host_dir}/${ssh_key}"
    fi
}

do_start_hosts() {
    info "Start OSM hosts"
    declare -n hosts=$1
    local machines ipaddr

    mapfile -t machines < <(find "$HOSTS_DIR" -name "mac" -exec dirname {} \;)

    for host in "${machines[@]}"; do
        host="${host##*/}"
        run_qemu "$host" "${VOSM_HOSTBR}"
    done

    warn "Reset hosts in '$ANSIBLE_HOSTS'"
    sed -i '/\[all:vars\]/,$!d' "$ANSIBLE_HOSTS"

    for host in "${machines[@]}"; do
        host="${host##*/}"
        info "Waiting for IP address assigned..."
        # shellcheck disable=SC2034
        hosts["$host"]="$(wait_for_ip "$host" "${OSM_SUBNET}.1")"
        setup_ssh "${hosts[$host]}"
        add_ansible_host "$host" "${hosts[$host]}"
    done
}

do_stop_hosts() {
    info "Stop OSM hosts"

    declare -a hosts
    mapfile -t hosts < <(find "$HOSTS_DIR" -name "qemu.pid" -exec dirname {} \;)

    for host in "${hosts[@]}"; do
        shutdown_vm "$host"
    done
}

shutdown_vm() {
    [[ -z "$1" || ! -v 1 || ! -d "$1" ]] && return
    local hostdir="$1"
    local mon="monitor.sock"

    warn "Shutting down '$hostdir' host..."

    if [[ ! -f "${hostdir}/qemu.pid" ]]; then
        warn "There is no pid file in '$hostdir'. Is VM running?"
        return
    fi

    if [[ ! -S "${hostdir}/${mon}" ]]; then
        warn "There is no monitor socket in '$hostdir'"
        return
    else
        echo "system_powerdown" | socat - unix-connect:"${hostdir}/${mon}" &> /dev/null
        if [[ -f "${hostdir}/qemu.pid" ]]; then
            timeout 5 pidwait -f "${hostdir}/qemu.pid" || true
        fi
        info "The host '${hostdir##*/}' powered off"
    fi
}

request_pebble_cert() {
    local name="$1"
    local srvip="$2"
    local args=(
        certonly
        --standalone
        -d "${name}.${OSM_DOMAIN}"
        --server "https://${srvip}:14000/dir"
        --agree-tos
        --no-verify-ssl
        --http-01-port=5002
        --register-unsafely-without-email
        --quiet
    )
    info "Request certificate from '$srvip' for ${name}.${OSM_DOMAIN} domain."
    for (( i=0; i<3; i++ )); do
        # shellcheck disable=SC2029
        if ! ssh -v root@"$ipaddr" "REQUESST_CA_BUNDLE=devtank.minica.pem certbot ${args[*]} &>/dev/null"; then
            warn "Request certificate failed. Re-trying one more time... [$(( i + 1))]"
        else
            return 0
        fi
    done
    die "Unable to get certificate."
}

run_dnsmasq() {
    local hosts_dir
    hosts_dir="$(readlink -f "$HOSTS_DIR")"
    local conf_file="${hosts_dir}/dnsmasq.conf"
    local lease_file="${hosts_dir}/${VOSM_HOSTBR}.leasefile"
    local pid_file="${hosts_dir}/${VOSM_HOSTBR}.pid"
    local dns_fbaddr="8.8.8.8"  # should be global?
    local dns_serv
    # generate config: base settings
    local settings=(
        interface="$VOSM_HOSTBR"
        pid-file="$pid_file"
        dhcp-leasefile="$lease_file"
        except-interface=lo
        bind-interfaces
        dhcp-range="${OSM_SUBNET}.2,${OSM_SUBNET}.255"
        server="/${OSM_DOMAIN}/${OSM_SUBNET}.2"
    )
    declare -A macs=()
    local hosts=("${hosts_dir}"/vosmhost*)

    # get hosts hw addresses
    for host in "${hosts[@]}"; do
        if [[ ! -s "${host}/mac" ]]; then
            warn "Unable to get '$host' MAC address"
            macs[$host]="$host"
        else
            macs[$host]="$(<"$host"/mac)"
        fi
    done

    for host in "${!macs[@]}"; do
        n=$((10#${host: -1}))
        # the main vosmhost0 host always has ${OSM_SUBNET}.2 address
        if (( n == 0 )); then
            settings+=(dhcp-host="${macs[$host]},${OSM_SUBNET}.2")
        else
            settings+=(dhcp-host="${macs[$host]},${OSM_SUBNET}.${n}0")
        fi
    done

    dns_serv="$(dns_ip)"
    if [[ -n "$dns_serv" && "$dns_serv" != "$dns_fbaddr" ]]; then
        settings+=(dhcp-option="6,${dns_serv},${dns_fbaddr}")
    else
        settings+=(dhcp-option="6,${dns_fbaddr}")
    fi

    : > "$lease_file"
    printf "%s\n" "${settings[@]}" > "$conf_file"
    [[ -f "$pid_file" ]] && pkill -F "$pid_file" || true
    sudo dnsmasq --conf-file="$conf_file" || return 1
}

has() {
    local want="$1"
    local x
    shift

    for x in "$@"; do
        [[ "$x" == "$want" ]] && return 0
    done
    return 1
}

hostis() {
    [[ "$(hostname)" == "$1" ]] && return 0 || return 1
}

do_until() {
    local -i timeout="$1"
    local callback="$2"
    shift 2
    local args=("$@")
    local ret=""

    SECONDS=0

    set +o errexit
    trap 'echo "Oh, no! Wait until I finish with $callback function please" >&2' SIGINT
    while (( SECONDS < timeout )); do
        if ret="$("$callback" "${args[@]}")"; then
            printf '%s' "$ret"
            return 0
        else
            sleep .25
        fi
    done
    trap SIGINT
    set -o errexit
    error "TIME IS UP for '$callback'"
    return 1
}

is_env_running() {
    local hosts_dir="${ARGS[hosts_dir]}"

    if ! _check_hosts_dir "$hosts_dir"; then
        return 1
    fi

    # shellcheck source=/dev/null
    source "${hosts_dir}/env"

    if [[ ! -v VOSM_HOSTBR || ! -v OSM_SUBNET || ! -v OSM_DOMAIN ]]; then
        error "Essential environment variables are not set."
        return 1
    fi

    if [[ $(ip -br l show "$VOSM_HOSTBR") =~ DOWN.*\<.* ]]; then
        error "The interface '$VOSM_HOSTBR' is down"
        return 1
    fi
}

run_tests() {
    yesno "Do you want to run tests? "
    local tests_file="/srv/osm-lxc/orchestrator/env/tests/customers.bats"
    local bats_args=(-p --print-output-on-failure --verbose-run -T)
    local cmd=(bats "${bats_args[@]}" "${tests_file}")

    edo ssh root@"${OSM_SUBNET}.2" "export DOMAIN=$OSM_DOMAIN; TERM=xterm " "${cmd[@]}"
    return 0
}
