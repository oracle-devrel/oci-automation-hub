# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

from typing import Any

from ..context import CleanupContext
from .. import runtime


def delete_bucket(resource: Any, context: CleanupContext) -> bool:
    object_client = context.client(runtime.oci.object_storage.ObjectStorageClient)
    namespace = context.get_object_namespace(object_client)
    return runtime.delete_bucket_resource(
        resource,
        object_client,
        namespace,
        context.logger,
    )
