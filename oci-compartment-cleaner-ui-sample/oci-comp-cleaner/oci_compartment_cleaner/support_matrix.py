# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
from __future__ import annotations

from .registry import ResourceRegistry, load_registry


def support_matrix_markdown(registry: ResourceRegistry | None = None) -> str:
    active_registry = registry or load_registry()
    lines = [
        "| Resource type | Priority | Handler | API/action | Notes |",
        "| --- | ---: | --- | --- | --- |",
    ]
    for handler in sorted(
        active_registry.handlers,
        key=lambda item: (item.is_skip, item.priority, item.normalized_type, item.key),
    ):
        resource_types = ", ".join(handler.resource_types)
        action = handler.delete_description
        if handler.is_skip:
            action = f"skip: {handler.skip_reason}"
        lines.append(
            "| "
            + " | ".join(
                [
                    resource_types.replace("|", "\\|"),
                    str(handler.priority),
                    handler.key,
                    action.replace("|", "\\|"),
                    handler.notes.replace("|", "\\|"),
                ]
            )
            + " |"
        )
    return "\n".join(lines)


def main() -> int:
    print(support_matrix_markdown())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
