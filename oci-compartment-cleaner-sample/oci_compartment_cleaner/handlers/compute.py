# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

from typing import Any

from ..context import CleanupContext
from .. import runtime


def delete_compute_capacity_reservation(resource: Any, context: CleanupContext) -> bool:
    return runtime.delete_compute_capacity_reservation_resource(
        resource,
        context.config,
        context.signer,
        timeout_seconds=context.delete_wait_timeout_seconds,
        interval_seconds=context.delete_wait_interval_seconds,
        logger=context.logger,
    )
