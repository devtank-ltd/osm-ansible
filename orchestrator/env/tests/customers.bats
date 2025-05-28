setup() {
    load /usr/lib/bats/bats-assert/load
    load /usr/lib/bats/bats-support/load

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    PATH="$DIR/..:$PATH"

    CLI="/srv/osm-lxc/orchestrator/orchestrator_cli.py"
}

@test "Add customer" {
    run "$CLI" add_customer customer1
    assert_success
}

@test "Delete customer" {
    run "$CLI" del_customer customer1
    assert_success
}
