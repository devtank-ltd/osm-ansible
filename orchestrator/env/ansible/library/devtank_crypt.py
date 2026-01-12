#!/usr/bin/python

import base64
import traceback

from ansible.module_utils.basic import AnsibleModule  # type: ignore
from cryptography.fernet import Fernet


def main():
    module_args = dict(
        input_string=dict(type="str", required=False),
        action=dict(type="str", required=True),
        key=dict(type="str", required=False),
    )

    module = AnsibleModule(
        argument_spec=module_args,
        required_if=[
            ("action", "encrypt", ("key", "input_string")),
            ("action", "decrypt", ("key", "input_string")),
        ],
    )

    try:
        action = module.params["action"].lower()
        input_string = module.params.get("input_string")
        key_param = module.params.get("key")

        allowed_actions = ("encrypt", "decrypt", "generate_key")
        if action not in allowed_actions:
            module.fail_json(msg=f"Only {allowed_actions} are supported. Got '{action}'")

        if key_param:
            try:
                key = key_param
            except Exception:
                module.fail_json(msg=f"Invalid base64 key provided: {key_param}")
        else:
            key = Fernet.generate_key()

        result = {"changed": False, "output": {}}

        if action == "generate_key":
            result["output"]["key"] = key
            module.exit_json(**result)

        if not input_string:
            module.fail_json(msg=f"input_string is required for action '{action}'")

        try:
            crypt = Fernet(key)
        except Exception:
            module.fail_json(msg=f"Invalid Fernet key provided: {key_param}")

        if action == "encrypt":
            encrypted_bytes = crypt.encrypt(input_string.encode("utf-8"))
            output_string = encrypted_bytes.decode("utf-8")
        else:
            try:
                input_bytes = base64.b64decode(input_string)
            except Exception:
                module.fail_json(msg="input_string must be base64-encoded for decryption")

            try:
                output_string = crypt.decrypt(input_bytes).decode("utf-8")
            except Exception as e:
                module.fail_json(
                    msg=(
                        f"Error during decrypt: {e}\n"
                        f"Check that the key matches the input string.\n"
                        f"input_string={input_string}\n"
                        f"key={key_param}"
                    )
                )

        result["output"]["key"] = key_param if key_param else base64.b64encode(key).decode("utf-8")
        result["output"]["string"] = output_string
        module.exit_json(**result)

    except Exception as e:
        module.fail_json(msg=f"Unexpected exception: {e}\n{traceback.format_exc()}")


if __name__ == "__main__":
    main()
