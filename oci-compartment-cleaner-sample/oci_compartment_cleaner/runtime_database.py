# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Database-specific pre-delete handling."""

from __future__ import annotations

from .runtime_core import *
from .runtime_discovery import paged_sdk_list
from .runtime_waiters import is_not_found_error, wait_for_delete_completion

def autonomous_database_peer_ids_from_db(autonomous_database: Any) -> list[str]:
    raw = sdk_to_dict(autonomous_database)
    peer_ids = getattr(autonomous_database, "peer_db_ids", None)
    if peer_ids is None:
        peer_ids = raw.get("peer_db_ids") or raw.get("peerDbIds") or []
    if isinstance(peer_ids, str):
        peer_ids = [peer_ids]
    return unique_nonempty(peer_ids)


def autonomous_database_data_guard_state(
    autonomous_database: Any,
) -> tuple[str, str, bool | None, bool | None, bool | None, list[str]]:
    raw = sdk_to_dict(autonomous_database)
    role = first_present(
        getattr(autonomous_database, "role", None),
        raw.get("role"),
        default="UNKNOWN",
    ).upper()
    lifecycle_state = first_present(
        getattr(autonomous_database, "lifecycle_state", None),
        raw.get("lifecycle_state"),
        raw.get("lifecycleState"),
        default="UNKNOWN",
    ).upper()
    is_data_guard_enabled = first_bool(
        getattr(autonomous_database, "is_data_guard_enabled", None),
        raw.get("is_data_guard_enabled"),
        raw.get("isDataGuardEnabled"),
    )
    is_remote_data_guard_enabled = first_bool(
        getattr(autonomous_database, "is_remote_data_guard_enabled", None),
        raw.get("is_remote_data_guard_enabled"),
        raw.get("isRemoteDataGuardEnabled"),
    )
    is_local_data_guard_enabled = first_bool(
        getattr(autonomous_database, "is_local_data_guard_enabled", None),
        raw.get("is_local_data_guard_enabled"),
        raw.get("isLocalDataGuardEnabled"),
    )
    peer_ids = autonomous_database_peer_ids_from_db(autonomous_database)
    return (
        role,
        lifecycle_state,
        is_data_guard_enabled,
        is_remote_data_guard_enabled,
        is_local_data_guard_enabled,
        peer_ids,
    )


def list_autonomous_database_peer_ids(
    client: Any,
    autonomous_database_id: str,
    logger: logging.Logger,
) -> list[str]:
    peers = paged_sdk_list(
        client.list_autonomous_database_peers,
        logger,
        autonomous_database_id=autonomous_database_id,
    )
    peer_ids: list[str] = []
    for peer in peers:
        raw = sdk_to_dict(peer)
        peer_ids.append(
            first_present(
                getattr(peer, "id", None),
                raw.get("id"),
                raw.get("peer_db_id"),
                raw.get("peerDbId"),
            )
        )
    return unique_nonempty(peer_ids)


def autonomous_database_data_guard_active(
    is_data_guard_enabled: bool | None,
    is_remote_data_guard_enabled: bool | None,
    is_local_data_guard_enabled: bool | None,
) -> bool:
    return any(
        value is True
        for value in (
            is_data_guard_enabled,
            is_remote_data_guard_enabled,
            is_local_data_guard_enabled,
        )
    )


def delete_autonomous_database_standby_peer(
    primary_resource: ResourceRecord,
    peer_id: str,
    peer_region: str,
    config: dict[str, Any],
    signer: Any,
    timeout_seconds: int,
    interval_seconds: int,
    logger: logging.Logger,
) -> bool:
    peer_config = config_for_region(config, peer_region)
    peer_client = make_client(oci.database.DatabaseClient, peer_config, signer)
    try:
        response = call_oci(
            logger,
            f"DatabaseClient.get_autonomous_database standby peer {peer_id}",
            peer_client.get_autonomous_database,
            peer_id,
        )
    except Exception as exc:
        if is_not_found_error(exc):
            logger.info(
                "Autonomous Database standby peer %s in region %s is already gone",
                peer_id,
                peer_region,
            )
            return True
        logger.error(
            "Could not read Autonomous Database standby peer %s in region %s for primary %s (%s): %s",
            peer_id,
            peer_region,
            primary_resource.display_name,
            primary_resource.identifier,
            exc,
        )
        return False

    (
        peer_role,
        peer_lifecycle_state,
        peer_is_data_guard_enabled,
        peer_is_remote_data_guard_enabled,
        peer_is_local_data_guard_enabled,
        peer_peer_ids,
    ) = autonomous_database_data_guard_state(response.data)
    peer_raw = sdk_to_dict(response.data)
    peer_compartment_id = first_present(
        getattr(response.data, "compartment_id", None),
        peer_raw.get("compartment_id"),
        peer_raw.get("compartmentId"),
    )
    peer_name = first_present(
        getattr(response.data, "display_name", None),
        getattr(response.data, "db_name", None),
        peer_raw.get("display_name"),
        peer_raw.get("displayName"),
        default=peer_id,
    )
    if (
        primary_resource.compartment_id
        and peer_compartment_id
        and peer_compartment_id != primary_resource.compartment_id
    ):
        logger.error(
            "Refusing to delete Autonomous Database standby peer %s in region %s because it is in compartment %s, not target compartment %s",
            peer_id,
            peer_region,
            peer_compartment_id,
            primary_resource.compartment_id,
        )
        return False
    if peer_role != "STANDBY":
        logger.error(
            "Refusing to delete Autonomous Database peer %s in region %s because role is %s, not STANDBY; primary=%s peer_lifecycle_state=%s peer_ids=%s",
            peer_id,
            peer_region,
            peer_role,
            primary_resource.identifier,
            peer_lifecycle_state,
            ",".join(peer_peer_ids) or "-",
        )
        return False

    logger.info(
        "Deleting cross-region Autonomous Database standby peer %s (%s) in region %s for primary %s (%s); lifecycle_state=%s is_data_guard_enabled=%s is_remote_data_guard_enabled=%s is_local_data_guard_enabled=%s",
        peer_name,
        peer_id,
        peer_region,
        primary_resource.display_name,
        primary_resource.identifier,
        peer_lifecycle_state,
        peer_is_data_guard_enabled,
        peer_is_remote_data_guard_enabled,
        peer_is_local_data_guard_enabled,
    )
    try:
        call_oci(
            logger,
            f"DatabaseClient.delete_autonomous_database standby peer {peer_id}",
            peer_client.delete_autonomous_database,
            peer_id,
        )
    except Exception as exc:
        if is_not_found_error(exc):
            logger.info(
                "Autonomous Database standby peer %s in region %s is already gone",
                peer_id,
                peer_region,
            )
            return True
        logger.error(
            "Failed deleting Autonomous Database standby peer %s in region %s for primary %s (%s): %s",
            peer_id,
            peer_region,
            primary_resource.display_name,
            primary_resource.identifier,
            exc,
        )
        return False

    peer_resource = ResourceRecord(
        identifier=peer_id,
        resource_type="AutonomousDatabase",
        resource_type_normalized="autonomous_database",
        display_name=peer_name,
        compartment_id=primary_resource.compartment_id,
        lifecycle_state=peer_lifecycle_state,
        time_created="",
        availability_domain="",
        raw={},
        priority=primary_resource.priority,
    )
    return wait_for_delete_completion(
        peer_resource,
        peer_config,
        signer,
        timeout_seconds,
        interval_seconds,
        logger,
    )


def prepare_autonomous_database_for_delete(
    resource: ResourceRecord,
    config: dict[str, Any],
    signer: Any,
    timeout_seconds: int,
    interval_seconds: int,
    logger: logging.Logger,
) -> bool:
    if resource.resource_type_normalized != "autonomous_database":
        return True

    client = make_client(oci.database.DatabaseClient, config, signer)
    try:
        response = call_oci(
            logger,
            f"DatabaseClient.get_autonomous_database {resource.identifier}",
            client.get_autonomous_database,
            resource.identifier,
        )
    except Exception as exc:
        if is_not_found_error(exc):
            logger.info(
                "Autonomous Database %s (%s) is no longer returned before Data Guard check",
                resource.display_name,
                resource.identifier,
            )
            return True
        logger.error(
            "Could not read Autonomous Database before Data Guard check %s (%s): %s",
            resource.display_name,
            resource.identifier,
            exc,
        )
        return False

    (
        role,
        lifecycle_state,
        is_data_guard_enabled,
        is_remote_data_guard_enabled,
        is_local_data_guard_enabled,
        model_peer_ids,
    ) = autonomous_database_data_guard_state(response.data)
    try:
        listed_peer_ids = list_autonomous_database_peer_ids(client, resource.identifier, logger)
    except Exception as exc:
        logger.error(
            "Could not list Autonomous Database peers for %s (%s): %s",
            resource.display_name,
            resource.identifier,
            exc,
        )
        return False
    peer_ids = unique_nonempty([*listed_peer_ids, *model_peer_ids])

    if not peer_ids:
        logger.info(
            "Autonomous Database %s (%s) has no Data Guard peers; role=%s lifecycle_state=%s is_data_guard_enabled=%s is_remote_data_guard_enabled=%s is_local_data_guard_enabled=%s",
            resource.display_name,
            resource.identifier,
            role,
            lifecycle_state,
            is_data_guard_enabled,
            is_remote_data_guard_enabled,
            is_local_data_guard_enabled,
        )
        return True
    if role == "STANDBY":
        logger.info(
            "Autonomous Database %s (%s) is a Data Guard standby with peer_ids=%s; deleting standby directly before primary cleanup",
            resource.display_name,
            resource.identifier,
            ",".join(peer_ids),
        )
        return True

    peer_id = peer_ids[0]
    current_region = normalize_region_name(first_present(config.get("region"), default=""))
    peer_region = ocid_region_name(peer_id)
    if peer_region and current_region and peer_region != current_region:
        logger.info(
            "Autonomous Database %s (%s) has cross-region Data Guard peer %s in region %s; deleting standby peer before primary",
            resource.display_name,
            resource.identifier,
            peer_id,
            peer_region,
        )
        if not delete_autonomous_database_standby_peer(
            primary_resource=resource,
            peer_id=peer_id,
            peer_region=peer_region,
            config=config,
            signer=signer,
            timeout_seconds=timeout_seconds,
            interval_seconds=interval_seconds,
            logger=logger,
        ):
            return False
    else:
        logger.info(
            "Disabling Data Guard for Autonomous Database %s (%s); role=%s lifecycle_state=%s peer_id=%s peer_ids=%s",
            resource.display_name,
            resource.identifier,
            role,
            lifecycle_state,
            peer_id,
            ",".join(peer_ids),
        )
        try:
            details = oci.database.models.UpdateAutonomousDatabaseDetails(
                peer_db_id=peer_id,
                is_data_guard_enabled=False,
            )
            call_oci(
                logger,
                f"DatabaseClient.update_autonomous_database is_data_guard_enabled=False {resource.identifier}",
                client.update_autonomous_database,
                resource.identifier,
                details,
            )
        except Exception as exc:
            logger.error(
                "Failed disabling Data Guard for Autonomous Database %s (%s): %s",
                resource.display_name,
                resource.identifier,
                exc,
            )
            return False

    if timeout_seconds <= 0:
        logger.info(
            "Data Guard cleanup request accepted for Autonomous Database %s; delete wait is disabled, continuing",
            resource.display_name,
        )
        return True

    interval = max(1, interval_seconds)
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            response = call_oci(
                logger,
                f"DatabaseClient.get_autonomous_database {resource.identifier}",
                client.get_autonomous_database,
                resource.identifier,
            )
            (
                role,
                lifecycle_state,
                is_data_guard_enabled,
                is_remote_data_guard_enabled,
                is_local_data_guard_enabled,
                model_peer_ids,
            ) = autonomous_database_data_guard_state(response.data)
            listed_peer_ids = list_autonomous_database_peer_ids(client, resource.identifier, logger)
        except Exception as exc:
            if is_not_found_error(exc):
                logger.info(
                    "Autonomous Database %s is no longer returned while waiting for Data Guard disable",
                    resource.display_name,
                )
                return True
            logger.error(
                "Failed while waiting for Autonomous Database %s Data Guard disable: %s",
                resource.display_name,
                exc,
            )
            return False

        peer_ids = unique_nonempty([*listed_peer_ids, *model_peer_ids])
        if (
            not peer_ids
            and not autonomous_database_data_guard_active(
                is_data_guard_enabled,
                is_remote_data_guard_enabled,
                is_local_data_guard_enabled,
            )
            and lifecycle_state not in {"CREATING", "PROVISIONING", "UPDATING"}
        ):
            logger.info(
                "Autonomous Database %s Data Guard is disabled; lifecycle_state=%s",
                resource.display_name,
                lifecycle_state,
            )
            return True

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            logger.error(
                "Timed out waiting for Autonomous Database %s Data Guard disable; role=%s lifecycle_state=%s peer_ids=%s is_data_guard_enabled=%s is_remote_data_guard_enabled=%s is_local_data_guard_enabled=%s",
                resource.display_name,
                role,
                lifecycle_state,
                ",".join(peer_ids) or "-",
                is_data_guard_enabled,
                is_remote_data_guard_enabled,
                is_local_data_guard_enabled,
            )
            return False
        sleep_seconds = min(interval, max(1, int(remaining)))
        logger.info(
            "Autonomous Database %s still has Data Guard state; role=%s lifecycle_state=%s peer_ids=%s is_data_guard_enabled=%s is_remote_data_guard_enabled=%s is_local_data_guard_enabled=%s; sleeping %s seconds",
            resource.display_name,
            role,
            lifecycle_state,
            ",".join(peer_ids) or "-",
            is_data_guard_enabled,
            is_remote_data_guard_enabled,
            is_local_data_guard_enabled,
            sleep_seconds,
        )
        time.sleep(sleep_seconds)
