# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Build and filter the visible OCI compartment hierarchy."""

from __future__ import annotations

from dataclasses import dataclass, replace

from .models import Compartment


@dataclass(frozen=True)
class CompartmentTreeNode:
    """A selectable compartment node or a non-selectable grouping node."""

    label: str
    compartment: Compartment | None
    children: tuple[CompartmentTreeNode, ...] = ()

    @property
    def is_selectable(self) -> bool:
        return self.compartment is not None


def build_compartment_tree(compartments: list[Compartment], tenancy_id: str) -> CompartmentTreeNode:
    """Return a tenancy-rooted tree from accessible OCI compartment records."""
    by_id = {compartment.id: compartment for compartment in compartments}
    children_by_parent: dict[str, list[str]] = {}
    for compartment in compartments:
        if compartment.parent_id in by_id:
            children_by_parent.setdefault(compartment.parent_id, []).append(compartment.id)

    for child_ids in children_by_parent.values():
        child_ids.sort(key=lambda item: _sort_key(by_id[item]))

    def make_node(compartment_id: str, ancestors: frozenset[str]) -> CompartmentTreeNode:
        compartment = by_id[compartment_id]
        children = tuple(
            make_node(child_id, ancestors | {compartment_id})
            for child_id in children_by_parent.get(compartment_id, [])
            if child_id not in ancestors
        )
        return CompartmentTreeNode(
            label=compartment.name,
            compartment=compartment,
            children=children,
        )

    root_ids = sorted(
        [item.id for item in compartments if item.parent_id == tenancy_id],
        key=lambda item: _sort_key(by_id[item]),
    )
    rendered_ids = _descendant_ids(root_ids, children_by_parent)
    orphan_root_ids = sorted(
        [
            item.id
            for item in compartments
            if item.parent_id != tenancy_id and item.parent_id not in by_id
        ],
        key=lambda item: _sort_key(by_id[item]),
    )
    orphan_rendered_ids = _descendant_ids(orphan_root_ids, children_by_parent)
    remaining_ids = sorted(
        [
            item.id
            for item in compartments
            if item.id not in rendered_ids and item.id not in orphan_rendered_ids
        ],
        key=lambda item: _sort_key(by_id[item]),
    )
    orphan_ids = orphan_root_ids + remaining_ids

    root_children = [make_node(compartment_id, frozenset()) for compartment_id in root_ids]
    if orphan_ids:
        root_children.append(
            CompartmentTreeNode(
                label="Unavailable parent",
                compartment=None,
                children=tuple(
                    make_node(compartment_id, frozenset()) for compartment_id in orphan_ids
                ),
            )
        )
    return CompartmentTreeNode(
        label="Tenancy root (not selectable)",
        compartment=None,
        children=tuple(root_children),
    )


def filter_tree(node: CompartmentTreeNode, query: str) -> CompartmentTreeNode | None:
    """Filter a tree while preserving ancestors of matching compartments."""
    normalized_query = query.strip().casefold()
    if not normalized_query:
        return node
    if _matches(node, normalized_query):
        return node
    filtered_children = tuple(
        filtered for child in node.children if (filtered := filter_tree(child, normalized_query))
    )
    return replace(node, children=filtered_children) if filtered_children else None


def visible_path(node: CompartmentTreeNode, compartment_id: str) -> tuple[str, ...] | None:
    """Return the displayed hierarchy path for one selectable compartment."""
    if node.compartment and node.compartment.id == compartment_id:
        return (node.label,)
    for child in node.children:
        child_path = visible_path(child, compartment_id)
        if child_path:
            return (node.label, *child_path)
    return None


def _descendant_ids(root_ids: list[str], children_by_parent: dict[str, list[str]]) -> set[str]:
    seen: set[str] = set()
    pending = list(root_ids)
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        pending.extend(children_by_parent.get(current, []))
    return seen


def _matches(node: CompartmentTreeNode, query: str) -> bool:
    if node.compartment is None:
        return query in node.label.casefold()
    return query in node.label.casefold() or query in node.compartment.id.casefold()


def _sort_key(compartment: Compartment) -> tuple[str, str]:
    return compartment.name.casefold(), compartment.id
