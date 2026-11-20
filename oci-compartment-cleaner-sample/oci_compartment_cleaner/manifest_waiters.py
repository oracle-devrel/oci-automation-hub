# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

import importlib
import inspect
import pkgutil
import time
from functools import lru_cache
from typing import Any

from . import runtime
from .context import CleanupContext
from .models import PlanEntry, HandlerSpec


def infer_wait_method(delete_method: str) -> str:
    for prefix in ("delete_", "terminate_", "detach_"):
        if delete_method.startswith(prefix):
            return "get_" + delete_method[len(prefix) :]
    return ""


def _required_single_id_parameter(method: Any) -> str | None:
    try:
        signature = inspect.signature(method)
    except (TypeError, ValueError):
        return None
    required: list[str] = []
    for parameter in signature.parameters.values():
        if parameter.name == "self":
            continue
        if parameter.kind in (parameter.VAR_KEYWORD, parameter.VAR_POSITIONAL):
            continue
        if parameter.default is inspect.Parameter.empty:
            required.append(parameter.name)
    if len(required) != 1:
        return None
    name = required[0]
    if name.endswith("_id") or name.endswith("_name_or_id") or name in {"id", "resource_id", "name_or_id"}:
        return name
    return None


@lru_cache(maxsize=1)
def _discover_get_method_targets() -> dict[str, tuple[tuple[type[Any], str], ...]]:
    registry: dict[str, list[tuple[type[Any], str]]] = {}
    if runtime.oci is None:
        return {}
    for module_info in pkgutil.walk_packages(runtime.oci.__path__, runtime.oci.__name__ + "."):
        if not module_info.name.endswith("_client"):
            continue
        try:
            module = importlib.import_module(module_info.name)
        except Exception:
            continue
        for _, client_class in inspect.getmembers(module, inspect.isclass):
            if client_class.__module__ != module.__name__:
                continue
            if not client_class.__name__.endswith("Client"):
                continue
            for method_name, method in inspect.getmembers(client_class, inspect.isfunction):
                if not method_name.startswith("get_"):
                    continue
                parameter_name = _required_single_id_parameter(method)
                if parameter_name is None:
                    continue
                registry.setdefault(method_name, []).append((client_class, parameter_name))
    return {method_name: tuple(targets) for method_name, targets in registry.items()}


def _handler_wait_method(handler: HandlerSpec) -> str:
    return handler.wait_method or infer_wait_method(handler.method)


def _target_score(handler: HandlerSpec, client_class: type[Any]) -> tuple[int, str, str]:
    score = 0
    expected_class = handler.wait_client_class or handler.client_class
    if expected_class and client_class.__name__ == expected_class:
        score += 1000
    expected_module = handler.wait_client_module or handler.client_module
    if expected_module and client_class.__module__ == expected_module:
        score += 500
    for preferred_prefix in handler.preferred_client_prefixes:
        if client_class.__module__.startswith(preferred_prefix):
            score += 100
    return (-score, client_class.__module__, client_class.__name__)


def _manifest_wait_targets(handler: HandlerSpec) -> list[tuple[type[Any], str]]:
    wait_method = _handler_wait_method(handler)
    if not wait_method:
        return []

    targets = list(_discover_get_method_targets().get(wait_method, ()))
    if not targets:
        return []

    expected_class = handler.wait_client_class or handler.client_class
    if expected_class:
        exact_class_targets = [
            target for target in targets if target[0].__name__ == expected_class
        ]
        if exact_class_targets:
            targets = exact_class_targets

    expected_module = handler.wait_client_module or handler.client_module
    if expected_module:
        exact_module_targets = [
            target for target in targets if target[0].__module__ == expected_module
        ]
        if exact_module_targets:
            targets = exact_module_targets

    if handler.preferred_client_prefixes:
        preferred_targets = [
            target
            for target in targets
            if target[0].__module__.startswith(handler.preferred_client_prefixes)
        ]
        if preferred_targets:
            targets = preferred_targets

    if handler.wait_id_parameter:
        targets = [
            (client_class, handler.wait_id_parameter)
            for client_class, _ in targets
        ]

    return sorted(targets, key=lambda target: _target_score(handler, target[0]))


def _manifest_complete_states(handler: HandlerSpec) -> set[str]:
    states = handler.delete_complete_states or tuple(runtime.DELETE_COMPLETE_STATES)
    return {state.upper() for state in states}


def _wait_with_manifest(entry: PlanEntry, context: CleanupContext) -> bool | None:
    handler = entry.handler
    resource = entry.resource
    if not handler.wait_for_delete:
        return None
    if context.delete_wait_timeout_seconds <= 0:
        context.logger.info("Delete wait disabled for %s %s", resource.resource_type, resource.display_name)
        return True

    wait_method = _handler_wait_method(handler)
    targets = _manifest_wait_targets(handler)
    if not wait_method or not targets:
        context.logger.info(
            "No manifest wait target found for %s %s (%s); falling back to built-in waiter table",
            resource.resource_type,
            resource.display_name,
            resource.identifier,
        )
        return None

    client_class, id_parameter_name = targets[0]
    client = context.client(client_class)
    get_method = getattr(client, wait_method)
    interval = max(1, context.delete_wait_interval_seconds)
    deadline = time.monotonic() + context.delete_wait_timeout_seconds
    complete_states = _manifest_complete_states(handler)
    last_state = "UNKNOWN"

    context.logger.info(
        "Waiting up to %s seconds for %s %s (%s) deletion using %s.%s",
        context.delete_wait_timeout_seconds,
        resource.resource_type,
        resource.display_name,
        resource.identifier,
        client_class.__name__,
        wait_method,
    )
    while True:
        try:
            response = runtime.call_oci(
                context.logger,
                f"{client_class.__name__}.{wait_method} {resource.identifier}",
                get_method,
                **{id_parameter_name: resource.identifier},
            )
            data = response.data
            raw_data = runtime.sdk_to_dict(data)
            last_state = runtime.first_present(
                getattr(data, "lifecycle_state", None),
                raw_data.get("lifecycle_state"),
                raw_data.get("lifecycleState"),
                default="UNKNOWN",
            ).upper()
            if last_state in complete_states:
                context.logger.info(
                    "%s %s reached lifecycle state %s",
                    resource.resource_type,
                    resource.display_name,
                    last_state,
                )
                return True
        except Exception as exc:
            if runtime.is_not_found_error(exc):
                context.logger.info(
                    "%s %s is no longer returned by %s.%s; delete is complete",
                    resource.resource_type,
                    resource.display_name,
                    client_class.__name__,
                    wait_method,
                )
                return True
            context.logger.error(
                "Failed while waiting for %s %s deletion completion using %s.%s: %s",
                resource.resource_type,
                resource.display_name,
                client_class.__name__,
                wait_method,
                exc,
            )
            return False

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            context.logger.error(
                "Timed out waiting for %s %s deletion completion using %s.%s; last lifecycle state was %s",
                resource.resource_type,
                resource.display_name,
                client_class.__name__,
                wait_method,
                last_state,
            )
            return False
        sleep_seconds = min(interval, max(1, int(remaining)))
        context.logger.info(
            "%s %s deletion still in lifecycle state %s; sleeping %s seconds",
            resource.resource_type,
            resource.display_name,
            last_state,
            sleep_seconds,
        )
        time.sleep(sleep_seconds)


def wait_for_handler_delete_completion(entry: PlanEntry, context: CleanupContext) -> bool:
    manifest_result = _wait_with_manifest(entry, context)
    if manifest_result is not None:
        return manifest_result
    return runtime.wait_for_delete_completion(
        entry.resource,
        context.config,
        context.signer,
        timeout_seconds=context.delete_wait_timeout_seconds,
        interval_seconds=context.delete_wait_interval_seconds,
        logger=context.logger,
    )
