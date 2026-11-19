# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Object Storage bucket emptying and bucket deletion helpers."""

from __future__ import annotations

from .runtime_core import *

def get_object_namespace(
    object_client: Any, configured_namespace: str | None, logger: logging.Logger
) -> str:
    if configured_namespace:
        return configured_namespace
    namespace = call_oci(logger, "ObjectStorageClient.get_namespace", object_client.get_namespace).data
    logger.info("Resolved Object Storage namespace: %s", namespace)
    return namespace


def paged_list_buckets(
    object_client: Any, namespace: str, compartment_id: str, logger: logging.Logger
) -> list[Any]:
    buckets: list[Any] = []
    page: str | None = None
    while True:
        kwargs: dict[str, Any] = {"limit": 1000}
        if page:
            kwargs["page"] = page
        response = call_oci(
            logger,
            f"ObjectStorageClient.list_buckets page for compartment {compartment_id}",
            object_client.list_buckets,
            namespace,
            compartment_id,
            **kwargs,
        )
        buckets.extend(response.data or [])
        page = response.headers.get("opc-next-page")
        if not page:
            break
    return buckets


def resolve_bucket_name(
    resource: ResourceRecord,
    object_client: Any,
    namespace: str,
    logger: logging.Logger,
) -> str:
    name_candidates = [
        resource.display_name,
        str(resource.raw.get("name") or ""),
        resource.identifier if not resource.identifier.startswith("ocid1.") else "",
    ]
    for candidate in name_candidates:
        if candidate and not candidate.startswith("ocid1."):
            return candidate

    try:
        for bucket in paged_list_buckets(object_client, namespace, resource.compartment_id, logger):
            bucket_id = first_present(getattr(bucket, "id", None), default="")
            bucket_name = first_present(getattr(bucket, "name", None), default="")
            if resource.identifier and resource.identifier == bucket_id:
                return bucket_name
            if resource.display_name and resource.display_name == bucket_name:
                return bucket_name
    except Exception as exc:
        logger.error("Could not list buckets to resolve bucket name for %s: %s", resource.identifier, exc)
    return resource.display_name or resource.identifier


def retention_rule_id(rule: Any) -> str:
    raw = sdk_to_dict(rule)
    return first_present(getattr(rule, "id", None), raw.get("id"), default="")


def retention_rule_name(rule: Any) -> str:
    raw = sdk_to_dict(rule)
    return first_present(
        getattr(rule, "display_name", None),
        raw.get("display_name"),
        raw.get("displayName"),
        retention_rule_id(rule),
        default="unknown",
    )


def retention_rule_etag(rule: Any) -> str:
    raw = sdk_to_dict(rule)
    return first_present(getattr(rule, "etag", None), raw.get("etag"), default="")


def retention_rule_locked_time(rule: Any) -> str:
    raw = sdk_to_dict(rule)
    return first_present(
        getattr(rule, "time_rule_locked", None),
        raw.get("time_rule_locked"),
        raw.get("timeRuleLocked"),
        default="",
    )


def list_retention_rules(
    object_client: Any,
    namespace: str,
    bucket_name: str,
    logger: logging.Logger,
) -> list[Any]:
    list_rules = getattr(object_client, "list_retention_rules", None)
    if list_rules is None:
        logger.info("OCI SDK has no list_retention_rules method; skipping retention rule cleanup for bucket %s", bucket_name)
        return []

    rules: list[Any] = []
    page: str | None = None
    while True:
        kwargs: dict[str, Any] = {}
        if page:
            kwargs["page"] = page
        response = call_oci(
            logger,
            f"ObjectStorageClient.list_retention_rules bucket={bucket_name}",
            list_rules,
            namespace,
            bucket_name,
            **kwargs,
        )
        data = response.data
        rules.extend(getattr(data, "items", data if isinstance(data, list) else []) or [])
        page = response.headers.get("opc-next-page")
        if not page:
            return rules


def wait_for_retention_rules_to_clear(
    object_client: Any,
    namespace: str,
    bucket_name: str,
    logger: logging.Logger,
    timeout_seconds: int = 60,
    interval_seconds: int = 5,
) -> None:
    deadline = time.monotonic() + max(0, timeout_seconds)
    interval = max(1, interval_seconds)
    while True:
        rules = list_retention_rules(object_client, namespace, bucket_name, logger)
        if not rules:
            logger.info("No retention rules remain on bucket %s", bucket_name)
            return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            logger.warning(
                "Retention rules still exist on bucket %s after waiting %s seconds; object deletion may still be blocked",
                bucket_name,
                timeout_seconds,
            )
            for rule in rules:
                logger.warning(
                    "Remaining retention rule bucket=%s name=%s id=%s locked_time=%s",
                    bucket_name,
                    retention_rule_name(rule),
                    retention_rule_id(rule),
                    retention_rule_locked_time(rule) or "-",
                )
            return
        sleep_seconds = min(interval, max(1, int(remaining)))
        logger.info(
            "Bucket %s still has %s retention rules; sleeping %s seconds before checking again",
            bucket_name,
            len(rules),
            sleep_seconds,
        )
        time.sleep(sleep_seconds)


def delete_retention_rules(
    object_client: Any,
    namespace: str,
    bucket_name: str,
    logger: logging.Logger,
) -> None:
    delete_rule = getattr(object_client, "delete_retention_rule", None)
    if delete_rule is None:
        logger.info("OCI SDK has no delete_retention_rule method; skipping retention rule cleanup for bucket %s", bucket_name)
        return

    rules = list_retention_rules(object_client, namespace, bucket_name, logger)
    if not rules:
        logger.info("No retention rules found on bucket %s", bucket_name)
        return

    deleted = 0
    failed = 0
    for rule in rules:
        rule_id = retention_rule_id(rule)
        if not rule_id:
            logger.error(
                "Skipping retention rule without ID in bucket %s: %s",
                bucket_name,
                sdk_to_dict(rule),
            )
            failed += 1
            continue
        kwargs = {}
        etag = retention_rule_etag(rule)
        if etag:
            kwargs["if_match"] = etag
        try:
            logger.info(
                "Deleting retention rule bucket=%s name=%s id=%s locked_time=%s",
                bucket_name,
                retention_rule_name(rule),
                rule_id,
                retention_rule_locked_time(rule) or "-",
            )
            call_oci(
                logger,
                f"ObjectStorageClient.delete_retention_rule bucket={bucket_name} rule={rule_id}",
                delete_rule,
                namespace,
                bucket_name,
                rule_id,
                **kwargs,
            )
            deleted += 1
        except Exception as exc:
            failed += 1
            logger.error(
                "Failed deleting retention rule bucket=%s name=%s id=%s: %s",
                bucket_name,
                retention_rule_name(rule),
                rule_id,
                exc,
            )
    logger.info(
        "Deleted %s retention rules from bucket %s; %s failed",
        deleted,
        bucket_name,
        failed,
    )
    if deleted:
        wait_for_retention_rules_to_clear(object_client, namespace, bucket_name, logger)


def delete_object_versions(
    object_client: Any,
    namespace: str,
    bucket_name: str,
    logger: logging.Logger,
) -> None:
    list_versions = getattr(object_client, "list_object_versions", None)
    if list_versions is None:
        logger.info("OCI SDK has no list_object_versions method; skipping version listing for bucket %s", bucket_name)
        return

    page: str | None = None
    deleted = 0
    while True:
        kwargs: dict[str, Any] = {"limit": 1000}
        if page:
            kwargs["page"] = page
        response = call_oci(
            logger,
            f"ObjectStorageClient.list_object_versions bucket={bucket_name}",
            list_versions,
            namespace,
            bucket_name,
            **kwargs,
        )
        items = getattr(response.data, "items", None) or []
        for item in items:
            object_name = first_present(
                getattr(item, "name", None),
                getattr(item, "object_name", None),
                default="",
            )
            version_id = first_present(getattr(item, "version_id", None), default="")
            if not object_name:
                continue
            try:
                kwargs = {"version_id": version_id} if version_id else {}
                call_oci(
                    logger,
                    f"ObjectStorageClient.delete_object version bucket={bucket_name} object={object_name}",
                    object_client.delete_object,
                    namespace,
                    bucket_name,
                    object_name,
                    **kwargs,
                )
                deleted += 1
            except Exception as exc:
                logger.error(
                    "Failed deleting object version bucket=%s object=%s version=%s: %s",
                    bucket_name,
                    object_name,
                    version_id,
                    exc,
                )
        page = response.headers.get("opc-next-page")
        if not page:
            break
    logger.info("Deleted %s object versions/delete markers from bucket %s", deleted, bucket_name)


def delete_current_objects(
    object_client: Any,
    namespace: str,
    bucket_name: str,
    logger: logging.Logger,
) -> None:
    start: str | None = None
    deleted = 0
    while True:
        kwargs: dict[str, Any] = {"limit": 1000}
        if start:
            kwargs["start"] = start
        response = call_oci(
            logger,
            f"ObjectStorageClient.list_objects bucket={bucket_name}",
            object_client.list_objects,
            namespace,
            bucket_name,
            **kwargs,
        )
        objects = getattr(response.data, "objects", None) or []
        for item in objects:
            object_name = first_present(getattr(item, "name", None), default="")
            if not object_name:
                continue
            try:
                call_oci(
                    logger,
                    f"ObjectStorageClient.delete_object bucket={bucket_name} object={object_name}",
                    object_client.delete_object,
                    namespace,
                    bucket_name,
                    object_name,
                )
                deleted += 1
            except Exception as exc:
                logger.error("Failed deleting object bucket=%s object=%s: %s", bucket_name, object_name, exc)
        start = getattr(response.data, "next_start_with", None)
        if not start:
            break
    logger.info("Deleted %s current objects from bucket %s", deleted, bucket_name)


def abort_multipart_uploads(
    object_client: Any,
    namespace: str,
    bucket_name: str,
    logger: logging.Logger,
) -> None:
    list_uploads = getattr(object_client, "list_multipart_uploads", None)
    abort_upload = getattr(object_client, "abort_multipart_upload", None)
    if list_uploads is None or abort_upload is None:
        return

    page: str | None = None
    aborted = 0
    while True:
        kwargs: dict[str, Any] = {"limit": 1000}
        if page:
            kwargs["page"] = page
        response = call_oci(
            logger,
            f"ObjectStorageClient.list_multipart_uploads bucket={bucket_name}",
            list_uploads,
            namespace,
            bucket_name,
            **kwargs,
        )
        data = response.data
        uploads = getattr(data, "items", data if isinstance(data, list) else []) or []
        for upload in uploads:
            object_name = first_present(
                getattr(upload, "object", None),
                getattr(upload, "object_name", None),
                getattr(upload, "name", None),
                default="",
            )
            upload_id = first_present(getattr(upload, "upload_id", None), default="")
            if not object_name or not upload_id:
                continue
            try:
                call_oci(
                    logger,
                    f"ObjectStorageClient.abort_multipart_upload bucket={bucket_name} object={object_name}",
                    abort_upload,
                    namespace,
                    bucket_name,
                    object_name,
                    upload_id,
                )
                aborted += 1
            except Exception as exc:
                logger.error(
                    "Failed aborting multipart upload bucket=%s object=%s upload_id=%s: %s",
                    bucket_name,
                    object_name,
                    upload_id,
                    exc,
                )
        page = response.headers.get("opc-next-page")
        if not page:
            break
    if aborted:
        logger.info("Aborted %s multipart uploads in bucket %s", aborted, bucket_name)


def delete_bucket_resource(
    resource: ResourceRecord,
    object_client: Any,
    namespace: str,
    logger: logging.Logger,
) -> bool:
    bucket_name = resolve_bucket_name(resource, object_client, namespace, logger)
    logger.info(
        "Emptying Object Storage bucket before deletion: %s (%s)",
        bucket_name,
        resource.identifier,
    )
    try:
        abort_multipart_uploads(object_client, namespace, bucket_name, logger)
    except Exception as exc:
        logger.error("Failed while aborting multipart uploads for bucket %s: %s", bucket_name, exc)
    try:
        delete_retention_rules(object_client, namespace, bucket_name, logger)
    except Exception as exc:
        logger.error("Failed while deleting retention rules for bucket %s: %s", bucket_name, exc)
    try:
        delete_object_versions(object_client, namespace, bucket_name, logger)
    except Exception as exc:
        logger.error("Failed while deleting object versions for bucket %s: %s", bucket_name, exc)
    try:
        delete_current_objects(object_client, namespace, bucket_name, logger)
    except Exception as exc:
        logger.error("Failed while deleting current objects for bucket %s: %s", bucket_name, exc)

    try:
        logger.info("Calling ObjectStorageClient.delete_bucket for bucket %s", bucket_name)
        call_oci(
            logger,
            f"ObjectStorageClient.delete_bucket bucket={bucket_name}",
            object_client.delete_bucket,
            namespace,
            bucket_name,
        )
        logger.info("Delete API accepted for bucket %s", bucket_name)
        return True
    except Exception as exc:
        logger.error("Failed deleting bucket %s (%s): %s", bucket_name, resource.identifier, exc)
        return False
