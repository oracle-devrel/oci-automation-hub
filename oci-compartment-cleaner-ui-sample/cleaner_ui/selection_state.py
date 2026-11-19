# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Session-state changes required when OCI profile selection changes."""

from __future__ import annotations

from collections.abc import MutableMapping


def reset_profile_selection(state: MutableMapping[str, object]) -> None:
    """Remove selection values that are unsafe to carry across OCI profiles."""
    state["regions"] = []
    state["compartments"] = []
    state["tenancy_id"] = None
    state["tenancy_name"] = None
    for key in (
        "selected_region",
        "selected_compartment_id",
        "compartment_search",
        "audit_scan_compartment_ids",
    ):
        state.pop(key, None)


def clear_completed_run_display(state: MutableMapping[str, object]) -> None:
    """Clear completed-run output when the operator chooses a new target."""
    state["run"] = None
    state["log_offset"] = 0
    state["run_log"] = ""
    state["run_output"] = ""
    state["audit_run"] = None
    state["audit_log_offset"] = 0
    state["audit_log"] = ""
    state["audit_output"] = ""
    state["reviewed_dry_run"] = None
    state["execute_run"] = None
    state["execute_log_offset"] = 0
    state["execute_log"] = ""
    state["execute_output"] = ""


def abandon_execute_review(state: MutableMapping[str, object]) -> None:
    """Remove the UI-only approval that allows a dry-run to be executed."""
    state["reviewed_dry_run"] = None
    state["execute_confirmation"] = ""
    state["execute_backup_mode"] = "Create Resource Manager discovery stack"
    state.pop("execute_backup_compartment", None)
    state.pop("execute_backup_region", None)
