# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Resource Search and service-specific discovery enrichment."""

from __future__ import annotations

from .runtime_core import *

def search_resources(
    compartment_id: str,
    query: str | None,
    limit: int,
    config: dict[str, Any],
    signer: Any,
    logger: logging.Logger,
) -> list[ResourceRecord]:
    search_client = make_client(oci.resource_search.ResourceSearchClient, config, signer)
    search_query = query or f"query all resources where compartmentId = '{compartment_id}'"
    logger.info("Running OCI resource search query: %s", search_query)

    details = oci.resource_search.models.StructuredSearchDetails(
        query=search_query,
        matching_context_type=oci.resource_search.models.SearchDetails.MATCHING_CONTEXT_TYPE_NONE,
    )

    records: list[ResourceRecord] = []
    page: str | None = None
    page_number = 0
    while True:
        kwargs: dict[str, Any] = {"limit": limit}
        if page:
            kwargs["page"] = page
        response = call_oci(
            logger,
            f"ResourceSearchClient.search_resources page {page_number + 1}",
            search_client.search_resources,
            details,
            **kwargs,
        )
        page_number += 1
        items = getattr(response.data, "items", None) or []
        logger.info("Resource search page %s returned %s resources", page_number, len(items))
        records.extend(build_resource_record(item) for item in items)
        page = response.headers.get("opc-next-page")
        if not page:
            break
    logger.info("Resource search found %s total resources before filtering", len(records))
    return records


def discover_compartment_resources(
    compartment_id: str,
    query: str | None,
    limit: int,
    config: dict[str, Any],
    signer: Any,
    include_terminal: bool,
    logger: logging.Logger,
) -> list[ResourceRecord]:
    resources = search_resources(
        compartment_id=compartment_id,
        query=query,
        limit=limit,
        config=config,
        signer=signer,
        logger=logger,
    )
    resources = augment_with_oke_resources(
        resources=resources,
        compartment_id=compartment_id,
        config=config,
        signer=signer,
        include_terminal=include_terminal,
        logger=logger,
    )
    resources = augment_with_virtual_network_resources(
        resources=resources,
        compartment_id=compartment_id,
        config=config,
        signer=signer,
        logger=logger,
    )
    resources = augment_with_block_storage_resources(
        resources=resources,
        compartment_id=compartment_id,
        config=config,
        signer=signer,
        logger=logger,
    )
    resources = augment_with_database_resources(
        resources=resources,
        compartment_id=compartment_id,
        config=config,
        signer=signer,
        logger=logger,
    )
    resources = augment_with_mysql_resources(
        resources=resources,
        compartment_id=compartment_id,
        config=config,
        signer=signer,
        logger=logger,
    )
    return resources


def response_items(data: Any) -> list[Any]:
    if data is None:
        return []
    if isinstance(data, list):
        return data
    return getattr(data, "items", None) or []


def sdk_summary_to_resource_record(
    summary: Any,
    resource_type: str,
    compartment_id: str,
    source: str,
) -> ResourceRecord:
    raw = sdk_to_dict(summary)
    raw["resource_type_source"] = source
    identifier = first_present(
        getattr(summary, "id", None),
        raw.get("id"),
        raw.get("identifier"),
    )
    display_name = first_present(
        getattr(summary, "name", None),
        getattr(summary, "display_name", None),
        raw.get("name"),
        raw.get("display_name"),
        raw.get("displayName"),
        identifier,
    )
    lifecycle_state = first_present(
        getattr(summary, "lifecycle_state", None),
        raw.get("lifecycle_state"),
        raw.get("lifecycleState"),
    ).upper()
    time_created = first_present(
        getattr(summary, "time_created", None),
        raw.get("time_created"),
        raw.get("timeCreated"),
    )
    normalized = to_snake(resource_type)
    return ResourceRecord(
        identifier=identifier,
        resource_type=resource_type,
        resource_type_normalized=normalized,
        display_name=display_name,
        compartment_id=compartment_id,
        lifecycle_state=lifecycle_state,
        time_created=time_created,
        availability_domain="",
        raw=raw,
        priority=DELETE_PRIORITY.get(normalized, DEFAULT_DELETE_PRIORITY),
    )


def paged_sdk_list(method: Any, logger: logging.Logger, **kwargs: Any) -> list[Any]:
    items: list[Any] = []
    page: str | None = None
    page_number = 0
    while True:
        call_kwargs = dict(kwargs)
        call_kwargs["limit"] = 1000
        if page:
            call_kwargs["page"] = page
        method_name = getattr(method, "__name__", "sdk_list")
        response = call_oci(
            logger,
            f"{method_name} page {page_number + 1}",
            method,
            **call_kwargs,
        )
        page_number += 1
        page_items = response_items(response.data)
        logger.debug(
            "%s page %s returned %s resources",
            method_name,
            page_number,
            len(page_items),
        )
        items.extend(page_items)
        page = response.headers.get("opc-next-page")
        if not page:
            return items


def augment_with_oke_resources(
    resources: list[ResourceRecord],
    compartment_id: str,
    config: dict[str, Any],
    signer: Any,
    include_terminal: bool,
    logger: logging.Logger,
) -> list[ResourceRecord]:
    existing_ids = {resource.identifier for resource in resources if resource.identifier}
    added: list[ResourceRecord] = []
    skipped_terminal: list[ResourceRecord] = []
    try:
        ce_client = make_client(oci.container_engine.ContainerEngineClient, config, signer)
        for cluster in paged_sdk_list(
            ce_client.list_clusters,
            logger,
            compartment_id=compartment_id,
        ):
            record = sdk_summary_to_resource_record(
                cluster,
                resource_type="Cluster",
                compartment_id=compartment_id,
                source="container_engine.list_clusters",
            )
            if record.identifier and record.identifier not in existing_ids:
                if not include_terminal and record.lifecycle_state in TERMINAL_LIFECYCLE_STATES:
                    skipped_terminal.append(record)
                    existing_ids.add(record.identifier)
                    continue
                existing_ids.add(record.identifier)
                added.append(record)

        for node_pool in paged_sdk_list(
            ce_client.list_node_pools,
            logger,
            compartment_id=compartment_id,
        ):
            record = sdk_summary_to_resource_record(
                node_pool,
                resource_type="NodePool",
                compartment_id=compartment_id,
                source="container_engine.list_node_pools",
            )
            if record.identifier and record.identifier not in existing_ids:
                if not include_terminal and record.lifecycle_state in TERMINAL_LIFECYCLE_STATES:
                    skipped_terminal.append(record)
                    existing_ids.add(record.identifier)
                    continue
                existing_ids.add(record.identifier)
                added.append(record)
    except Exception as exc:
        logger.error("Could not list OKE clusters/node pools for cleanup enrichment: %s", exc)
        return resources

    if added:
        if include_terminal:
            logger.info(
                "Added %s OKE cluster/node pool resources from Container Engine API that were not returned by Resource Search",
                len(added),
            )
        else:
            logger.info(
                "Added %s non-terminal OKE cluster/node pool resources from Container Engine API that were not returned by Resource Search",
                len(added),
            )
    else:
        if include_terminal:
            logger.info("Container Engine API did not find additional OKE cluster/node pool resources")
        else:
            logger.info("Container Engine API did not find additional non-terminal OKE cluster/node pool resources")
    if skipped_terminal:
        logger.info(
            "Ignored %s terminal-state OKE cluster/node pool resources returned by Container Engine API",
            len(skipped_terminal),
        )
    return resources + added


def augment_with_virtual_network_resources(
    resources: list[ResourceRecord],
    compartment_id: str,
    config: dict[str, Any],
    signer: Any,
    logger: logging.Logger,
) -> list[ResourceRecord]:
    merged_resources = list(resources)
    existing_indexes = {
        resource.identifier: index
        for index, resource in enumerate(merged_resources)
        if resource.identifier
    }
    added: list[ResourceRecord] = []
    enriched = 0
    list_specs = [
        ("Vcn", "list_vcns"),
        ("Subnet", "list_subnets"),
        ("InternetGateway", "list_internet_gateways"),
        ("NatGateway", "list_nat_gateways"),
        ("ServiceGateway", "list_service_gateways"),
        ("LocalPeeringGateway", "list_local_peering_gateways"),
        ("Drg", "list_drgs"),
        ("DrgAttachment", "list_drg_attachments"),
        ("RouteTable", "list_route_tables"),
        ("SecurityList", "list_security_lists"),
        ("DHCPOptions", "list_dhcp_options"),
        ("NetworkSecurityGroup", "list_network_security_groups"),
    ]
    try:
        network_client = make_client(oci.core.VirtualNetworkClient, config, signer)
        for resource_type, method_name in list_specs:
            method = getattr(network_client, method_name)
            for item in paged_sdk_list(
                method,
                logger,
                compartment_id=compartment_id,
            ):
                record = sdk_summary_to_resource_record(
                    item,
                    resource_type=resource_type,
                    compartment_id=compartment_id,
                    source=f"virtual_network.{method_name}",
                )
                if not record.identifier:
                    continue
                existing_index = existing_indexes.get(record.identifier)
                if existing_index is not None and existing_index < len(merged_resources):
                    merged_resources[existing_index] = record
                    enriched += 1
                elif existing_index is not None:
                    continue
                else:
                    existing_indexes[record.identifier] = len(merged_resources) + len(added)
                    added.append(record)
    except Exception as exc:
        logger.error("Could not list virtual network resources for cleanup enrichment: %s", exc)
        return resources

    if added:
        logger.info(
            "Added %s virtual network resources from VirtualNetwork API that were not returned by Resource Search",
            len(added),
        )
    else:
        logger.info("VirtualNetwork API did not find additional resources")
    if enriched:
        logger.info(
            "Enriched %s virtual network resources from VirtualNetwork API",
            enriched,
        )
    return merged_resources + added


def augment_with_block_storage_resources(
    resources: list[ResourceRecord],
    compartment_id: str,
    config: dict[str, Any],
    signer: Any,
    logger: logging.Logger,
) -> list[ResourceRecord]:
    merged_resources = list(resources)
    existing_indexes = {
        resource.identifier: index
        for index, resource in enumerate(merged_resources)
        if resource.identifier
    }
    added: list[ResourceRecord] = []
    enriched = 0
    list_specs = [
        ("VolumeGroup", "list_volume_groups"),
        ("VolumeGroupBackup", "list_volume_group_backups"),
        ("VolumeBackup", "list_volume_backups"),
    ]
    try:
        block_client = make_client(oci.core.BlockstorageClient, config, signer)
        for resource_type, method_name in list_specs:
            method = getattr(block_client, method_name)
            for item in paged_sdk_list(
                method,
                logger,
                compartment_id=compartment_id,
            ):
                record = sdk_summary_to_resource_record(
                    item,
                    resource_type=resource_type,
                    compartment_id=compartment_id,
                    source=f"block_storage.{method_name}",
                )
                if not record.identifier:
                    continue
                existing_index = existing_indexes.get(record.identifier)
                if existing_index is not None and existing_index < len(merged_resources):
                    merged_resources[existing_index] = record
                    enriched += 1
                elif existing_index is not None:
                    continue
                else:
                    existing_indexes[record.identifier] = len(merged_resources) + len(added)
                    added.append(record)
    except Exception as exc:
        logger.error("Could not list Block Storage resources for cleanup enrichment: %s", exc)
        return resources

    if added:
        logger.info(
            "Added %s Block Storage resources from Blockstorage API that were not returned by Resource Search",
            len(added),
        )
    else:
        logger.info("Blockstorage API did not find additional volume group or backup resources")
    if enriched:
        logger.info(
            "Enriched %s Block Storage resources from Blockstorage API",
            enriched,
        )
    return merged_resources + added


def augment_with_database_resources(
    resources: list[ResourceRecord],
    compartment_id: str,
    config: dict[str, Any],
    signer: Any,
    logger: logging.Logger,
) -> list[ResourceRecord]:
    merged_resources = list(resources)
    existing_indexes = {
        resource.identifier: index
        for index, resource in enumerate(merged_resources)
        if resource.identifier
    }
    added: list[ResourceRecord] = []
    enriched = 0
    try:
        database_client = make_client(oci.database.DatabaseClient, config, signer)
        for backup in paged_sdk_list(
            database_client.list_backups,
            logger,
            compartment_id=compartment_id,
        ):
            record = sdk_summary_to_resource_record(
                backup,
                resource_type="DbBackup",
                compartment_id=compartment_id,
                source="database.list_backups",
            )
            if not record.identifier:
                continue
            existing_index = existing_indexes.get(record.identifier)
            if existing_index is not None and existing_index < len(merged_resources):
                merged_resources[existing_index] = record
                enriched += 1
            elif existing_index is not None:
                continue
            else:
                existing_indexes[record.identifier] = len(merged_resources) + len(added)
                added.append(record)
    except Exception as exc:
        logger.error("Could not list Oracle Database backups for cleanup enrichment: %s", exc)
        return resources

    if added:
        logger.info(
            "Added %s Oracle Database backup resources from Database API that were not returned by Resource Search",
            len(added),
        )
    else:
        logger.info("Database API did not find additional Oracle Database backup resources")
    if enriched:
        logger.info(
            "Enriched %s Oracle Database backup resources from Database API",
            enriched,
        )
    return merged_resources + added


def augment_with_mysql_resources(
    resources: list[ResourceRecord],
    compartment_id: str,
    config: dict[str, Any],
    signer: Any,
    logger: logging.Logger,
) -> list[ResourceRecord]:
    merged_resources = list(resources)
    existing_indexes = {
        resource.identifier: index
        for index, resource in enumerate(merged_resources)
        if resource.identifier
    }
    added: list[ResourceRecord] = []
    enriched = 0
    try:
        mysql_backup_client = make_client(oci.mysql.DbBackupsClient, config, signer)
        added_before = len(added)
        enriched_before = enriched
        for backup in paged_sdk_list(
            mysql_backup_client.list_backups,
            logger,
            compartment_id=compartment_id,
        ):
            record = sdk_summary_to_resource_record(
                backup,
                resource_type="MysqlBackup",
                compartment_id=compartment_id,
                source="mysql.list_backups",
            )
            if not record.identifier:
                continue
            existing_index = existing_indexes.get(record.identifier)
            if existing_index is not None and existing_index < len(merged_resources):
                merged_resources[existing_index] = record
                enriched += 1
            elif existing_index is not None:
                continue
            else:
                existing_indexes[record.identifier] = len(merged_resources) + len(added)
                added.append(record)
        logger.info(
            "MySQL backup API enrichment added %s resources and enriched %s resources",
            len(added) - added_before,
            enriched - enriched_before,
        )
    except Exception as exc:
        logger.error("Could not list MySQL backups for cleanup enrichment: %s", exc)

    try:
        mysql_config_client = make_client(oci.mysql.MysqlaasClient, config, signer)
        added_before = len(added)
        enriched_before = enriched
        for configuration in paged_sdk_list(
            mysql_config_client.list_configurations,
            logger,
            compartment_id=compartment_id,
        ):
            record = sdk_summary_to_resource_record(
                configuration,
                resource_type="MysqlConfiguration",
                compartment_id=compartment_id,
                source="mysql.list_configurations",
            )
            if not record.identifier:
                continue
            existing_index = existing_indexes.get(record.identifier)
            if existing_index is not None and existing_index < len(merged_resources):
                merged_resources[existing_index] = record
                enriched += 1
            elif existing_index is not None:
                continue
            else:
                existing_indexes[record.identifier] = len(merged_resources) + len(added)
                added.append(record)
        logger.info(
            "MySQL configuration API enrichment added %s resources and enriched %s resources",
            len(added) - added_before,
            enriched - enriched_before,
        )
    except Exception as exc:
        logger.error("Could not list MySQL configurations for cleanup enrichment: %s", exc)

    if added:
        logger.info(
            "Added %s MySQL resources from MySQL APIs that were not returned by Resource Search",
            len(added),
        )
    else:
        logger.info("MySQL APIs did not find additional resources")
    if enriched:
        logger.info(
            "Enriched %s MySQL resources from MySQL APIs",
            enriched,
        )
    return merged_resources + added
