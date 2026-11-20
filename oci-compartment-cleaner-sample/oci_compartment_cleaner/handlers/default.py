# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

from typing import Any

from ..context import CleanupContext
from .. import runtime
from ..models import HandlerSpec
from . import database, file_storage, mysql, network


PRE_DELETE_HOOKS = {
    "remove_route_rules": lambda resource, context: (
        network.remove_route_rules_referencing_resource(resource, context) or True
    ),
    "prepare_autonomous_database": database.prepare_autonomous_database_for_delete,
    "prepare_mysql_db_system": mysql.prepare_mysql_db_system_for_delete,
    "disassociate_dr_protection_group": database.disassociate_dr_protection_group_if_needed,
    "prepare_file_system": file_storage.prepare_file_system_for_delete,
}


def run_pre_delete_hooks(resource: Any, context: CleanupContext, hook_names: tuple[str, ...]) -> bool:
    for hook_name in hook_names:
        hook = PRE_DELETE_HOOKS.get(hook_name)
        if hook is None:
            context.logger.error(
                "No pre-delete hook named %s for %s %s (%s)",
                hook_name,
                resource.resource_type,
                resource.display_name,
                resource.identifier,
            )
            return False
        if not hook(resource, context):
            return False
    return True


def _manifest_preferred_targets(
    handler: HandlerSpec,
    targets: list[tuple[type[Any], str]],
) -> list[tuple[type[Any], str]]:
    if not handler.preferred_client_prefixes:
        return targets
    preferred = [
        target
        for target in targets
        if target[0].__module__.startswith(handler.preferred_client_prefixes)
    ]
    return preferred or targets


def _try_manifest_method(resource: Any, context: CleanupContext, handler: HandlerSpec) -> bool | None:
    if not handler.method:
        return None

    deleter = context.dynamic_deleter
    if handler.method in deleter.method_candidates(resource):
        return None

    targets = sorted(
        deleter.registry.get(handler.method, []),
        key=lambda target: deleter._target_sort_key(resource, target[0], handler.method),
    )
    targets = _manifest_preferred_targets(handler, targets)
    if not targets:
        context.logger.debug(
            "Manifest method %s for %s %s (%s) was not found in discovered one-id OCI SDK methods",
            handler.method,
            resource.resource_type,
            resource.display_name,
            resource.identifier,
        )
        return None

    for client_class, parameter_name in targets:
        try:
            client = deleter._client(client_class)
            method = getattr(client, handler.method)
            kwargs = {parameter_name: resource.identifier}
            if handler.method == "terminate_instance":
                kwargs["preserve_boot_volume"] = False
                kwargs["preserve_data_volumes_created_at_launch"] = False
                context.logger.info(
                    "Terminating instance with preserve_boot_volume=False and preserve_data_volumes_created_at_launch=False"
                )
            context.logger.info(
                "Calling %s.%s for %s %s (%s) from resource manifest",
                client_class.__name__,
                handler.method,
                resource.resource_type,
                resource.display_name,
                resource.identifier,
            )
            runtime.call_oci(
                context.logger,
                f"{client_class.__name__}.{handler.method} {resource.identifier}",
                method,
                **kwargs,
            )
            context.logger.info(
                "Delete API accepted for %s %s (%s)",
                resource.resource_type,
                resource.display_name,
                resource.identifier,
            )
            return True
        except Exception as exc:
            context.logger.error(
                "Delete API failed for %s %s (%s) using manifest method %s.%s: %s",
                resource.resource_type,
                resource.display_name,
                resource.identifier,
                client_class.__name__,
                handler.method,
                exc,
            )
    return False


def delete_dynamic(resource: Any, context: CleanupContext, handler: HandlerSpec) -> bool:
    manifest_result = _try_manifest_method(resource, context, handler)
    if manifest_result is not None:
        if manifest_result:
            return True
        context.logger.info(
            "Manifest method %s did not delete %s %s (%s); falling back to legacy dynamic candidates",
            handler.method,
            resource.resource_type,
            resource.display_name,
            resource.identifier,
        )
    return context.dynamic_deleter.delete(resource)
