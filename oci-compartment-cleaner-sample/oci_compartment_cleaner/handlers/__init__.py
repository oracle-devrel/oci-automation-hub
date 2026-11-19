# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

from typing import Any

from ..context import CleanupContext
from ..models import HandlerSpec
from . import compute, default, object_storage


def delete_resource(resource: Any, handler: HandlerSpec, context: CleanupContext) -> bool:
    if handler.action == "skip":
        context.logger.info(
            "Skipping %s %s (%s): %s",
            resource.resource_type,
            resource.display_name,
            resource.identifier,
            handler.skip_reason,
        )
        return False

    if handler.pre_delete and not default.run_pre_delete_hooks(
        resource,
        context,
        handler.pre_delete,
    ):
        return False

    if handler.action == "bucket_delete":
        return object_storage.delete_bucket(resource, context)
    if handler.action == "capacity_reservation_delete":
        return compute.delete_compute_capacity_reservation(resource, context)
    if handler.action == "dynamic_delete":
        return default.delete_dynamic(resource, context, handler)

    context.logger.error(
        "Unsupported handler action %s for %s %s (%s)",
        handler.action,
        resource.resource_type,
        resource.display_name,
        resource.identifier,
    )
    return False
