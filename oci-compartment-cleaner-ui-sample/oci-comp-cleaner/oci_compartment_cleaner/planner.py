# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import dataclasses
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import runtime
from .models import DeletionPlan, PlanEntry
from .registry import ResourceRegistry, load_registry


def _resource_with_priority(resource: Any, priority: int) -> Any:
    if getattr(resource, "priority", None) == priority:
        return resource
    if dataclasses.is_dataclass(resource):
        return dataclasses.replace(resource, priority=priority)
    return resource


def build_plan(
    resources: list[Any],
    *,
    include_terminal: bool,
    skip_oke_workers: bool,
    logger: Any,
    registry: ResourceRegistry | None = None,
) -> DeletionPlan:
    active_registry = registry or load_registry()
    ordered, skipped = runtime.filter_and_order_resources(
        resources,
        include_terminal=include_terminal,
        skip_oke_workers=skip_oke_workers,
        logger=logger,
    )
    matched = []
    for resource in ordered:
        handler = active_registry.match_resource(resource)
        matched.append((_resource_with_priority(resource, handler.priority), handler))

    matched = sorted(
        matched,
        key=lambda item: (
            item[0].priority,
            item[0].resource_type_normalized,
            item[0].display_name.lower(),
            item[0].identifier,
        ),
    )
    entries = tuple(
        PlanEntry(sequence=index, resource=resource, handler=handler)
        for index, (resource, handler) in enumerate(matched, start=1)
    )
    return DeletionPlan(entries=entries, skipped=tuple(skipped))


def resource_manager_backup_plan(args: Any) -> dict[str, Any]:
    rm_services_to_discover = runtime.parse_csv_values(args.rm_backup_services_to_discover)
    return {
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


def write_plan_files(
    plan_json_path: Path,
    plan_text_path: Path,
    plan: DeletionPlan,
    args: Any,
    search_query: str,
) -> None:
    plan_json_path.parent.mkdir(parents=True, exist_ok=True)
    generated_at_utc = datetime.now(timezone.utc).isoformat()
    payload = plan.to_payload(
        args=args,
        search_query=search_query,
        generated_at_utc=generated_at_utc,
    )
    payload["resource_manager_backup_stack"] = resource_manager_backup_plan(args)
    plan_json_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")

    lines = [
        "OCI compartment deletion dry-run plan",
        f"Generated UTC: {generated_at_utc}",
        f"Compartment: {args.compartment_id}",
        f"Region: {args.region}",
        f"Search query: {search_query}",
        "",
        "Resource Manager backup stack:",
    ]
    rm_backup = payload["resource_manager_backup_stack"]
    if args.skip_rm_backup_stack:
        lines.append("  Skipped by --skip-rm-backup-stack.")
    else:
        stack_compartment = args.rm_backup_stack_compartment_id or (
            "REQUIRED before deletion; not provided"
        )
        lines.extend(
            [
                "  Enabled before deletion; created only after DELETE confirmation.",
                f"  Stack compartment: {stack_compartment}",
                f"  Stack region: {rm_backup['stack_region']}",
                "  Services to discover: "
                f"{', '.join(rm_backup['services_to_discover']) or 'all supported services'}",
                f"  Failure action: {args.rm_backup_failure_action}",
                f"  Wait: {args.rm_backup_wait_seconds}s timeout, "
                f"{args.rm_backup_wait_interval_seconds}s interval",
            ]
        )
        if rm_backup["stack_compartment_is_target_compartment"]:
            lines.append("  Status: INVALID; stack compartment must differ from target compartment.")

    lines.extend(["", "Deletion order:"])
    if plan.entries:
        lines.append(
            f"{'#':>4} {'Priority':>8} {'Type':<28} {'Handler':<24} {'API/action':<36} Identifier"
        )
        lines.append("-" * 150)
        for entry in plan.entries:
            resource = entry.resource
            handler = entry.handler
            lines.append(
                f"{entry.sequence:>4} {resource.priority:>8} "
                f"{resource.resource_type:<28.28} {handler.key:<24.24} "
                f"{handler.delete_description:<36.36} {resource.identifier}"
            )
    else:
        lines.append("  No resources are planned for deletion.")

    lines.extend(["", "Skipped resources:"])
    if plan.skipped:
        lines.append(f"{'Type':<28} {'Lifecycle':<14} {'Reason':<58} Identifier")
        lines.append("-" * 130)
        for skipped_item in plan.skipped:
            resource = skipped_item.resource
            lines.append(
                f"{resource.resource_type:<28.28} {resource.lifecycle_state:<14.14} "
                f"{skipped_item.reason:<58.58} {resource.identifier}"
            )
    else:
        lines.append("  No resources skipped.")
    plan_text_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
