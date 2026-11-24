"""Entry point for MacKVM Ubuntu X11 controlled client."""

from __future__ import annotations

import argparse
import os
import signal
import sys

from .state import config_dir


def _signal_running_instance() -> bool:
    pid_file = config_dir() / "instance.pid"
    if not pid_file.exists():
        return False
    try:
        pid = int(pid_file.read_text(encoding="utf-8").strip())
        if pid <= 0 or pid == os.getpid():
            return False
        os.kill(pid, signal.SIGUSR1)
        return True
    except (ValueError, ProcessLookupError, PermissionError):
        return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="MacKVM Ubuntu X11 controlled client")
    parser.add_argument("--show", action="store_true", help="Show the MacKVM window (or focus running instance)")
    args = parser.parse_args(argv)

    if _signal_running_instance():
        return 0

    from .app import UbuntuApp

    app = UbuntuApp(force_show=args.show)
    app.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
