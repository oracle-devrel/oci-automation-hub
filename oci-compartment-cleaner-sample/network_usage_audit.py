#!/usr/bin/env python3
"""Audit external OCI resources using VCNs/subnets in a target compartment.
# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

This script is intentionally standalone. It can be run before
``oci_compartment_cleaner`` without changing the cleaner package or its CLI.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import logging
import random
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

try:
    import oci
except ImportError:
    oci = None  # type: ignore[assignment]


TERMINAL_STATES = {
    "DELETED",
    "DELETING",
    "TERMINATED",
    "TERMINATING",
}

THROTTLE_RETRY_ATTEMPTS = 8
THROTTLE_RETRY_BASE_SLEEP_SECONDS = 2.0
THROTTLE_RETRY_MAX_SLEEP_SECONDS = 60.0


@dataclasses.dataclass(frozen=True)
class CompartmentInfo:
    identifier: str
    name: str
    lifecycle_state: str = ""


@dataclasses.dataclass(frozen=True)
class TargetVcn:
    identifier: str
    name: str
    cidr_blocks: tuple[str, ...]
    lifecycle_state: str


@dataclasses.dataclass(frozen=True)
class TargetSubnet:
    identifier: str
    name: str
    vcn_id: str
    cidr_block: str
    lifecycle_state: str


@dataclasses.dataclass(frozen=True)
class TargetNsg:
    identifier: str
    name: str
    vcn_id: str
    lifecycle_state: str


@dataclasses.dataclass(frozen=True)
class TargetLpg:
    identifier: str
    name: str
    vcn_id: str
    lifecycle_state: str


@dataclasses.dataclass
class NetworkInventory:
    target_compartment_id: str
    vcns: dict[str, TargetVcn]
    subnets: dict[str, TargetSubnet]
    nsgs: dict[str, TargetNsg]
    lpgs: dict[str, TargetLpg]


@dataclasses.dataclass(frozen=True)
class ReferenceMatch:
    reference_type: str
    reference_id: str
    path: str
    vcn_id: str = ""
    subnet_id: str = ""
    nsg_id: str = ""


@dataclasses.dataclass(frozen=True)
class UsageFinding:
    source: str
    resource_type: str
    resource_id: str
    display_name: str
    compartment_id: str
    compartment_name: str
    lifecycle_state: str
    reference_type: str
    reference_id: str
    matched_path: str
    vcn_id: str
    vcn_name: str
    subnet_id: str
    subnet_name: str
    nsg_id: str
    nsg_name: str
    evidence: str
    details: dict[str, Any]


@dataclasses.dataclass(frozen=True)
class ScanError:
    source: str
    compartment_id: str
    compartment_name: str
    message: str


@dataclasses.dataclass(frozen=True)
class ServiceScanSpec:
    source: str
    resource_type: str
    client_class_path: str
    list_method: str
    get_method: str = ""
    get_id_parameter: str = ""
    requires_availability_domain: bool = False
    page_limit: int | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Report accessible resources outside a target compartment that reference "
            "VCNs, subnets, or NSGs in the target compartment."
        )
    )
    parser.add_argument("--compartment-id", required=True, help="Target compartment OCID.")
    parser.add_argument("--region", required=True, help="OCI region, for example eu-frankfurt-1.")
    parser.add_argument(
        "--auth",
        choices=("config", "instance_principal", "resource_principal"),
        default="config",
        help="Authentication mode.",
    )
    parser.add_argument(
        "--config-file",
        default=str(Path.home() / ".oci" / "config"),
        help="OCI config file path when --auth config is used.",
    )
    parser.add_argument(
        "--profile",
        default="DEFAULT",
        help="OCI config profile when --auth config is used.",
    )
    parser.add_argument(
        "--tenancy-id",
        default="",
        help=(
            "Tenancy OCID used to enumerate accessible compartments. If omitted, "
            "the script uses the config tenancy or signer tenancy when available."
        ),
    )
    parser.add_argument(
        "--output-dir",
        default="delete_runs",
        help="Directory for audit log and report files.",
    )
    parser.add_argument("--page-limit", type=int, default=1000, help="OCI list page size.")
    parser.add_argument(
        "--compartment-access-level",
        choices=("ACCESSIBLE", "ANY"),
        default="ACCESSIBLE",
        help="Identity list_compartments access_level.",
    )
    parser.add_argument(
        "--include-inactive-compartments",
        action="store_true",
        help="Scan inactive/deleting compartments returned by Identity.",
    )
    parser.add_argument(
        "--scan-compartment-id",
        action="append",
        default=[],
        help=(
            "Scan only this external compartment. Can be supplied multiple times. "
            "When omitted, all accessible compartments are scanned."
        ),
    )
    parser.add_argument(
        "--no-vnic-scan",
        action="store_true",
        help="Skip subnet private-IP/VNIC attachment checks.",
    )
    parser.add_argument(
        "--no-service-scan",
        action="store_true",
        help="Skip service resource scans and only run the VNIC scan.",
    )
    parser.add_argument(
        "--no-sdk-retry-strategy",
        action="store_true",
        help="Disable OCI SDK DEFAULT_RETRY_STRATEGY; explicit 429 retry remains enabled.",
    )
    parser.add_argument(
        "--zero-exit-on-findings",
        action="store_true",
        help="Exit 0 even when external usage findings are reported.",
    )
    parser.add_argument("--debug", action="store_true", help="Enable debug logging.")
    return parser.parse_args()


def require_oci_sdk() -> None:
    if oci is None:
        raise SystemExit("The OCI Python SDK is required. Install it with: python3 -m pip install oci")


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def short_ocid(value: str) -> str:
    return value[-16:] if len(value) > 16 else value


def sanitize_label(value: str) -> str:
    safe = []
    for char in value:
        if char.isalnum() or char in ("-", "_"):
            safe.append(char)
        else:
            safe.append("_")
    return "".join(safe).strip("_") or "unknown"


def setup_logging(log_path: Path, debug: bool) -> logging.Logger:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("network_usage_audit")
    logger.handlers.clear()
    logger.setLevel(logging.DEBUG if debug else logging.INFO)
    formatter = logging.Formatter(
        "%(asctime)sZ %(levelname)s %(message)s", datefmt="%Y-%m-%dT%H:%M:%S"
    )
    formatter.converter = time.gmtime

    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)

    file_handler = logging.FileHandler(log_path, encoding="utf-8")
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)
    return logger


def configure_retry_behavior(args: argparse.Namespace, logger: logging.Logger) -> None:
    if args.no_sdk_retry_strategy:
        logger.info("OCI SDK DEFAULT_RETRY_STRATEGY disabled")
        return
    try:
        oci.retry.DEFAULT_RETRY_STRATEGY  # type: ignore[union-attr]
        logger.info("OCI SDK DEFAULT_RETRY_STRATEGY enabled for clients")
    except Exception:
        logger.warning("OCI SDK retry strategy was not available")


def auth_config_and_signer(args: argparse.Namespace) -> tuple[dict[str, Any], Any]:
    if args.auth == "config":
        config = oci.config.from_file(args.config_file, args.profile)  # type: ignore[union-attr]
        config["region"] = args.region
        return config, None
    if args.auth == "instance_principal":
        signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()  # type: ignore[union-attr]
        return {"region": args.region}, signer
    signer = oci.auth.signers.get_resource_principals_signer()  # type: ignore[union-attr]
    return {"region": args.region}, signer


def resolve_tenancy_id(args: argparse.Namespace, config: dict[str, Any], signer: Any) -> str:
    return first_present(
        args.tenancy_id,
        config.get("tenancy"),
        getattr(signer, "tenancy_id", None),
        getattr(signer, "tenancy_ocid", None),
        default="",
    )


def make_client(client_class: type[Any], config: dict[str, Any], signer: Any) -> Any:
    kwargs: dict[str, Any] = {}
    if signer is not None:
        kwargs["signer"] = signer
    if not getattr(make_client, "disable_sdk_retry", False):
        try:
            kwargs["retry_strategy"] = oci.retry.DEFAULT_RETRY_STRATEGY  # type: ignore[union-attr]
        except Exception:
            pass
    return client_class(config, **kwargs)


def is_throttle_error(exc: Exception) -> bool:
    status = getattr(exc, "status", None)
    code = str(getattr(exc, "code", "") or "").lower()
    message = str(exc).lower()
    return status == 429 or "too many requests" in message or "throttl" in code or "throttl" in message


def is_invalid_limit_error(exc: Exception) -> bool:
    status = getattr(exc, "status", None)
    code = str(getattr(exc, "code", "") or "").lower()
    message = str(getattr(exc, "message", "") or exc).lower()
    return status == 400 and "invalid" in code and "limit" in message


def retry_after_seconds(exc: Exception) -> float | None:
    headers = getattr(exc, "headers", None) or {}
    value = headers.get("retry-after") or headers.get("Retry-After")
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def call_oci(
    logger: logging.Logger,
    action: str,
    func: Callable[..., Any],
    *args: Any,
    **kwargs: Any,
) -> Any:
    for attempt in range(1, THROTTLE_RETRY_ATTEMPTS + 1):
        try:
            return func(*args, **kwargs)
        except Exception as exc:
            if not is_throttle_error(exc) or attempt >= THROTTLE_RETRY_ATTEMPTS:
                raise
            retry_after = retry_after_seconds(exc)
            if retry_after is None:
                retry_after = min(
                    THROTTLE_RETRY_MAX_SLEEP_SECONDS,
                    THROTTLE_RETRY_BASE_SLEEP_SECONDS * (2 ** (attempt - 1)),
                )
                retry_after += random.uniform(0, min(1.0, retry_after / 4.0))
            else:
                retry_after = min(THROTTLE_RETRY_MAX_SLEEP_SECONDS, retry_after)
            logger.warning(
                "%s was throttled; retrying attempt %s/%s after %.1f seconds",
                action,
                attempt + 1,
                THROTTLE_RETRY_ATTEMPTS,
                retry_after,
            )
            time.sleep(retry_after)


def response_items(data: Any) -> list[Any]:
    if data is None:
        return []
    if isinstance(data, list):
        return data
    return getattr(data, "items", None) or []


def paged_list(
    logger: logging.Logger,
    method: Callable[..., Any],
    *,
    page_limit: int,
    action: str,
    **kwargs: Any,
) -> list[Any]:
    items: list[Any] = []
    page: str | None = None
    page_number = 0
    effective_limit = page_limit
    while True:
        call_kwargs = dict(kwargs)
        call_kwargs["limit"] = effective_limit
        if page:
            call_kwargs["page"] = page
        try:
            logger.info(
                "%s page %s: calling list API with limit=%s%s",
                action,
                page_number + 1,
                effective_limit,
                " page_token=present" if page else "",
            )
            response = call_oci(logger, f"{action} page {page_number + 1}", method, **call_kwargs)
        except Exception as exc:
            if is_invalid_limit_error(exc) and effective_limit > 10:
                new_limit = 100 if effective_limit > 100 else 50 if effective_limit > 50 else 10
                logger.warning(
                    "%s rejected limit=%s; retrying this list call with limit=%s",
                    action,
                    effective_limit,
                    new_limit,
                )
                effective_limit = new_limit
                continue
            raise
        page_number += 1
        page_items = response_items(response.data)
        logger.info("%s page %s returned %s items", action, page_number, len(page_items))
        items.extend(page_items)
        page = response.headers.get("opc-next-page")
        if not page:
            return items


def sdk_to_dict(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, (list, tuple, set)):
        return [sdk_to_dict(item) for item in value]
    if isinstance(value, dict):
        return {str(key): sdk_to_dict(item) for key, item in value.items()}
    swagger_types = getattr(value, "swagger_types", None)
    if swagger_types:
        return {
            attr_name: sdk_to_dict(getattr(value, attr_name, None))
            for attr_name in swagger_types
        }
    return str(value)


def first_present(*values: Any, default: str = "") -> str:
    for value in values:
        if value is not None and value != "":
            return str(value)
    return default


def compartment_label(compartment: CompartmentInfo) -> str:
    return f"{compartment.name} ({compartment.identifier})"


def subnet_label(subnet: TargetSubnet) -> str:
    return f"{subnet.name} ({subnet.identifier})"


def vcn_label(vcn: TargetVcn) -> str:
    return f"{vcn.name} ({vcn.identifier})"


def lifecycle_state(resource: Any) -> str:
    raw = sdk_to_dict(resource)
    if isinstance(raw, dict):
        return first_present(raw.get("lifecycle_state"), raw.get("lifecycleState")).upper()
    return first_present(getattr(resource, "lifecycle_state", None)).upper()


def is_terminal(resource: Any) -> bool:
    return lifecycle_state(resource) in TERMINAL_STATES


def display_name(resource: Any) -> str:
    raw = sdk_to_dict(resource)
    if isinstance(raw, dict):
        return first_present(
            raw.get("display_name"),
            raw.get("displayName"),
            raw.get("name"),
            raw.get("id"),
            default="-",
        )
    return first_present(
        getattr(resource, "display_name", None),
        getattr(resource, "name", None),
        getattr(resource, "id", None),
        default="-",
    )


def resource_id(resource: Any) -> str:
    raw = sdk_to_dict(resource)
    if isinstance(raw, dict):
        return first_present(raw.get("id"), raw.get("identifier"))
    return first_present(getattr(resource, "id", None))


def compartment_id_of(resource: Any, fallback: str = "") -> str:
    raw = sdk_to_dict(resource)
    if isinstance(raw, dict):
        return first_present(raw.get("compartment_id"), raw.get("compartmentId"), fallback)
    return first_present(getattr(resource, "compartment_id", None), fallback)


def list_target_networks(
    network_client: Any,
    target_compartment_id: str,
    page_limit: int,
    logger: logging.Logger,
) -> NetworkInventory:
    vcns: dict[str, TargetVcn] = {}
    subnets: dict[str, TargetSubnet] = {}
    nsgs: dict[str, TargetNsg] = {}
    lpgs: dict[str, TargetLpg] = {}

    logger.info("Listing target VCNs in compartment %s", target_compartment_id)
    for vcn in paged_list(
        logger,
        network_client.list_vcns,
        page_limit=page_limit,
        action="VirtualNetworkClient.list_vcns",
        compartment_id=target_compartment_id,
    ):
        if is_terminal(vcn):
            continue
        raw = sdk_to_dict(vcn)
        vcn_id = resource_id(vcn)
        cidr_blocks = tuple(raw.get("cidr_blocks") or raw.get("cidrBlocks") or [])
        if not cidr_blocks:
            cidr_block = first_present(raw.get("cidr_block"), raw.get("cidrBlock"))
            cidr_blocks = (cidr_block,) if cidr_block else ()
        vcns[vcn_id] = TargetVcn(
            identifier=vcn_id,
            name=display_name(vcn),
            cidr_blocks=cidr_blocks,
            lifecycle_state=lifecycle_state(vcn),
        )

    for vcn_id in vcns:
        logger.info("Listing target subnets for VCN %s", vcn_label(vcns[vcn_id]))
        for subnet in paged_list(
            logger,
            network_client.list_subnets,
            page_limit=page_limit,
            action=f"VirtualNetworkClient.list_subnets {vcn_id}",
            compartment_id=target_compartment_id,
            vcn_id=vcn_id,
        ):
            if is_terminal(subnet):
                continue
            raw = sdk_to_dict(subnet)
            subnet_id = resource_id(subnet)
            subnets[subnet_id] = TargetSubnet(
                identifier=subnet_id,
                name=display_name(subnet),
                vcn_id=first_present(raw.get("vcn_id"), raw.get("vcnId"), vcn_id),
                cidr_block=first_present(raw.get("cidr_block"), raw.get("cidrBlock")),
                lifecycle_state=lifecycle_state(subnet),
            )

        try:
            logger.info("Listing target NSGs for VCN %s", vcn_label(vcns[vcn_id]))
            for nsg in paged_list(
                logger,
                network_client.list_network_security_groups,
                page_limit=page_limit,
                action=f"VirtualNetworkClient.list_network_security_groups {vcn_id}",
                compartment_id=target_compartment_id,
                vcn_id=vcn_id,
            ):
                if is_terminal(nsg):
                    continue
                raw = sdk_to_dict(nsg)
                nsg_id = resource_id(nsg)
                nsgs[nsg_id] = TargetNsg(
                    identifier=nsg_id,
                    name=display_name(nsg),
                    vcn_id=first_present(raw.get("vcn_id"), raw.get("vcnId"), vcn_id),
                    lifecycle_state=lifecycle_state(nsg),
                )
        except Exception as exc:
            logger.warning("Failed listing target NSGs for VCN %s: %s", vcn_id, exc)

        try:
            logger.info("Listing target local peering gateways for VCN %s", vcn_label(vcns[vcn_id]))
            for lpg in paged_list(
                logger,
                network_client.list_local_peering_gateways,
                page_limit=page_limit,
                action=f"VirtualNetworkClient.list_local_peering_gateways {vcn_id}",
                compartment_id=target_compartment_id,
                vcn_id=vcn_id,
            ):
                if is_terminal(lpg):
                    continue
                raw = sdk_to_dict(lpg)
                lpg_id = resource_id(lpg)
                lpgs[lpg_id] = TargetLpg(
                    identifier=lpg_id,
                    name=display_name(lpg),
                    vcn_id=first_present(raw.get("vcn_id"), raw.get("vcnId"), vcn_id),
                    lifecycle_state=lifecycle_state(lpg),
                )
        except Exception as exc:
            logger.warning("Failed listing target LPGs for VCN %s: %s", vcn_id, exc)

    logger.info(
        "Target network inventory: %s VCNs, %s subnets, %s NSGs, %s LPGs",
        len(vcns),
        len(subnets),
        len(nsgs),
        len(lpgs),
    )
    for vcn in sorted(vcns.values(), key=lambda item: item.name.lower()):
        logger.info(
            "Target VCN discovered: %s cidr_blocks=%s lifecycle_state=%s",
            vcn_label(vcn),
            ",".join(vcn.cidr_blocks) or "-",
            vcn.lifecycle_state or "-",
        )
    for subnet in sorted(subnets.values(), key=lambda item: item.name.lower()):
        logger.info(
            "Target subnet discovered: %s vcn=%s cidr_block=%s lifecycle_state=%s",
            subnet_label(subnet),
            subnet.vcn_id,
            subnet.cidr_block or "-",
            subnet.lifecycle_state or "-",
        )
    for nsg in sorted(nsgs.values(), key=lambda item: item.name.lower()):
        logger.info(
            "Target NSG discovered: %s vcn=%s lifecycle_state=%s",
            nsg.name + f" ({nsg.identifier})",
            nsg.vcn_id,
            nsg.lifecycle_state or "-",
        )
    for lpg in sorted(lpgs.values(), key=lambda item: item.name.lower()):
        logger.info(
            "Target LPG discovered: %s vcn=%s lifecycle_state=%s",
            lpg.name + f" ({lpg.identifier})",
            lpg.vcn_id,
            lpg.lifecycle_state or "-",
        )
    return NetworkInventory(
        target_compartment_id=target_compartment_id,
        vcns=vcns,
        subnets=subnets,
        nsgs=nsgs,
        lpgs=lpgs,
    )


def get_tenancy_name(identity_client: Any, tenancy_id: str, logger: logging.Logger) -> str:
    try:
        response = call_oci(
            logger,
            f"IdentityClient.get_tenancy {tenancy_id}",
            identity_client.get_tenancy,
            tenancy_id,
        )
        return display_name(response.data)
    except Exception as exc:
        logger.warning("Failed resolving tenancy name for %s: %s", tenancy_id, exc)
        return "tenancy"


def log_external_compartments(logger: logging.Logger, compartments: dict[str, CompartmentInfo]) -> None:
    for compartment in sorted(compartments.values(), key=lambda item: (item.name.lower(), item.identifier)):
        logger.info(
            "External scan compartment selected: %s lifecycle_state=%s",
            compartment_label(compartment),
            compartment.lifecycle_state or "-",
        )


def discover_compartments(
    identity_client: Any,
    args: argparse.Namespace,
    tenancy_id: str,
    logger: logging.Logger,
) -> dict[str, CompartmentInfo]:
    compartments: dict[str, CompartmentInfo] = {}
    if args.scan_compartment_id:
        for compartment_id in args.scan_compartment_id:
            if compartment_id == args.compartment_id:
                continue
            try:
                response = call_oci(
                    logger,
                    f"IdentityClient.get_compartment {compartment_id}",
                    identity_client.get_compartment,
                    compartment_id,
                )
                compartment = response.data
                compartments[compartment_id] = CompartmentInfo(
                    identifier=compartment_id,
                    name=display_name(compartment),
                    lifecycle_state=lifecycle_state(compartment),
                )
            except Exception as exc:
                logger.warning("Failed resolving scan compartment %s: %s", compartment_id, exc)
                compartments[compartment_id] = CompartmentInfo(
                    identifier=compartment_id,
                    name=short_ocid(compartment_id),
                    lifecycle_state="UNKNOWN",
                )
        logger.info("Scanning %s explicitly supplied external compartments", len(compartments))
        log_external_compartments(logger, compartments)
        return compartments

    tenancy_name = get_tenancy_name(identity_client, tenancy_id, logger)
    if tenancy_id != args.compartment_id:
        compartments[tenancy_id] = CompartmentInfo(
            identifier=tenancy_id,
            name=tenancy_name,
            lifecycle_state="ACTIVE",
        )

    listed = paged_list(
        logger,
        identity_client.list_compartments,
        page_limit=args.page_limit,
        action="IdentityClient.list_compartments",
        compartment_id=tenancy_id,
        compartment_id_in_subtree=True,
        access_level=args.compartment_access_level,
    )
    for compartment in listed:
        compartment_id = resource_id(compartment)
        if not compartment_id or compartment_id == args.compartment_id:
            continue
        state = lifecycle_state(compartment)
        if not args.include_inactive_compartments and state and state != "ACTIVE":
            continue
        compartments[compartment_id] = CompartmentInfo(
            identifier=compartment_id,
            name=display_name(compartment),
            lifecycle_state=state,
        )
    logger.info("Discovered %s external compartments to scan", len(compartments))
    log_external_compartments(logger, compartments)
    return compartments


def reference_kind(key: str) -> str:
    compact = key.replace("_", "").lower()
    if compact in {
        "subnetid",
        "targetsubnetid",
        "backupsubnetid",
        "loadbalancersubnetid",
        "privateendpointsubnetid",
    }:
        return "subnet"
    if compact in {"subnetids"}:
        return "subnet"
    if compact in {"vcnid", "targetvcnid"}:
        return "vcn"
    if compact in {"networkid"}:
        return "network"
    if compact in {"nsgids", "networksecuritygroupids"}:
        return "nsg"
    return ""


def values_from_reference(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, (list, tuple, set)):
        values: list[str] = []
        for item in value:
            values.extend(values_from_reference(item))
        return values
    return []


def target_match(kind: str, value: str, path: str, inventory: NetworkInventory) -> ReferenceMatch | None:
    if kind == "subnet" and value in inventory.subnets:
        subnet = inventory.subnets[value]
        return ReferenceMatch(
            reference_type="subnet",
            reference_id=value,
            path=path,
            vcn_id=subnet.vcn_id,
            subnet_id=value,
        )
    if kind in {"vcn", "network"} and value in inventory.vcns:
        return ReferenceMatch(
            reference_type="vcn",
            reference_id=value,
            path=path,
            vcn_id=value,
        )
    if kind == "nsg" and value in inventory.nsgs:
        nsg = inventory.nsgs[value]
        return ReferenceMatch(
            reference_type="nsg",
            reference_id=value,
            path=path,
            vcn_id=nsg.vcn_id,
            nsg_id=value,
        )
    return None


def extract_reference_matches(
    value: Any,
    inventory: NetworkInventory,
    path: str = "$",
) -> list[ReferenceMatch]:
    matches: list[ReferenceMatch] = []
    if isinstance(value, dict):
        for key, item in value.items():
            child_path = f"{path}.{key}"
            kind = reference_kind(key)
            if kind:
                for reference_value in values_from_reference(item):
                    match = target_match(kind, reference_value, child_path, inventory)
                    if match is not None:
                        matches.append(match)
            matches.extend(extract_reference_matches(item, inventory, child_path))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            matches.extend(extract_reference_matches(item, inventory, f"{path}[{index}]"))
    return matches


def finding_for_resource(
    *,
    source: str,
    resource_type: str,
    resource: Any,
    compartment: CompartmentInfo,
    match: ReferenceMatch,
    inventory: NetworkInventory,
    evidence: str,
    details: dict[str, Any] | None = None,
) -> UsageFinding:
    vcn = inventory.vcns.get(match.vcn_id)
    subnet = inventory.subnets.get(match.subnet_id)
    nsg = inventory.nsgs.get(match.nsg_id)
    return UsageFinding(
        source=source,
        resource_type=resource_type,
        resource_id=resource_id(resource),
        display_name=display_name(resource),
        compartment_id=compartment.identifier,
        compartment_name=compartment.name,
        lifecycle_state=lifecycle_state(resource),
        reference_type=match.reference_type,
        reference_id=match.reference_id,
        matched_path=match.path,
        vcn_id=match.vcn_id,
        vcn_name=vcn.name if vcn else "",
        subnet_id=match.subnet_id,
        subnet_name=subnet.name if subnet else "",
        nsg_id=match.nsg_id,
        nsg_name=nsg.name if nsg else "",
        evidence=evidence,
        details=details or {},
    )


def add_finding(
    findings: list[UsageFinding],
    seen: set[tuple[str, str, str, str, str]],
    finding: UsageFinding,
) -> None:
    key = (
        finding.resource_type,
        finding.resource_id,
        finding.compartment_id,
        finding.reference_type,
        finding.reference_id,
    )
    if key in seen:
        return
    seen.add(key)
    findings.append(finding)


def resolve_class(path: str) -> type[Any] | None:
    module_name, class_name = path.rsplit(".", 1)
    try:
        module = __import__(module_name, fromlist=[class_name])
        return getattr(module, class_name)
    except Exception:
        return None


def get_full_resource(
    client: Any,
    spec: ServiceScanSpec,
    item: Any,
    logger: logging.Logger,
) -> Any:
    if not spec.get_method:
        return item
    item_id = resource_id(item)
    if not item_id:
        return item
    try:
        method = getattr(client, spec.get_method)
        response = call_oci(
            logger,
            f"{client.__class__.__name__}.{spec.get_method} {item_id}",
            method,
            **{spec.get_id_parameter: item_id},
        )
        return response.data
    except Exception as exc:
        logger.debug(
            "Could not read full %s %s from %s: %s",
            spec.resource_type,
            item_id,
            spec.source,
            exc,
        )
        return item


def service_scan_specs() -> list[ServiceScanSpec]:
    return [
        ServiceScanSpec(
            "API Gateway",
            "ApiGateway",
            "oci.apigateway.GatewayClient",
            "list_gateways",
            "get_gateway",
            "gateway_id",
        ),
        ServiceScanSpec(
            "Bastion",
            "Bastion",
            "oci.bastion.BastionClient",
            "list_bastions",
            "get_bastion",
            "bastion_id",
        ),
        ServiceScanSpec(
            "Functions",
            "FunctionsApplication",
            "oci.functions.FunctionsManagementClient",
            "list_applications",
            "get_application",
            "application_id",
            page_limit=100,
        ),
        ServiceScanSpec(
            "Load Balancer",
            "LoadBalancer",
            "oci.load_balancer.LoadBalancerClient",
            "list_load_balancers",
            "get_load_balancer",
            "load_balancer_id",
        ),
        ServiceScanSpec(
            "Network Load Balancer",
            "NetworkLoadBalancer",
            "oci.network_load_balancer.NetworkLoadBalancerClient",
            "list_network_load_balancers",
            "get_network_load_balancer",
            "network_load_balancer_id",
        ),
        ServiceScanSpec(
            "File Storage",
            "MountTarget",
            "oci.file_storage.FileStorageClient",
            "list_mount_targets",
            "get_mount_target",
            "mount_target_id",
            requires_availability_domain=True,
        ),
        ServiceScanSpec(
            "Database",
            "DbSystem",
            "oci.database.DatabaseClient",
            "list_db_systems",
            "get_db_system",
            "db_system_id",
        ),
        ServiceScanSpec(
            "Database",
            "AutonomousDatabase",
            "oci.database.DatabaseClient",
            "list_autonomous_databases",
            "get_autonomous_database",
            "autonomous_database_id",
        ),
        ServiceScanSpec(
            "MySQL",
            "MysqlDbSystem",
            "oci.mysql.DbSystemClient",
            "list_db_systems",
            "get_db_system",
            "db_system_id",
        ),
        ServiceScanSpec(
            "PostgreSQL",
            "PostgresqlDbSystem",
            "oci.psql.PostgresqlClient",
            "list_db_systems",
            "get_db_system",
            "db_system_id",
        ),
        ServiceScanSpec(
            "Container Instances",
            "ContainerInstance",
            "oci.container_instances.ContainerInstanceClient",
            "list_container_instances",
            "get_container_instance",
            "container_instance_id",
        ),
        ServiceScanSpec(
            "GoldenGate",
            "GoldenGateDeployment",
            "oci.golden_gate.GoldenGateClient",
            "list_deployments",
            "get_deployment",
            "deployment_id",
        ),
        ServiceScanSpec(
            "Analytics",
            "AnalyticsInstance",
            "oci.analytics.AnalyticsClient",
            "list_analytics_instances",
            "get_analytics_instance",
            "analytics_instance_id",
        ),
        ServiceScanSpec(
            "Integration",
            "IntegrationInstance",
            "oci.integration.IntegrationInstanceClient",
            "list_integration_instances",
            "get_integration_instance",
            "integration_instance_id",
        ),
    ]


def list_availability_domains(
    identity_client: Any,
    tenancy_id: str,
    page_limit: int,
    logger: logging.Logger,
) -> list[str]:
    try:
        ads = paged_list(
            logger,
            identity_client.list_availability_domains,
            page_limit=page_limit,
            action="IdentityClient.list_availability_domains",
            compartment_id=tenancy_id,
        )
        return [display_name(ad) for ad in ads if display_name(ad)]
    except Exception as exc:
        logger.warning("Failed listing availability domains; File Storage scan will be skipped: %s", exc)
        return []


def scan_private_ips_and_vnics(
    network_client: Any,
    compute_client: Any,
    inventory: NetworkInventory,
    compartments: dict[str, CompartmentInfo],
    vnic_attachment_index: dict[str, tuple[Any, CompartmentInfo]],
    page_limit: int,
    logger: logging.Logger,
    findings: list[UsageFinding],
    seen: set[tuple[str, str, str, str, str]],
    scan_errors: list[ScanError],
) -> None:
    if not inventory.subnets:
        return
    logger.info("Starting scan phase: Core private IP/VNIC")
    logger.info("Scanning private IPs and VNICs in %s target subnets", len(inventory.subnets))
    logger.info(
        "Using %s cached external VNIC attachments from the compartment-wide compute scan",
        len(vnic_attachment_index),
    )
    for subnet in inventory.subnets.values():
        try:
            logger.info("Listing private IPs for target subnet %s", subnet_label(subnet))
            private_ips = paged_list(
                logger,
                network_client.list_private_ips,
                page_limit=page_limit,
                action=f"VirtualNetworkClient.list_private_ips {subnet.identifier}",
                subnet_id=subnet.identifier,
            )
            logger.info(
                "Private IP scan for target subnet %s returned %s private IPs",
                subnet_label(subnet),
                len(private_ips),
            )
        except Exception as exc:
            scan_errors.append(
                ScanError(
                    source="Core private IP",
                    compartment_id=inventory.target_compartment_id,
                    compartment_name="target",
                    message=f"Failed listing private IPs for subnet {subnet.identifier}: {exc}",
                )
            )
            logger.warning("Failed listing private IPs for subnet %s: %s", subnet.identifier, exc)
            continue

        for private_ip in private_ips:
            private_raw = sdk_to_dict(private_ip)
            private_compartment_id = compartment_id_of(private_ip)
            vnic_id = first_present(private_raw.get("vnic_id"), private_raw.get("vnicId"))
            cached_attachment = vnic_attachment_index.get(vnic_id) if vnic_id else None
            if not vnic_id and private_compartment_id == inventory.target_compartment_id:
                continue

            vnic = None
            vnic_compartment_id = ""
            if vnic_id and cached_attachment is None:
                try:
                    logger.info(
                        "Reading VNIC %s referenced by private IP %s in subnet %s",
                        vnic_id,
                        resource_id(private_ip),
                        subnet_label(subnet),
                    )
                    response = call_oci(
                        logger,
                        f"VirtualNetworkClient.get_vnic {vnic_id}",
                        network_client.get_vnic,
                        vnic_id,
                    )
                    vnic = response.data
                    vnic_compartment_id = compartment_id_of(vnic)
                except Exception as exc:
                    logger.debug("Failed reading VNIC %s for private IP %s: %s", vnic_id, resource_id(private_ip), exc)

            owner_compartment_id = first_present(vnic_compartment_id, private_compartment_id)
            match = ReferenceMatch(
                reference_type="subnet",
                reference_id=subnet.identifier,
                path="PrivateIp.subnet_id",
                vcn_id=subnet.vcn_id,
                subnet_id=subnet.identifier,
            )
            if cached_attachment is not None:
                attachment, attachment_compartment = cached_attachment
                logger.info(
                    "Using cached external VNIC attachment for VNIC %s from compartment %s",
                    vnic_id,
                    compartment_label(attachment_compartment),
                )
            else:
                attachment, attachment_compartment = None, CompartmentInfo("", "", "")
            if attachment is not None:
                compartment = attachment_compartment
                finding_resource = attachment
                resource_type = "VnicAttachment"
                evidence = "VNIC attachment outside the target compartment uses a target subnet"
                instance = get_attached_instance(compute_client, attachment, logger)
                if instance is not None:
                    finding_resource = instance
                    resource_type = "Instance"
                    evidence = "Compute instance outside the target compartment has a VNIC in a target subnet"
            else:
                if owner_compartment_id == inventory.target_compartment_id:
                    continue
                compartment = compartments.get(
                    owner_compartment_id,
                    CompartmentInfo(owner_compartment_id, short_ocid(owner_compartment_id), "UNKNOWN"),
                )
                finding_resource = vnic or private_ip
                resource_type = "Vnic" if vnic is not None else "PrivateIp"
                evidence = "Private IP/VNIC outside the target compartment is allocated in a target subnet"

            add_finding(
                findings,
                seen,
                finding_for_resource(
                    source="Core private IP/VNIC",
                    resource_type=resource_type,
                    resource=finding_resource,
                    compartment=compartment,
                    match=match,
                    inventory=inventory,
                    evidence=evidence,
                    details={
                        "private_ip_id": resource_id(private_ip),
                        "private_ip_address": first_present(private_raw.get("ip_address"), private_raw.get("ipAddress")),
                        "private_ip_compartment_id": private_compartment_id,
                        "vnic_id": vnic_id,
                        "vnic_compartment_id": vnic_compartment_id,
                        "subnet_id": subnet.identifier,
                    },
                ),
            )


def scan_external_compute_vnic_attachments(
    compute_client: Any,
    inventory: NetworkInventory,
    compartments: dict[str, CompartmentInfo],
    page_limit: int,
    logger: logging.Logger,
    findings: list[UsageFinding],
    seen: set[tuple[str, str, str, str, str]],
    scan_errors: list[ScanError],
) -> dict[str, tuple[Any, CompartmentInfo]]:
    attachment_index: dict[str, tuple[Any, CompartmentInfo]] = {}
    if not inventory.subnets:
        return attachment_index
    logger.info("Starting scan phase: Compute VNIC attachments")
    logger.info("Scanning compute VNIC attachments in external compartments")
    for compartment in compartments.values():
        try:
            logger.info("Scanning Compute VNIC attachments in compartment %s", compartment_label(compartment))
            attachments = paged_list(
                logger,
                compute_client.list_vnic_attachments,
                page_limit=page_limit,
                action="ComputeClient.list_vnic_attachments external",
                compartment_id=compartment.identifier,
            )
            logger.info(
                "Compute VNIC attachment scan in compartment %s returned %s attachments",
                compartment_label(compartment),
                len(attachments),
            )
        except Exception as exc:
            scan_errors.append(
                ScanError(
                    source="Compute VNIC attachments",
                    compartment_id=compartment.identifier,
                    compartment_name=compartment.name,
                    message=f"Failed listing VNIC attachments: {exc}",
                )
            )
            logger.debug(
                "Failed listing VNIC attachments in compartment %s: %s",
                compartment.identifier,
                exc,
            )
            continue
        for attachment in attachments:
            if is_terminal(attachment):
                continue
            raw = sdk_to_dict(attachment)
            subnet_id = first_present(raw.get("subnet_id"), raw.get("subnetId"))
            if subnet_id not in inventory.subnets:
                continue
            vnic_id = first_present(raw.get("vnic_id"), raw.get("vnicId"))
            if vnic_id:
                attachment_index[vnic_id] = (attachment, compartment)
            subnet = inventory.subnets[subnet_id]
            match = ReferenceMatch(
                reference_type="subnet",
                reference_id=subnet_id,
                path="VnicAttachment.subnet_id",
                vcn_id=subnet.vcn_id,
                subnet_id=subnet_id,
            )
            finding_resource = attachment
            resource_type = "VnicAttachment"
            evidence = "Compute VNIC attachment outside the target compartment references a target subnet"
            instance = get_attached_instance(compute_client, attachment, logger)
            if instance is not None:
                finding_resource = instance
                resource_type = "Instance"
                evidence = "Compute instance outside the target compartment has a VNIC in a target subnet"
            add_finding(
                findings,
                seen,
                finding_for_resource(
                    source="Compute VNIC attachment",
                    resource_type=resource_type,
                    resource=finding_resource,
                    compartment=compartment,
                    match=match,
                    inventory=inventory,
                    evidence=evidence,
                    details={
                        "vnic_attachment_id": resource_id(attachment),
                        "vnic_id": vnic_id,
                        "instance_id": first_present(raw.get("instance_id"), raw.get("instanceId")),
                        "subnet_id": subnet_id,
                    },
                ),
            )
    logger.info(
        "Cached %s external VNIC attachments that reference target subnets",
        len(attachment_index),
    )
    return attachment_index


def get_attached_instance(compute_client: Any, attachment: Any, logger: logging.Logger) -> Any | None:
    raw = sdk_to_dict(attachment)
    instance_id = first_present(raw.get("instance_id"), raw.get("instanceId"))
    if not instance_id:
        return None
    try:
        logger.info("Reading attached compute instance %s", instance_id)
        response = call_oci(
            logger,
            f"ComputeClient.get_instance {instance_id}",
            compute_client.get_instance,
            instance_id,
        )
        return response.data
    except Exception as exc:
        logger.debug("Failed reading attached instance %s: %s", instance_id, exc)
        return None


def scan_drg_attachments(
    network_client: Any,
    inventory: NetworkInventory,
    compartments: dict[str, CompartmentInfo],
    page_limit: int,
    logger: logging.Logger,
    findings: list[UsageFinding],
    seen: set[tuple[str, str, str, str, str]],
    scan_errors: list[ScanError],
) -> None:
    if not inventory.vcns:
        return
    logger.info("Starting scan phase: Core DRG attachments")
    logger.info("Scanning DRG attachments in external compartments")
    for compartment in compartments.values():
        for vcn in inventory.vcns.values():
            logger.info(
                "Scanning DRG attachments in compartment %s for target VCN %s",
                compartment_label(compartment),
                vcn_label(vcn),
            )
            for filter_name in ("vcn_id", "network_id"):
                try:
                    attachments = paged_list(
                        logger,
                        network_client.list_drg_attachments,
                        page_limit=page_limit,
                        action=f"VirtualNetworkClient.list_drg_attachments {filter_name}={vcn.identifier}",
                        compartment_id=compartment.identifier,
                        **{filter_name: vcn.identifier},
                    )
                except Exception as exc:
                    scan_errors.append(
                        ScanError(
                            source="Core DRG attachments",
                            compartment_id=compartment.identifier,
                            compartment_name=compartment.name,
                            message=f"Failed listing DRG attachments for VCN {vcn.identifier}: {exc}",
                        )
                    )
                    logger.debug(
                        "Failed listing DRG attachments in %s for VCN %s: %s",
                        compartment.identifier,
                        vcn.identifier,
                        exc,
                    )
                    continue
                logger.info(
                    "DRG attachment scan in compartment %s for target VCN %s filter=%s returned %s attachments",
                    compartment_label(compartment),
                    vcn_label(vcn),
                    filter_name,
                    len(attachments),
                )
                for attachment in attachments:
                    if is_terminal(attachment):
                        continue
                    match = ReferenceMatch(
                        reference_type="vcn",
                        reference_id=vcn.identifier,
                        path=f"DrgAttachment.{filter_name}",
                        vcn_id=vcn.identifier,
                    )
                    add_finding(
                        findings,
                        seen,
                        finding_for_resource(
                            source="Core DRG attachment",
                            resource_type="DrgAttachment",
                            resource=attachment,
                            compartment=compartment,
                            match=match,
                            inventory=inventory,
                            evidence="DRG attachment outside the target compartment references a target VCN",
                        ),
                    )


def scan_local_peering_gateways(
    network_client: Any,
    inventory: NetworkInventory,
    compartments: dict[str, CompartmentInfo],
    page_limit: int,
    logger: logging.Logger,
    findings: list[UsageFinding],
    seen: set[tuple[str, str, str, str, str]],
    scan_errors: list[ScanError],
) -> None:
    if not inventory.lpgs:
        return
    target_lpg_ids = set(inventory.lpgs)
    logger.info("Starting scan phase: Core local peering gateways")
    logger.info("Scanning local peering gateways in external compartments")
    for compartment in compartments.values():
        try:
            logger.info("Scanning local peering gateways in compartment %s", compartment_label(compartment))
            lpgs = paged_list(
                logger,
                network_client.list_local_peering_gateways,
                page_limit=page_limit,
                action="VirtualNetworkClient.list_local_peering_gateways external",
                compartment_id=compartment.identifier,
            )
            logger.info(
                "Local peering gateway scan in compartment %s returned %s LPGs",
                compartment_label(compartment),
                len(lpgs),
            )
        except Exception as exc:
            scan_errors.append(
                ScanError(
                    source="Core local peering gateways",
                    compartment_id=compartment.identifier,
                    compartment_name=compartment.name,
                    message=f"Failed listing local peering gateways: {exc}",
                )
            )
            logger.debug("Failed listing LPGs in %s: %s", compartment.identifier, exc)
            continue
        for lpg in lpgs:
            if is_terminal(lpg):
                continue
            raw = sdk_to_dict(lpg)
            peer_id = first_present(raw.get("peer_id"), raw.get("peerId"))
            lpg_vcn_id = first_present(raw.get("vcn_id"), raw.get("vcnId"))
            if peer_id in target_lpg_ids:
                target_lpg = inventory.lpgs[peer_id]
                match = ReferenceMatch(
                    reference_type="vcn",
                    reference_id=target_lpg.vcn_id,
                    path="LocalPeeringGateway.peer_id",
                    vcn_id=target_lpg.vcn_id,
                )
            elif lpg_vcn_id in inventory.vcns:
                match = ReferenceMatch(
                    reference_type="vcn",
                    reference_id=lpg_vcn_id,
                    path="LocalPeeringGateway.vcn_id",
                    vcn_id=lpg_vcn_id,
                )
            else:
                continue
            add_finding(
                findings,
                seen,
                finding_for_resource(
                    source="Core local peering gateway",
                    resource_type="LocalPeeringGateway",
                    resource=lpg,
                    compartment=compartment,
                    match=match,
                    inventory=inventory,
                    evidence="Local peering gateway outside the target compartment peers with a target VCN",
                    details={"peer_id": peer_id},
                ),
            )


def scan_service_resources(
    config: dict[str, Any],
    signer: Any,
    inventory: NetworkInventory,
    compartments: dict[str, CompartmentInfo],
    availability_domains: list[str],
    page_limit: int,
    logger: logging.Logger,
    findings: list[UsageFinding],
    seen: set[tuple[str, str, str, str, str]],
    scan_errors: list[ScanError],
) -> None:
    logger.info("Scanning common OCI service resources in external compartments")
    for spec in service_scan_specs():
        logger.info("Starting service scan: %s (%s)", spec.source, spec.resource_type)
        client_class = resolve_class(spec.client_class_path)
        if client_class is None:
            logger.debug("Skipping %s; SDK client %s is unavailable", spec.source, spec.client_class_path)
            continue
        client = make_client(client_class, config, signer)
        list_method = getattr(client, spec.list_method, None)
        if list_method is None:
            logger.debug("Skipping %s; method %s is unavailable", spec.source, spec.list_method)
            continue
        if spec.requires_availability_domain and not availability_domains:
            logger.debug("Skipping %s; no availability domains resolved", spec.source)
            continue
        for compartment in compartments.values():
            ad_values = availability_domains if spec.requires_availability_domain else [None]
            for availability_domain in ad_values:
                try:
                    kwargs: dict[str, Any] = {"compartment_id": compartment.identifier}
                    if availability_domain:
                        kwargs["availability_domain"] = availability_domain
                    if availability_domain:
                        logger.info(
                            "Scanning %s in compartment %s availability domain %s",
                            spec.source,
                            compartment_label(compartment),
                            availability_domain,
                        )
                    else:
                        logger.info(
                            "Scanning %s in compartment %s",
                            spec.source,
                            compartment_label(compartment),
                        )
                    items = paged_list(
                        logger,
                        list_method,
                        page_limit=spec.page_limit or page_limit,
                        action=f"{client.__class__.__name__}.{spec.list_method}",
                        **kwargs,
                    )
                    logger.info(
                        "%s scan in compartment %s%s returned %s resources",
                        spec.source,
                        compartment_label(compartment),
                        f" availability domain {availability_domain}" if availability_domain else "",
                        len(items),
                    )
                except Exception as exc:
                    scan_errors.append(
                        ScanError(
                            source=spec.source,
                            compartment_id=compartment.identifier,
                            compartment_name=compartment.name,
                            message=f"Failed {spec.list_method}: {exc}",
                        )
                    )
                    logger.debug(
                        "Failed scanning %s in compartment %s: %s",
                        spec.source,
                        compartment.identifier,
                        exc,
                    )
                    continue
                for item in items:
                    if is_terminal(item):
                        continue
                    resource = get_full_resource(client, spec, item, logger)
                    raw = sdk_to_dict(resource)
                    for match in extract_reference_matches(raw, inventory):
                        add_finding(
                            findings,
                            seen,
                            finding_for_resource(
                                source=spec.source,
                                resource_type=spec.resource_type,
                                resource=resource,
                                compartment=compartment,
                                match=match,
                                inventory=inventory,
                                evidence=(
                                    f"{spec.resource_type} outside the target compartment "
                                    f"contains a reference to a target {match.reference_type}"
                                ),
                                details={"list_method": spec.list_method},
                            ),
                        )


def inventory_payload(inventory: NetworkInventory) -> dict[str, Any]:
    return {
        "target_compartment_id": inventory.target_compartment_id,
        "vcns": [dataclasses.asdict(item) for item in inventory.vcns.values()],
        "subnets": [dataclasses.asdict(item) for item in inventory.subnets.values()],
        "nsgs": [dataclasses.asdict(item) for item in inventory.nsgs.values()],
        "local_peering_gateways": [dataclasses.asdict(item) for item in inventory.lpgs.values()],
    }


def json_default(value: Any) -> Any:
    if isinstance(value, datetime):
        return value.isoformat()
    if dataclasses.is_dataclass(value):
        return dataclasses.asdict(value)
    return str(value)


def write_reports(
    *,
    json_path: Path,
    text_path: Path,
    generated_at: str,
    args: argparse.Namespace,
    tenancy_id: str,
    inventory: NetworkInventory,
    compartments: dict[str, CompartmentInfo],
    findings: list[UsageFinding],
    scan_errors: list[ScanError],
) -> None:
    json_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "generated_at_utc": generated_at,
        "target_compartment_id": args.compartment_id,
        "region": args.region,
        "tenancy_id": tenancy_id,
        "scanned_external_compartment_count": len(compartments),
        "target_inventory": inventory_payload(inventory),
        "findings": [dataclasses.asdict(item) for item in findings],
        "scan_errors": [dataclasses.asdict(item) for item in scan_errors],
        "limitations": [
            "The audit is best-effort and limited by IAM permissions.",
            "Services without implemented scanners can still use the target network.",
            "Application-level dependencies are not detectable from OCI network metadata.",
        ],
    }
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True, default=json_default), encoding="utf-8")

    lines = [
        "OCI external network usage audit",
        f"Generated UTC: {generated_at}",
        f"Target compartment: {args.compartment_id}",
        f"Region: {args.region}",
        f"Tenancy: {tenancy_id or '-'}",
        "",
        "Target network inventory:",
        f"  VCNs: {len(inventory.vcns)}",
        f"  Subnets: {len(inventory.subnets)}",
        f"  NSGs: {len(inventory.nsgs)}",
        f"  Local peering gateways: {len(inventory.lpgs)}",
        f"External compartments scanned: {len(compartments)}",
        "",
        f"Findings: {len(findings)}",
    ]
    if findings:
        for index, finding in enumerate(findings, start=1):
            target_bits = []
            if finding.subnet_id:
                target_bits.append(f"subnet={finding.subnet_name} ({finding.subnet_id})")
            if finding.vcn_id:
                target_bits.append(f"vcn={finding.vcn_name} ({finding.vcn_id})")
            if finding.nsg_id:
                target_bits.append(f"nsg={finding.nsg_name} ({finding.nsg_id})")
            lines.extend(
                [
                    "",
                    f"{index}. {finding.resource_type} {finding.display_name}",
                    f"   Resource OCID: {finding.resource_id}",
                    f"   Resource compartment: {finding.compartment_name} ({finding.compartment_id})",
                    f"   Source: {finding.source}",
                    f"   Lifecycle state: {finding.lifecycle_state or '-'}",
                    f"   Reference type: {finding.reference_type}",
                    f"   Matched path: {finding.matched_path}",
                    f"   Target: {', '.join(target_bits) or finding.reference_id}",
                    f"   Evidence: {finding.evidence}",
                ]
            )
            if finding.details:
                lines.append(f"   Details: {json.dumps(finding.details, sort_keys=True, default=json_default)}")
    else:
        lines.append("  No external network usage was found by the implemented checks.")

    lines.extend(["", f"Scan errors: {len(scan_errors)}"])
    if scan_errors:
        for error in scan_errors:
            lines.append(
                f"  - {error.source} in {error.compartment_name} ({error.compartment_id}): {error.message}"
            )
    lines.extend(
        [
            "",
            "Limitations:",
            "  - This audit is best-effort and limited by IAM permissions.",
            "  - Services without implemented scanners can still use the target network.",
            "  - Application-level dependencies are not detectable from OCI network metadata.",
        ]
    )
    text_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def log_summary(
    logger: logging.Logger,
    findings: list[UsageFinding],
    scan_errors: list[ScanError],
    json_path: Path,
    text_path: Path,
    log_path: Path,
) -> None:
    if findings:
        logger.warning("External network usage findings: %s", len(findings))
        counts: dict[str, int] = {}
        for finding in findings:
            counts[finding.resource_type] = counts.get(finding.resource_type, 0) + 1
        logger.warning(
            "Findings by resource type: %s",
            ", ".join(f"{key}={value}" for key, value in sorted(counts.items())),
        )
        for finding in findings[:25]:
            logger.warning(
                "%s %s in %s references target %s %s",
                finding.resource_type,
                finding.display_name,
                finding.compartment_name,
                finding.reference_type,
                finding.reference_id,
            )
        if len(findings) > 25:
            logger.warning("Additional findings omitted from console; see report files")
    else:
        logger.info("No external network usage was found by the implemented checks")

    if scan_errors:
        logger.warning("Scan errors were recorded: %s. The audit may be incomplete.", len(scan_errors))
    logger.info("Audit JSON report: %s", json_path)
    logger.info("Audit text report: %s", text_path)
    logger.info("Audit log: %s", log_path)


def main() -> int:
    args = parse_args()
    require_oci_sdk()
    make_client.disable_sdk_retry = bool(args.no_sdk_retry_strategy)  # type: ignore[attr-defined]

    run_id = utc_timestamp()
    compartment_short = sanitize_label(short_ocid(args.compartment_id))
    region_label = sanitize_label(args.region)
    run_base = f"network_usage_audit_{compartment_short}_{region_label}_{run_id}"
    output_dir = Path(args.output_dir).expanduser().resolve()
    log_path = output_dir / f"{run_base}.log"
    json_path = output_dir / f"{run_base}.json"
    text_path = output_dir / f"{run_base}.txt"
    logger = setup_logging(log_path, args.debug)
    configure_retry_behavior(args, logger)

    try:
        logger.info("Starting external network usage audit")
        logger.info("Target compartment OCID: %s", args.compartment_id)
        logger.info("Region: %s", args.region)
        logger.info("Auth mode: %s", args.auth)

        config, signer = auth_config_and_signer(args)
        tenancy_id = resolve_tenancy_id(args, config, signer)
        if not tenancy_id:
            logger.error("Tenancy OCID could not be resolved; pass --tenancy-id")
            return 1

        identity_client = make_client(oci.identity.IdentityClient, config, signer)  # type: ignore[union-attr]
        network_client = make_client(oci.core.VirtualNetworkClient, config, signer)  # type: ignore[union-attr]
        compute_client = make_client(oci.core.ComputeClient, config, signer)  # type: ignore[union-attr]

        inventory = list_target_networks(
            network_client,
            args.compartment_id,
            args.page_limit,
            logger,
        )
        compartments = discover_compartments(identity_client, args, tenancy_id, logger)

        findings: list[UsageFinding] = []
        seen: set[tuple[str, str, str, str, str]] = set()
        scan_errors: list[ScanError] = []

        if not args.no_vnic_scan:
            vnic_attachment_index = scan_external_compute_vnic_attachments(
                compute_client,
                inventory,
                compartments,
                args.page_limit,
                logger,
                findings,
                seen,
                scan_errors,
            )
            scan_private_ips_and_vnics(
                network_client,
                compute_client,
                inventory,
                compartments,
                vnic_attachment_index,
                args.page_limit,
                logger,
                findings,
                seen,
                scan_errors,
            )

        if compartments:
            scan_drg_attachments(
                network_client,
                inventory,
                compartments,
                args.page_limit,
                logger,
                findings,
                seen,
                scan_errors,
            )
            scan_local_peering_gateways(
                network_client,
                inventory,
                compartments,
                args.page_limit,
                logger,
                findings,
                seen,
                scan_errors,
            )
            if not args.no_service_scan:
                availability_domains = list_availability_domains(
                    identity_client,
                    tenancy_id,
                    args.page_limit,
                    logger,
                )
                scan_service_resources(
                    config,
                    signer,
                    inventory,
                    compartments,
                    availability_domains,
                    args.page_limit,
                    logger,
                    findings,
                    seen,
                    scan_errors,
                )
        else:
            logger.warning("No external compartments were available to scan")

        findings.sort(
            key=lambda item: (
                item.compartment_name.lower(),
                item.resource_type,
                item.display_name.lower(),
                item.reference_type,
                item.reference_id,
            )
        )
        write_reports(
            json_path=json_path,
            text_path=text_path,
            generated_at=datetime.now(timezone.utc).isoformat(),
            args=args,
            tenancy_id=tenancy_id,
            inventory=inventory,
            compartments=compartments,
            findings=findings,
            scan_errors=scan_errors,
        )
        log_summary(logger, findings, scan_errors, json_path, text_path, log_path)
        if findings and not args.zero_exit_on_findings:
            return 2
        return 0
    finally:
        for handler in logging.getLogger("network_usage_audit").handlers:
            handler.flush()


if __name__ == "__main__":
    raise SystemExit(main())
