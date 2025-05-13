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
    )

    result = dict(
        changed=False,
        message=""
    )
    module = AnsibleModule(
        argument_spec=module_args,
        required_if=[
            ("method", "add_customer",
             ("osm_host_id", "customer_name", "mqtt_port")
             ),
            ("method", "add_customer_dns",
             ("customer_name", "domain", "domain_id", "host_name")
             ),
        ],
    )
    conf = {
        "drivername": "mysql+pymysql",
        "username": module.params["db_username"],
        "password": module.params["db_password"],
        "host": module.params["db_host"],
        "database": module.params["db_name"]
    }
    osm_db = DBConnectionOrchestrator(**conf)
    dns_db = DBConnectionPowerDNS(**conf)


    if module.params['method'] == "add_customer":
        query = getattr(osm_db, module.params['method'])
        res = query(
            module.params["osm_host_id"],
            module.params["customer_name"],
            module.params["mqtt_port"],
        )

        if res:
            result['changed'] = True
            result['message'] = (
                f"Customer {module.params['customer_name']} added. "
                f"Host ID: {module.params['osm_host_id']}, record ID: {res.id}"
        )
    if module.params['method'] == "add_customer_dns":
        query = getattr(dns_db, "add_customer")
        target_host = f"{module.params['host_name']}.{module.params['domain']}"
        for part in ("", "-chirspstack", "-influx", "-mqtt"):
            full_name = (
                f"{module.params['customer_name']}{part}."
                f"{module.params['domain']}"
            )
            res = query(module.params["domain_id"], full_name, target_host)
            if not res:
                module.fail_json(msg=f"Failed to add DNS record '{full_name}'")

    module.exit_json(**result)

if __name__ == '__main__':
    main()
