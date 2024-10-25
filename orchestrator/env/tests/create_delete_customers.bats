setup() {
    load /usr/lib/bats/bats-assert/load
    load /usr/lib/bats/bats-support/load

    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    PATH="$DIR/..:$PATH"

    ORCH_SCRIPT="/srv/osm-lxc/orchestrator/orchestrator_cli.py"
    # TODO: verify customers existence and remove all customers before testing
}

display_customers() {
    :
}

@test "Create customer" {
    skip
    run "$ORCH_SCRIPT" add_customer "customer-1"
    assert_output "Command: add_customer : Result: SUCCESS"
    assert_success
}

@test "Create customer with existing name" {
    skip
    run "$ORCH_SCRIPT" add_customer "customer-1"
    [[ "${lines[0]}" == 'WARNING:OSMORCH:Already customer "customer-1"' ]]
    [[ "${lines[1]}" == 'Command: add_customer : Result: FAILED' ]]
    assert_success
}

@test "Delete customer" {
    skip
    run "$ORCH_SCRIPT" del_customer "customer-1"
    # assert_output "Command: del_customer : Result: SUCCESS"
    assert_line --index 0 --regexp '^ERROR:vosmhost[0-9]:Command '\'ping -c1 customer-1-svr\'' failed : 2:No such file or directory'
    assert_line --index 1 --regexp '^ERROR:vosmhost[0-9]:ping: customer-1-svr: Temporary failure in name resolution'
    assert_line --index 2 'Command: del_customer : Result: SUCCESS'
    assert_success
}

@test "Delete non-existent customer" {
    skip
    run "$ORCH_SCRIPT" del_customer "customer-1"
    (( $status > 0 ))
    [[ "${lines[0]}" == 'WARNING:OSMORCH:No customer "customer-1"' ]]
    [[ "${lines[1]}" == 'Command: del_customer : Result: FAILED' ]]
}

@test "Create 8 customers" {
    skip
    for n in $(seq 8); do
        run "$ORCH_SCRIPT" add_customer "customer-${n}"
        assert_output "Command: add_customer : Result: SUCCESS"
        assert_success
    done
}

@test "Delete 8 customers" {
    skip
    for n in $(seq 8); do
        run "$ORCH_SCRIPT" del_customer "customer-${n}"
        assert_success
        assert_line --index 0 --regexp '^ERROR:vosmhost[0-9]:Command '\'ping -c1 customer-'"$n"'-svr\'' failed : 2:No such file or directory'
        assert_line --index 1 --regexp '^ERROR:vosmhost[0-9]:ping: customer-'"$n"'-svr: Temporary failure in name resolution'
        assert_line --index 2 'Command: del_customer : Result: SUCCESS'
    done
}

@test "Create and delete 8 customers 10 times" {
    # skip
    for i in $(seq 10); do
        echo "===== iteration #${i} =====" >&3
        echo "Create..." >&3
        for n in $(seq 8); do
            run "$ORCH_SCRIPT" add_customer "customer-${n}"
            assert_output "Command: add_customer : Result: SUCCESS"
            assert_success
        done

        echo "Delete..." >&3
        for n in $(seq 8); do
            run "$ORCH_SCRIPT" del_customer "customer-${n}"
            (( $status == 0 ))
            assert_line --index 0 --regexp '^ERROR:vosmhost[0-9]:Command '\'ping -c1 customer-'"$n"'-svr\'' failed : 2:No such file or directory'
            assert_line --index 1 --regexp '^ERROR:vosmhost[0-9]:ping: customer-'"$n"'-svr: Temporary failure in name resolution'
            assert_line --index 2 'Command: del_customer : Result: SUCCESS'
            assert_success
        done
    done
}

@test "Create customer when there is no more space" {
    :
}

teardown() {
    # echo "Clean up..." >&3
    :
}
