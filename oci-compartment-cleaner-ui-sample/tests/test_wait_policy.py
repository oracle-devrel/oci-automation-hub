# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

import sys
from logging import getLogger
from pathlib import Path
from types import SimpleNamespace

import pytest

CLEANER_ROOT = Path(__file__).resolve().parents[1] / "oci-comp-cleaner"
sys.path.insert(0, str(CLEANER_ROOT))

from oci_compartment_cleaner import manifest_waiters  # noqa: E402
from oci_compartment_cleaner.models import HandlerSpec, PlanEntry  # noqa: E402
from oci_compartment_cleaner.registry import load_registry  # noqa: E402


def _entry(wait_for_delete: bool):
    resource = SimpleNamespace(
        resource_type="TestResource", display_name="test", identifier="test-id"
    )
    handler = HandlerSpec(
        key="test",
        normalized_type="test",
        resource_types=("TestResource",),
        aliases=(),
        priority=1,
        action="dynamic_delete",
        wait_for_delete=wait_for_delete,
    )
    return PlanEntry(sequence=1, resource=resource, handler=handler)


def test_manifest_false_skips_all_generic_post_delete_waits(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    context = SimpleNamespace(logger=getLogger("test"))
    monkeypatch.setattr(
        manifest_waiters,
        "_wait_with_manifest",
        lambda *_args: pytest.fail("manifest wait should not run when disabled"),
    )

    assert manifest_waiters.wait_for_handler_delete_completion(_entry(False), context)


def test_manifest_true_uses_manifest_waiter(monkeypatch: pytest.MonkeyPatch) -> None:
    context = SimpleNamespace(logger=getLogger("test"))
    monkeypatch.setattr(manifest_waiters, "_wait_with_manifest", lambda *_args: False)

    assert not manifest_waiters.wait_for_handler_delete_completion(_entry(True), context)


def test_all_previously_generic_waited_resource_types_are_explicit_in_manifest() -> None:
    legacy_waited_types = {
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
        "vcn",
        "volume",
        "volume_backup",
        "volume_group",
        "volume_group_backup",
    }
    handlers = {handler.normalized_type: handler for handler in load_registry().handlers}

    assert all(handlers[resource_type].wait_for_delete for resource_type in legacy_waited_types)
