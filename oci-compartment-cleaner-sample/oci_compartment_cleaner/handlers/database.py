# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

from typing import Any

from ..context import CleanupContext
from .. import runtime


def prepare_autonomous_database_for_delete(resource: Any, context: CleanupContext) -> bool:
    return runtime.prepare_autonomous_database_for_delete(
        resource,
        context.config,
        context.signer,
        timeout_seconds=context.delete_wait_timeout_seconds,
        interval_seconds=context.delete_wait_interval_seconds,
        logger=context.logger,
    )


def disassociate_dr_protection_group_if_needed(resource: Any, context: CleanupContext) -> bool:
    return runtime.disassociate_dr_protection_group_if_needed(
        resource,
        context.config,
        context.signer,
        timeout_seconds=context.delete_wait_timeout_seconds,
        interval_seconds=context.delete_wait_interval_seconds,
        logger=context.logger,
    )
