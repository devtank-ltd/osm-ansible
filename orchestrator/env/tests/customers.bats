setup() {
    load /usr/lib/bats/bats-assert/load
    load /usr/lib/bats/bats-support/load

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    PATH="$DIR/..:$PATH"
    CLI="/srv/osm-lxc/orchestrator/orchestrator_cli.py"
    DOMAIN="${DOMAIN:-incus-devtank.co.uk}"
    CUSTOMER_NAME="test-customer"
    CUSTOMER_MAIL="test-customer@mail.me"
    mapfile -t OSM_HOSTS < <("$CLI" list_hosts | sed -rn 's/.*Host: (.*): capacity.*/\1/p')
}

setup_file() {
    UUID="$(uuidgen)"
    echo "Some test data: $UUID" > /tmp/devtank_test_data
}

teardown_file() {
    # we don't have remove contacts functionality so far
    mysql -u root osm_orchestrator -e 'delete from osm_customer_contact'
    rm -v /tmp/devtank_test_data
}

@test "Add customer" {
    run "$CLI" add_customer "$CUSTOMER_NAME"
    assert_success
}

@test "Add same customer" {
    run "$CLI" add_customer "$CUSTOMER_NAME"
    assert_failure
}

@test "Add Host" {
    skip "Not implemented"
}

@test "Del Host" {
    skip "Not implemented"
}

@test "Test Hosts" {
    for i in "${!OSM_HOSTS[@]}"; do
        host="${OSM_HOSTS[$i]}"
        run "$CLI" test_host "$host"
        assert_success
        assert_line --index 0 --regexp ''"$host"' \[[[:digit:]].+\]: Online \(Fully operational\)'
    done

    run "$CLI" test_host vosmhost3
    assert_line --index 0 'Error: Cluster member not found'
    assert_failure
}

@test "Add Alerts Contact" {
    run "$CLI" add_alerts_contact "$CUSTOMER_NAME" "$CUSTOMER_MAIL"
    assert_success
}

@test "List Alerts Contacts" {
    run "$CLI" list_alerts_contacts
    assert_success
    assert_output --regexp '.*^'"$CUSTOMER_NAME"'[[:blank:]]+\| '"$CUSTOMER_MAIL"'[[:blank:]]+\| [[:alnum:]]{8}\-([[:alnum:]]{4}\-){3}[[:alnum:]]{12}'
}

@test "List Hosts" {
    customer_host="$(incus ls "$CUSTOMER_NAME" -cL -fcsv)"
    host_idx="${customer_host: -1}"

    run "$CLI" list_hosts
    assert_success

    for i in "${!OSM_HOSTS[@]}"; do
        capacity=0
        (( host_idx == i )) && capacity=1
        assert_line --index $(( i + 1 )) --regexp '^[[:blank:]]+Host: vosmhost'"$i"': capacity: '"$capacity"'\/[[:digit:]]+'
    done
}

@test "List Host Customers" {
    customer_host="$(incus ls "$CUSTOMER_NAME" -cL -fcsv)"

    for host in "${OSM_HOSTS[@]}"; do
        run "$CLI" list_host_customers "$host"
        assert_success

        if [[ "$host" == "$customer_host" ]]; then
            assert_line --index 0 --regexp '^Host: '"$host"': capacity: 1\/[[:digit:]]+'
            assert_line --index 1 --regexp '^[[:blank:]]+Customer: '"$CUSTOMER_NAME"' \(MQTT:[[:digit:]]+\)$'
        else
            assert_line --index 0 --regexp '^Host: '"$host"': capacity: 0\/[[:digit:]]+'
            assert_line --index 1 'Command: list_host_customers : Result: SUCCESS'
        fi
    done
}

@test "Move Customer" {
    current_host="$(incus ls "$CUSTOMER_NAME" -cL -fcsv)"
    target_host=
    target_host_idx=

    for i in "${!OSM_HOSTS[@]}"; do
        target_host="${OSM_HOSTS[$i]}"
        if [[ "$target_host" != "$current_host" ]]; then
            target_host_idx=$i
            break
        fi
    done

    run "$CLI" mv_customer "$CUSTOMER_NAME" "$target_host"
    assert_success

    run "$CLI" list_hosts
    assert_success

    for i in "${!OSM_HOSTS[@]}"; do
        capacity=0
        (( target_host_idx == i )) && capacity=1
        assert_line --index $(( i + 1 )) --regexp '^[[:blank:]]+Host: vosmhost'"$i"': capacity: '"$capacity"'\/[[:digit:]]+'
    done

    run "$CLI" list_host_customers "$target_host"
    assert_success

    for host in "${OSM_HOSTS[@]}"; do
        run "$CLI" list_host_customers "$host"
        assert_success

        if [[ "$host" == "$target_host" ]]; then
            assert_line --index 0 --regexp '^Host: '"$host"': capacity: 1\/[[:digit:]]+'
            assert_line --index 1 --regexp '^[[:blank:]]+Customer: '"$CUSTOMER_NAME"' \(MQTT:[[:digit:]]+\)$'
        else
            assert_line --index 0 --regexp '^Host: '"$host"': capacity: 0\/[[:digit:]]+'
            assert_line --index 1 'Command: list_host_customers : Result: SUCCESS'
        fi
    done
}

@test "Clone Customer. Same OSM host. Non-public" {
    current_host="$(incus ls "$CUSTOMER_NAME" -cL -fcsv)"
    run "$CLI" clone_container "$CUSTOMER_NAME"
    assert_success

    run incus ls "$CUSTOMER_NAME"-clone -cnL -fcsv
    assert_output ''"$CUSTOMER_NAME"'-clone,'"$current_host"''

    run incus stop "$CUSTOMER_NAME"-clone
    run incus rm "$CUSTOMER_NAME"-clone
}

@test "Clone Customer. Other OSM host. Non-public" {
    current_host="$(incus ls "$CUSTOMER_NAME" -cL -fcsv)"
    target_host=

    for i in "${!OSM_HOSTS[@]}"; do
        target_host="${OSM_HOSTS[$i]}"
        [[ "$target_host" != "$current_host" ]] && break
    done

    run "$CLI" clone_container "$CUSTOMER_NAME" "$target_host"
    assert_success

    run incus ls "$CUSTOMER_NAME"-clone -cnL -fcsv
    assert_output ''"$CUSTOMER_NAME"'-clone,'"$target_host"''

    run incus stop "$CUSTOMER_NAME"-clone
    run incus rm "$CUSTOMER_NAME"-clone
}

@test "Clone Customer. Other OSM host. Public" {
    current_host="$(incus ls "$CUSTOMER_NAME" -cL -fcsv)"
    target_host=
    target_host_idx=

    for i in "${!OSM_HOSTS[@]}"; do
        target_host="${OSM_HOSTS[$i]}"
        if [[ "$target_host" != "$current_host" ]]; then
            target_host_idx=$i
            break
        fi
    done

    run "$CLI" clone_container "$CUSTOMER_NAME" "$target_host" yes
    assert_success
    run resolvectl flush-caches
    run ping -c3 "$CUSTOMER_NAME"-clone."$DOMAIN"
    assert_line --index 0 --regexp '^PING '"$target_host"'.'"$DOMAIN"' \([[:digit:]].+\).*$'
    for n in $(seq 1 3); do
        assert_line --index "$n" --regexp '^[[:digit:]]+ bytes from '"$target_host"' \([[:digit:]].+\): icmp_seq='"$n"''
    done
    assert_line --index 5 --regexp '^.*, 0% packet loss.*$'
    run bash -c 'printf "Y\n" | '"$CLI"' del_customer '"$CUSTOMER_NAME"'-clone'
    assert_success

}

@test "Clone Already Cloned Customer. Same OSM host. Non-public" {
    run "$CLI" clone_container "$CUSTOMER_NAME"
    run "$CLI" clone_container "$CUSTOMER_NAME"
    assert_failure
}

@test "Clone Already Cloned Customer. Other OSM host. Non-public" {
    current_host="$(incus ls "$CUSTOMER_NAME" -cL -fcsv)"
    target_host=

    for i in "${!OSM_HOSTS[@]}"; do
        target_host="${OSM_HOSTS[$i]}"
        if [[ "$target_host" != "$current_host" ]]; then
            break
        fi
    done

    run "$CLI" clone_container "$CUSTOMER_NAME"  "$target_host"
    assert_failure
}

@test "Clone Already Cloned Customer. Other OSM host. Public" {
    current_host="$(incus ls "$CUSTOMER_NAME" -cL -fcsv)"
    target_host=

    for i in "${!OSM_HOSTS[@]}"; do
        target_host="${OSM_HOSTS[$i]}"
        if [[ "$target_host" != "$current_host" ]]; then
            break
        fi
    done

    run "$CLI" clone_container "$CUSTOMER_NAME" "$target_host" yes
    assert_failure

    incus rm -f "${CUSTOMER_NAME}-clone"
}

@test "Upgrade Customer" {
    skip "Not implemented"
}

@test "List Customers" {
    run "$CLI" list_customers
    assert_success
}

@test "Get Customer Passwords" {
    run "$CLI" get_customer_passwords "$CUSTOMER_NAME"
    assert_success
}

@test "Get WG Info" {
    for host in "${OSM_HOSTS[@]}"; do
        run "$CLI" get_wg_info "$host"
        assert_success
    done

    run "$CLI" get_wg_info nonexistent_host
    assert_failure
}

@test "Push File Or Directory" {
    run "$CLI" push_file_or_directory "$CUSTOMER_NAME" /tmp/devtank_test_data /root/
    assert_success

    run incus exec "$CUSTOMER_NAME" -- cat /root/devtank_test_data
    echo "Some test data: $UUID" | assert_output
}

@test "Pull File Or Directory" {
    rm /tmp/devtank_test_data
    run "$CLI" pull_file_or_directory "$CUSTOMER_NAME" /root/devtank_test_data /tmp
    assert_success

    run cat /tmp/devtank_test_data
    assert_success
    echo "Some test data: $UUID" | assert_output
}

@test "Add Dashboards" {
    skip "Not implemented"
}

@test "Del Dashboards" {
    skip "Not implemented"
}

@test "MQTT Listener" {
    run "$CLI" mqtt_listener "$CUSTOMER_NAME"
    assert_success
}

@test "Delete customer" {
    run bash -c 'printf "Y\n" | '"$CLI"' del_customer '"$CUSTOMER_NAME"''
    assert_success
}
