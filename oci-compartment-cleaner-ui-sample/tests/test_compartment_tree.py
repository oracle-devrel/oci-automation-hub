# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from cleaner_ui.compartment_tree import build_compartment_tree, filter_tree, visible_path
from cleaner_ui.models import Compartment

TENANCY = "ocid1.tenancy.oc1..example"


def test_builds_parent_child_hierarchy_and_visible_path() -> None:
    parent = Compartment("parent", "Parent", TENANCY)
    child = Compartment("child", "Child", "parent")
    tree = build_compartment_tree([child, parent], TENANCY)

    assert tree.children[0].compartment == parent
    assert tree.children[0].children[0].compartment == child
    assert visible_path(tree, "child") == ("Tenancy root (not selectable)", "Parent", "Child")


def test_groups_compartment_with_unavailable_parent() -> None:
    orphan = Compartment("orphan", "Orphan", "inaccessible-parent")
    tree = build_compartment_tree([orphan], TENANCY)

    assert tree.children[0].label == "Unavailable parent"
    assert tree.children[0].children[0].compartment == orphan


def test_search_retains_ancestors_of_matching_compartment() -> None:
    parent = Compartment("parent", "Parent", TENANCY)
    child = Compartment("child", "Production", "parent")
    filtered = filter_tree(build_compartment_tree([parent, child], TENANCY), "production")

    assert filtered is not None
    assert filtered.children[0].compartment == parent
    assert filtered.children[0].children[0].compartment == child
