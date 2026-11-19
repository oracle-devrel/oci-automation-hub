# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

from typing import Any

from ..context import CleanupContext
from .. import runtime


def remove_route_rules_referencing_resource(resource: Any, context: CleanupContext) -> None:
    if runtime.oci is None:
        return
    network_client = context.client(runtime.oci.core.VirtualNetworkClient)
    runtime.remove_route_rules_referencing_resource(
        network_client,
        resource,
        context.logger,
    )
