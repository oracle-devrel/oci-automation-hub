# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Post-delete verification scan."""

from __future__ import annotations

from .runtime_core import *
from .runtime_discovery import discover_compartment_resources
from .runtime_planning_rules import is_default_mysql_configuration
from .runtime_waiters import refresh_authoritative_resource

def unique_resources(resources: list[ResourceRecord]) -> list[ResourceRecord]:
    unique: list[ResourceRecord] = []
    seen: set[str] = set()
    for resource in resources:
        key = resource.identifier or "|".join(
            [
                resource.resource_type,
                resource.display_name,
                resource.compartment_id,
            ]
        )
        if key in seen:
            continue
        seen.add(key)
        unique.append(resource)
    return unique


def report_remaining_resources_after_deletion(
    compartment_id: str,
    query: str | None,
    limit: int,
    config: dict[str, Any],
    signer: Any,
    timeout_seconds: int,
    interval_seconds: int,
    logger: logging.Logger,
) -> None:
    logger.info("Starting post-delete verification scan")
    timeout = max(0, timeout_seconds)
    interval = max(1, interval_seconds)
    deadline = time.monotonic() + timeout
    attempt = 0

    while True:
        attempt += 1
        resources = discover_compartment_resources(
            compartment_id=compartment_id,
            query=query,
            limit=limit,
            config=config,
            signer=signer,
            include_terminal=True,
            logger=logger,
        )
        remaining: list[ResourceRecord] = []
        completed_count = 0
        stale_search_count = 0
        default_mysql_configuration_count = 0
        for resource in unique_resources(resources):
            if is_default_mysql_configuration(resource):
                default_mysql_configuration_count += 1
                continue
            if resource.lifecycle_state in POST_DELETE_COMPLETED_STATES:
                completed_count += 1
                continue
            refreshed = refresh_authoritative_resource(resource, config, signer, logger)
            if refreshed is None:
                stale_search_count += 1
                continue
            if refreshed.lifecycle_state in POST_DELETE_COMPLETED_STATES:
                completed_count += 1
                continue
            remaining.append(refreshed)

        if completed_count:
            logger.info(
                "Post-delete verification attempt %s ignored %s resources already in completed lifecycle states",
                attempt,
                completed_count,
            )
        if stale_search_count:
            logger.info(
                "Post-delete verification attempt %s ignored %s stale Resource Search results",
                attempt,
                stale_search_count,
            )
        if default_mysql_configuration_count:
            logger.info(
                "Post-delete verification attempt %s ignored %s default MySQL configurations",
                attempt,
                default_mysql_configuration_count,
            )
        if not remaining:
            logger.info("Post-delete verification found no resources still returned for the compartment")
            return

        remaining = sorted(
            remaining,
            key=lambda item: (
                item.resource_type_normalized,
                item.display_name.lower(),
                item.identifier,
            ),
        )
        counts: dict[str, int] = defaultdict(int)
        for resource in remaining:
            counts[resource.resource_type] += 1
        count_summary = ", ".join(f"{resource_type}={count}" for resource_type, count in sorted(counts.items()))

        remaining_wait = deadline - time.monotonic()
        if remaining_wait <= 0:
            logger.warning(
                "Post-delete verification found %s resources still returned for the compartment",
                len(remaining),
            )
            logger.warning("Remaining resource counts by type: %s", count_summary)
            for index, resource in enumerate(remaining, start=1):
                logger.warning(
                    "Remaining %s/%s type=%s state=%s name=%s id=%s",
                    index,
                    len(remaining),
                    resource.resource_type,
                    resource.lifecycle_state or "UNKNOWN",
                    resource.display_name,
                    resource.identifier,
                )
            return

        sleep_seconds = min(interval, max(1, int(remaining_wait)))
        logger.info(
            "Post-delete verification attempt %s found %s resources still returned (%s); sleeping %s seconds before retry",
            attempt,
            len(remaining),
            count_summary,
            sleep_seconds,
        )
        time.sleep(sleep_seconds)
