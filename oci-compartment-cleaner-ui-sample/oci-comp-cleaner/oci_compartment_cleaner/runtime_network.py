# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Network dependency cleanup helpers."""

from __future__ import annotations

from .runtime_core import *
from .runtime_discovery import paged_sdk_list

ROUTE_RULE_TARGET_RESOURCE_TYPES = {
    "drg",
    "internet_gateway",
    "local_peering_gateway",
    "nat_gateway",
    "service_gateway",
}


def route_rule_target_id(route_rule: Any) -> str:
    raw = sdk_to_dict(route_rule)
    return first_present(
        getattr(route_rule, "network_entity_id", None),
        raw.get("network_entity_id"),
        raw.get("networkEntityId"),
    )


def remove_route_rules_referencing_resource(
    network_client: Any,
    resource: ResourceRecord,
    logger: logging.Logger,
) -> None:
    if resource.resource_type_normalized not in ROUTE_RULE_TARGET_RESOURCE_TYPES:
        return
    if not resource.compartment_id:
        logger.warning(
            "Cannot remove route rules for %s %s because compartment_id is missing",
            resource.resource_type,
            resource.identifier,
        )
        return

    logger.info(
        "Removing route table rules that reference %s %s (%s)",
        resource.resource_type,
        resource.display_name,
        resource.identifier,
    )
    try:
        route_tables = paged_sdk_list(
            network_client.list_route_tables,
            logger,
            compartment_id=resource.compartment_id,
        )
    except Exception as exc:
        logger.error(
            "Failed listing route tables before deleting %s %s: %s",
            resource.resource_type,
            resource.identifier,
            exc,
        )
        return

    for route_table in route_tables:
        route_rules = list(getattr(route_table, "route_rules", None) or [])
        if not route_rules:
            continue
        remaining_rules = [
            route_rule
            for route_rule in route_rules
            if route_rule_target_id(route_rule) != resource.identifier
        ]
        removed_count = len(route_rules) - len(remaining_rules)
        if removed_count == 0:
            continue
        route_table_id = first_present(getattr(route_table, "id", None), default="")
        route_table_name = first_present(getattr(route_table, "display_name", None), default=route_table_id)
        try:
            details = oci.core.models.UpdateRouteTableDetails(route_rules=remaining_rules)
            logger.info(
                "Updating route table %s (%s): removing %s route rules referencing %s",
                route_table_name,
                route_table_id,
                removed_count,
                resource.identifier,
            )
            call_oci(
                logger,
                f"VirtualNetworkClient.update_route_table {route_table_id}",
                network_client.update_route_table,
                route_table_id,
                details,
            )
        except Exception as exc:
            logger.error(
                "Failed updating route table %s (%s) before deleting %s %s: %s",
                route_table_name,
                route_table_id,
                resource.resource_type,
                resource.identifier,
                exc,
            )
