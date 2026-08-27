run_ansible_early() {
    local ipaddr="$1"
    local -A hosts

    local playbook="ansible/incus/deploy.yaml"
    local extra_vars=(
        osm_dns="$ipaddr"
        smtp_host="${MAIL_SMTP_HOST}"
        smtp_user="${MAIL_SMTP_USER}"
        smtp_password="${MAIL_SMTP_PASSWORD}"
        mail_recipients="${MAIL_RECIPIENTS}"
        osm_domain="$OSM_DOMAIN"
        # alternative branch name is set by DEVTANK_BRANCH environmet variable
        git_branch="${DEVTANK_BRANCH:-$(git rev-parse --abbrev-ref @ | sed -n 's/HEAD/main/p;t;p')}"
    )
    ANSIBLE_LIBRARY="ansible/library"
    export ANSIBLE_LIBRARY
    local ansible_args=(
        -e "${extra_vars[*]}"
        -i "$ANSIBLE_HOSTS"
        --tags "bootstrap,testenv"
        "$playbook"
    )
    edo ansible-playbook "${ansible_args[@]}"
}

run_ansible_pebble() {
    local host="$1"
    local playbook="ansible/incus/deploy.yaml"
    local args=(
        --tags "testenv"
        -u root
        -i "$ANSIBLE_HOSTS"
        -e target="$host"
        -e osm_domain="$OSM_DOMAIN"
    )

    edo ansible-playbook "${args[@]}" "$playbook"
}

run_ansible_incus() {
    local args=(
        -i "${HOSTS_DIR}/hosts"
        -e osm_domain="$OSM_DOMAIN"
        -e dns_ip="$(dns_ip)"
        --tags incus
    )

    edo ansible-playbook "${args[@]}" ansible/incus/deploy.yaml
}

run_ansible_postinst() {
    local args=(
        --tags postinst
        -e osm_domain="$OSM_DOMAIN"
        -i "$ANSIBLE_HOSTS"
    )

    if hostis "debian-jenkins"; then
        args+=(-e "install_java=yes")
    fi

    edo ansible-playbook "${args[@]}" ansible/incus/deploy.yaml
}
