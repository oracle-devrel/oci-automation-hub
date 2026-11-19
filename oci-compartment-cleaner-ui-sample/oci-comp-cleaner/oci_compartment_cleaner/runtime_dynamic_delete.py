# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
"""Dynamic OCI SDK delete/terminate/detach method discovery."""

from __future__ import annotations

from .runtime_core import *

def required_single_id_parameter(method: Any) -> str | None:
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


class DynamicOciDeleter:
    def __init__(self, config: dict[str, Any], signer: Any, logger: logging.Logger) -> None:
        self.config = config
        self.signer = signer
        self.logger = logger
        self.registry: dict[str, list[tuple[type[Any], str]]] = defaultdict(list)
        self.client_cache: dict[type[Any], Any] = {}
        self._discover_delete_methods()

    def _discover_delete_methods(self) -> None:
        discovered_clients = 0
        discovered_methods = 0
        for module_info in pkgutil.walk_packages(oci.__path__, oci.__name__ + "."):
            if not module_info.name.endswith("_client"):
                continue
            try:
                module = importlib.import_module(module_info.name)
            except Exception as exc:
                self.logger.debug("Skipping OCI client module %s: %s", module_info.name, exc)
                continue
            for _, client_class in inspect.getmembers(module, inspect.isclass):
                if client_class.__module__ != module.__name__:
                    continue
                if not client_class.__name__.endswith("Client"):
                    continue
                discovered_clients += 1
                for method_name, method in inspect.getmembers(client_class, inspect.isfunction):
                    if not method_name.startswith(DELETE_VERBS):
                        continue
                    parameter_name = required_single_id_parameter(method)
                    if parameter_name is None:
                        continue
                    self.registry[method_name].append((client_class, parameter_name))
                    discovered_methods += 1
        self.logger.info(
            "Discovered %s one-id delete/terminate/detach methods across %s OCI SDK clients",
            discovered_methods,
            discovered_clients,
        )

    def _client(self, client_class: type[Any]) -> Any:
        if client_class not in self.client_cache:
            self.client_cache[client_class] = make_client(client_class, self.config, self.signer)
        return self.client_cache[client_class]

    def method_candidates(self, resource: ResourceRecord) -> list[str]:
        type_names: list[str] = []
        for type_name in (
            raw_to_snake(resource.resource_type),
            resource.resource_type_normalized,
            ocid_resource_part(resource.identifier, apply_alias=False),
            ocid_resource_part(resource.identifier, apply_alias=True),
        ):
            if type_name and type_name not in type_names:
                type_names.append(type_name)

        candidates: list[str] = []
        for type_name in type_names:
            candidates.extend(METHOD_OVERRIDES.get(type_name, []))
            candidates.extend(f"{verb}_{type_name}" for verb in DELETE_VERBS)

        unique: list[str] = []
        seen: set[str] = set()
        for candidate in candidates:
            if candidate not in seen:
                unique.append(candidate)
                seen.add(candidate)
        return unique

    def _target_sort_key(
        self, resource: ResourceRecord, client_class: type[Any], method_name: str
    ) -> tuple[int, str, str]:
        client_text = raw_to_snake(f"{client_class.__module__}_{client_class.__name__}")
        client_text_compact = client_text.replace("_", "")
        raw_type = raw_to_snake(resource.resource_type)
        raw_ocid_type = ocid_resource_part(resource.identifier, apply_alias=False)
        tokens = [
            token
            for source in (raw_type, raw_ocid_type)
            for token in source.split("_")
            if len(token) > 2
        ]
        score = 0
        for preferred_prefix in PREFERRED_CLIENT_MODULE_PREFIXES.get(
            resource.resource_type_normalized, ()
        ):
            if client_class.__module__.startswith(preferred_prefix):
                score += 100
        for token in tokens:
            if token in client_text or token in client_text_compact:
                score += 10
        if method_name in client_text:
            score += 3
        return (-score, client_class.__module__, client_class.__name__)

    def _preferred_targets(
        self,
        resource: ResourceRecord,
        method_name: str,
        targets: list[tuple[type[Any], str]],
    ) -> list[tuple[type[Any], str]]:
        preferred_prefixes = PREFERRED_CLIENT_MODULE_PREFIXES.get(resource.resource_type_normalized, ())
        if not preferred_prefixes:
            return targets
        preferred_targets = [
            target
            for target in targets
            if target[0].__module__.startswith(preferred_prefixes)
        ]
        if not preferred_targets:
            self.logger.debug(
                "For %s %s, skipping %s targets for %s because none match preferred client prefixes %s",
                resource.resource_type,
                resource.identifier,
                len(targets),
                method_name,
                ", ".join(preferred_prefixes),
            )
            return []
        skipped_count = len(targets) - len(preferred_targets)
        if skipped_count:
            self.logger.debug(
                "For %s %s, restricting %s targets for %s to preferred client prefixes %s",
                resource.resource_type,
                resource.identifier,
                method_name,
                skipped_count,
                ", ".join(preferred_prefixes),
            )
        return preferred_targets

    def delete(self, resource: ResourceRecord) -> bool:
        candidates = self.method_candidates(resource)
        errors: list[str] = []
        for method_name in candidates:
            targets = sorted(
                self.registry.get(method_name, []),
                key=lambda target: self._target_sort_key(resource, target[0], method_name),
            )
            targets = self._preferred_targets(resource, method_name, targets)
            if not targets:
                continue
            for client_class, parameter_name in targets:
                try:
                    client = self._client(client_class)
                    method = getattr(client, method_name)
                    kwargs = {parameter_name: resource.identifier}
                    if method_name == "terminate_instance":
                        kwargs["preserve_boot_volume"] = False
                        kwargs["preserve_data_volumes_created_at_launch"] = False
                        self.logger.info(
                            "Terminating instance with preserve_boot_volume=False and preserve_data_volumes_created_at_launch=False"
                        )
                    self.logger.info(
                        "Calling %s.%s for %s %s (%s)",
                        client_class.__name__,
                        method_name,
                        resource.resource_type,
                        resource.display_name,
                        resource.identifier,
                    )
                    call_oci(
                        self.logger,
                        f"{client_class.__name__}.{method_name} {resource.identifier}",
                        method,
                        **kwargs,
                    )
                    self.logger.info(
                        "Delete API accepted for %s %s (%s)",
                        resource.resource_type,
                        resource.display_name,
                        resource.identifier,
                    )
                    return True
                except Exception as exc:
                    message = f"{client_class.__name__}.{method_name}: {exc}"
                    errors.append(message)
                    self.logger.error(
                        "Delete API failed for %s %s (%s) using %s.%s: %s",
                        resource.resource_type,
                        resource.display_name,
                        resource.identifier,
                        client_class.__name__,
                        method_name,
                        exc,
                    )
        if not errors:
            self.logger.error(
                "No dynamic one-id delete/terminate/detach API was found for %s %s (%s); tried method names: %s",
                resource.resource_type,
                resource.display_name,
                resource.identifier,
                ", ".join(candidates),
            )
        return False
