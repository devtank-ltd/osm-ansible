#!/usr/bin/python

from ansible.module_utils.basic import AnsibleModule  # type: ignore
from pyosmorch import DBConnectionOrchestrator, DBConnectionPowerDNS  # type: ignore


def main():
    module_args = dict(
        db_username=dict(type="str", required=True),
        db_password=dict(type="str", required=True, no_log=True),
        db_host=dict(type="str", required=True),
        db_name=dict(type="str", required=True),
        method=dict(type="str", required=True),
        osm_host_id=dict(type="int"),
        customer_name=dict(type="str"),
        mqtt_port=dict(type="int"),
        domain=dict(type="str"),
        domain_id=dict(type="int"),
        host_name=dict(type="str"),
        customer_id=dict(type="str"),
        key=dict(type="str"),
        data=dict(type="str"),
    )

    result = dict(
        changed=False,
        message="",
        output=""
    )
    module = AnsibleModule(
        argument_spec=module_args,
        mutually_exclusive=[
            ("osm_host_id", "domain"),
            ("osm_host_id", "domain_id"),
            ("osm_host_id", "host_name"),
            ("mqtt_port", "domain"),
            ("mqtt_port", "domain_id"),
            ("mqtt_port", "host_name"),

        ]
    )
    conf = {
        "drivername": "mysql+pymysql",
        "username": module.params["db_username"],
        "password": module.params["db_password"],
        "host": module.params["db_host"],
        "database": module.params["db_name"]
    }

    db_name = module.params["db_name"]
    db_query = module.params["method"]

    if db_name == "pdns":
        db = DBConnectionPowerDNS(**conf)
    elif db_name == "osm_orchestrator":
        db = DBConnectionOrchestrator(**conf)
    else:
        module.fail_json(msg=f"Unknown database name '{db_name}'")

    query = getattr(db, db_query, None)

    if db_name == "osm_orchestrator":
        if db_query == "add_customer":
            args = [
                module.params["osm_host_id"],
                module.params["customer_name"],
                module.params["mqtt_port"],
            ]
            res = query(*args)
            if not res:
                module.fail_json(msg=f"Failed to customer")
            result['output'] = {'id': res.id}

        if db_query == "remove_customer":
            customer = module.params['customer_name']
            host_id = db.get_host_by_customer(customer)

            if not host_id:
                module.fail_json(msg=f"Unable to get host id of '{customer}'")

            host_name = db.get_host_name_by_id(host_id)
            host_ipaddr = db.get_hosts_ipaddr(host_id)

            if not host_name:
                module.fail_json(
                    msg=f"Unable to get host name by id '{host_id}'"
                )

            if not host_ipaddr:
                module.fail_json(
                    msg=f"Unable to get ip address of '{host_name}'"
                )

            if not db.del_customer(customer, host_id):
                module.fail_json(msg=f"Unable to delete customer '{customer}'")

            result['output'] = {
                'customer_name': customer,
                'host_name': host_name,
                'host_ipaddr': host_ipaddr
            }

        if db_query == "add_customer_secrets":
            key = module.params["key"]
            data = module.params["data"]
            customer_id = module.params["customer_id"]
            db.add_customer_secret_key(customer_id, key) or module.fail_json(
                msg="Failed to add customer key"
            )
            db.add_customer_secrets(customer_id, data) or module.fail_json(
                msg="Failed to add customer secrets"
            )

    elif db_name == "pdns":
        name_parts = ("", "-chirspstack", "-influx", "-mqtt")
        customer = module.params.get('customer_name') or module.fail_json(
            msg="Unable to get customer name"
        )
        domain_id = module.params.get('domain_id') or module.fail_json(
            msg="Unable to get domain_id"
        )
        domain = module.params.get('domain') or module.fail_json(
            msg="Unable to get domain"
        )
        osm_host = module.params.get('host_name') or module.fail_json(
                msg="Unable to get host name"
        )
        target_host = f"{osm_host}.{domain}"

        for part in name_parts:
            alias = f"{customer}{part}.{domain}"
            action = "add" if "add" in db_query else "remove"
            query(domain_id, alias, target_host) or module.fail_json(
                msg=f"Failed to {action} alias '{alias}'"
            )

    module.exit_json(**result)

if __name__ == '__main__':
    main()
