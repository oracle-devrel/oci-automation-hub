# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import dataclasses
from typing import Any


@dataclasses.dataclass(frozen=True)
class HandlerSpec:
    key: str
    normalized_type: str
    resource_types: tuple[str, ...]
    aliases: tuple[str, ...]
    priority: int
    action: str
    service: str = ""
    client_module: str = ""
    client_class: str = ""
    method: str = ""
    preferred_client_prefixes: tuple[str, ...] = ()
    wait_for_delete: bool = False
    wait_client_module: str = ""
    wait_client_class: str = ""
    wait_method: str = ""
    wait_id_parameter: str = ""
    delete_complete_states: tuple[str, ...] = ()
    pre_delete: tuple[str, ...] = ()
    owns_child_types: tuple[str, ...] = ()
    skip_reason: str = ""
    notes: str = ""

    @property
    def is_skip(self) -> bool:
        return self.action == "skip"

    @property
    def delete_description(self) -> str:
        if self.method:
            target = f"{self.client_class}.{self.method}" if self.client_class else self.method
            return target
        return self.action


@dataclasses.dataclass(frozen=True)
class PlanEntry:
    sequence: int
    resource: Any
    handler: HandlerSpec

    def plan_item(self) -> dict[str, Any]:
        item = self.resource.plan_item(self.sequence)
        item["handler"] = {
            "key": self.handler.key,
            "action": self.handler.action,
            "service": self.handler.service,
            "client_class": self.handler.client_class,
            "method": self.handler.method,
            "pre_delete": list(self.handler.pre_delete),
            "wait_for_delete": self.handler.wait_for_delete,
            "wait_client_class": self.handler.wait_client_class,
            "wait_method": self.handler.wait_method,
            "wait_id_parameter": self.handler.wait_id_parameter,
            "delete_complete_states": list(self.handler.delete_complete_states),
            "owns_child_types": list(self.handler.owns_child_types),
            "notes": self.handler.notes,
        }
        return item


@dataclasses.dataclass(frozen=True)
class DeletionPlan:
    entries: tuple[PlanEntry, ...]
    skipped: tuple[Any, ...]

    @property
    def resources(self) -> list[Any]:
        return [entry.resource for entry in self.entries]

    def handler_counts(self) -> dict[str, int]:
        counts: dict[str, int] = {}
        for entry in self.entries:
            counts[entry.handler.key] = counts.get(entry.handler.key, 0) + 1
        return counts

    def to_payload(self, *, args: Any, search_query: str, generated_at_utc: str) -> dict[str, Any]:
        return {
            "generated_at_utc": generated_at_utc,
            "compartment_id": args.compartment_id,
            "region": args.region,
            "search_query": search_query,
            "delete_count": len(self.entries),
            "skipped_count": len(self.skipped),
            "handler_counts": self.handler_counts(),
            "deletion_order": [entry.plan_item() for entry in self.entries],
            "skipped": [item.plan_item() for item in self.skipped],
        }
