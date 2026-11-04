import re

from pynvim import Nvim


def redact(msg: str) -> str:
    """Hide Jupyter Server tokens: remote kernels are named after a URL that carries one."""
    return re.sub(r"(token=)[^&\s'`\"]+", r"\1***", msg)


class MoltenException(Exception):
    pass


def nvimui(func):  # type: ignore
    def inner(self, *args, **kwargs):  # type: ignore
        try:
            func(self, *args, **kwargs)
        except MoltenException as err:
            self.nvim.err_write("[Molten] " + redact(str(err)) + "\n")

    return inner


def _notify(nvim: Nvim, msg: str, log_level: str) -> None:
    msg = redact(msg)
    lua = f"""
        vim.schedule_wrap(function()
            vim.notify([[[Molten] {msg}]], vim.log.levels.{log_level}, {{}})
        end)()
    """
    nvim.exec_lua(lua)


def notify_info(nvim: Nvim, msg: str) -> None:
    """Use the vim.notify API to display an info message."""
    _notify(nvim, msg, "INFO")


def notify_warn(nvim: Nvim, msg: str) -> None:
    """Use the vim.notify API to display a warning message."""
    _notify(nvim, msg, "WARN")


def notify_error(nvim: Nvim, msg: str) -> None:
    """Use the vim.notify API to display an error message."""
    _notify(nvim, msg, "ERROR")
