setup() {
    load /usr/lib/bats/bats-assert/load
    load /usr/lib/bats/bats-support/load

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    PATH="$DIR/..:$PATH"
    CLI="/srv/osm-lxc/orchestrator/orchestrator_cli.py"
    DOMAIN="${DOMAIN:-incus-devtank.co.uk}"
}

setup_file() {
    OSM_HOSTS=("vosmhost0" "vosmhost1" "vosmhost2")
    UUID="$(uuidgen)"
    echo "Some test data: $UUID" > /tmp/devtank_test_data
}

teardown_file() {
    # we don't have remove contacts functionality so far
    mysql -u root osm_orchestrator -e 'delete from osm_customer_contact'
    rm -v /tmp/devtank_test_data
}

@test "Add customer" {
    run "$CLI" add_customer customer1
    assert_success
}

@test "Add same customer" {
    run "$CLI" add_customer customer1
    assert_failure
}

@test "Add Host" {
    skip "Not implemented"
}

@test "Del Host" {
    skip "Not implemented"
}

@test "Find Host" {
    run "$CLI" find_host customer1
    assert_success
}

@test "Test Host" {
    for h in "${OSM_HOSTS[@]}"; do
        run "$CLI" test_host vosmhost0
        assert_line --index 0 --regexp ''"$h"' \[[[:digit:]].+\]: Online \(Fully operational\)'
        assert_success
    done

    run "$CLI" test_host vosmhost3
    assert_line --index 0 'Error: Cluster member not found'
    assert_failure
}

@test "Add Alerts Contact" {
    run "$CLI" add_alerts_contact customer1 customer1@mail.xyz
    assert_success
}

@test "List Alerts Contacts" {
    run "$CLI" list_alerts_contacts
    assert_success
    assert_output --regexp '.*^customer1[[:blank:]]+\| customer1@mail.xyz[[:blank:]]+\| [[:alnum:]]{8}\-([[:alnum:]]{4}\-){3}[[:alnum:]]{12}'
}


@test "List Hosts (customer on vosmhost0)" {
    host="$(incus ls customer1 -cL -fcsv)"
    index="${host: -1}"
    run "$CLI" list_hosts
    assert_success
    for i in $(seq 0 2); do
        capacity=0
        if (( index == i )); then
            capacity=1
        fi
        assert_line --index $(( i + 1 )) --regexp '^[[:blank:]]+Host: vosmhost'"$i"': capacity: '"$capacity"'\/[[:digit:]]+'
    done
}

@test "List Host Customers (customer on vsomhost0)" {
    for host in "${OSM_HOSTS[@]}"; do
        run "$CLI" list_host_customers "$host"
        assert_success
        if [[ "$host" == "vosmhost0" ]]; then
            assert_line --index 0 --regexp '^Host: '"$host"': capacity: 1\/[[:digit:]]+'
            assert_line --index 1 --regexp '^[[:blank:]]+Customer: customer1 \(MQTT:[[:digit:]]+\)$'
        else
            assert_line --index 0 --regexp '^Host: '"$host"': capacity: 0\/[[:digit:]]+'
            assert_line --index 1 'Command: list_host_customers : Result: SUCCESS'
        fi
    done
}

@test "Move Customer" {
    run "$CLI" mv_customer customer1 vosmhost1
    assert_success
}

@test "List Hosts (customer on vosmhost1)" {
    run "$CLI" list_hosts
    assert_success
    assert_line --index 1 --regexp '^[[:blank:]]+Host: vosmhost0: capacity: 0\/[[:digit:]]+'
    assert_line --index 2 --regexp '^[[:blank:]]+Host: vosmhost1: capacity: 1\/[[:digit:]]+'
    assert_line --index 3 --regexp '^[[:blank:]]+Host: vosmhost2: capacity: 0\/[[:digit:]]+'
}

@test "List Host Customers (customer on vosmhost1)" {
    for host in "${OSM_HOSTS[@]}"; do
        run "$CLI" list_host_customers "$host"
        assert_success
        if [[ "$host" == "vosmhost1" ]]; then
            assert_line --index 0 --regexp '^Host: '"$host"': capacity: 1\/[[:digit:]]+'
            assert_line --index 1 --regexp '^[[:blank:]]+Customer: customer1 \(MQTT:[[:digit:]]+\)$'
        else
            assert_line --index 0 --regexp '^Host: '"$host"': capacity: 0\/[[:digit:]]+'
            assert_line --index 1 'Command: list_host_customers : Result: SUCCESS'
        fi
    done
}

@test "Clone Customer. Same OSM host. Non-public" {
    run "$CLI" clone_container customer1
    assert_success
    run incus ls customer1-clone -cnL -fcsv
    assert_output 'customer1-clone,vosmhost1'
    run incus stop customer1-clone
    run incus rm customer1-clone
}

@test "Clone Customer. Other OSM host. Non-public" {
    run "$CLI" clone_container customer1 vosmhost0
    assert_success
    run incus ls customer1-clone -cnL -fcsv
    assert_output 'customer1-clone,vosmhost0'
    run incus stop customer1-clone
    run incus rm customer1-clone
}

@test "Clone Customer. Same OSM host. Public" {
    run "$CLI" clone_container customer1 vosmhost1 yes
    assert_success
    run ping -c3 customer1-clone."$DOMAIN"
    assert_success
    assert_line --index 0 --regexp '^PING vosmhost1.'"$DOMAIN"' \([[:digit:]].+\).*$'
    for n in $(seq 1 3); do
        assert_line --index "$n" --regexp '^[[:digit:]]+ bytes from vosmhost1 \([[:digit:]].+\): icmp_seq='"$n"''
    done
    assert_line --index 5 --regexp '^.*, 0% packet loss.*$'
    run "$CLI" del_customer customer1-clone
}

@test "Clone Customer. Other OSM host. Public" {
    run "$CLI" clone_container customer1 vosmhost0 yes
    assert_success
    run resolvectl flush-caches
    run ping -c3 customer1-clone."$DOMAIN"
    assert_line --index 0 --regexp '^PING vosmhost0.'"$DOMAIN"' \([[:digit:]].+\).*$'
    for n in $(seq 1 3); do
        assert_line --index "$n" --regexp '^[[:digit:]]+ bytes from vosmhost0 \([[:digit:]].+\): icmp_seq='"$n"''
    done
    assert_line --index 5 --regexp '^.*, 0% packet loss.*$'
    run "$CLI" del_customer customer1-clone

}

@test "Clone Already Cloned Customer. Same OSM host. Non-public" {
    run "$CLI" clone_container customer1
    run "$CLI" clone_container customer1
    assert_failure
}

@test "Clone Already Cloned Customer. Other OSM host. Non-public" {
    run "$CLI" clone_container customer1 vosmhost2
    assert_failure
}

@test "Clone Already Cloned Customer. Other OSM host. Public" {
    run "$CLI" clone_container customer1 vosmhost2 yes
    assert_failure
}

@test "Upgrade Customers" {
    skip "Not implemented"
}

@test "List Customers" {
    run "$CLI" list_customers
    assert_success
}

@test "Get Customer Passwords" {
    run "$CLI" get_customer_passwords customer1
    assert_success
}

@test "Get WG Info" {
    for host in "${OSM_HOSTS[@]}"; do
        run "$CLI" get_wg_info "$host"
        assert_success
    done

    run "$CLI" get_wg_info vosmhost3
    assert_failure
}

@test "Push File Or Directory" {
    run "$CLI" push_file_or_directory customer1 /tmp/devtank_test_data /root/
    assert_success

    run incus exec customer1 -- cat /root/devtank_test_data
    echo "Some test data: $UUID" | assert_output
}

@test "Pull File Or Directory" {
    rm /tmp/devtank_test_data
    run "$CLI" pull_file_or_directory customer1 /root/devtank_test_data /tmp
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
    run "$CLI" mqtt_listener customer1
    assert_success
}

@test "Delete customer" {
    run "$CLI" del_customer customer1
    assert_success
}
