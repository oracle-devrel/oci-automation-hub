# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""File Storage replication cleanup before file system deletion."""

from __future__ import annotations

from .runtime_core import *
from .runtime_waiters import is_not_found_error

def file_system_replication_state(file_system: Any) -> tuple[str, int, str, str]:
    raw = sdk_to_dict(file_system)
    replication_target_id = first_present(
        getattr(file_system, "replication_target_id", None),
        raw.get("replication_target_id"),
        raw.get("replicationTargetId"),
        default="",
    )
    raw_replication_source_count = first_present(
        getattr(file_system, "replication_source_count", None),
        raw.get("replication_source_count"),
        raw.get("replicationSourceCount"),
        default="0",
    )
    try:
        replication_source_count = int(raw_replication_source_count)
    except (TypeError, ValueError):
        replication_source_count = 0
    availability_domain = first_present(
        getattr(file_system, "availability_domain", None),
        raw.get("availability_domain"),
        raw.get("availabilityDomain"),
        default="",
    )
    lifecycle_state = first_present(
        getattr(file_system, "lifecycle_state", None),
        raw.get("lifecycle_state"),
        raw.get("lifecycleState"),
        default="UNKNOWN",
    ).upper()
    return replication_target_id, replication_source_count, availability_domain, lifecycle_state


def display_optional_id(value: str) -> str:
    return value if value else "<none>"


def paged_file_storage_call(
    method: Any,
    logger: logging.Logger,
    description: str,
    *args: Any,
    **kwargs: Any,
) -> list[Any]:
    items: list[Any] = []
    page: str | None = None
    while True:
        call_kwargs = dict(kwargs)
        call_kwargs["limit"] = 1000
        if page:
            call_kwargs["page"] = page
        response = call_oci(logger, description, method, *args, **call_kwargs)
        data = response.data
        items.extend(data if isinstance(data, list) else getattr(data, "items", data or []))
        page = response.headers.get("opc-next-page")
        if not page:
            return items


def replication_related_to_file_system(replication: Any, file_system_id: str) -> bool:
    raw = sdk_to_dict(replication)
    values = [
        getattr(replication, "source_id", None),
        getattr(replication, "target_id", None),
        raw.get("source_id"),
        raw.get("sourceId"),
        raw.get("target_id"),
        raw.get("targetId"),
    ]
    return any(str(value) == file_system_id for value in values if value)


def delete_file_storage_replication(
    file_client: Any,
    replication_id: str,
    description: str,
    timeout_seconds: int,
    interval_seconds: int,
    logger: logging.Logger,
) -> bool:
    logger.info("Deleting File Storage replication %s (%s)", description, replication_id)
    try:
        call_oci(
            logger,
            f"FileStorageClient.delete_replication {replication_id}",
            file_client.delete_replication,
            replication_id,
            delete_mode="FINISH_CYCLE_IF_CAPTURING_OR_APPLYING",
        )
    except Exception as exc:
        logger.error("Failed deleting File Storage replication %s (%s): %s", description, replication_id, exc)
        return False

    if timeout_seconds <= 0:
        return True

    interval = max(1, interval_seconds)
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            response = call_oci(
                logger,
                f"FileStorageClient.get_replication {replication_id}",
                file_client.get_replication,
                replication_id,
            )
            lifecycle_state = first_present(
                getattr(response.data, "lifecycle_state", None),
                sdk_to_dict(response.data).get("lifecycle_state"),
                sdk_to_dict(response.data).get("lifecycleState"),
                default="UNKNOWN",
            ).upper()
            if lifecycle_state in DELETE_COMPLETE_STATES:
                logger.info("File Storage replication %s reached lifecycle state %s", description, lifecycle_state)
                return True
        except Exception as exc:
            if is_not_found_error(exc):
                logger.info("File Storage replication %s is no longer returned", description)
                return True
            logger.error("Failed while waiting for File Storage replication %s deletion: %s", description, exc)
            return False

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            logger.error(
                "Timed out waiting for File Storage replication %s deletion; last lifecycle state was %s",
                description,
                lifecycle_state,
            )
            return False
        sleep_seconds = min(interval, max(1, int(remaining)))
        logger.info(
            "File Storage replication %s deletion still in lifecycle state %s; sleeping %s seconds",
            description,
            lifecycle_state,
            sleep_seconds,
        )
        time.sleep(sleep_seconds)


def delete_file_storage_replication_target(
    file_client: Any,
    replication_target_id: str,
    description: str,
    timeout_seconds: int,
    interval_seconds: int,
    logger: logging.Logger,
) -> bool:
    logger.info("Deleting File Storage replication target %s (%s)", description, replication_target_id)
    try:
        call_oci(
            logger,
            f"FileStorageClient.delete_replication_target {replication_target_id}",
            file_client.delete_replication_target,
            replication_target_id,
        )
    except Exception as exc:
        logger.error("Failed deleting File Storage replication target %s (%s): %s", description, replication_target_id, exc)
        return False

    if timeout_seconds <= 0:
        return True

    interval = max(1, interval_seconds)
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            response = call_oci(
                logger,
                f"FileStorageClient.get_replication_target {replication_target_id}",
                file_client.get_replication_target,
                replication_target_id,
            )
            lifecycle_state = first_present(
                getattr(response.data, "lifecycle_state", None),
                sdk_to_dict(response.data).get("lifecycle_state"),
                sdk_to_dict(response.data).get("lifecycleState"),
                default="UNKNOWN",
            ).upper()
            if lifecycle_state in DELETE_COMPLETE_STATES:
                logger.info("File Storage replication target %s reached lifecycle state %s", description, lifecycle_state)
                return True
        except Exception as exc:
            if is_not_found_error(exc):
                logger.info("File Storage replication target %s is no longer returned", description)
                return True
            logger.error("Failed while waiting for File Storage replication target %s deletion: %s", description, exc)
            return False

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            logger.error(
                "Timed out waiting for File Storage replication target %s deletion; last lifecycle state was %s",
                description,
                lifecycle_state,
            )
            return False
        sleep_seconds = min(interval, max(1, int(remaining)))
        logger.info(
            "File Storage replication target %s deletion still in lifecycle state %s; sleeping %s seconds",
            description,
            lifecycle_state,
            sleep_seconds,
        )
        time.sleep(sleep_seconds)


def prepare_file_system_for_delete(
    resource: ResourceRecord,
    config: dict[str, Any],
    signer: Any,
    timeout_seconds: int,
    interval_seconds: int,
    logger: logging.Logger,
) -> bool:
    if resource.resource_type_normalized != "file_system":
        return True

    file_client = make_client(oci.file_storage.FileStorageClient, config, signer)
    try:
        response = call_oci(
            logger,
            f"FileStorageClient.get_file_system {resource.identifier}",
            file_client.get_file_system,
            resource.identifier,
        )
    except Exception as exc:
        logger.error(
            "Could not read FileSystem before replication cleanup %s (%s): %s",
            resource.display_name,
            resource.identifier,
            exc,
        )
        return False

    replication_target_id, replication_source_count, availability_domain, lifecycle_state = file_system_replication_state(response.data)
    if not replication_target_id and replication_source_count == 0:
        return True
    if not availability_domain:
        availability_domain = resource.availability_domain
    if not availability_domain:
        logger.error(
            "Cannot inspect File Storage replications for %s (%s) because availability domain is missing",
            resource.display_name,
            resource.identifier,
        )
        return False

    logger.info(
        "FileSystem %s has replication references before delete: replication_target_id=%s replication_source_count=%s lifecycle_state=%s",
        resource.display_name,
        display_optional_id(replication_target_id),
        replication_source_count,
        lifecycle_state,
    )

    local_replication_cleanup_started = False
    try:
        replications = paged_file_storage_call(
            file_client.list_replications,
            logger,
            f"FileStorageClient.list_replications file_system_id={resource.identifier}",
            resource.compartment_id,
            availability_domain,
            file_system_id=resource.identifier,
        )
    except Exception as exc:
        logger.error("Could not list File Storage replications for %s (%s): %s", resource.display_name, resource.identifier, exc)
        replications = []

    for replication in replications:
        replication_id = first_present(getattr(replication, "id", None), sdk_to_dict(replication).get("id"), default="")
        replication_name = first_present(getattr(replication, "display_name", None), sdk_to_dict(replication).get("display_name"), default=replication_id)
        if not replication_id:
            continue
        if delete_file_storage_replication(
            file_client,
            replication_id,
            replication_name,
            timeout_seconds,
            interval_seconds,
            logger,
        ):
            local_replication_cleanup_started = True

    try:
        replication_targets = paged_file_storage_call(
            file_client.list_replication_targets,
            logger,
            f"FileStorageClient.list_replication_targets {availability_domain}",
            resource.compartment_id,
            availability_domain,
        )
    except Exception as exc:
        logger.error("Could not list File Storage replication targets for %s (%s): %s", resource.display_name, resource.identifier, exc)
        replication_targets = []

    for target_summary in replication_targets:
        target_id = first_present(getattr(target_summary, "id", None), sdk_to_dict(target_summary).get("id"), default="")
        if not target_id:
            continue
        try:
            target_response = call_oci(
                logger,
                f"FileStorageClient.get_replication_target {target_id}",
                file_client.get_replication_target,
                target_id,
            )
        except Exception as exc:
            logger.error("Could not read File Storage replication target %s: %s", target_id, exc)
            continue
        target = target_response.data
        if target_id != replication_target_id and not replication_related_to_file_system(target, resource.identifier):
            continue
        target_name = first_present(getattr(target, "display_name", None), sdk_to_dict(target).get("display_name"), default=target_id)
        if delete_file_storage_replication_target(
            file_client,
            target_id,
            target_name,
            timeout_seconds,
            interval_seconds,
            logger,
        ):
            local_replication_cleanup_started = True

    if replication_target_id and not local_replication_cleanup_started:
        if delete_file_storage_replication_target(
            file_client,
            replication_target_id,
            replication_target_id,
            timeout_seconds,
            interval_seconds,
            logger,
        ):
            local_replication_cleanup_started = True

    if not local_replication_cleanup_started:
        logger.error(
            "FileSystem %s still has replication references, but no local replication or replication target was found to delete; "
            "replication_target_id=%s replication_source_count=%s. Not waiting because nothing was started that can clear this state.",
            resource.display_name,
            display_optional_id(replication_target_id),
            replication_source_count,
        )
        return False

    if timeout_seconds <= 0:
        return True

    interval = max(1, interval_seconds)
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            response = call_oci(
                logger,
                f"FileStorageClient.get_file_system {resource.identifier}",
                file_client.get_file_system,
                resource.identifier,
            )
        except Exception as exc:
            if is_not_found_error(exc):
                return True
            logger.error("Failed while waiting for FileSystem %s replication cleanup: %s", resource.display_name, exc)
            return False

        replication_target_id, replication_source_count, _, lifecycle_state = file_system_replication_state(response.data)
        if not replication_target_id and replication_source_count == 0:
            logger.info("FileSystem %s no longer has File Storage replication references", resource.display_name)
            return True

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            logger.error(
                "Timed out waiting for FileSystem %s replication cleanup; replication_target_id=%s replication_source_count=%s lifecycle_state=%s",
                resource.display_name,
                display_optional_id(replication_target_id),
                replication_source_count,
                lifecycle_state,
            )
            return False
        sleep_seconds = min(interval, max(1, int(remaining)))
        logger.info(
            "FileSystem %s still has replication references; replication_target_id=%s replication_source_count=%s lifecycle_state=%s; sleeping %s seconds",
            resource.display_name,
            display_optional_id(replication_target_id),
            replication_source_count,
            lifecycle_state,
            sleep_seconds,
        )
        time.sleep(sleep_seconds)
