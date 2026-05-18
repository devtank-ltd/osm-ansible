gen_ssh_key(){
    info "Generating SSH keys"
    local type="${1:-ed25519}"
    local path="${2:-${HOSTS_DIR}/id_${type}}"
    local comment="${3:-generated-osm-dev}"

    ssh-keygen -t "$type" -N "" -f "$path" -C "$comment"
}

gen_password() {
    local -i len=${1:-10}
    tr -dc '[:alnum:][:punct:]' < /dev/urandom | head -c "$len"
    return 0
}

gen_osm_user_data() {
    local hostname="$1"
    local template="cloud-init/user-data.template"
    local data_file="${hostname}/user-data"

    data_file="${HOSTS_DIR}/${data_file}"
    info "Generating user-data for '$hostname' host"
    sed -r 's|<<HOSTNAME>>|'"$hostname"'|g' "$template" > "$data_file"
}

gen_base_user_data() {
    local password="${1:-}"
    local ssh_key="${2:-}"
    local dir=""
    local key=""
    local priv_key=""
    local pub_key=""

    local template_file="cloud-init/base-user-data.template"
    local data_file="cloud-init/base-user-data"

    [[ -z "$password" ]] && password="$(gen_password)"

    if [[ -z "$ssh_key" ]]; then
        gen_ssh_key
        priv_key="${HOSTS_DIR}/id_ed25519"
        pub_key="${HOSTS_DIR}/id_ed25519.pub"
    else
        dir="${ssh_key%/*}"
        key="${ssh_key##*/}"
        key="${key%.*}"

        if [[ "$dir" == "$key" ]]; then
            dir="$(dirname "$(readlink -f "$0")")"
        fi

        priv_key="${dir}/${key}"
        pub_key="${dir}/${key}.pub"

        for k in "$pub_key" "$priv_key"; do
            if [[ ! -f "${dir}/${k}" ]]; then
                die "Unable to find '$k' file in '$dir' directory."
            fi
        done
        info "Copy '$pub_key' to '$HOSTS_DIR'"
        cp "$pub_key" "$HOSTS_DIR"
        info "Copy '$priv_key' to '$HOSTS_DIR'"
        cp "$priv_key" "$HOSTS_DIR"
    fi

    pub_key="$(< "$pub_key")"
    sed -r 's|<<<PASSWORD>>>|'"$password"'|' "$template_file" > "$data_file"
    sed -i -r 's|<<<SSH_PUB_KEY>>>|'"$pub_key"'|' "$data_file"
    sed -i -e '/<<<SSH_PRIV_KEY>>>/ {
            r '"$priv_key"'
            d
    }' "$data_file"
    # indent
    sed -i -r '/----BEGIN/,/----END/ s/^/      /' "$data_file"
}
