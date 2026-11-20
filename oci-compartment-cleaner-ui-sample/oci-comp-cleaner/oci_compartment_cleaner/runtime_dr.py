# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Full Stack Disaster Recovery pre-delete handling."""

from __future__ import annotations

from .runtime_core import *
from .runtime_waiters import is_not_found_error

def dr_protection_group_association_state(group: Any) -> tuple[str, str, str, str]:
    raw = sdk_to_dict(group)
    role = first_present(
        getattr(group, "role", None),
        raw.get("role"),
        default="",
    ).upper()
    peer_id = first_present(
        getattr(group, "peer_id", None),
        raw.get("peer_id"),
        raw.get("peerId"),
        default="",
    )
    peer_region = first_present(
        getattr(group, "peer_region", None),
        raw.get("peer_region"),
        raw.get("peerRegion"),
        default="",
    )
    lifecycle_state = first_present(
        getattr(group, "lifecycle_state", None),
        raw.get("lifecycle_state"),
        raw.get("lifecycleState"),
        default="UNKNOWN",
    ).upper()
    return role, peer_id, peer_region, lifecycle_state


def is_dr_protection_group_disassociated(group: Any) -> bool:
    role, peer_id, _, _ = dr_protection_group_association_state(group)
    return role == "UNCONFIGURED" and not peer_id


def disassociate_dr_protection_group_if_needed(
    resource: ResourceRecord,
    config: dict[str, Any],
    signer: Any,
    timeout_seconds: int,
    interval_seconds: int,
    logger: logging.Logger,
) -> bool:
    if resource.resource_type_normalized != "dr_protection_group":
        return True

    client = make_client(oci.disaster_recovery.DisasterRecoveryClient, config, signer)
    try:
        response = call_oci(
            logger,
            f"DisasterRecoveryClient.get_dr_protection_group {resource.identifier}",
            client.get_dr_protection_group,
            resource.identifier,
        )
    except Exception as exc:
        logger.error(
            "Could not read DR Protection Group before disassociation %s %s (%s): %s",
            resource.resource_type,
            resource.display_name,
            resource.identifier,
            exc,
        )
        return False

    role, peer_id, peer_region, lifecycle_state = dr_protection_group_association_state(response.data)
    if is_dr_protection_group_disassociated(response.data):
        logger.info(
            "DR Protection Group %s (%s) is already disassociated",
            resource.display_name,
            resource.identifier,
        )
        return True

    logger.info(
        "Disassociating DR Protection Group %s (%s), role=%s peer_id=%s peer_region=%s lifecycle_state=%s",
        resource.display_name,
        resource.identifier,
        role or "UNKNOWN",
        peer_id or "-",
        peer_region or "-",
        lifecycle_state,
    )
    try:
        details = oci.disaster_recovery.models.DisassociateDrProtectionGroupDefaultDetails()
        call_oci(
            logger,
            f"DisasterRecoveryClient.disassociate_dr_protection_group {resource.identifier}",
            client.disassociate_dr_protection_group,
            details,
            resource.identifier,
        )
    except Exception as exc:
        logger.error(
            "Failed disassociating DR Protection Group %s (%s): %s",
            resource.display_name,
            resource.identifier,
            exc,
        )
        return False

    if timeout_seconds <= 0:
        logger.info(
            "Disassociate accepted for DR Protection Group %s; delete wait is disabled, continuing",
            resource.display_name,
        )
        return True

    interval = max(1, interval_seconds)
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            response = call_oci(
                logger,
                f"DisasterRecoveryClient.get_dr_protection_group {resource.identifier}",
                client.get_dr_protection_group,
                resource.identifier,
            )
        except Exception as exc:
            if is_not_found_error(exc):
                logger.info(
                    "DR Protection Group %s is no longer returned while waiting for disassociation",
                    resource.display_name,
                )
                return True
            logger.error(
                "Failed while waiting for DR Protection Group %s disassociation: %s",
                resource.display_name,
                exc,
            )
            return False

        role, peer_id, peer_region, lifecycle_state = dr_protection_group_association_state(response.data)
        if is_dr_protection_group_disassociated(response.data):
            logger.info(
                "DR Protection Group %s is disassociated; role=%s lifecycle_state=%s",
                resource.display_name,
                role or "UNKNOWN",
                lifecycle_state,
            )
            return True

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            logger.error(
                "Timed out waiting for DR Protection Group %s disassociation; role=%s peer_id=%s peer_region=%s lifecycle_state=%s",
                resource.display_name,
                role or "UNKNOWN",
                peer_id or "-",
                peer_region or "-",
                lifecycle_state,
            )
            return False
        sleep_seconds = min(interval, max(1, int(remaining)))
        logger.info(
            "DR Protection Group %s still associated; role=%s peer_id=%s lifecycle_state=%s; sleeping %s seconds",
            resource.display_name,
            role or "UNKNOWN",
            peer_id or "-",
            lifecycle_state,
            sleep_seconds,
        )
        time.sleep(sleep_seconds)
