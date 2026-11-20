# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Sequential deletion loop retained for direct runtime execution."""

from __future__ import annotations

from .runtime_core import *
from .runtime_dynamic_delete import DynamicOciDeleter
from .runtime_object_storage import get_object_namespace, delete_bucket_resource
from .runtime_compute import delete_compute_capacity_reservation_resource
from .runtime_database import prepare_autonomous_database_for_delete
from .runtime_mysql import prepare_mysql_db_system_for_delete
from .runtime_dr import disassociate_dr_protection_group_if_needed
from .runtime_file_storage import prepare_file_system_for_delete
from .runtime_network import remove_route_rules_referencing_resource
from .runtime_waiters import wait_for_delete_completion

def execute_deletion(
    resources: list[ResourceRecord],
    config: dict[str, Any],
    signer: Any,
    object_namespace: str | None,
    sleep_between_phases: int,
    delete_wait_timeout_seconds: int,
    delete_wait_interval_seconds: int,
    logger: logging.Logger,
) -> None:
    deleter = DynamicOciDeleter(config, signer, logger)
    object_client = make_client(oci.object_storage.ObjectStorageClient, config, signer)
    network_client = make_client(oci.core.VirtualNetworkClient, config, signer)
    namespace: str | None = None

    last_priority: int | None = None
    successes = 0
    failures = 0
    for index, resource in enumerate(resources, start=1):
        if (
            last_priority is not None
            and resource.priority != last_priority
            and sleep_between_phases > 0
        ):
            logger.info(
                "Completed priority group %s; sleeping %s seconds for dependency cleanup",
                last_priority,
                sleep_between_phases,
            )
            time.sleep(sleep_between_phases)
        last_priority = resource.priority

        logger.info(
            "Deleting %s/%s priority=%s type=%s name=%s id=%s",
            index,
            len(resources),
            resource.priority,
            resource.resource_type,
            resource.display_name,
            resource.identifier,
        )
        try:
            if resource.resource_type_normalized == "bucket":
                if namespace is None:
                    namespace = get_object_namespace(object_client, object_namespace, logger)
                ok = delete_bucket_resource(resource, object_client, namespace, logger)
            elif resource.resource_type_normalized == "compute_capacity_reservation":
                ok = delete_compute_capacity_reservation_resource(
                    resource,
                    config,
                    signer,
                    timeout_seconds=delete_wait_timeout_seconds,
                    interval_seconds=delete_wait_interval_seconds,
                    logger=logger,
                )
            else:
                remove_route_rules_referencing_resource(network_client, resource, logger)
                if (
                    prepare_autonomous_database_for_delete(
                        resource,
                        config,
                        signer,
                        timeout_seconds=delete_wait_timeout_seconds,
                        interval_seconds=delete_wait_interval_seconds,
                        logger=logger,
                    )
                    and prepare_mysql_db_system_for_delete(
                        resource,
                        config,
                        signer,
                        timeout_seconds=delete_wait_timeout_seconds,
                        interval_seconds=delete_wait_interval_seconds,
                        logger=logger,
                    )
                    and disassociate_dr_protection_group_if_needed(
                        resource,
                        config,
                        signer,
                        timeout_seconds=delete_wait_timeout_seconds,
                        interval_seconds=delete_wait_interval_seconds,
                        logger=logger,
                    )
                    and prepare_file_system_for_delete(
                        resource,
                        config,
                        signer,
                        timeout_seconds=delete_wait_timeout_seconds,
                        interval_seconds=delete_wait_interval_seconds,
                        logger=logger,
                    )
                ):
                    ok = deleter.delete(resource)
                else:
                    ok = False
            if ok:
                successes += 1
                if not wait_for_delete_completion(
                    resource,
                    config,
                    signer,
                    timeout_seconds=delete_wait_timeout_seconds,
                    interval_seconds=delete_wait_interval_seconds,
                    logger=logger,
                ):
                    failures += 1
            else:
                failures += 1
        except Exception as exc:
            failures += 1
            logger.exception(
                "Unexpected failure deleting %s %s (%s): %s",
                resource.resource_type,
                resource.display_name,
                resource.identifier,
                exc,
            )
    logger.info("Delete API call phase completed: %s accepted, %s failed/skipped by API", successes, failures)
