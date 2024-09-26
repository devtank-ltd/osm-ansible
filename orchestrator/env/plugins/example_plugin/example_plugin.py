import os
from collections import namedtuple


class example_plugin_t:
    def __init__(self):
        self._version = 1

    @property
    def get_version(self) -> int:
        return self._version

    def example_cmd(self, arg: str) -> int:
        print(f"Example cmd - you supplied the argument: {arg}")
        return os.EX_OK

    def get_commands(self) -> dict:
        cmd_entry = namedtuple("cmd_entry", ["help", "func"])
        self.commands = {
            "example_imported_cmd": cmd_entry(
                "example_imported_cmd <arg> : call example function \
                 with argument",
                 self.example_cmd
            )
        }
        return self.commands


def init_plugin():
    return example_plugin_t()
