# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Compute-specific delete preparation and special cases."""

from __future__ import annotations

from .runtime_core import *
from .runtime_discovery import paged_sdk_list

def instance_lifecycle_state(instance: Any) -> str:
    raw = sdk_to_dict(instance)
    return first_present(
        getattr(instance, "lifecycle_state", None),
        raw.get("lifecycle_state"),
        raw.get("lifecycleState"),
        default="UNKNOWN",
    ).upper()


def instance_display_name(instance: Any) -> str:
    raw = sdk_to_dict(instance)
    return first_present(
        getattr(instance, "display_name", None),
        raw.get("display_name"),
        raw.get("displayName"),
        getattr(instance, "id", None),
        raw.get("id"),
        default="unknown",
    )


def instance_identifier(instance: Any) -> str:
    raw = sdk_to_dict(instance)
    return first_present(getattr(instance, "id", None), raw.get("id"), default="")


def list_instances_using_capacity_reservation(
    compute_client: Any,
    resource: ResourceRecord,
    logger: logging.Logger,
) -> list[Any]:
    return paged_sdk_list(
        compute_client.list_instances,
        logger,
        compartment_id=resource.compartment_id,
        capacity_reservation_id=resource.identifier,
    )


def active_capacity_reservation_instances(instances: list[Any]) -> list[Any]:
    return [
        instance
        for instance in instances
        if instance_lifecycle_state(instance) not in {"TERMINATED"}
    ]


def summarize_instance_states(instances: list[Any]) -> str:
    counts: dict[str, int] = defaultdict(int)
    for instance in instances:
        counts[instance_lifecycle_state(instance)] += 1
    return ", ".join(f"{state}={count}" for state, count in sorted(counts.items())) or "none"


def log_capacity_reservation_instance_sample(
    resource: ResourceRecord,
    instances: list[Any],
    logger: logging.Logger,
    level: int = logging.INFO,
) -> None:
    for index, instance in enumerate(instances[:5], start=1):
        logger.log(
            level,
            "Capacity reservation %s blocker %s/%s instance state=%s name=%s id=%s",
            resource.display_name,
            index,
            len(instances),
            instance_lifecycle_state(instance),
            instance_display_name(instance),
            instance_identifier(instance),
        )


def wait_for_capacity_reservation_instances_to_clear(
    compute_client: Any,
    resource: ResourceRecord,
    timeout_seconds: int,
    interval_seconds: int,
    logger: logging.Logger,
    deadline: float | None = None,
) -> bool:
    if resource.resource_type_normalized != "compute_capacity_reservation":
        return True
    if timeout_seconds <= 0:
        logger.info(
            "Capacity reservation instance wait disabled for %s %s",
            resource.resource_type,
            resource.display_name,
        )
        return True

    if deadline is None:
        deadline = time.monotonic() + timeout_seconds
    interval = max(1, interval_seconds)

    while True:
        try:
            instances = list_instances_using_capacity_reservation(compute_client, resource, logger)
        except Exception as exc:
            logger.warning(
                "Could not list instances using ComputeCapacityReservation %s (%s): %s; delete will be attempted",
                resource.display_name,
                resource.identifier,
                exc,
            )
            return True

        active_instances = active_capacity_reservation_instances(instances)
        if not active_instances:
            logger.info(
                "No non-terminated instances are using ComputeCapacityReservation %s (%s)",
                resource.display_name,
                resource.identifier,
            )
            return True

        non_terminating = [
            instance
            for instance in active_instances
            if instance_lifecycle_state(instance) != "TERMINATING"
        ]
        if non_terminating:
            logger.warning(
                "ComputeCapacityReservation %s (%s) still has non-terminating instances using it (%s); delete may fail",
                resource.display_name,
                resource.identifier,
                summarize_instance_states(active_instances),
            )
            log_capacity_reservation_instance_sample(
                resource,
                non_terminating,
                logger,
                level=logging.WARNING,
            )
            return True

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            logger.warning(
                "Timed out waiting for ComputeCapacityReservation %s (%s) instances to terminate (%s); delete will be attempted",
                resource.display_name,
                resource.identifier,
                summarize_instance_states(active_instances),
            )
            return True

        sleep_seconds = min(interval, max(1, int(remaining)))
        logger.info(
            "ComputeCapacityReservation %s (%s) still has %s terminating instances; sleeping %s seconds",
            resource.display_name,
            resource.identifier,
            len(active_instances),
            sleep_seconds,
        )
        log_capacity_reservation_instance_sample(resource, active_instances, logger)
        time.sleep(sleep_seconds)


def delete_compute_capacity_reservation_resource(
    resource: ResourceRecord,
    config: dict[str, Any],
    signer: Any,
    timeout_seconds: int,
    interval_seconds: int,
    logger: logging.Logger,
) -> bool:
    compute_client = make_client(oci.core.ComputeClient, config, signer)
    deadline = time.monotonic() + max(0, timeout_seconds)
    wait_for_capacity_reservation_instances_to_clear(
        compute_client,
        resource,
        timeout_seconds=timeout_seconds,
        interval_seconds=interval_seconds,
        logger=logger,
        deadline=deadline,
    )

    interval = max(1, interval_seconds)
    attempt = 0
    while True:
        attempt += 1
        try:
            logger.info(
                "Calling ComputeClient.delete_compute_capacity_reservation for %s %s (%s), attempt %s",
                resource.resource_type,
                resource.display_name,
                resource.identifier,
                attempt,
            )
            call_oci(
                logger,
                f"ComputeClient.delete_compute_capacity_reservation {resource.identifier}",
                compute_client.delete_compute_capacity_reservation,
                capacity_reservation_id=resource.identifier,
            )
            logger.info(
                "Delete API accepted for %s %s (%s)",
                resource.resource_type,
                resource.display_name,
                resource.identifier,
            )
            return True
        except Exception as exc:
            if not is_conflict_error(exc):
                logger.error(
                    "Delete API failed for %s %s (%s) using ComputeClient.delete_compute_capacity_reservation: %s",
                    resource.resource_type,
                    resource.display_name,
                    resource.identifier,
                    exc,
                )
                return False

            remaining = deadline - time.monotonic()
            if timeout_seconds <= 0 or remaining <= 0:
                logger.error(
                    "Delete API failed for %s %s (%s) using ComputeClient.delete_compute_capacity_reservation after %s attempts: %s",
                    resource.resource_type,
                    resource.display_name,
                    resource.identifier,
                    attempt,
                    exc,
                )
                return False

            try:
                active_instances = active_capacity_reservation_instances(
                    list_instances_using_capacity_reservation(compute_client, resource, logger)
                )
            except Exception as list_exc:
                active_instances = []
                logger.warning(
                    "Could not list instances after capacity reservation delete conflict for %s (%s): %s",
                    resource.display_name,
                    resource.identifier,
                    list_exc,
                )

            non_terminating = [
                instance
                for instance in active_instances
                if instance_lifecycle_state(instance) != "TERMINATING"
            ]
            if non_terminating:
                logger.error(
                    "Delete API failed for %s %s (%s) because non-terminating instances still use the reservation (%s): %s",
                    resource.resource_type,
                    resource.display_name,
                    resource.identifier,
                    summarize_instance_states(active_instances),
                    exc,
                )
                log_capacity_reservation_instance_sample(
                    resource,
                    non_terminating,
                    logger,
                    level=logging.ERROR,
                )
                return False

            sleep_seconds = min(interval, max(1, int(remaining)))
            if active_instances:
                logger.warning(
                    "Compute capacity reservation delete returned 409 while instances are still terminating (%s); sleeping %s seconds before retry",
                    summarize_instance_states(active_instances),
                    sleep_seconds,
                )
            else:
                logger.warning(
                    "Compute capacity reservation delete returned 409 but no active instances were listed; sleeping %s seconds before retry",
                    sleep_seconds,
                )
            time.sleep(sleep_seconds)
