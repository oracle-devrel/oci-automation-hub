# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from cleaner_ui.selection_state import (
    abandon_execute_review,
    clear_completed_run_display,
    reset_profile_selection,
)


def test_profile_change_clears_stale_selection_without_affecting_active_run() -> None:
    state: dict[str, object] = {
        "regions": ["eu-frankfurt-1"],
        "compartments": ["old-compartment"],
        "tenancy_id": "old-tenancy",
        "tenancy_name": "Old Tenancy",
        "selected_region": "eu-frankfurt-1",
        "selected_compartment_id": "old-compartment",
        "compartment_search": "old",
        "run": "active-run",
    }

    reset_profile_selection(state)

    assert state == {
        "regions": [],
        "compartments": [],
        "tenancy_id": None,
        "tenancy_name": None,
        "run": "active-run",
    }


def test_new_target_clears_completed_run_output() -> None:
    state: dict[str, object] = {
        "run": "completed-run",
        "log_offset": 250,
        "run_log": "old cleaner log",
        "run_output": "old process output",
    }

    clear_completed_run_display(state)

    assert state == {
        "run": None,
        "log_offset": 0,
        "run_log": "",
        "run_output": "",
        "audit_run": None,
        "audit_log_offset": 0,
        "audit_log": "",
        "audit_output": "",
        "reviewed_dry_run": None,
        "execute_run": None,
        "execute_log_offset": 0,
        "execute_log": "",
        "execute_output": "",
    }


def test_abandon_execute_review_clears_only_ui_approval() -> None:
    state: dict[str, object] = {
        "reviewed_dry_run": {"path": "/tmp/plan"},
        "execute_confirmation": "DELETE",
        "execute_backup_mode": "Skip Resource Manager discovery stack",
        "execute_backup_compartment": "ocid1.compartment.oc1..backup",
        "execute_backup_region": "eu-amsterdam-1",
        "run": "completed-dry-run",
    }

    abandon_execute_review(state)

    assert state == {
        "reviewed_dry_run": None,
        "execute_confirmation": "",
        "execute_backup_mode": "Create Resource Manager discovery stack",
        "run": "completed-dry-run",
    }
