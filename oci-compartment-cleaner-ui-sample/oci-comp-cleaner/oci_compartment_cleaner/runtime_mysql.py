# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""MySQL-specific pre-delete handling."""

from __future__ import annotations

from .runtime_core import *
from .runtime_waiters import is_not_found_error

def mysql_db_system_delete_policy_state(db_system: Any) -> tuple[bool | None, str, str, str]:
    raw = sdk_to_dict(db_system)
    deletion_policy = getattr(db_system, "deletion_policy", None)
    raw_policy = raw.get("deletion_policy") or raw.get("deletionPolicy") or {}
    if not isinstance(raw_policy, dict):
        raw_policy = {}
    protected_value = first_present(
        getattr(deletion_policy, "is_delete_protected", None),
        raw_policy.get("is_delete_protected"),
        raw_policy.get("isDeleteProtected"),
        default="",
    ).lower()
    if protected_value == "true":
        is_delete_protected: bool | None = True
    elif protected_value == "false":
        is_delete_protected = False
    else:
        is_delete_protected = None
    lifecycle_state = first_present(
        getattr(db_system, "lifecycle_state", None),
        raw.get("lifecycle_state"),
        raw.get("lifecycleState"),
        default="UNKNOWN",
    ).upper()
    automatic_backup_retention = first_present(
        getattr(deletion_policy, "automatic_backup_retention", None),
        raw_policy.get("automatic_backup_retention"),
        raw_policy.get("automaticBackupRetention"),
        default="UNKNOWN",
    ).upper()
    final_backup = first_present(
        getattr(deletion_policy, "final_backup", None),
        raw_policy.get("final_backup"),
        raw_policy.get("finalBackup"),
        default="UNKNOWN",
    ).upper()
    return is_delete_protected, lifecycle_state, automatic_backup_retention, final_backup


def mysql_deletion_policy_update_details() -> Any:
    return oci.mysql.models.UpdateDeletionPolicyDetails(
        is_delete_protected=False,
        automatic_backup_retention=oci.mysql.models.UpdateDeletionPolicyDetails.AUTOMATIC_BACKUP_RETENTION_DELETE,
        final_backup=oci.mysql.models.UpdateDeletionPolicyDetails.FINAL_BACKUP_SKIP_FINAL_BACKUP,
    )


def prepare_mysql_db_system_for_delete(
    resource: ResourceRecord,
    config: dict[str, Any],
    signer: Any,
    timeout_seconds: int,
    interval_seconds: int,
    logger: logging.Logger,
) -> bool:
    if resource.resource_type_normalized != "mysql_db_system":
        return True

    client = make_client(oci.mysql.DbSystemClient, config, signer)
    try:
        response = call_oci(
            logger,
            f"DbSystemClient.get_db_system {resource.identifier}",
            client.get_db_system,
            resource.identifier,
        )
    except Exception as exc:
        logger.error(
            "Could not read MySQL DB System before delete-protection check %s (%s): %s",
            resource.display_name,
            resource.identifier,
            exc,
        )
        return False

    (
        is_delete_protected,
        lifecycle_state,
        automatic_backup_retention,
        final_backup,
    ) = mysql_db_system_delete_policy_state(response.data)
    cleanup_policy_ready = (
        is_delete_protected is False
        and automatic_backup_retention == oci.mysql.models.UpdateDeletionPolicyDetails.AUTOMATIC_BACKUP_RETENTION_DELETE
        and final_backup == oci.mysql.models.UpdateDeletionPolicyDetails.FINAL_BACKUP_SKIP_FINAL_BACKUP
    )
    if cleanup_policy_ready:
        logger.info(
            "MySQL DB System %s (%s) already has cleanup deletion policy; lifecycle_state=%s automatic_backup_retention=%s final_backup=%s",
            resource.display_name,
            resource.identifier,
            lifecycle_state,
            automatic_backup_retention,
            final_backup,
        )
        return True

    logger.info(
        "Setting cleanup deletion policy for MySQL DB System %s (%s); current is_delete_protected=%s lifecycle_state=%s automatic_backup_retention=%s final_backup=%s",
        resource.display_name,
        resource.identifier,
        "UNKNOWN" if is_delete_protected is None else str(is_delete_protected),
        lifecycle_state,
        automatic_backup_retention,
        final_backup,
    )
    try:
        details = oci.mysql.models.UpdateDbSystemDetails(
            deletion_policy=mysql_deletion_policy_update_details(),
        )
        call_oci(
            logger,
            f"DbSystemClient.update_db_system cleanup deletion_policy {resource.identifier}",
            client.update_db_system,
            resource.identifier,
            details,
        )
    except Exception as exc:
        logger.error(
            "Failed setting cleanup deletion policy for MySQL DB System %s (%s): %s",
            resource.display_name,
            resource.identifier,
            exc,
        )
        return False

    if timeout_seconds <= 0:
        logger.info(
            "Cleanup deletion policy update accepted for MySQL DB System %s; delete wait is disabled, continuing",
            resource.display_name,
        )
        return True

    interval = max(1, interval_seconds)
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            response = call_oci(
                logger,
                f"DbSystemClient.get_db_system {resource.identifier}",
                client.get_db_system,
                resource.identifier,
            )
        except Exception as exc:
            if is_not_found_error(exc):
                logger.info(
                    "MySQL DB System %s is no longer returned while waiting for cleanup deletion policy update",
                    resource.display_name,
                )
                return True
            logger.error(
                "Failed while waiting for MySQL DB System %s cleanup deletion policy update: %s",
                resource.display_name,
                exc,
            )
            return False

        (
            is_delete_protected,
            lifecycle_state,
            automatic_backup_retention,
            final_backup,
        ) = mysql_db_system_delete_policy_state(response.data)
        cleanup_policy_ready = (
            is_delete_protected is False
            and automatic_backup_retention == oci.mysql.models.UpdateDeletionPolicyDetails.AUTOMATIC_BACKUP_RETENTION_DELETE
            and final_backup == oci.mysql.models.UpdateDeletionPolicyDetails.FINAL_BACKUP_SKIP_FINAL_BACKUP
        )
        if cleanup_policy_ready and lifecycle_state not in {"CREATING", "UPDATING"}:
            logger.info(
                "MySQL DB System %s cleanup deletion policy is applied; lifecycle_state=%s automatic_backup_retention=%s final_backup=%s",
                resource.display_name,
                lifecycle_state,
                automatic_backup_retention,
                final_backup,
            )
            return True

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            logger.error(
                "Timed out waiting for MySQL DB System %s cleanup deletion policy; is_delete_protected=%s lifecycle_state=%s automatic_backup_retention=%s final_backup=%s",
                resource.display_name,
                "UNKNOWN" if is_delete_protected is None else str(is_delete_protected),
                lifecycle_state,
                automatic_backup_retention,
                final_backup,
            )
            return False
        sleep_seconds = min(interval, max(1, int(remaining)))
        logger.info(
            "MySQL DB System %s cleanup deletion policy update not ready; is_delete_protected=%s lifecycle_state=%s automatic_backup_retention=%s final_backup=%s; sleeping %s seconds",
            resource.display_name,
            "UNKNOWN" if is_delete_protected is None else str(is_delete_protected),
            lifecycle_state,
            automatic_backup_retention,
            final_backup,
            sleep_seconds,
        )
        time.sleep(sleep_seconds)
