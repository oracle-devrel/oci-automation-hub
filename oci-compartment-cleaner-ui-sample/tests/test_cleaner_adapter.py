# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from pathlib import Path

import pytest

from cleaner_ui.cleaner_adapter import (
    build_dry_run_command,
    build_execute_command,
    build_network_audit_command,
)
from cleaner_ui.validation import ValidationError


def test_builds_dry_run_command_without_shell(tmp_path: Path) -> None:
    config = tmp_path / "config"
    config.write_text("[DEFAULT]\n", encoding="utf-8")
    output = tmp_path / "run"
    output.mkdir()

    command = build_dry_run_command(
        compartment_id="ocid1.compartment.oc1..example",
        region="eu-frankfurt-1",
        config_file=config,
        profile="DEFAULT",
        output_directory=output,
        python_executable="python-test",
    )

    assert command[:3] == ["python-test", "-m", "oci_compartment_cleaner"]
    assert "--dry-run-only" in command
    assert "--execute" not in command
    assert str(output.resolve()) in command


def test_rejects_missing_output_directory(tmp_path: Path) -> None:
    config = tmp_path / "config"
    config.write_text("[DEFAULT]\n", encoding="utf-8")
    with pytest.raises(ValidationError):
        build_dry_run_command(
            compartment_id="ocid1.compartment.oc1..example",
            region="eu-frankfurt-1",
            config_file=config,
            profile="DEFAULT",
            output_directory=tmp_path / "missing",
        )


def test_builds_network_audit_command_with_selected_external_compartments(tmp_path: Path) -> None:
    config = tmp_path / "config"
    config.write_text("[DEFAULT]\n", encoding="utf-8")
    output = tmp_path / "audit"
    output.mkdir()

    command = build_network_audit_command(
        compartment_id="ocid1.compartment.oc1..target",
        region="eu-frankfurt-1",
        config_file=config,
        profile="DEFAULT",
        output_directory=output,
        scan_compartment_ids=(
            "ocid1.compartment.oc1..external-one",
            "ocid1.compartment.oc1..external-two",
        ),
        skip_vnic_scan=True,
    )

    assert command[1].endswith("network_usage_audit.py")
    assert command.count("--scan-compartment-id") == 2
    assert "--no-vnic-scan" in command
    assert "--zero-exit-on-findings" not in command


def test_rejects_target_compartment_as_external_audit_scope(tmp_path: Path) -> None:
    config = tmp_path / "config"
    config.write_text("[DEFAULT]\n", encoding="utf-8")
    output = tmp_path / "audit"
    output.mkdir()

    with pytest.raises(ValidationError, match="target compartment"):
        build_network_audit_command(
            compartment_id="ocid1.compartment.oc1..target",
            region="eu-frankfurt-1",
            config_file=config,
            profile="DEFAULT",
            output_directory=output,
            scan_compartment_ids=("ocid1.compartment.oc1..target",),
        )


def test_builds_execute_command_with_backup_failure_stop_policy(tmp_path: Path) -> None:
    config = tmp_path / "config"
    config.write_text("[DEFAULT]\n", encoding="utf-8")
    output = tmp_path / "execute"
    output.mkdir()

    command = build_execute_command(
        compartment_id="ocid1.compartment.oc1..target",
        region="eu-frankfurt-1",
        config_file=config,
        profile="DEFAULT",
        output_directory=output,
        create_backup_stack=True,
        backup_stack_compartment_id="ocid1.compartment.oc1..backup",
        backup_stack_region="eu-amsterdam-1",
        confirmation="DELETE",
    )

    assert "--execute" in command
    assert "--dry-run-only" not in command
    assert command[command.index("--confirm-delete") + 1] == "DELETE"
    assert command[command.index("--rm-backup-failure-action") + 1] == "stop"


def test_builds_execute_command_that_pauses_for_ui_confirmation(tmp_path: Path) -> None:
    config = tmp_path / "config"
    config.write_text("[DEFAULT]\n", encoding="utf-8")
    output = tmp_path / "execute"
    output.mkdir()

    command = build_execute_command(
        compartment_id="ocid1.compartment.oc1..target",
        region="eu-frankfurt-1",
        config_file=config,
        profile="DEFAULT",
        output_directory=output,
        create_backup_stack=False,
        ui_confirmation_stdin=True,
    )

    assert "--ui-confirmation-stdin" in command
    assert "--confirm-delete" not in command


def test_execute_rejects_invalid_confirmation_and_same_backup_compartment(tmp_path: Path) -> None:
    config = tmp_path / "config"
    config.write_text("[DEFAULT]\n", encoding="utf-8")
    output = tmp_path / "execute"
    output.mkdir()
    common = dict(
        compartment_id="ocid1.compartment.oc1..target",
        region="eu-frankfurt-1",
        config_file=config,
        profile="DEFAULT",
        output_directory=output,
    )

    with pytest.raises(ValidationError, match="DELETE exactly"):
        build_execute_command(**common, create_backup_stack=False, confirmation="delete")
    with pytest.raises(ValidationError, match="cannot be combined"):
        build_execute_command(
            **common,
            create_backup_stack=False,
            confirmation="DELETE",
            ui_confirmation_stdin=True,
        )
    with pytest.raises(ValidationError, match="must differ"):
        build_execute_command(
            **common,
            create_backup_stack=True,
            backup_stack_compartment_id="ocid1.compartment.oc1..target",
            confirmation="DELETE",
        )
