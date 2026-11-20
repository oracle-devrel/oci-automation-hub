# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

import sys
import time
from pathlib import Path

from cleaner_ui.cleaner_adapter import CleanerRun
from cleaner_ui.execute_supervisor import supervise


def test_stale_heartbeat_interrupts_harmless_child(tmp_path: Path) -> None:
    heartbeat = tmp_path / "heartbeat"
    heartbeat.touch()
    time.sleep(0.05)

    exit_code = supervise(
        [sys.executable, "-c", "import time; time.sleep(30)"],
        heartbeat,
        stale_seconds=0.01,
        grace_seconds=0.1,
    )

    assert exit_code != 0


def test_cancelled_execute_run_interrupts_supervised_harmless_child(tmp_path: Path) -> None:
    run = CleanerRun.start_execute(
        [sys.executable, "-c", "import time; time.sleep(30)"],
        tmp_path,
    )
    time.sleep(0.1)
    run.cancel()
    run.process.wait(timeout=5)

    assert run.status().value == "cancelled"


def test_closed_ui_pipe_interrupts_supervised_harmless_child(tmp_path: Path) -> None:
    run = CleanerRun.start_execute(
        [sys.executable, "-c", "import time; time.sleep(30)"],
        tmp_path,
    )
    assert run.process.stdin is not None
    run.process.stdin.close()
    run.process.wait(timeout=5)

    assert run.status().value == "failed"


def test_supervisor_forwards_ui_confirmation_to_harmless_child(tmp_path: Path) -> None:
    run = CleanerRun.start_execute(
        [
            sys.executable,
            "-u",
            "-c",
            "print('UI_CONFIRMATION_REQUIRED', flush=True); print(input(), flush=True)",
        ],
        tmp_path,
    )
    for _ in range(20):
        run.drain_output()
        if run.awaiting_confirmation:
            break
        time.sleep(0.05)

    assert run.awaiting_confirmation
    run.send_confirmation("DELETE")
    run.process.wait(timeout=5)

    assert run.status().value == "succeeded"


def test_supervisor_uses_configured_cleaner_working_directory(tmp_path: Path) -> None:
    heartbeat = tmp_path / "heartbeat"
    heartbeat.touch()
    output = tmp_path / "working-directory.txt"

    exit_code = supervise(
        [
            sys.executable,
            "-c",
            f"from pathlib import Path; Path({str(output)!r}).write_text(str(Path.cwd()))",
        ],
        heartbeat,
        stale_seconds=1,
        grace_seconds=0.1,
        child_cwd=tmp_path,
    )

    assert exit_code == 0
    assert output.read_text(encoding="utf-8") == str(tmp_path)
