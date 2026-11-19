# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""OCI Logging deletion helpers for logs that require a parent log-group ID."""

from __future__ import annotations

import time
from typing import Any

from .. import runtime
from ..context import CleanupContext


def delete_log(resource: Any, context: CleanupContext) -> bool:
    """Delete one log and wait until OCI no longer returns it."""
    log_group_id = runtime.first_present(
        resource.raw.get("log_group_id"),
        resource.raw.get("logGroupId"),
    )
    if not log_group_id:
        context.logger.error(
            "Cannot delete Log %s (%s): its parent log_group_id is unavailable",
            resource.display_name,
            resource.identifier,
        )
        return False

    client = context.client(runtime.oci.logging.LoggingManagementClient)
    try:
        runtime.call_oci(
            context.logger,
            f"LoggingManagementClient.delete_log {resource.identifier}",
            client.delete_log,
            log_group_id=log_group_id,
            log_id=resource.identifier,
        )
    except Exception as exc:
        if runtime.is_not_found_error(exc):
            context.logger.info("Log %s is already absent", resource.display_name)
            return True
        context.logger.error(
            "Delete API failed for Log %s (%s): %s",
            resource.display_name,
            resource.identifier,
            exc,
        )
        return False

    if context.delete_wait_timeout_seconds <= 0:
        return True

    deadline = time.monotonic() + context.delete_wait_timeout_seconds
    interval = max(1, context.delete_wait_interval_seconds)
    while True:
        try:
            runtime.call_oci(
                context.logger,
                f"LoggingManagementClient.get_log {resource.identifier}",
                client.get_log,
                log_group_id=log_group_id,
                log_id=resource.identifier,
            )
        except Exception as exc:
            if runtime.is_not_found_error(exc):
                context.logger.info(
                    "Log %s is no longer returned; delete is complete", resource.display_name
                )
                return True
            context.logger.error(
                "Failed while waiting for Log %s deletion completion: %s",
                resource.display_name,
                exc,
            )
            return False

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            context.logger.error(
                "Timed out waiting for Log %s deletion completion", resource.display_name
            )
            return False
        sleep_seconds = min(interval, max(1, int(remaining)))
        context.logger.info(
            "Log %s is still returned after delete; sleeping %s seconds",
            resource.display_name,
            sleep_seconds,
        )
        time.sleep(sleep_seconds)
