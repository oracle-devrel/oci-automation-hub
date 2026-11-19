#!/usr/bin/env python3

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""
Create an OCI Resource Manager stack from compartment resource discovery.

This module is intentionally small and side-effect free apart from OCI API
calls. The cleanup script owns CLI parsing, confirmation prompts, and logging.
"""

from __future__ import annotations

import dataclasses
import logging
import re
import time
from datetime import datetime, timezone
from typing import Any, Callable

try:
    import oci
except ImportError:  # Keep importing the main script possible without the SDK.
    oci = None  # type: ignore[assignment]


STACK_NAME_MAX_LENGTH = 255
TAG_VALUE_MAX_LENGTH = 255
READY_STATES = {"ACTIVE"}
FAILED_STATES = {"FAILED", "DELETED"}


@dataclasses.dataclass(frozen=True)
class ResourceManagerBackupOptions:
    source_compartment_id: str
    source_region: str
    stack_compartment_id: str
    stack_region: str
    source_compartment_label: str = ""
    services_to_discover: list[str] | None = None
    wait_seconds: int = 1800
    wait_interval_seconds: int = 20
    run_id: str = ""


@dataclasses.dataclass(frozen=True)
class ResourceManagerBackupResult:
    stack_id: str
    stack_name: str
    stack_region: str
    stack_compartment_id: str
    lifecycle_state: str
    opc_work_request_id: str = ""


class ResourceManagerBackupError(RuntimeError):
    pass


CallOciFunc = Callable[..., Any]


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def sanitize_label(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "-", (value or "").strip())
    cleaned = cleaned.strip("-._")
    return cleaned[:80] or "unknown"


def short_ocid(value: str) -> str:
    if not value:
        return "unknown"
    parts = value.split(".")
    tail = parts[-1] if parts else value
    return tail[-16:] if len(tail) > 16 else tail


def truncate_tag_value(value: str) -> str:
    return str(value)[:TAG_VALUE_MAX_LENGTH]


def config_for_region(config: dict[str, Any], region: str) -> dict[str, Any]:
    region_config = dict(config)
    region_config["region"] = region
    return region_config


def client_kwargs(signer: Any) -> dict[str, Any]:
    kwargs = {"signer": signer} if signer is not None else {}
    if oci is not None:
        retry_strategy = getattr(getattr(oci, "retry", None), "DEFAULT_RETRY_STRATEGY", None)
        if retry_strategy is not None:
            kwargs["retry_strategy"] = retry_strategy
    return kwargs


def invoke_oci(
    call_oci_func: CallOciFunc | None,
    logger: logging.Logger,
    description: str,
    method: Any,
    *args: Any,
    **kwargs: Any,
) -> Any:
    if call_oci_func is None:
        return method(*args, **kwargs)
    return call_oci_func(logger, description, method, *args, **kwargs)


def response_header(response: Any, header_name: str) -> str:
    headers = getattr(response, "headers", None) or {}
    for key, value in headers.items():
        if str(key).lower() == header_name.lower():
            return str(value)
    return ""


def stack_lifecycle_state(stack: Any) -> str:
    return str(getattr(stack, "lifecycle_state", "") or "").upper()


def backup_stack_display_name(options: ResourceManagerBackupOptions) -> str:
    run_id = sanitize_label(options.run_id or utc_timestamp())
    label_source = options.source_compartment_label or short_ocid(options.source_compartment_id)
    label = sanitize_label(label_source)
    compartment = sanitize_label(short_ocid(options.source_compartment_id))
    region = sanitize_label(options.source_region)
    display_name = f"predelete-backup_{label}_{compartment}_{region}_{run_id}"
    return display_name[:STACK_NAME_MAX_LENGTH]


def backup_stack_description(options: ResourceManagerBackupOptions) -> str:
    return (
        "Resource Manager resource-discovery stack created before compartment cleanup. "
        f"Source compartment: {options.source_compartment_id}; "
        f"source region: {options.source_region}; "
        f"cleanup run: {options.run_id or 'unknown'}."
    )


def make_resource_manager_client(
    config: dict[str, Any],
    signer: Any,
    stack_region: str,
) -> Any:
    if oci is None:
        raise ResourceManagerBackupError(
            "The OCI Python SDK is not installed. Install it with: python3 -m pip install oci"
        )
    return oci.resource_manager.ResourceManagerClient(
        config_for_region(config, stack_region),
        **client_kwargs(signer),
    )


def create_stack_details(options: ResourceManagerBackupOptions, stack_name: str) -> Any:
    if oci is None:
        raise ResourceManagerBackupError(
            "The OCI Python SDK is not installed. Install it with: python3 -m pip install oci"
        )

    config_source_kwargs: dict[str, Any] = {
        "compartment_id": options.source_compartment_id,
        "region": options.source_region,
    }
    if options.services_to_discover:
        config_source_kwargs["services_to_discover"] = options.services_to_discover

    config_source = oci.resource_manager.models.CreateCompartmentConfigSourceDetails(
        **config_source_kwargs
    )

    return oci.resource_manager.models.CreateStackDetails(
        compartment_id=options.stack_compartment_id,
        display_name=stack_name,
        description=backup_stack_description(options),
        config_source=config_source,
        freeform_tags={
            "created_by": "oci_compartment_cleaner",
            "purpose": "pre-delete-resource-discovery",
            "source_compartment_id": truncate_tag_value(options.source_compartment_id),
            "source_region": truncate_tag_value(options.source_region),
            "cleanup_run_id": truncate_tag_value(options.run_id or ""),
        },
    )


def wait_for_stack_active(
    client: Any,
    stack_id: str,
    stack_name: str,
    options: ResourceManagerBackupOptions,
    logger: logging.Logger,
    call_oci_func: CallOciFunc | None = None,
) -> str:
    if options.wait_seconds <= 0:
        logger.info(
            "Resource Manager backup stack wait disabled; stack %s (%s) creation request was accepted",
            stack_name,
            stack_id,
        )
        return ""

    deadline = time.monotonic() + max(0, options.wait_seconds)
    interval = max(1, options.wait_interval_seconds)
    last_state = ""

    while True:
        response = invoke_oci(
            call_oci_func,
            logger,
            f"ResourceManagerClient.get_stack {stack_id}",
            client.get_stack,
            stack_id,
        )
        last_state = stack_lifecycle_state(response.data)
        if last_state in READY_STATES:
            logger.info(
                "Resource Manager backup stack is %s: name=%s id=%s",
                last_state,
                stack_name,
                stack_id,
            )
            return last_state
        if last_state in FAILED_STATES:
            raise ResourceManagerBackupError(
                f"Resource Manager backup stack {stack_name} ({stack_id}) reached lifecycle state {last_state}"
            )
        now = time.monotonic()
        if now >= deadline:
            raise ResourceManagerBackupError(
                f"Timed out after {options.wait_seconds}s waiting for Resource Manager backup stack "
                f"{stack_name} ({stack_id}) to become ACTIVE; last state was {last_state or 'unknown'}"
            )
        sleep_seconds = min(interval, max(1, int(deadline - now)))
        logger.info(
            "Resource Manager backup stack %s (%s) still in lifecycle state %s; sleeping %s seconds",
            stack_name,
            stack_id,
            last_state or "unknown",
            sleep_seconds,
        )
        time.sleep(sleep_seconds)


def create_compartment_backup_stack(
    options: ResourceManagerBackupOptions,
    config: dict[str, Any],
    signer: Any,
    logger: logging.Logger,
    call_oci_func: CallOciFunc | None = None,
) -> ResourceManagerBackupResult:
    if not options.source_compartment_id:
        raise ResourceManagerBackupError("source_compartment_id is required")
    if not options.source_region:
        raise ResourceManagerBackupError("source_region is required")
    if not options.stack_compartment_id:
        raise ResourceManagerBackupError("stack_compartment_id is required")
    if not options.stack_region:
        raise ResourceManagerBackupError("stack_region is required")
    if options.stack_compartment_id == options.source_compartment_id:
        raise ResourceManagerBackupError(
            "Resource Manager backup stack compartment must be different from the target cleanup compartment"
        )

    stack_name = backup_stack_display_name(options)
    client = make_resource_manager_client(config, signer, options.stack_region)
    details = create_stack_details(options, stack_name)
    services = ", ".join(options.services_to_discover or []) or "all supported services"

    logger.info(
        "Creating Resource Manager backup stack: name=%s source_compartment=%s source_region=%s "
        "stack_compartment=%s stack_region=%s services=%s",
        stack_name,
        options.source_compartment_id,
        options.source_region,
        options.stack_compartment_id,
        options.stack_region,
        services,
    )

    response = invoke_oci(
        call_oci_func,
        logger,
        f"ResourceManagerClient.create_stack {stack_name}",
        client.create_stack,
        details,
    )
    stack = response.data
    stack_id = str(getattr(stack, "id", "") or "")
    if not stack_id:
        raise ResourceManagerBackupError(
            f"Resource Manager create_stack for {stack_name} did not return a stack OCID"
        )

    create_state = stack_lifecycle_state(stack)
    work_request_id = response_header(response, "opc-work-request-id")
    logger.info(
        "Resource Manager backup stack creation accepted: name=%s id=%s lifecycle_state=%s work_request=%s",
        stack_name,
        stack_id,
        create_state or "unknown",
        work_request_id or "-",
    )

    final_state = create_state
    if create_state not in READY_STATES:
        final_state = wait_for_stack_active(
            client=client,
            stack_id=stack_id,
            stack_name=stack_name,
            options=options,
            logger=logger,
            call_oci_func=call_oci_func,
        ) or create_state

    return ResourceManagerBackupResult(
        stack_id=stack_id,
        stack_name=stack_name,
        stack_region=options.stack_region,
        stack_compartment_id=options.stack_compartment_id,
        lifecycle_state=final_state,
        opc_work_request_id=work_request_id,
    )
