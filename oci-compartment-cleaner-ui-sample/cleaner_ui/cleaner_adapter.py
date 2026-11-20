# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Safe, narrow subprocess adapter for the existing OCI cleaner module."""

from __future__ import annotations

import os
import queue
import signal
import subprocess
import sys
import threading
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

from .models import RunStatus
from .settings import APP_ROOT, load_settings
from .validation import (
    ValidationError,
    require_compartment_ocid,
    require_existing_file,
    require_region,
)

CLEANER_ROOT = load_settings().cleaner_root


def build_dry_run_command(
    *,
    compartment_id: str,
    region: str,
    config_file: str | Path,
    profile: str,
    output_directory: Path,
    python_executable: str = sys.executable,
) -> list[str]:
    """Build a dry-run-only command without involving a shell."""
    if not CLEANER_ROOT.is_dir():
        raise ValidationError(f"Cleaner source directory is missing: {CLEANER_ROOT}")
    if not profile.strip():
        raise ValidationError("Select an OCI config profile.")
    config_path = require_existing_file(config_file, "OCI config file")
    if not output_directory.is_dir():
        raise ValidationError("Run output directory has not been created.")
    return [
        python_executable,
        "-m",
        "oci_compartment_cleaner",
        "--compartment-id",
        require_compartment_ocid(compartment_id),
        "--region",
        require_region(region),
        "--auth",
        "config",
        "--config-file",
        str(config_path),
        "--profile",
        profile.strip(),
        "--output-dir",
        str(output_directory.resolve()),
        "--dry-run-only",
    ]


def build_network_audit_command(
    *,
    compartment_id: str,
    region: str,
    config_file: str | Path,
    profile: str,
    output_directory: Path,
    scan_compartment_ids: Sequence[str] = (),
    page_limit: int = 1000,
    compartment_access_level: str = "ACCESSIBLE",
    include_inactive_compartments: bool = False,
    skip_vnic_scan: bool = False,
    skip_service_scan: bool = False,
    debug: bool = False,
    python_executable: str = sys.executable,
) -> list[str]:
    """Build a read-only network-usage-audit command without a shell."""
    if not CLEANER_ROOT.is_dir():
        raise ValidationError(f"Cleaner source directory is missing: {CLEANER_ROOT}")
    audit_script = CLEANER_ROOT / "network_usage_audit.py"
    if not audit_script.is_file():
        raise ValidationError(f"Network audit script is missing: {audit_script}")
    if not profile.strip():
        raise ValidationError("Select an OCI config profile.")
    if not output_directory.is_dir():
        raise ValidationError("Audit output directory has not been created.")
    if page_limit <= 0:
        raise ValidationError("Audit page limit must be greater than zero.")
    if compartment_access_level not in {"ACCESSIBLE", "ANY"}:
        raise ValidationError("Audit compartment access level must be ACCESSIBLE or ANY.")

    target_compartment_id = require_compartment_ocid(compartment_id)
    external_compartment_ids = [require_compartment_ocid(item) for item in scan_compartment_ids]
    if target_compartment_id in external_compartment_ids:
        raise ValidationError(
            "The target compartment cannot be scanned as an external compartment."
        )
    config_path = require_existing_file(config_file, "OCI config file")
    command = [
        python_executable,
        str(audit_script),
        "--compartment-id",
        target_compartment_id,
        "--region",
        require_region(region),
        "--auth",
        "config",
        "--config-file",
        str(config_path),
        "--profile",
        profile.strip(),
        "--output-dir",
        str(output_directory.resolve()),
        "--page-limit",
        str(page_limit),
        "--compartment-access-level",
        compartment_access_level,
    ]
    for external_compartment_id in external_compartment_ids:
        command.extend(("--scan-compartment-id", external_compartment_id))
    if include_inactive_compartments:
        command.append("--include-inactive-compartments")
    if skip_vnic_scan:
        command.append("--no-vnic-scan")
    if skip_service_scan:
        command.append("--no-service-scan")
    if debug:
        command.append("--debug")
    return command


def build_execute_command(
    *,
    compartment_id: str,
    region: str,
    config_file: str | Path,
    profile: str,
    output_directory: Path,
    create_backup_stack: bool,
    backup_stack_compartment_id: str | None = None,
    backup_stack_region: str | None = None,
    confirmation: str | None = None,
    ui_confirmation_stdin: bool = False,
    python_executable: str = sys.executable,
) -> list[str]:
    """Build an execute command that confirms now or pauses for UI confirmation."""
    if ui_confirmation_stdin and confirmation is not None:
        raise ValidationError("UI confirmation cannot be combined with --confirm-delete.")
    if not ui_confirmation_stdin and confirmation != "DELETE":
        raise ValidationError("Type DELETE exactly before starting an execution.")
    command = build_dry_run_command(
        compartment_id=compartment_id,
        region=region,
        config_file=config_file,
        profile=profile,
        output_directory=output_directory,
        python_executable=python_executable,
    )
    command.remove("--dry-run-only")
    command.append("--execute")
    if ui_confirmation_stdin:
        command.append("--ui-confirmation-stdin")
    else:
        command.extend(("--confirm-delete", "DELETE"))
    target_compartment_id = require_compartment_ocid(compartment_id)
    if create_backup_stack:
        if backup_stack_compartment_id is None:
            raise ValidationError(
                "Select a separate backup-stack compartment or choose to skip it."
            )
        backup_compartment_id = require_compartment_ocid(backup_stack_compartment_id)
        if backup_compartment_id == target_compartment_id:
            raise ValidationError(
                "The backup-stack compartment must differ from the target compartment."
            )
        command.extend(("--rm-backup-stack-compartment-id", backup_compartment_id))
        command.extend(("--rm-backup-stack-region", require_region(backup_stack_region or region)))
        command.extend(("--rm-backup-failure-action", "stop"))
    else:
        command.append("--skip-rm-backup-stack")
    return command


@dataclass
class CleanerRun:
    """One started cleaner subprocess and its captured non-secret output."""

    command: Sequence[str]
    output_directory: Path
    process: subprocess.Popen[str]
    output: queue.SimpleQueue[str] = field(default_factory=queue.SimpleQueue)
    cancellation_requested: bool = False
    awaiting_confirmation: bool = False
    confirmation_sent: bool = False
    abort_requested: bool = False
    heartbeat_path: Path | None = None
    _heartbeat_stop: threading.Event | None = field(default=None, repr=False)

    @classmethod
    def start(cls, command: Sequence[str], output_directory: Path) -> CleanerRun:
        popen_options: dict[str, object] = {
            "cwd": str(CLEANER_ROOT),
            "stdout": subprocess.PIPE,
            "stderr": subprocess.PIPE,
            "text": True,
            "bufsize": 1,
        }
        if os.name == "nt":
            popen_options["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
        else:
            popen_options["start_new_session"] = True
        process = subprocess.Popen(list(command), **popen_options)  # type: ignore[arg-type]
        run = cls(command=list(command), output_directory=output_directory, process=process)
        run._start_reader(process.stdout, "stdout")
        run._start_reader(process.stderr, "stderr")
        return run

    @classmethod
    def start_execute(cls, command: Sequence[str], output_directory: Path) -> CleanerRun:
        """Start an execute run through the independent heartbeat supervisor."""
        heartbeat_path = output_directory / ".ui-heartbeat"
        heartbeat_path.touch()
        supervisor_command = [
            sys.executable,
            "-m",
            "cleaner_ui.execute_supervisor",
            "--heartbeat-path",
            str(heartbeat_path),
            "--child-cwd",
            str(CLEANER_ROOT),
            "--",
            *command,
        ]
        popen_options: dict[str, object] = {
            "cwd": str(APP_ROOT),
            "stdout": subprocess.PIPE,
            "stderr": subprocess.PIPE,
            "stdin": subprocess.PIPE,
            "text": True,
            "bufsize": 1,
        }
        if os.name == "nt":
            popen_options["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
        else:
            popen_options["start_new_session"] = True
        process = subprocess.Popen(supervisor_command, **popen_options)  # type: ignore[arg-type]
        run = cls(
            command=list(command),
            output_directory=output_directory,
            process=process,
            heartbeat_path=heartbeat_path,
            _heartbeat_stop=threading.Event(),
        )
        run._start_reader(process.stdout, "stdout")
        run._start_reader(process.stderr, "stderr")
        run._start_heartbeat()
        return run

    def _start_heartbeat(self) -> None:
        if self.heartbeat_path is None or self._heartbeat_stop is None:
            return

        def write_heartbeat() -> None:
            while not self._heartbeat_stop.wait(2):
                if self.process.poll() is not None:
                    return
                self.heartbeat_path.touch(exist_ok=True)

        threading.Thread(target=write_heartbeat, daemon=True).start()

    def _start_reader(self, stream: object, stream_name: str) -> None:
        if stream is None:
            return

        def read_lines() -> None:
            for line in stream:  # type: ignore[union-attr]
                self.output.put(f"[{stream_name}] {line}")

        threading.Thread(target=read_lines, daemon=True).start()

    def drain_output(self) -> str:
        lines: list[str] = []
        while True:
            try:
                lines.append(self.output.get_nowait())
            except queue.Empty:
                text = "".join(lines)
                if "UI_CONFIRMATION_REQUIRED" in text:
                    self.awaiting_confirmation = True
                return text

    def send_confirmation(self, value: str) -> None:
        """Send one UI decision through the supervisor-owned stdin pipe."""
        if value not in {"DELETE", "ABORT"}:
            raise ValidationError("Confirmation must be DELETE or ABORT.")
        if (
            self.process.poll() is not None
            or not self.awaiting_confirmation
            or self.confirmation_sent
        ):
            raise ValidationError("The cleaner is not awaiting a confirmation.")
        if self.process.stdin is None:
            raise ValidationError("The execute confirmation channel is unavailable.")
        try:
            self.process.stdin.write(f"{value}\n")
            self.process.stdin.flush()
        except OSError as exc:
            raise ValidationError(f"Could not send the execution decision: {exc}") from exc
        self.awaiting_confirmation = False
        self.confirmation_sent = True
        self.abort_requested = value == "ABORT"

    def status(self) -> RunStatus:
        exit_code = self.process.poll()
        if exit_code is None:
            if self.cancellation_requested:
                return RunStatus.CANCELLATION_REQUESTED
            return RunStatus.RUNNING
        if self._heartbeat_stop is not None:
            self._heartbeat_stop.set()
        if self.cancellation_requested:
            return RunStatus.CANCELLED
        if self.abort_requested:
            return RunStatus.ABORTED
        return RunStatus.SUCCEEDED if exit_code == 0 else RunStatus.FAILED

    def cancel(self) -> None:
        """Request interruption; OCI-side operations may already be in progress."""
        if self.process.poll() is not None:
            return
        self.cancellation_requested = True
        if os.name == "nt":
            self.process.send_signal(signal.CTRL_BREAK_EVENT)
        else:
            os.killpg(self.process.pid, signal.SIGINT)
