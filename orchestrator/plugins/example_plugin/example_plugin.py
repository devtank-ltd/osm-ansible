import os
import sys
from pathlib import Path
from collections import namedtuple

sys.path.append(str(Path(__file__).parents[1]))

from plugin_base import plugin_base_t

class example_plugin_t(plugin_base_t):
    def __init__(self, parent):
        super().__init__(parent)
        self._api_version = 1

    @property
    def api_version(self) -> int:
        return self._api_version

    def example_cmd(self, arg: str) -> int:
        print(f"Example cmd - you supplied the argument: {arg}")
        return os.EX_OK

    def get_commands(self) -> dict:
        cmd_entry = namedtuple("cmd_entry", ["help", "func"])
        self.commands = {
            "example_imported_cmd": cmd_entry(
                "example_imported_cmd <arg> : call example function with argument",
                 self.example_cmd
            )
        }
        return self.commands


def init_plugin(parent):
    return example_plugin_t(parent)

