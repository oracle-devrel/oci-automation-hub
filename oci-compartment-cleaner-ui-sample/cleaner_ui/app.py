# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Streamlit entry point for dry-run OCI compartment-cleaner orchestration."""

from __future__ import annotations

import json
from datetime import datetime, timezone

import streamlit as st

from cleaner_ui.artifacts import (
    AuditArtifacts,
    RunArtifacts,
    find_artifacts,
    find_audit_artifacts,
    read_new_text,
)
from cleaner_ui.cleaner_adapter import (
    CleanerRun,
    build_dry_run_command,
    build_execute_command,
    build_network_audit_command,
)
from cleaner_ui.compartment_tree import (
    CompartmentTreeNode,
    build_compartment_tree,
    filter_tree,
    visible_path,
)
from cleaner_ui.config_profiles import default_config_path, list_profiles, load_profile
from cleaner_ui.log_analysis import find_error_entries
from cleaner_ui.models import Compartment
from cleaner_ui.oci_selection import accessible_compartments, subscribed_regions, tenancy_name
from cleaner_ui.paths import create_run_directory
from cleaner_ui.selection_state import (
    clear_completed_run_display,
    reset_profile_selection,
)
from cleaner_ui.ui_errors import profile_refresh_error
from cleaner_ui.validation import ValidationError

st.set_page_config(page_title="OCI Compartment Cleaner", page_icon="⚠️", layout="wide")


def _initialize_state() -> None:
    st.session_state.setdefault("config_path", str(default_config_path()))
    st.session_state.setdefault("profiles", [])
    st.session_state.setdefault("loaded_profile", None)
    st.session_state.setdefault("regions", [])
    st.session_state.setdefault("compartments", [])
    st.session_state.setdefault("run", None)
    st.session_state.setdefault("log_offset", 0)
    st.session_state.setdefault("run_log", "")
    st.session_state.setdefault("run_output", "")
    st.session_state.setdefault("audit_run", None)
    st.session_state.setdefault("audit_log_offset", 0)
    st.session_state.setdefault("audit_log", "")
    st.session_state.setdefault("audit_output", "")
    st.session_state.setdefault("reviewed_dry_run", None)
    st.session_state.setdefault("execute_run", None)
    st.session_state.setdefault("execute_log_offset", 0)
    st.session_state.setdefault("execute_log", "")
    st.session_state.setdefault("execute_output", "")


def _load_profiles() -> None:
    try:
        st.session_state.profiles = list_profiles(st.session_state.config_path)
        st.session_state.loaded_profile = None
        reset_profile_selection(st.session_state)
        if st.session_state.profiles:
            st.session_state.selected_profile = st.session_state.profiles[0]
    except ValidationError as exc:
        st.error(str(exc))


def _load_oci_choices(profile: str) -> bool:
    try:
        config = load_profile(st.session_state.config_path, profile)
        st.session_state.tenancy_name = tenancy_name(config)
        st.session_state.regions = subscribed_regions(config)
        st.session_state.compartments = accessible_compartments(config)
        st.session_state.tenancy_id = config["tenancy"]
        return True
    except ValidationError as exc:
        st.error(profile_refresh_error(exc))
        return False


def _start_dry_run(profile: str, region: str, compartment: Compartment) -> None:
    try:
        output_directory = create_run_directory(
            tenancy_name=st.session_state.get("tenancy_name", "unknown"),
            compartment_name=compartment.name,
            compartment_id=compartment.id,
            region=region,
        )
        command = build_dry_run_command(
            compartment_id=compartment.id,
            region=region,
            config_file=st.session_state.config_path,
            profile=profile,
            output_directory=output_directory,
        )
        st.session_state.run = CleanerRun.start(command, output_directory)
        st.session_state.log_offset = 0
        st.session_state.run_log = ""
        st.session_state.run_output = ""
        st.session_state.reviewed_dry_run = None
    except (OSError, ValidationError) as exc:
        st.error(f"Could not start dry run: {exc}")


def _start_network_audit(
    profile: str,
    region: str,
    compartment: Compartment,
    scan_compartment_ids: list[str],
    page_limit: int,
    compartment_access_level: str,
    include_inactive_compartments: bool,
    skip_vnic_scan: bool,
    skip_service_scan: bool,
    debug: bool,
) -> None:
    try:
        output_directory = create_run_directory(
            tenancy_name=st.session_state.get("tenancy_name", "unknown"),
            compartment_name=compartment.name,
            compartment_id=compartment.id,
            region=region,
            run_type="network-usage-audit",
        )
        command = build_network_audit_command(
            compartment_id=compartment.id,
            region=region,
            config_file=st.session_state.config_path,
            profile=profile,
            output_directory=output_directory,
            scan_compartment_ids=scan_compartment_ids,
            page_limit=page_limit,
            compartment_access_level=compartment_access_level,
            include_inactive_compartments=include_inactive_compartments,
            skip_vnic_scan=skip_vnic_scan,
            skip_service_scan=skip_service_scan,
            debug=debug,
        )
        st.session_state.audit_run = CleanerRun.start(command, output_directory)
        st.session_state.audit_log_offset = 0
        st.session_state.audit_log = ""
        st.session_state.audit_output = ""
    except (OSError, ValidationError) as exc:
        st.error(f"Could not start network usage audit: {exc}")


def _start_execute(
    profile: str,
    region: str,
    compartment: Compartment,
    create_backup_stack: bool,
    backup_compartment_id: str | None,
    backup_region: str | None,
) -> None:
    try:
        output_directory = create_run_directory(
            tenancy_name=st.session_state.get("tenancy_name", "unknown"),
            compartment_name=compartment.name,
            compartment_id=compartment.id,
            region=region,
            run_type="execute",
        )
        command = build_execute_command(
            compartment_id=compartment.id,
            region=region,
            config_file=st.session_state.config_path,
            profile=profile,
            output_directory=output_directory,
            create_backup_stack=create_backup_stack,
            backup_stack_compartment_id=backup_compartment_id,
            backup_stack_region=backup_region,
            ui_confirmation_stdin=True,
        )
        st.session_state.execute_run = CleanerRun.start_execute(command, output_directory)
        st.session_state.execute_log_offset = 0
        st.session_state.execute_log = ""
        st.session_state.execute_output = ""
        st.session_state.execute_confirmation = ""
    except (OSError, ValidationError) as exc:
        st.error(f"Could not start destructive execution: {exc}")


@st.fragment(run_every="1s")
def _render_run() -> None:
    run: CleanerRun | None = st.session_state.run
    if run is None:
        return

    status = run.status()
    st.subheader("Run status")
    if status.value == "running":
        st.error("Running")
    elif status.value == "succeeded":
        st.success("Succeeded")
    elif status.value == "cancellation_requested":
        st.warning("Cancellation requested")
    elif status.value == "cancelled":
        st.warning("Cancelled")
    else:
        st.error("Failed")
    st.caption(f"Artifacts: {run.output_directory}")
    if status.value in {"running", "cancellation_requested"}:
        if st.button("Cancel run", type="secondary"):
            run.cancel()
            st.warning(
                "Cancellation requested. OCI operations already started may continue; "
                "inspect the final log."
            )

    st.session_state.run_output += run.drain_output()
    artifacts = find_artifacts(run.output_directory)
    new_log, next_offset = read_new_text(artifacts.log_path, st.session_state.log_offset)
    st.session_state.log_offset = next_offset
    st.session_state.run_log += new_log

    left, right = st.columns(2)
    with left:
        st.caption("Cleaner log (updates while the run is active)")
        st.code(
            st.session_state.run_log or "Waiting for cleaner log output…",
            language="text",
            height=320,
        )
    with right:
        st.caption("Process standard output and standard error")
        st.code(
            st.session_state.run_output or "No process output yet.",
            language="text",
            height=320,
        )

    if status.value not in {"running", "cancellation_requested"}:
        if status.value == "succeeded" and st.session_state.reviewed_dry_run is None:
            st.session_state.reviewed_dry_run = {
                "profile": st.session_state.get("loaded_profile"),
                "region": st.session_state.get("selected_region"),
                "compartment_id": st.session_state.get("selected_compartment_id"),
                "path": str(run.output_directory),
                "completed_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
            }
        _render_artifacts(artifacts)

    with st.expander("Cleaner command (non-secret arguments)"):
        st.code("\n".join(_redacted_command(run.command)), language="text")


def _render_artifacts(artifacts: RunArtifacts) -> None:
    plan_text_path = artifacts.plan_text_path
    plan_json_path = artifacts.plan_json_path
    if plan_text_path:
        st.subheader("Dry-run plan")
        st.code(
            plan_text_path.read_text(encoding="utf-8", errors="replace"),
            language="text",
            height=320,
        )
    if plan_json_path:
        try:
            st.json(json.loads(plan_json_path.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError) as exc:
            st.warning(f"Could not display JSON plan: {exc}")


@st.fragment(run_every="1s")
def _render_audit_run() -> None:
    run: CleanerRun | None = st.session_state.audit_run
    if run is None:
        return

    status = run.status()
    exit_code = run.process.poll()
    active = status.value in {"running", "cancellation_requested"}
    st.subheader("Network usage audit status")
    if status.value == "running":
        st.error("Running")
    elif exit_code == 2 and not run.cancellation_requested:
        st.warning("Completed with external network-usage findings")
    elif status.value == "succeeded":
        st.success("Succeeded")
    elif status.value == "cancellation_requested":
        st.warning("Cancellation requested")
    elif status.value == "cancelled":
        st.warning("Cancelled")
    else:
        st.error("Failed")
    st.caption(f"Audit artifacts: {run.output_directory}")
    if active and st.button("Cancel audit", type="secondary", key="cancel-audit"):
        run.cancel()
        st.warning("Cancellation requested. Inspect the final audit log for completed scan steps.")

    st.session_state.audit_output += run.drain_output()
    artifacts = find_audit_artifacts(run.output_directory)
    new_log, next_offset = read_new_text(artifacts.log_path, st.session_state.audit_log_offset)
    st.session_state.audit_log_offset = next_offset
    st.session_state.audit_log += new_log

    left, right = st.columns(2)
    with left:
        st.caption("Audit log (updates while the audit is active)")
        st.code(
            st.session_state.audit_log or "Waiting for audit log output…",
            language="text",
            height=320,
        )
    with right:
        st.caption("Audit process standard output and standard error")
        st.code(
            st.session_state.audit_output or "No process output yet.",
            language="text",
            height=320,
        )

    if not active:
        _render_audit_artifacts(artifacts)
    with st.expander("Audit command (non-secret arguments)"):
        st.code("\n".join(_redacted_command(run.command)), language="text")


def _render_audit_artifacts(artifacts: AuditArtifacts) -> None:
    if artifacts.text_path:
        st.subheader("Audit text report")
        st.code(artifacts.text_path.read_text(encoding="utf-8", errors="replace"), language="text")
    if artifacts.json_path:
        try:
            report = json.loads(artifacts.json_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            st.warning(f"Could not display audit JSON report: {exc}")
        else:
            findings = report.get("findings", [])
            scan_errors = report.get("scan_errors", [])
            inventory = report.get("target_inventory", {})
            st.subheader("Audit summary")
            metrics = st.columns(4)
            metrics[0].metric(
                "External compartments scanned", report.get("scanned_external_compartment_count", 0)
            )
            metrics[1].metric("Findings", len(findings))
            metrics[2].metric("Scan errors", len(scan_errors))
            metrics[3].metric("Target VCNs", len(inventory.get("vcns", [])))
            if findings:
                st.warning(
                    "Review the findings before cleaning resources in the target compartment."
                )
            if scan_errors:
                st.error("The audit recorded scan errors and may be incomplete.")
            st.json(report)


@st.fragment(run_every="1s")
def _render_execute_run() -> None:
    run: CleanerRun | None = st.session_state.execute_run
    if run is None:
        return
    st.session_state.execute_output += run.drain_output()
    artifacts = find_artifacts(run.output_directory)
    new_log, next_offset = read_new_text(artifacts.log_path, st.session_state.execute_log_offset)
    st.session_state.execute_log_offset = next_offset
    st.session_state.execute_log += new_log
    status = run.status()
    active = status.value in {"running", "cancellation_requested"}
    st.subheader("Destructive execution status")
    if run.awaiting_confirmation:
        st.warning("Awaiting confirmation — no Resource Manager stack or deletion has started")
    elif status.value == "running":
        if run.confirmation_sent:
            st.error("Running — Resource Manager protection or deletion is in progress")
        else:
            st.info(
                "Execute discovery is running — no Resource Manager stack or deletion has started"
            )
    elif status.value == "succeeded":
        st.success("Cleaner process completed")
    elif status.value == "cancellation_requested":
        st.warning("Cancellation requested")
    elif status.value == "cancelled":
        st.warning("Interrupted — OCI calls already accepted cannot be rolled back")
    elif status.value == "aborted":
        st.success("Aborted before Resource Manager stack creation and deletion")
    else:
        st.error("Failed or interrupted")
    latest_log_lines = _last_nonempty_lines(st.session_state.execute_log, count=2)
    st.caption("Latest execution log (last two lines)")
    st.code("\n".join(latest_log_lines) or "Waiting for log output…", language="text", height=72)
    st.caption(f"Execute artifacts: {run.output_directory}")
    if active and st.button("Cancel destructive execution", type="secondary", key="cancel-execute"):
        run.cancel()
        st.warning("Cancellation requested. OCI calls already accepted cannot be rolled back.")
    left, right = st.columns(2)
    with left:
        st.caption("Execution log (updates while deletion is active)")
        st.code(
            st.session_state.execute_log or "Waiting for cleaner log output…",
            language="text",
            height=320,
        )
    with right:
        st.caption("Execution process standard output and standard error")
        st.code(
            st.session_state.execute_output or "No process output yet.", language="text", height=320
        )
    if not active or run.awaiting_confirmation:
        _render_artifacts(artifacts)
    if not active:
        st.subheader("Execution log analysis")
        error_entries = find_error_entries(artifacts.log_path)
        if error_entries:
            entry_label = "entry" if len(error_entries) == 1 else "entries"
            st.error(f"Found {len(error_entries)} error-level log {entry_label}.")
            st.code("\n".join(error_entries), language="text", height=320)
        else:
            st.success("No ERROR or CRITICAL entries were found in the execution log.")
        st.warning(
            "A successful process exit does not prove every resource was deleted. Review this log "
            "for per-resource failures and the remaining-resource verification results."
        )
    with st.expander("Execution command (non-secret arguments)"):
        st.code("\n".join(_redacted_command(run.command)), language="text")


def _redacted_command(command: list[str] | tuple[str, ...] | object) -> list[str]:
    """Avoid repeating the typed confirmation in displayed command details."""
    values = list(command)  # type: ignore[arg-type]
    return ["[typed confirmation omitted]" if value == "DELETE" else value for value in values]


def _last_nonempty_lines(text: str, count: int) -> list[str]:
    """Return the latest useful log lines for compact status display."""
    return [line for line in text.splitlines() if line.strip()][-count:]


@st.fragment(run_every="1s")
def _render_execute_review(profile: str, region: str, selected_id: str | None) -> None:
    """Start one execute discovery, then confirm or abort its exact plan."""
    selected = _selected_compartment()
    st.subheader("Execute deletion")
    if selected is None or selected.id != selected_id:
        st.info("Select a target compartment before starting execute discovery.")
        return

    execute_run: CleanerRun | None = st.session_state.execute_run
    is_execute_active = execute_run is not None and execute_run.status().value in {
        "running",
        "cancellation_requested",
    }
    if is_execute_active:
        if execute_run.awaiting_confirmation:
            st.warning(
                "Review the execution plan shown below. No Resource Manager stack or deletion has "
                "started yet."
            )
            confirmation = st.text_input(
                "Type DELETE to confirm this execution plan",
                key="execute_confirmation",
                disabled=execute_run.confirmation_sent,
            )
            if st.button(
                "Confirm deletion of this execution plan",
                type="primary",
                disabled=confirmation != "DELETE" or execute_run.confirmation_sent,
            ):
                try:
                    execute_run.send_confirmation("DELETE")
                except ValidationError as exc:
                    st.error(str(exc))
            if st.button(
                "Abort execute plan",
                type="secondary",
                disabled=execute_run.confirmation_sent,
            ):
                try:
                    execute_run.send_confirmation("ABORT")
                except ValidationError as exc:
                    st.error(str(exc))
        else:
            st.info(
                "Execute discovery is running. The confirmation controls appear after its plan."
            )
        return

    st.error(
        "Destructive action: this starts a new execute discovery. You will review that exact "
        "execution plan before it can create a Resource Manager stack or delete resources."
    )
    st.write(
        "Create dry-run plan remains an independent preview. The network usage audit is advisory; "
        "you may proceed without it."
    )
    st.warning(
        "Linked resources can be discovered in another OCI region. Confirm the selected region and "
        "review the cleaner log after execution."
    )
    backup_mode = st.radio(
        "Resource Manager discovery stack",
        ("Create Resource Manager discovery stack", "Skip Resource Manager discovery stack"),
        disabled=is_execute_active,
        key="execute_backup_mode",
    )
    create_backup_stack = backup_mode.startswith("Create")
    backup_compartment_id: str | None = None
    backup_region: str | None = None
    assert selected is not None
    if create_backup_stack:
        backup_options = [
            item.id for item in st.session_state.compartments if item.id != selected.id
        ]
        if backup_options:
            backup_compartment_id = st.selectbox(
                "Backup-stack compartment",
                backup_options,
                format_func=lambda value: next(
                    item.label for item in st.session_state.compartments if item.id == value
                ),
                disabled=is_execute_active,
                key="execute_backup_compartment",
            )
            backup_region = st.selectbox(
                "Backup-stack region",
                st.session_state.regions,
                index=st.session_state.regions.index(region),
                disabled=is_execute_active,
                key="execute_backup_region",
            )
        else:
            st.error(
                "No distinct accessible compartment is available for the Resource Manager stack."
            )
    else:
        st.warning(
            "Skipping the Resource Manager stack removes discovery-output protection. "
            "This is not a data backup."
        )
    can_start_execute_discovery = not create_backup_stack or backup_compartment_id is not None
    if st.button(
        "Start execute discovery",
        type="primary",
        disabled=not can_start_execute_discovery,
    ):
        _start_execute(
            profile,
            region,
            selected,
            create_backup_stack,
            backup_compartment_id,
            backup_region,
        )
    st.caption(
        "Closing the browser tab does not cancel execution. If the local UI server stops or its "
        "heartbeat ends, the supervisor interrupts the cleaner; accepted OCI calls cannot be "
        "rolled back."
    )


def _render_compartment_node(
    node: CompartmentTreeNode, search_active: bool, selection_disabled: bool
) -> None:
    """Render one expandable hierarchy node and allow selecting compartments only."""
    if node.is_selectable:
        assert node.compartment is not None
        child_count = len(node.children)
        label = f"{node.label} ({child_count} accessible child{'ren' if child_count != 1 else ''})"
        with st.expander(label, expanded=search_active):
            if st.button(
                "Select this compartment",
                key=f"select-compartment-{node.compartment.id}",
                disabled=selection_disabled,
            ):
                _select_compartment(node.compartment.id)
            for child in node.children:
                _render_compartment_node(child, search_active, selection_disabled)
        return

    with st.expander(node.label, expanded=True):
        for child in node.children:
            _render_compartment_node(child, search_active, selection_disabled)


def _selected_compartment() -> Compartment | None:
    selected_id = st.session_state.get("selected_compartment_id")
    return next(
        (
            compartment
            for compartment in st.session_state.compartments
            if compartment.id == selected_id
        ),
        None,
    )


def _select_compartment(compartment_id: str) -> None:
    """Change target and discard only the prior completed run's on-screen output."""
    if st.session_state.get("selected_compartment_id") == compartment_id:
        return
    clear_completed_run_display(st.session_state)
    st.session_state.selected_compartment_id = compartment_id


def main() -> None:
    _initialize_state()
    st.title("OCI Compartment Cleaner")
    st.warning("Dry-run is the default. Execute discovery requires plan review and DELETE.")
    st.write(
        "Select an existing OCI profile, region, and accessible compartment "
        "to generate a deletion plan."
    )

    with st.sidebar:
        st.header("OCI configuration")
        st.text_input("OCI config file", key="config_path")
        if st.button("Load profiles"):
            _load_profiles()

    if not st.session_state.profiles:
        st.info("Load an OCI config file to begin.")
        _render_run()
        _render_audit_run()
        return

    profile = st.selectbox("OCI profile", st.session_state.profiles, key="selected_profile")
    if profile != st.session_state.loaded_profile:
        reset_profile_selection(st.session_state)
        with st.spinner(f"Loading regions and compartments for profile {profile}…"):
            _load_oci_choices(profile)
        st.session_state.loaded_profile = profile
    if st.button("Refresh regions and compartments"):
        reset_profile_selection(st.session_state)
        with st.spinner(f"Refreshing regions and compartments for profile {profile}…"):
            _load_oci_choices(profile)

    if not st.session_state.get("regions") or not st.session_state.get("compartments"):
        st.info("Load the selected profile's subscribed regions and accessible compartments.")
        _render_run()
        _render_audit_run()
        return

    st.subheader(f"Tenancy: {st.session_state.get('tenancy_name', 'Unknown tenancy')}")
    region = st.selectbox("Region", st.session_state.regions, key="selected_region")
    st.subheader("Target compartment")
    search = st.text_input("Search compartment name or OCID", key="compartment_search")
    tree = build_compartment_tree(st.session_state.compartments, st.session_state.tenancy_id)
    filtered_tree = filter_tree(tree, search)
    active_run = st.session_state.run
    active_audit_run = st.session_state.audit_run
    is_cleaner_active = active_run is not None and active_run.status().value in {
        "running",
        "cancellation_requested",
    }
    is_audit_active = active_audit_run is not None and active_audit_run.status().value in {
        "running",
        "cancellation_requested",
    }
    active_execute_run = st.session_state.execute_run
    is_execute_active = active_execute_run is not None and active_execute_run.status().value in {
        "running",
        "cancellation_requested",
    }
    selection_locked = is_cleaner_active or is_audit_active or is_execute_active
    if selection_locked:
        st.info(
            "Compartment selection is locked while a cleaner run, audit, or execution is active."
        )
    if filtered_tree is None:
        st.info("No accessible compartments match the search.")
    else:
        _render_compartment_node(filtered_tree, bool(search.strip()), selection_locked)

    selected = _selected_compartment()
    if selected:
        path = visible_path(tree, selected.id) or (selected.name,)
        display_path = (st.session_state.get("tenancy_name", "Unknown tenancy"), *path[1:])
        st.success(f"Selected: {' / '.join(display_path)}")
        st.caption(f"Selected compartment OCID: `{selected.id}`")
        child_count = sum(
            compartment.parent_id == selected.id for compartment in st.session_state.compartments
        )
        st.caption(f"Direct accessible children: {child_count}")

    if st.button(
        "Create dry-run plan", type="primary", disabled=is_cleaner_active or selected is None
    ):
        assert selected is not None
        _start_dry_run(profile, region, selected)
    _render_run()

    st.divider()
    st.subheader("Network usage audit")
    st.caption(
        "Read-only pre-delete audit. It looks for accessible resources in other compartments "
        "that reference VCNs, subnets, NSGs, or local peering gateways in the target compartment."
    )
    external_compartments = [
        item for item in st.session_state.compartments if item.id != getattr(selected, "id", None)
    ]
    scan_compartment_ids = st.multiselect(
        "External compartments to scan (optional)",
        options=[item.id for item in external_compartments],
        format_func=lambda item: next(
            compartment.label for compartment in external_compartments if compartment.id == item
        ),
        key="audit_scan_compartment_ids",
        disabled=selection_locked,
        help="Leave empty to scan all accessible external compartments.",
    )
    with st.expander("Advanced audit options"):
        page_limit = st.number_input("Audit page limit", min_value=1, value=1000, step=100)
        access_level = st.selectbox("Compartment access level", ("ACCESSIBLE", "ANY"))
        include_inactive = st.checkbox("Include inactive/deleting compartments")
        skip_vnic = st.checkbox("Skip VNIC scan")
        skip_service = st.checkbox("Skip service resource scans")
        audit_debug = st.checkbox("Enable audit debug logging")
    if st.button(
        "Run network usage audit", type="secondary", disabled=is_audit_active or selected is None
    ):
        assert selected is not None
        _start_network_audit(
            profile,
            region,
            selected,
            scan_compartment_ids,
            int(page_limit),
            access_level,
            include_inactive,
            skip_vnic,
            skip_service,
            audit_debug,
        )
    _render_audit_run()

    st.divider()
    _render_execute_review(profile, region, getattr(selected, "id", None))
    _render_execute_run()


if __name__ == "__main__":
    main()
