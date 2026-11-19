# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Dry-run plan file rendering."""

from __future__ import annotations

from .runtime_core import *

def write_plan_files(
    plan_json_path: Path,
    plan_text_path: Path,
    resources: list[ResourceRecord],
    skipped: list[SkippedResource],
    args: argparse.Namespace,
    search_query: str,
) -> None:
    plan_json_path.parent.mkdir(parents=True, exist_ok=True)
    rm_services_to_discover = parse_csv_values(args.rm_backup_services_to_discover)
    rm_backup_info = {
        "enabled_before_deletion": not args.skip_rm_backup_stack,
        "skip_argument_supplied": args.skip_rm_backup_stack,
        "stack_compartment_id": args.rm_backup_stack_compartment_id or "",
        "stack_compartment_is_target_compartment": (
            args.rm_backup_stack_compartment_id == args.compartment_id
        ),
        "stack_region": args.rm_backup_stack_region or args.region,
        "services_to_discover": rm_services_to_discover,
        "failure_action": args.rm_backup_failure_action,
        "wait_seconds": args.rm_backup_wait_seconds,
        "wait_interval_seconds": args.rm_backup_wait_interval_seconds,
    }
    payload = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "compartment_id": args.compartment_id,
        "region": args.region,
        "search_query": search_query,
        "resource_manager_backup_stack": rm_backup_info,
        "delete_count": len(resources),
        "skipped_count": len(skipped),
        "deletion_order": [
            resource.plan_item(sequence=index)
            for index, resource in enumerate(resources, start=1)
        ],
        "skipped": [item.plan_item() for item in skipped],
    }
    plan_json_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")

    lines = [
        f"OCI compartment deletion dry-run plan",
        f"Generated UTC: {payload['generated_at_utc']}",
        f"Compartment: {args.compartment_id}",
        f"Region: {args.region}",
        f"Search query: {search_query}",
    ]
    lines.append("Resource Manager backup stack:")
    if args.skip_rm_backup_stack:
        lines.append("  Skipped by --skip-rm-backup-stack.")
    else:
        rm_stack_compartment = args.rm_backup_stack_compartment_id or (
            "REQUIRED before deletion; not provided"
        )
        lines.extend(
            [
                "  Enabled before deletion; created only after DELETE confirmation.",
                f"  Stack compartment: {rm_stack_compartment}",
                f"  Stack region: {rm_backup_info['stack_region']}",
                f"  Services to discover: {', '.join(rm_services_to_discover) or 'all supported services'}",
                f"  Failure action: {args.rm_backup_failure_action}",
                f"  Wait: {args.rm_backup_wait_seconds}s timeout, "
                f"{args.rm_backup_wait_interval_seconds}s interval",
            ]
        )
        if rm_backup_info["stack_compartment_is_target_compartment"]:
            lines.append("  Status: INVALID; stack compartment must differ from target compartment.")
    lines.extend(["", "Deletion order:"])
    if resources:
        lines.append(
            f"{'#':>4} {'Priority':>8} {'Type':<28} {'Lifecycle':<14} {'Display name':<36} Identifier"
        )
        lines.append("-" * 130)
        for index, resource in enumerate(resources, start=1):
            display = resource.display_name[:36]
            lines.append(
                f"{index:>4} {resource.priority:>8} "
                f"{resource.resource_type:<28.28} {resource.lifecycle_state:<14.14} "
                f"{display:<36} {resource.identifier}"
            )
    else:
        lines.append("  No resources are planned for deletion.")

    lines.extend(["", "Skipped resources:"])
    if skipped:
        lines.append(f"{'Type':<28} {'Lifecycle':<14} {'Reason':<58} Identifier")
        lines.append("-" * 130)
        for skipped_item in skipped:
            resource = skipped_item.resource
            lines.append(
                f"{resource.resource_type:<28.28} {resource.lifecycle_state:<14.14} "
                f"{skipped_item.reason:<58.58} {resource.identifier}"
            )
    else:
        lines.append("  No resources skipped.")
    plan_text_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
