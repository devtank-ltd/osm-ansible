# TODO:
# - setup: create file for push test
# - teardown: remove files, clean up database
# - parse commands output

setup_file() {
    load /usr/lib/bats/bats-assert/load
    load /usr/lib/bats/bats-support/load

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    PATH="$DIR/..:$PATH"
    CLI="/srv/osm-lxc/orchestrator/orchestrator_cli.py"

    UUID="$(uuidgen)"
    echo "Some test data: $UUID" > /tmp/devtank_test_data
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

@test "Test Host vosmhost0" {
    run "$CLI" test_host vosmhost0
    assert_success
}

@test "Test Host vosmhost1" {
    run "$CLI" test_host vosmhost1
    assert_success
}

@test "Test Host vosmhost2" {
    run "$CLI" test_host vosmhost2
    assert_success
}

@test "Test Host vosmhost3" {
    run "$CLI" test_host vosmhost3
    assert_failure
}

@test "Add Alerts Contact" {
    run "$CLI" add_alerts_contact c1 c1@mail.xyz
    assert_success
}

@test "List Alerts Contacts" {
    skip "Not implemented. Parse output"
}

@test "Clone Container" {
    skip "Not implemented. Use incus instead?"
}

@test "Move Customer" {
    run "$CLI" mv_customer customer1 vosmhost1
    assert_success
}

@test "Upgrade Customers" {
    skip "Not implemented"
}

@test "List Hosts" {
    run "$CLI" list_hosts
    assert_success
}

@test "List Host Customers vosmhost0" {
    run "$CLI" list_host_customers vosmhost0
    assert_success
}

@test "List Host Customers vosmhost1" {
    run "$CLI" list_host_customers vosmhost1
    assert_success
}

@test "List Host Customers vosmhost2" {
    run "$CLI" list_host_customers vosmhost2
    assert_success
}

@test "List Host Customers vosmhost3" {
    run "$CLI" list_host_customers vosmhost3
    assert_failure
}

@test "List Customers" {
    run "$CLI" list_customers
    assert_success
}

@test "Get Customer Passwords" {
    run "$CLI" get_customer_passwords customer1
    assert_success
}

@test "Get WG Info vosmhost0" {
    run "$CLI" get_wg_info vosmhost0
    assert_success
}

@test "Get WG Info vosmhost1" {
    run "$CLI" get_wg_info vosmhost1
    assert_success
}

@test "Get WG Info vosmhost2" {
    run "$CLI" get_wg_info vosmhost2
    assert_success
}

@test "Get WG Info vosmhost3" {
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
    run "$CLI" push_file_or_directory customer1 /root/devtank_test_data /tmp
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

@test "Upgrade Influx Inserter" {
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
