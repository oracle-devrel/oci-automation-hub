# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Authoritative refresh and async delete wait helpers."""

from __future__ import annotations

from .runtime_core import *
from .runtime_discovery import sdk_summary_to_resource_record

def delete_wait_spec(resource: ResourceRecord) -> tuple[type[Any], str, str] | None:
    resource_type = resource.resource_type_normalized
    if resource_type == "autonomous_database":
        return oci.database.DatabaseClient, "get_autonomous_database", "autonomous_database_id"
    if resource_type == "cluster":
        return oci.container_engine.ContainerEngineClient, "get_cluster", "cluster_id"
    if resource_type == "compute_capacity_reservation":
        return (
            oci.core.ComputeClient,
            "get_compute_capacity_reservation",
            "capacity_reservation_id",
        )
    if resource_type == "node_pool":
        return oci.container_engine.ContainerEngineClient, "get_node_pool", "node_pool_id"
    if resource_type == "db_system":
        return oci.database.DatabaseClient, "get_db_system", "db_system_id"
    if resource_type == "db_backup":
        return oci.database.DatabaseClient, "get_backup", "backup_id"
    if resource_type == "devops_project":
        return oci.devops.DevopsClient, "get_project", "project_id"
    if resource_type == "devops_repository":
        return oci.devops.DevopsClient, "get_repository", "repository_id"
    if resource_type == "mysql_backup":
        return oci.mysql.DbBackupsClient, "get_backup", "backup_id"
    if resource_type == "mysql_configuration":
        return oci.mysql.MysqlaasClient, "get_configuration", "configuration_id"
    if resource_type == "mysql_db_system":
        return oci.mysql.DbSystemClient, "get_db_system", "db_system_id"
    if resource_type == "nosql_table":
        return oci.nosql.NosqlClient, "get_table", "table_name_or_id"
    if resource_type == "ons_subscription":
        return oci.ons.NotificationDataPlaneClient, "get_subscription", "subscription_id"
    if resource_type == "ons_topic":
        return oci.ons.NotificationControlPlaneClient, "get_topic", "topic_id"
    if resource_type == "postgresql_backup":
        return oci.psql.PostgresqlClient, "get_backup", "backup_id"
    if resource_type == "postgresql_db_system":
        return oci.psql.PostgresqlClient, "get_db_system", "db_system_id"
    if resource_type == "dr_protection_group":
        return oci.disaster_recovery.DisasterRecoveryClient, "get_dr_protection_group", "dr_protection_group_id"
    if resource_type == "replication":
        return oci.file_storage.FileStorageClient, "get_replication", "replication_id"
    if resource_type == "replication_target":
        return oci.file_storage.FileStorageClient, "get_replication_target", "replication_target_id"
    if resource_type == "file_system":
        return oci.file_storage.FileStorageClient, "get_file_system", "file_system_id"
    if resource_type == "load_balancer":
        return oci.load_balancer.LoadBalancerClient, "get_load_balancer", "load_balancer_id"
    if resource_type == "network_load_balancer":
        return (
            oci.network_load_balancer.NetworkLoadBalancerClient,
            "get_network_load_balancer",
            "network_load_balancer_id",
        )
    if resource_type == "bastion":
        return oci.bastion.BastionClient, "get_bastion", "bastion_id"
    if resource_type in {"bastion_session", "session"}:
        return oci.bastion.BastionClient, "get_session", "session_id"
    if resource_type == "vcn":
        return oci.core.VirtualNetworkClient, "get_vcn", "vcn_id"
    if resource_type == "volume":
        return oci.core.BlockstorageClient, "get_volume", "volume_id"
    if resource_type == "volume_backup":
        return oci.core.BlockstorageClient, "get_volume_backup", "volume_backup_id"
    if resource_type == "volume_group":
        return oci.core.BlockstorageClient, "get_volume_group", "volume_group_id"
    if resource_type == "volume_group_backup":
        return oci.core.BlockstorageClient, "get_volume_group_backup", "volume_group_backup_id"
    return None


def authoritative_get_spec(resource: ResourceRecord) -> tuple[type[Any], str, str] | None:
    resource_type = resource.resource_type_normalized
    wait_spec = delete_wait_spec(resource)
    if wait_spec is not None:
        return wait_spec
    network_specs: dict[str, tuple[str, str]] = {
        "dhcp_options": ("get_dhcp_options", "dhcp_id"),
        "drg": ("get_drg", "drg_id"),
        "drg_attachment": ("get_drg_attachment", "drg_attachment_id"),
        "drg_route_distribution": ("get_drg_route_distribution", "drg_route_distribution_id"),
        "drg_route_table": ("get_drg_route_table", "drg_route_table_id"),
        "internet_gateway": ("get_internet_gateway", "ig_id"),
        "local_peering_gateway": ("get_local_peering_gateway", "local_peering_gateway_id"),
        "nat_gateway": ("get_nat_gateway", "nat_gateway_id"),
        "network_security_group": ("get_network_security_group", "network_security_group_id"),
        "route_table": ("get_route_table", "rt_id"),
        "security_list": ("get_security_list", "security_list_id"),
        "service_gateway": ("get_service_gateway", "service_gateway_id"),
        "subnet": ("get_subnet", "subnet_id"),
    }
    if resource_type in network_specs:
        method_name, id_parameter_name = network_specs[resource_type]
        return oci.core.VirtualNetworkClient, method_name, id_parameter_name
    dns_specs: dict[str, tuple[str, str]] = {
        "dns_resolver": ("get_resolver", "resolver_id"),
        "dns_view": ("get_view", "view_id"),
        "zone": ("get_zone", "zone_name_or_id"),
    }
    if resource_type in dns_specs:
        method_name, id_parameter_name = dns_specs[resource_type]
        return oci.dns.DnsClient, method_name, id_parameter_name
    return None


def is_not_found_error(exc: Exception) -> bool:
    return (
        getattr(exc, "status", None) == 404
        or getattr(exc, "code", None) == "NotAuthorizedOrNotFound"
    )


def refresh_authoritative_resource(
    resource: ResourceRecord,
    config: dict[str, Any],
    signer: Any,
    logger: logging.Logger,
) -> ResourceRecord | None:
    spec = authoritative_get_spec(resource)
    if spec is None or not resource.identifier:
        return resource

    client_class, get_method_name, id_parameter_name = spec
    client = make_client(client_class, config, signer)
    get_method = getattr(client, get_method_name)
    try:
        response = call_oci(
            logger,
            f"{get_method_name} {resource.identifier}",
            get_method,
            **{id_parameter_name: resource.identifier},
        )
        refreshed = sdk_summary_to_resource_record(
            response.data,
            resource_type=resource.resource_type,
            compartment_id=resource.compartment_id,
            source=f"authoritative.{get_method_name}",
        )
        if not refreshed.identifier:
            refreshed = dataclasses.replace(refreshed, identifier=resource.identifier)
        return refreshed
    except Exception as exc:
        if is_not_found_error(exc):
            logger.info(
                "Ignoring stale Resource Search result for %s %s (%s); %s no longer returns it",
                resource.resource_type,
                resource.display_name,
                resource.identifier,
                get_method_name,
            )
            return None
        logger.warning(
            "Could not verify remaining %s %s (%s) with %s: %s",
            resource.resource_type,
            resource.display_name,
            resource.identifier,
            get_method_name,
            exc,
        )
        return resource


def wait_for_delete_completion(
    resource: ResourceRecord,
    config: dict[str, Any],
    signer: Any,
    timeout_seconds: int,
    interval_seconds: int,
    logger: logging.Logger,
) -> bool:
    if resource.resource_type_normalized not in DELETE_WAIT_RESOURCE_TYPES:
        return True
    if timeout_seconds <= 0:
        logger.info("Delete wait disabled for %s %s", resource.resource_type, resource.display_name)
        return True

    spec = delete_wait_spec(resource)
    if spec is None:
        return True
    client_class, get_method_name, id_parameter_name = spec
    client = make_client(client_class, config, signer)
    get_method = getattr(client, get_method_name)
    interval = max(1, interval_seconds)
    deadline = time.monotonic() + timeout_seconds
    last_state = "UNKNOWN"

    logger.info(
        "Waiting up to %s seconds for %s %s (%s) deletion to complete",
        timeout_seconds,
        resource.resource_type,
        resource.display_name,
        resource.identifier,
    )
    while True:
        try:
            response = call_oci(
                logger,
                f"{get_method_name} {resource.identifier}",
                get_method,
                **{id_parameter_name: resource.identifier},
            )
            data = response.data
            raw_data = sdk_to_dict(data)
            last_state = first_present(
                getattr(data, "lifecycle_state", None),
                raw_data.get("lifecycle_state"),
                raw_data.get("lifecycleState"),
                default="UNKNOWN",
            ).upper()
            if last_state in DELETE_COMPLETE_STATES:
                logger.info(
                    "%s %s reached lifecycle state %s",
                    resource.resource_type,
                    resource.display_name,
                    last_state,
                )
                return True
        except Exception as exc:
            if is_not_found_error(exc):
                logger.info(
                    "%s %s is no longer returned by %s; delete is complete",
                    resource.resource_type,
                    resource.display_name,
                    get_method_name,
                )
                return True
            logger.error(
                "Failed while waiting for %s %s deletion completion: %s",
                resource.resource_type,
                resource.display_name,
                exc,
            )
            return False

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            logger.error(
                "Timed out waiting for %s %s deletion completion; last lifecycle state was %s",
                resource.resource_type,
                resource.display_name,
                last_state,
            )
            return False
        sleep_seconds = min(interval, max(1, int(remaining)))
        logger.info(
            "%s %s deletion still in lifecycle state %s; sleeping %s seconds",
            resource.resource_type,
            resource.display_name,
            last_state,
            sleep_seconds,
        )
        time.sleep(sleep_seconds)
