# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Heartbeat-based parent for destructive cleaner executions.

This process deliberately owns the cleaner process group.  If the local UI
server disappears, or its heartbeat stops, it interrupts the cleaner rather
than leaving a destructive operation orphaned.
"""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path


def _interrupt_process_group(process: subprocess.Popen[str], grace_seconds: float) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        process.send_signal(signal.CTRL_BREAK_EVENT)
    else:
        os.killpg(process.pid, signal.SIGINT)
    try:
        process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        else:
            os.killpg(process.pid, signal.SIGTERM)


def supervise(
    command: list[str],
    heartbeat_path: Path,
    stale_seconds: float,
    grace_seconds: float,
    child_cwd: Path | None = None,
    monitor_ui_pipe: bool = False,
) -> int:
    options: dict[str, object] = {
        "stdout": None,
        "stderr": None,
        "stdin": subprocess.PIPE,
        "text": True,
        "cwd": str(child_cwd) if child_cwd else None,
    }
    if os.name == "nt":
        options["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        options["start_new_session"] = True
    child = subprocess.Popen(command, **options)  # type: ignore[arg-type]
    parent_pipe_closed = threading.Event()

    def forward_ui_decision() -> None:
        """Forward one UI decision; EOF means the UI/server process has gone away."""
        try:
            line = sys.stdin.readline()
        except (OSError, ValueError):
            parent_pipe_closed.set()
            return
        if not line:
            parent_pipe_closed.set()
            return
        if child.poll() is None and child.stdin is not None:
            try:
                child.stdin.write(line)
                child.stdin.flush()
            except OSError:
                return

    if monitor_ui_pipe:
        threading.Thread(target=forward_ui_decision, daemon=True).start()
    interruption_requested = False

    def request_interruption(_signal_number: int, _frame: object) -> None:
        nonlocal interruption_requested
        interruption_requested = True

    signal.signal(signal.SIGINT, request_interruption)
    signal.signal(signal.SIGTERM, request_interruption)
    while child.poll() is None:
        try:
            heartbeat_age = time.time() - heartbeat_path.stat().st_mtime
        except OSError:
            heartbeat_age = float("inf")
        if interruption_requested or heartbeat_age > stale_seconds or parent_pipe_closed.is_set():
            if interruption_requested:
                reason = "cancellation requested"
            elif parent_pipe_closed.is_set():
                reason = "UI confirmation pipe closed"
            else:
                reason = "UI heartbeat expired"
            print(
                f"Execute supervisor: {reason}; interrupting cleaner.",
                flush=True,
            )
            _interrupt_process_group(child, grace_seconds)
            return child.wait()
        time.sleep(min(1.0, stale_seconds / 3))
    return child.returncode or 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Supervise an OCI cleaner execute process.")
    parser.add_argument("--heartbeat-path", required=True)
    parser.add_argument("--stale-seconds", type=float, default=15.0)
    parser.add_argument("--grace-seconds", type=float, default=10.0)
    parser.add_argument("--child-cwd", help="Working directory for the cleaner process.")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a cleaner command is required after --")
    return supervise(
        command,
        Path(args.heartbeat_path),
        args.stale_seconds,
        args.grace_seconds,
        Path(args.child_cwd) if args.child_cwd else None,
        monitor_ui_pipe=True,
    )


if __name__ == "__main__":
    raise SystemExit(main())
