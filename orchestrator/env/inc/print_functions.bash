print_usage() {
    cat <<-EOF
	Usage:
	setup environment:
	./${0##*/} -a setup|--action=setup -c <conf_file>|--config=<conf_file>
	shutdown environment:
	./${0##*/} -a shutdown|--action=shutdown -d <hosts directory>|--hosts-dir=<hosts directory>
EOF
    exit 1
}

msg() {
    printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*" >&2
}

info() {
    msg "${GREEN}INFO:${RESET} $*" >&2
}

warn() {
    msg "    ${YELLOW}* WARNING:${RESET} $*" >&2
}

error() {
    msg "    ${RED}!!! ERROR:${RESET} $*" >&2
}

yesno() {
    [[ -t 0 ]] || return 0
    local resp
    read -r -p "$1 [${GREEN}y${RESET}/${RED}N${RESET}] " resp
    [[ "$resp" == [yY] ]] || exit 1
}

git_branch() {
    # git rev-parse --abbrev-ref HEAD | sed -n 's/HEAD/main/p;t;p'
    # TODO: remove after merge
    echo "main"
}

col() {
    local -i n=$1
    printf '%s' "+"
    printf -- '-%0.s' $(seq 1 $n)
}

end_col() {
    printf '+\n'
}

print_status() {
    local hosts_file="${HOSTS_DIR}/hosts"
    local host_title="Host Name"
    local ip_title="IP address"
    col 12; col 17; end_col
    printf '| %-10s | %-15s |\n' "$host_title" "$ip_title"
    col 12; col 17; end_col

    while read -r line; do
        [[ "$line" =~ \[all:vars\] ]] && break
        [[ ! "$line" =~ ansible_host= ]] && continue
        host="${line%% *}"
        ipaddr="${line##*=}"
        printf "| %-10s | %-15s |\n" "$host" "$ipaddr"
    done < "$hosts_file"
    col 12; col 17; end_col
}
