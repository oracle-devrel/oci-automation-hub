# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import time

from .context import CleanupContext
from .handlers import delete_resource
from .manifest_waiters import wait_for_handler_delete_completion
from .models import DeletionPlan


def execute_plan(plan: DeletionPlan, context: CleanupContext) -> None:
    last_priority: int | None = None
    successes = 0
    failures = 0

    for entry in plan.entries:
        resource = entry.resource
        if (
            last_priority is not None
            and resource.priority != last_priority
            and context.sleep_between_phases > 0
        ):
            context.logger.info(
                "Completed priority group %s; sleeping %s seconds for dependency cleanup",
                last_priority,
                context.sleep_between_phases,
            )
            time.sleep(context.sleep_between_phases)
        last_priority = resource.priority

        context.logger.info(
            "Deleting %s/%s priority=%s type=%s handler=%s name=%s id=%s",
            entry.sequence,
            len(plan.entries),
            resource.priority,
            resource.resource_type,
            entry.handler.key,
            resource.display_name,
            resource.identifier,
        )

        try:
            ok = delete_resource(resource, entry.handler, context)
            if ok:
                successes += 1
                if not wait_for_handler_delete_completion(entry, context):
                    failures += 1
            else:
                failures += 1
        except Exception as exc:
            failures += 1
            context.logger.exception(
                "Unexpected failure deleting %s %s (%s): %s",
                resource.resource_type,
                resource.display_name,
                resource.identifier,
                exc,
            )

    context.logger.info(
        "Delete API call phase completed: %s accepted, %s failed/skipped by API",
        successes,
        failures,
    )
