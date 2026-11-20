# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

import sys
from logging import getLogger
from pathlib import Path

import pytest

CLEANER_ROOT = Path(__file__).resolve().parents[1] / "oci-comp-cleaner"
sys.path.insert(0, str(CLEANER_ROOT))

from oci_compartment_cleaner.runtime_backup_flow import prompt_for_delete  # noqa: E402
from oci_compartment_cleaner.runtime_cli_args import parse_args  # noqa: E402


def test_confirm_delete_is_accepted_only_for_execute(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "cleaner",
            "--compartment-id",
            "ocid1.compartment.oc1..target",
            "--region",
            "eu-frankfurt-1",
            "--execute",
            "--confirm-delete",
            "DELETE",
        ],
    )
    assert parse_args().confirm_delete == "DELETE"


@pytest.mark.parametrize(
    "arguments",
    [
        ["--confirm-delete", "DELETE"],
        ["--execute", "--confirm-delete", "delete"],
        ["--ui-confirmation-stdin"],
        ["--execute", "--confirm-delete", "DELETE", "--ui-confirmation-stdin"],
    ],
)
def test_confirm_delete_rejects_misplaced_or_invalid_values(
    monkeypatch: pytest.MonkeyPatch, arguments: list[str]
) -> None:
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "cleaner",
            "--compartment-id",
            "ocid1.compartment.oc1..target",
            "--region",
            "eu-frankfurt-1",
            *arguments,
        ],
    )
    with pytest.raises(SystemExit):
        parse_args()


def test_ui_confirmation_uses_later_standard_input_without_a_new_plan(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr("builtins.input", lambda: "DELETE")

    assert prompt_for_delete([object()], getLogger("test"), ui_confirmation_stdin=True)

    assert "UI_CONFIRMATION_REQUIRED" in capsys.readouterr().out


def test_ui_confirmation_aborts_for_any_value_other_than_delete(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr("builtins.input", lambda: "ABORT")

    assert not prompt_for_delete([object()], getLogger("test"), ui_confirmation_stdin=True)
