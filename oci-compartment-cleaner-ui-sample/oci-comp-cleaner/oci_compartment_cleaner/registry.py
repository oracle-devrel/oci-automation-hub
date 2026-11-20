# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from . import runtime
from .models import HandlerSpec


PACKAGE_DIR = Path(__file__).resolve().parent
DEFAULT_RESOURCE_SUPPORT_PATH = PACKAGE_DIR / "resource_support.json"


DEFAULT_DYNAMIC_HANDLER = HandlerSpec(
    key="default_dynamic",
    normalized_type="*",
    resource_types=("*",),
    aliases=(),
    priority=runtime.DEFAULT_DELETE_PRIORITY,
    action="dynamic_delete",
    notes=(
        "Fallback handler. It asks the OCI SDK dynamic deleter to find a one-id "
        "delete, terminate, or detach method."
    ),
)


class ResourceRegistry:
    def __init__(self, handlers: list[HandlerSpec]) -> None:
        self.handlers = tuple(handlers)
        self.by_key = {handler.key: handler for handler in handlers}
        self.by_normalized_type: dict[str, HandlerSpec] = {}
        self.alias_to_normalized_type: dict[str, str] = {}
        for handler in handlers:
            if handler.normalized_type != "*":
                self.by_normalized_type[handler.normalized_type] = handler
            for value in (
                handler.normalized_type,
                *handler.aliases,
                *handler.resource_types,
            ):
                normalized = runtime.raw_to_snake(value)
                if normalized and normalized != "*":
                    self.alias_to_normalized_type[normalized] = handler.normalized_type

    def normalize_type(self, resource_type: str, identifier: str = "") -> str:
        candidates = [
            runtime.raw_to_snake(resource_type),
            runtime.to_snake(resource_type),
            runtime.ocid_resource_part(identifier, apply_alias=False),
            runtime.ocid_resource_part(identifier, apply_alias=True),
        ]
        for candidate in candidates:
            if candidate in self.alias_to_normalized_type:
                return self.alias_to_normalized_type[candidate]
        return candidates[1] or candidates[0] or "unknown"

    def match_type(self, resource_type: str, identifier: str = "") -> HandlerSpec:
        normalized_type = self.normalize_type(resource_type, identifier)
        return self.by_normalized_type.get(normalized_type, DEFAULT_DYNAMIC_HANDLER)

    def match_resource(self, resource: Any) -> HandlerSpec:
        normalized_type = getattr(resource, "resource_type_normalized", "") or self.normalize_type(
            getattr(resource, "resource_type", ""),
            getattr(resource, "identifier", ""),
        )
        normalized_type = self.alias_to_normalized_type.get(normalized_type, normalized_type)
        return self.by_normalized_type.get(normalized_type, DEFAULT_DYNAMIC_HANDLER)

    def skip_handlers(self) -> list[HandlerSpec]:
        return [handler for handler in self.handlers if handler.is_skip]

    def delete_handlers(self) -> list[HandlerSpec]:
        return [handler for handler in self.handlers if not handler.is_skip]


def _tuple_value(data: dict[str, Any], key: str) -> tuple[str, ...]:
    values = data.get(key) or []
    return tuple(str(value) for value in values)


def _handler_from_dict(data: dict[str, Any]) -> HandlerSpec:
    return HandlerSpec(
        key=str(data["key"]),
        normalized_type=str(data["normalized_type"]),
        resource_types=_tuple_value(data, "resource_types"),
        aliases=_tuple_value(data, "aliases"),
        priority=int(data.get("priority", runtime.DEFAULT_DELETE_PRIORITY)),
        action=str(data.get("action", "dynamic_delete")),
        service=str(data.get("service", "")),
        client_module=str(data.get("client_module", "")),
        client_class=str(data.get("client_class", "")),
        method=str(data.get("method", "")),
        preferred_client_prefixes=_tuple_value(data, "preferred_client_prefixes"),
        wait_for_delete=bool(data.get("wait_for_delete", False)),
        wait_client_module=str(data.get("wait_client_module", "")),
        wait_client_class=str(data.get("wait_client_class", "")),
        wait_method=str(data.get("wait_method", "")),
        wait_id_parameter=str(data.get("wait_id_parameter", "")),
        delete_complete_states=_tuple_value(data, "delete_complete_states"),
        pre_delete=_tuple_value(data, "pre_delete"),
        owns_child_types=_tuple_value(data, "owns_child_types"),
        skip_reason=str(data.get("skip_reason", "")),
        notes=str(data.get("notes", "")),
    )


def load_registry(path: Path | None = None) -> ResourceRegistry:
    """Load the JSON support manifest."""
    manifest_path = path or DEFAULT_RESOURCE_SUPPORT_PATH
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    handlers = [_handler_from_dict(item) for item in payload["handlers"]]
    return ResourceRegistry(handlers)
