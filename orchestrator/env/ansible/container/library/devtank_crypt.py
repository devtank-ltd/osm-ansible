#!/usr/bin/python

import subprocess

from ansible.module_utils.basic import AnsibleModule  # type: ignore
from cryptography.fernet import Fernet


def main():
    module_args = dict(
        input_string=dict(type="str"),
        action=dict(type="str", required=True),
        key=dict(type="str"),
    )

    result = dict(
        changed=False,
        message="",
        output="",
    )

    module = AnsibleModule(
        argument_spec=module_args,
        required_if=[
            ("action", "encrypt", ("key", "input_string")),
            ("action", "decrypt", ("key", "input_string")),
        ]
    )

    input_string = module.params["input_string"]
    action = module.params["action"]

    if action not in ("encrypt", "decrpyt","generate_key"):
        module.fail_json(
            msg=(
                "Only 'encrypt', 'decrypt' 'generate_key' actions are supported"
                f". Got '{action}'"
            )
        )

    if module.params["key"]:
        key = module.params["key"].encode("utf-8")
    else:
        key = Fernet.generate_key()

    if action == "generate_key":
        result["output"] = {"key": key}
    else:
        bstring = input_string.encode("utf-8")
        crypt = Fernet(key)

        output_string = getattr(crypt, action)(bstring).decode("utf-8")
        result["output"] = {"key": key, "string": output_string,}

    module.exit_json(**result)


if __name__ == '__main__':
    main()
