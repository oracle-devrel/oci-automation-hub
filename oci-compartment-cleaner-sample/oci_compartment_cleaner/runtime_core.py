#!/usr/bin/env python3

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Core constants, models, generic helpers, OCI auth, and retry wrappers."""

from __future__ import annotations

import argparse
import dataclasses
import importlib
import inspect
import json
import logging
import os
import pkgutil
import random
import re
import sys
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

try:
    import oci
except ImportError:  # Keep --help and syntax checks usable without the SDK.
    oci = None  # type: ignore[assignment]

from .resource_manager_backup import (
    ResourceManagerBackupOptions,
    create_compartment_backup_stack,
)


SDK_RETRY_STRATEGY_ENABLED = True
THROTTLE_RETRY_ATTEMPTS = 8
THROTTLE_RETRY_BASE_SLEEP_SECONDS = 2.0
THROTTLE_RETRY_MAX_SLEEP_SECONDS = 60.0

TERMINAL_LIFECYCLE_STATES = {
    "DELETED",
    "DELETING",
    "TERMINATED",
    "TERMINATING",
    "DETACHED",
    "DETACHING",
}

SKIP_RESOURCE_TYPES = {
    "compartment",
    "tenancy",
    "work_request",
}

AUTO_MANAGED_NETWORK_RESOURCE_TYPES = {
    "private_ip",
    "public_ip",
    "vnic",
    "vnic_attachment",
}

PARENT_MANAGED_COMPUTE_RESOURCE_TYPES = {
    "boot_volume",
    "boot_volume_attachment",
    "container",
}

PARENT_MANAGED_DATABASE_RESOURCE_TYPES = {
    "database",
    "db_node",
    "pluggable_database",
}

VCN_MANAGED_DNS_RESOURCE_TYPES = {
    "dns_resolver",
    "dns_view",
}

DEFAULT_VCN_RESOURCE_TYPES = {
    "dhcp_options",
    "route_table",
    "security_list",
}

DRG_MANAGED_RESOURCE_TYPES = {
    "drg_route_distribution",
    "drg_route_table",
}

RESOURCE_TYPE_ALIASES = {
    "bootvolume": "boot_volume",
    "boot_volume": "boot_volume",
    "bootvolumeattachment": "boot_volume_attachment",
    "boot_volume_attachment": "boot_volume_attachment",
    "containerinstance": "container_instance",
    "container_instance": "container_instance",
    "containerimage": "container_image",
    "container_image": "container_image",
    "containerrepo": "container_repository",
    "container_repo": "container_repository",
    "containerrepository": "container_repository",
    "container_repository": "container_repository",
    "capacityreservation": "compute_capacity_reservation",
    "compute_capacity_reservation": "compute_capacity_reservation",
    "computecapacityreservation": "compute_capacity_reservation",
    "customerdnszone": "zone",
    "customer_dns_zone": "zone",
    "databasebackup": "db_backup",
    "database_backup": "db_backup",
    "dbbackup": "db_backup",
    "db_backup": "db_backup",
    "dbnode": "db_node",
    "db_node": "db_node",
    "dbsystem": "db_system",
    "db_system": "db_system",
    "drgattachment": "drg_attachment",
    "drg_attachment": "drg_attachment",
    "drgroutedistribution": "drg_route_distribution",
    "drg_route_distribution": "drg_route_distribution",
    "drgroutetable": "drg_route_table",
    "drg_route_table": "drg_route_table",
    "dns-zone": "zone",
    "dns_zone": "zone",
    "dnsresolver": "dns_resolver",
    "dns_resolver": "dns_resolver",
    "dnsview": "dns_view",
    "dns_view": "dns_view",
    "drprotectiongroup": "dr_protection_group",
    "dr_protection_group": "dr_protection_group",
    "devopsproject": "devops_project",
    "devops_project": "devops_project",
    "devopsrepository": "devops_repository",
    "devops_repository": "devops_repository",
    "dev_ops_project": "devops_project",
    "dev_ops_repository": "devops_repository",
    "filesystem": "file_system",
    "file_system": "file_system",
    "fnapp": "application",
    "fnfunc": "function",
    "functionsapplication": "application",
    "functions_application": "application",
    "functionsfunction": "function",
    "functions_function": "function",
    "instancepool": "instance_pool",
    "instance_pool": "instance_pool",
    "internetgateway": "internet_gateway",
    "internet_gateway": "internet_gateway",
    "localpeeringgateway": "local_peering_gateway",
    "local_peering_gateway": "local_peering_gateway",
    "mounttarget": "mount_target",
    "mount_target": "mount_target",
    "mysqlbackup": "mysql_backup",
    "mysql_backup": "mysql_backup",
    "mysqlconfiguration": "mysql_configuration",
    "mysql_configuration": "mysql_configuration",
    "mysqldbsystem": "mysql_db_system",
    "mysql_db_system": "mysql_db_system",
    "natgateway": "nat_gateway",
    "nat_gateway": "nat_gateway",
    "networkloadbalancer": "network_load_balancer",
    "network_load_balancer": "network_load_balancer",
    "networksecuritygroup": "network_security_group",
    "network_security_group": "network_security_group",
    "cluster": "cluster",
    "clusterscluster": "cluster",
    "clusters_cluster": "cluster",
    "nosqltable": "nosql_table",
    "no_sql_table": "nosql_table",
    "nosql_table": "nosql_table",
    "nodepool": "node_pool",
    "node_pool": "node_pool",
    "onssubscription": "ons_subscription",
    "ons_subscription": "ons_subscription",
    "onstopic": "ons_topic",
    "ons_topic": "ons_topic",
    "postgresqlbackup": "postgresql_backup",
    "postgresql_backup": "postgresql_backup",
    "postgresqldbsystem": "postgresql_db_system",
    "postgresql_db_system": "postgresql_db_system",
    "replicationtarget": "replication_target",
    "replication_target": "replication_target",
    "privateip": "private_ip",
    "private_ip": "private_ip",
    "publicip": "public_ip",
    "public_ip": "public_ip",
    "routetable": "route_table",
    "route_table": "route_table",
    "securitylist": "security_list",
    "security_list": "security_list",
    "servicegateway": "service_gateway",
    "service_gateway": "service_gateway",
    "vnicattachment": "vnic_attachment",
    "vnic_attachment": "vnic_attachment",
    "volumeattachment": "volume_attachment",
    "volume_attachment": "volume_attachment",
    "volumebackup": "volume_backup",
    "volume_backup": "volume_backup",
    "volumegroup": "volume_group",
    "volume_group": "volume_group",
    "volumegroupbackup": "volume_group_backup",
    "volume_group_backup": "volume_group_backup",
    "zone": "zone",
}

METHOD_OVERRIDES = {
    "container_repo": ["delete_container_repository"],
    "containerrepo": ["delete_container_repository"],
    "capacityreservation": ["delete_compute_capacity_reservation"],
    "compute_capacity_reservation": ["delete_compute_capacity_reservation"],
    "computecapacityreservation": ["delete_compute_capacity_reservation"],
    "functions_application": ["delete_application"],
    "functions_function": ["delete_function"],
    "fnapp": ["delete_application"],
    "fnfunc": ["delete_function"],
    "customer_dns_zone": ["delete_zone"],
    "dns_zone": ["delete_zone"],
    "zone": ["delete_zone"],
    "databasebackup": ["delete_backup"],
    "database_backup": ["delete_backup"],
    "dbbackup": ["delete_backup"],
    "db_backup": ["delete_backup"],
    "dbsystem": ["terminate_db_system"],
    "db_system": ["terminate_db_system"],
    "instance": ["terminate_instance"],
    "boot_volume_attachment": ["detach_boot_volume"],
    "volume_attachment": ["detach_volume"],
    "vnic_attachment": ["detach_vnic", "detach_vnic_attachment"],
    "node_pool": ["delete_node_pool"],
    "cluster": ["delete_cluster"],
    "dr_protection_group": ["delete_dr_protection_group"],
    "devopsproject": ["delete_project"],
    "devops_project": ["delete_project"],
    "devopsrepository": ["delete_repository"],
    "devops_repository": ["delete_repository"],
    "dev_ops_project": ["delete_project"],
    "dev_ops_repository": ["delete_repository"],
    "mysqlbackup": ["delete_backup"],
    "mysql_backup": ["delete_backup"],
    "mysqlconfiguration": ["delete_configuration"],
    "mysql_configuration": ["delete_configuration"],
    "mysqldbsystem": ["delete_db_system"],
    "mysql_db_system": ["delete_db_system"],
    "nosqltable": ["delete_table"],
    "no_sql_table": ["delete_table"],
    "nosql_table": ["delete_table"],
    "onssubscription": ["delete_subscription"],
    "ons_subscription": ["delete_subscription"],
    "onstopic": ["delete_topic"],
    "ons_topic": ["delete_topic"],
    "postgresqlbackup": ["delete_backup"],
    "postgresql_backup": ["delete_backup"],
    "postgresqldbsystem": ["delete_db_system"],
    "postgresql_db_system": ["delete_db_system"],
}

PREFERRED_CLIENT_MODULE_PREFIXES = {
    "autonomous_database": ("oci.database.",),
    "compute_capacity_reservation": ("oci.core.",),
    "cluster": ("oci.container_engine.",),
    "db_backup": ("oci.database.",),
    "db_system": ("oci.database.",),
    "devops_project": ("oci.devops.",),
    "devops_repository": ("oci.devops.",),
    "mysql_backup": ("oci.mysql.",),
    "mysql_configuration": ("oci.mysql.",),
    "mysql_db_system": ("oci.mysql.",),
    "nosql_table": ("oci.nosql.",),
    "node_pool": ("oci.container_engine.",),
    "ons_subscription": ("oci.ons.notification_data_plane_client",),
    "ons_topic": ("oci.ons.notification_control_plane_client",),
    "postgresql_backup": ("oci.psql.",),
    "postgresql_db_system": ("oci.psql.",),
}

DELETE_VERBS = ("delete", "terminate", "detach")

# Lower priorities are deleted first. The default intentionally sits before
# subnets, route tables, gateways, and VCNs so dependencies are removed first.
DELETE_PRIORITY = {
    "cluster": 5,
    "node_pool": 10,
    "dr_protection_group": 20,
    "function": 30,
    "container_instance": 30,
    "application": 35,
    "bastion_session": 35,
    "session": 35,
    "bastion": 40,
    "instance_pool": 45,
    "instance": 50,
    "compute_capacity_reservation": 55,
    "load_balancer": 55,
    "network_load_balancer": 55,
    "db_backup": 60,
    "db_system": 60,
    "database": 60,
    "autonomous_database": 60,
    "mysql_backup": 60,
    "mysql_db_system": 60,
    "mysql_configuration": 120,
    "nosql_table": 60,
    "postgresql_backup": 60,
    "postgresql_db_system": 60,
    "mount_target": 65,
    "vnic_attachment": 70,
    "volume_attachment": 70,
    "boot_volume_attachment": 70,
    "private_endpoint": 75,
    "bucket": 80,
    "container_image": 85,
    "volume_group_backup": 86,
    "volume_backup": 87,
    "volume_group": 88,
    "container_repository": 90,
    "replication": 92,
    "replication_target": 93,
    "boot_volume": 90,
    "volume": 90,
    "file_system": 95,
    "public_ip": 105,
    "private_ip": 110,
    "devops_repository": 112,
    "devops_project": 113,
    "ons_subscription": 114,
    "ons_topic": 115,
    "subnet": 150,
    "network_security_group": 155,
    "security_list": 160,
    "route_table": 160,
    "dhcp_options": 165,
    "internet_gateway": 170,
    "nat_gateway": 170,
    "service_gateway": 170,
    "local_peering_gateway": 170,
    "drg_attachment": 175,
    "drg_route_table": 176,
    "drg_route_distribution": 177,
    "drg": 180,
    "vcn": 200,
}

DEFAULT_DELETE_PRIORITY = 120

DELETE_WAIT_RESOURCE_TYPES = {
    "autonomous_database",
    "bastion",
    "bastion_session",
    "cluster",
    "compute_capacity_reservation",
    "devops_project",
    "devops_repository",
    "dr_protection_group",
    "file_system",
    "load_balancer",
    "network_load_balancer",
    "db_backup",
    "db_system",
    "mysql_backup",
    "mysql_configuration",
    "mysql_db_system",
    "nosql_table",
    "node_pool",
    "ons_subscription",
    "ons_topic",
    "postgresql_backup",
    "postgresql_db_system",
    "replication",
    "replication_target",
    "session",
    "vcn",
    "volume",
    "volume_backup",
    "volume_group",
    "volume_group_backup",
}

DELETE_COMPLETE_STATES = {
    "DELETED",
    "TERMINATED",
}

POST_DELETE_COMPLETED_STATES = {
    "DELETED",
    "DETACHED",
    "TERMINATED",
}


@dataclasses.dataclass(frozen=True)
class ResourceRecord:
    identifier: str
    resource_type: str
    resource_type_normalized: str
    display_name: str
    compartment_id: str
    lifecycle_state: str
    time_created: str
    availability_domain: str
    raw: dict[str, Any]
    priority: int

    def plan_item(self, sequence: int) -> dict[str, Any]:
        return {
            "sequence": sequence,
            "priority": self.priority,
            "resource_type": self.resource_type,
            "resource_type_normalized": self.resource_type_normalized,
            "display_name": self.display_name,
            "identifier": self.identifier,
            "compartment_id": self.compartment_id,
            "lifecycle_state": self.lifecycle_state,
            "availability_domain": self.availability_domain,
            "time_created": self.time_created,
        }


@dataclasses.dataclass(frozen=True)
class SkippedResource:
    resource: ResourceRecord
    reason: str

    def plan_item(self) -> dict[str, Any]:
        item = self.resource.plan_item(sequence=0)
        item["reason"] = self.reason
        item.pop("sequence", None)
        return item


def require_oci_sdk() -> None:
    if oci is None:
        raise SystemExit(
            "The OCI Python SDK is not installed. Install it with: python3 -m pip install oci"
        )


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def sanitize_label(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "-", value.strip())
    cleaned = cleaned.strip("-._")
    return cleaned[:80] or "unknown"


def short_ocid(value: str) -> str:
    if not value:
        return "unknown-compartment"
    parts = value.split(".")
    tail = parts[-1] if parts else value
    return tail[-16:] if len(tail) > 16 else tail


def raw_to_snake(value: str) -> str:
    if not value:
        return "unknown"
    value = value.replace("-", "_").replace(" ", "_")
    value = re.sub(r"(.)([A-Z][a-z]+)", r"\1_\2", value)
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", value)
    value = re.sub(r"[^A-Za-z0-9_]+", "_", value)
    return re.sub(r"_+", "_", value).strip("_").lower()


def to_snake(value: str) -> str:
    value = raw_to_snake(value)
    return RESOURCE_TYPE_ALIASES.get(value, value)


def ocid_resource_part(identifier: str, apply_alias: bool = True) -> str:
    match = re.match(r"^ocid1\.([^.]+)\.", identifier or "")
    if not match:
        return ""
    resource_part = raw_to_snake(match.group(1))
    if apply_alias:
        return RESOURCE_TYPE_ALIASES.get(resource_part, resource_part)
    return resource_part


def ocid_region_part(identifier: str) -> str:
    parts = (identifier or "").split(".")
    return parts[3] if len(parts) > 4 else ""


def normalize_region_name(region: str) -> str:
    if not region or oci is None:
        return region
    try:
        if oci.regions.is_region(region):
            return region
    except Exception:
        pass
    try:
        return oci.regions.get_region_from_short_name(region)
    except Exception:
        return region


def ocid_region_name(identifier: str) -> str:
    return normalize_region_name(ocid_region_part(identifier))


def first_present(*values: Any, default: str = "") -> str:
    for value in values:
        if value is not None and value != "":
            return str(value)
    return default


def first_bool(*values: Any) -> bool | None:
    for value in values:
        if value is None or value == "":
            continue
        if isinstance(value, bool):
            return value
        text = str(value).strip().lower()
        if text in {"true", "1", "yes"}:
            return True
        if text in {"false", "0", "no"}:
            return False
    return None


def unique_nonempty(values: Iterable[Any]) -> list[str]:
    unique: list[str] = []
    seen: set[str] = set()
    for value in values:
        if value is None or value == "":
            continue
        text = str(value)
        if text not in seen:
            unique.append(text)
            seen.add(text)
    return unique


def parse_csv_values(value: str | None) -> list[str]:
    if not value:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]


def sdk_to_dict(value: Any) -> dict[str, Any]:
    if oci is not None:
        try:
            converted = oci.util.to_dict(value)
            return converted if isinstance(converted, dict) else {"value": converted}
        except Exception:
            pass
    if isinstance(value, dict):
        return value
    return {
        key: getattr(value, key)
        for key in dir(value)
        if not key.startswith("_") and not callable(getattr(value, key, None))
    }


def build_resource_record(summary: Any) -> ResourceRecord:
    raw = sdk_to_dict(summary)
    resource_type = first_present(
        getattr(summary, "resource_type", None),
        raw.get("resource_type"),
        raw.get("type"),
        default="unknown",
    )
    normalized = to_snake(resource_type)
    display_name = first_present(
        getattr(summary, "display_name", None),
        raw.get("display_name"),
        raw.get("name"),
        raw.get("identifier"),
    )
    identifier = first_present(
        getattr(summary, "identifier", None),
        raw.get("identifier"),
        raw.get("id"),
        raw.get("ocid"),
    )
    lifecycle_state = first_present(
        getattr(summary, "lifecycle_state", None),
        raw.get("lifecycle_state"),
        raw.get("lifecycleState"),
    ).upper()
    compartment_id = first_present(
        getattr(summary, "compartment_id", None),
        raw.get("compartment_id"),
        raw.get("compartmentId"),
    )
    time_created = first_present(
        getattr(summary, "time_created", None),
        raw.get("time_created"),
        raw.get("timeCreated"),
    )
    availability_domain = first_present(
        getattr(summary, "availability_domain", None),
        raw.get("availability_domain"),
        raw.get("availabilityDomain"),
    )
    return ResourceRecord(
        identifier=identifier,
        resource_type=resource_type,
        resource_type_normalized=normalized,
        display_name=display_name,
        compartment_id=compartment_id,
        lifecycle_state=lifecycle_state,
        time_created=time_created,
        availability_domain=availability_domain,
        raw=raw,
        priority=DELETE_PRIORITY.get(normalized, DEFAULT_DELETE_PRIORITY),
    )


def setup_logging(log_path: Path, debug: bool) -> logging.Logger:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("oci_compartment_cleaner")
    logger.handlers.clear()
    logger.setLevel(logging.DEBUG if debug else logging.INFO)
    formatter = logging.Formatter(
        "%(asctime)sZ %(levelname)s %(message)s", datefmt="%Y-%m-%dT%H:%M:%S"
    )
    formatter.converter = time.gmtime

    file_handler = logging.FileHandler(log_path, encoding="utf-8")
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setLevel(logging.DEBUG if debug else logging.INFO)
    stream_handler.setFormatter(formatter)
    logger.addHandler(stream_handler)
    return logger


def auth_config_and_signer(args: argparse.Namespace) -> tuple[dict[str, Any], Any]:
    require_oci_sdk()
    if args.auth == "config":
        config = oci.config.from_file(args.config_file, args.profile)
        config["region"] = args.region
        return config, None
    if args.auth == "instance_principal":
        signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
        return {"region": args.region}, signer
    if args.auth == "resource_principal":
        signer = oci.auth.signers.get_resource_principals_signer()
        return {"region": args.region}, signer
    raise ValueError(f"Unsupported auth mode: {args.auth}")


def client_kwargs(signer: Any) -> dict[str, Any]:
    kwargs = {"signer": signer} if signer is not None else {}
    if SDK_RETRY_STRATEGY_ENABLED and oci is not None:
        retry_strategy = getattr(getattr(oci, "retry", None), "DEFAULT_RETRY_STRATEGY", None)
        if retry_strategy is not None:
            kwargs["retry_strategy"] = retry_strategy
    return kwargs


def make_client(client_class: type[Any], config: dict[str, Any], signer: Any) -> Any:
    return client_class(config, **client_kwargs(signer))


def config_for_region(config: dict[str, Any], region: str) -> dict[str, Any]:
    region_config = dict(config)
    region_config["region"] = region
    return region_config


def configure_retry_behavior(args: argparse.Namespace, logger: logging.Logger) -> None:
    global SDK_RETRY_STRATEGY_ENABLED
    global THROTTLE_RETRY_ATTEMPTS
    global THROTTLE_RETRY_BASE_SLEEP_SECONDS
    global THROTTLE_RETRY_MAX_SLEEP_SECONDS

    SDK_RETRY_STRATEGY_ENABLED = not args.no_sdk_retry_strategy
    THROTTLE_RETRY_ATTEMPTS = max(1, args.throttle_retry_attempts)
    THROTTLE_RETRY_BASE_SLEEP_SECONDS = max(0.1, args.throttle_retry_base_sleep_seconds)
    THROTTLE_RETRY_MAX_SLEEP_SECONDS = max(
        THROTTLE_RETRY_BASE_SLEEP_SECONDS,
        args.throttle_retry_max_sleep_seconds,
    )
    logger.info(
        "429 retry handling: sdk_retry_strategy=%s explicit_attempts=%s base_sleep=%ss max_sleep=%ss",
        "enabled" if SDK_RETRY_STRATEGY_ENABLED else "disabled",
        THROTTLE_RETRY_ATTEMPTS,
        THROTTLE_RETRY_BASE_SLEEP_SECONDS,
        THROTTLE_RETRY_MAX_SLEEP_SECONDS,
    )


def is_throttling_error(exc: Exception) -> bool:
    status = getattr(exc, "status", None)
    try:
        if int(status) == 429:
            return True
    except (TypeError, ValueError):
        pass
    code = str(getattr(exc, "code", "") or "").lower()
    return code in {"toomanyrequests", "too_many_requests", "throttled", "throttling"}


def is_conflict_error(exc: Exception) -> bool:
    status = getattr(exc, "status", None)
    try:
        if int(status) == 409:
            return True
    except (TypeError, ValueError):
        pass
    code = str(getattr(exc, "code", "") or "").lower()
    return code in {"conflict", "incorrectstate", "incorrect_state"}


def retry_after_seconds(exc: Exception) -> float | None:
    headers = getattr(exc, "headers", None) or getattr(exc, "response_headers", None) or {}
    if not isinstance(headers, dict):
        return None
    for key, value in headers.items():
        if str(key).lower() != "retry-after":
            continue
        try:
            return max(0.0, float(value))
        except (TypeError, ValueError):
            return None
    return None


def throttle_sleep_seconds(exc: Exception, failed_attempt: int) -> float:
    retry_after = retry_after_seconds(exc)
    if retry_after is not None:
        return min(THROTTLE_RETRY_MAX_SLEEP_SECONDS, retry_after)
    base_sleep = THROTTLE_RETRY_BASE_SLEEP_SECONDS * (2 ** max(0, failed_attempt - 1))
    capped_sleep = min(THROTTLE_RETRY_MAX_SLEEP_SECONDS, base_sleep)
    return min(THROTTLE_RETRY_MAX_SLEEP_SECONDS, capped_sleep + random.uniform(0, capped_sleep * 0.25))


def call_oci(
    logger: logging.Logger,
    description: str,
    func: Any,
    *args: Any,
    **kwargs: Any,
) -> Any:
    max_attempts = max(1, THROTTLE_RETRY_ATTEMPTS)
    for attempt in range(1, max_attempts + 1):
        try:
            return func(*args, **kwargs)
        except Exception as exc:
            if not is_throttling_error(exc) or attempt >= max_attempts:
                raise
            sleep_seconds = throttle_sleep_seconds(exc, attempt)
            logger.warning(
                "429 throttling while calling %s; attempt %s/%s failed, sleeping %.1f seconds before retry",
                description,
                attempt,
                max_attempts,
                sleep_seconds,
            )
            time.sleep(sleep_seconds)
    raise RuntimeError(f"unreachable retry state for {description}")


def get_compartment_label(
    compartment_id: str, config: dict[str, Any], signer: Any, logger: logging.Logger
) -> str:
    try:
        identity = make_client(oci.identity.IdentityClient, config, signer)
        if compartment_id.startswith("ocid1.tenancy."):
            tenancy = call_oci(
                logger,
                f"IdentityClient.get_tenancy {compartment_id}",
                identity.get_tenancy,
                compartment_id,
            ).data
            return sanitize_label(first_present(getattr(tenancy, "name", None), default=short_ocid(compartment_id)))
        compartment = call_oci(
            logger,
            f"IdentityClient.get_compartment {compartment_id}",
            identity.get_compartment,
            compartment_id,
        ).data
        return sanitize_label(first_present(getattr(compartment, "name", None), default=short_ocid(compartment_id)))
    except Exception as exc:
        logger.warning("Could not resolve compartment name for log label: %s", exc)
        return sanitize_label(short_ocid(compartment_id))
