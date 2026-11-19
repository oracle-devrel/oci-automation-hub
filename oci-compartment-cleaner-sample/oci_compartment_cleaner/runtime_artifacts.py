# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Run artifact upload helpers."""

from __future__ import annotations

from .runtime_core import *
from .runtime_object_storage import get_object_namespace

def upload_artifacts_to_bucket(
    paths: list[Path],
    bucket_name: str | None,
    namespace: str | None,
    object_prefix: str,
    config: dict[str, Any],
    signer: Any,
    logger: logging.Logger,
) -> None:
    if not bucket_name:
        return
    try:
        object_client = make_client(oci.object_storage.ObjectStorageClient, config, signer)
        resolved_namespace = get_object_namespace(object_client, namespace, logger)
        prefix = object_prefix.strip("/")
        for path in paths:
            object_name = f"{prefix}/{path.name}" if prefix else path.name
            logger.info("Uploading artifact %s to bucket %s as %s", path, bucket_name, object_name)
            with path.open("rb") as file_handle:
                call_oci(
                    logger,
                    f"ObjectStorageClient.put_object bucket={bucket_name} object={object_name}",
                    object_client.put_object,
                    resolved_namespace,
                    bucket_name,
                    object_name,
                    file_handle,
                )
    except Exception as exc:
        logger.error("Failed uploading run artifacts to Object Storage bucket %s: %s", bucket_name, exc)
