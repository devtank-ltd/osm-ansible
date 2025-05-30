import base64

from ansible.module_utils.basic import AnsibleModule  # type: ignore
from typing import Any, Dict, Optional, Protocol, Union

from pyosmorch import DBConnectionOrchestrator, DBConnectionPowerDNS  # type: ignore


class DatabaseHandler(Protocol):
    def handle(self, module: AnsibleModule) -> Dict[str, Any]: ...


class OrchestratorHandler:
    def __init__(self, db: DBConnectionOrchestrator):
        self.db = db

    def handle(self, module: AnsibleModule) -> Dict[str, Any]:
        method = module.params["method"]
        db_method = getattr(self, method, None)
        if not callable(db_method):
            module.fail_json(msg=f"Unsupported method: {method}")
        # make mypy satisfied
        assert callable(db_method)
        return db_method(module)

    def add_customer(self, module: AnsibleModule) -> Dict[str, Any]:
        args = [
            module.params["osm_host_id"],
            module.params["customer_name"],
            module.params["mqtt_port"],
        ]
        res = self.db.add_customer(*args)
        if not res:
            module.fail_json(msg="Failed to add customer")
        return {"id": res.id}

    def remove_customer(self, module: AnsibleModule) -> Dict[str, Any]:
        customer = module.params["customer_name"]
        customer_id = self.db.get_customer_id(customer)
        host_id = self.db.get_host_by_customer(customer)

        if not customer_id or not host_id:
            module.fail_json(msg="Unable to get customer or host ID")

        host_name = self.db.get_host_name_by_id(host_id)
        host_ipaddr = self.db.get_hosts_ipaddr(host_id)

        if not host_name or not host_ipaddr:
            module.fail_json(msg="Unable to get host details")

        if not all(
            [
                self.db.del_customer(customer, host_id),
                self.db.del_customer_secret_key(customer_id),
                self.db.del_customer_secrets(customer_id),
            ]
        ):
            module.fail_json(
                msg=f"Failed to fully remove customer '{customer}'"
            )

        return {
            "customer_name": customer,
            "host_name": host_name,
            "host_ipaddr": host_ipaddr,
        }

    def add_customer_secrets(self, module: AnsibleModule) -> Dict[str, Any]:
        key = base64.b64encode(module.params["key"].encode("utf-8")).decode(
            "utf-8"
        )
        data = module.params["data"]
        customer_id = module.params["customer_id"]

        if not self.db.add_customer_secret_key(customer_id, key):
            module.fail_json(msg="Failed to add customer key")
        if not self.db.add_customer_secrets(customer_id, data):
            module.fail_json(msg="Failed to add customer secrets")

        return {}

    def get_host(self, module: AnsibleModule) -> Dict[str, Any]:
        host_name = module.params["host_name"]
        res = self.db.get_host(host_name)
        return {
            "host_id": res.id,
            "host_name": res.name,
            "host_ip": res.ip_addr,
            "host_capacity": res.capacity,
        }

    def get_host_name_by_customer(
        self, module: AnsibleModule
    ) -> Dict[str, Any]:
        customer = module.params.get("customer_name")
        host_id = self.db.get_host_by_customer(customer)
        host_name = self.db.get_host_name_by_id(host_id)

        if not host_name:
            module.fail_json(msg="Unable to get host name")
        return {"host_name": host_name}

    def get_customer_port(self, module: AnsibleModule) -> Dict[str, Any]:
        customer = module.params.get("customer_name")
        port = self.db.get_customer_port(customer)
        return {"mqtt_port": port}

    def update_customer_host(self, module: AnsibleModule) -> Dict[str, Any]:
        customer = module.params.get("customer_name")
        host_id = module.params.get("osm_host_id")
        if not self.db.update_customer_host(customer, host_id):
            module.fail_json(msg="Failed to update customer host")
        return {}


class PDNSHandler:
    def __init__(self, db: DBConnectionPowerDNS):
        self.db = db

    def handle(self, module: AnsibleModule) -> Dict[str, Any]:
        customer = module.params.get("customer_name")
        domain = module.params.get("domain")
        host_name = module.params.get("host_name")
        method = module.params.get("method")
        target_host = f"{host_name}.{domain}"
        name_parts = ("", "-chirspstack", "-influx", "-mqtt")

        result = (
            {"customer": customer, "host": target_host}
            if method == "update_record"
            else {}
        )

        for part in name_parts:
            alias = f"{customer}{part}.{domain}"

            if method == "update_record":
                if not self.db.update_record(alias, target_host):
                    module.fail_json(msg=f"Failed to update record for {alias}")

            elif method == "add_customer":
                domain_id = module.params.get("domain_id")
                if not self.db.add_customer(domain_id, alias, target_host):
                    module.fail_json(msg=f"Failed to add alias '{alias}'")

            elif method == "del_customer":
                domain_id = module.params.get("domain_id")
                if not self.db.del_customer(domain_id, alias, target_host):
                    module.fail_json(msg=f"Failed to remove alias '{alias}'")

            else:
                module.fail_json(
                    msg=f"Unsupported alias management method: {method}"
                )

        return result


def db_handler(conf: Dict[str, Any], module: AnsibleModule) -> DatabaseHandler:
    db_name = conf["database"]
    if db_name == "osm_orchestrator":
        return OrchestratorHandler(DBConnectionOrchestrator(**conf))
    elif db_name == "pdns":
        return PDNSHandler(DBConnectionPowerDNS(**conf))
    else:
        module.fail_json(msg=f"Unsupported database: {db_name}")
        # make mypy satisfied
        raise RuntimeError("Should never get this")


def main() -> None:
    module_args = dict(
        db_conf=dict(type="dict", required=True),
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

    result: Dict[str, Any] = {"changed": False, "message": "", "output": ""}

    module = AnsibleModule(argument_spec=module_args)

    conf = module.params["db_conf"]
    database_conf = {
        "drivername": "mysql+pymysql",
        "username": conf["user"],
        "password": conf["password"],
        "host": conf["host"],
        "database": conf["database"],
    }

    handler = db_handler(database_conf, module)
    result["output"] = handler.handle(module)

    module.exit_json(**result)


if __name__ == "__main__":
    main()
