import weakref

class plugin_base_t:
    def __init__(self, parent):
        self._parent = weakref.ref(parent)

    @property
    def parent(self):
        return self._parent()

    @property
    def version(self) -> int:
        raise NotImplementedError

    def get_commands(self) -> dict:
        raise NotImplementedError
