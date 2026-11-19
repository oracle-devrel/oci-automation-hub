# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

import sys
from logging import getLogger
from pathlib import Path
from types import SimpleNamespace

import pytest

CLEANER_ROOT = Path(__file__).resolve().parents[1] / "oci-comp-cleaner"
sys.path.insert(0, str(CLEANER_ROOT))

from oci_compartment_cleaner.context import CleanupContext  # noqa: E402
from oci_compartment_cleaner.handlers import logging as logging_handler  # noqa: E402
from oci_compartment_cleaner.registry import load_registry  # noqa: E402
from oci_compartment_cleaner.runtime_core import ResourceRecord  # noqa: E402
from oci_compartment_cleaner.runtime_discovery import augment_with_logging_resources  # noqa: E402


def _log_resource(log_group_id: str | None = "group-id") -> ResourceRecord:
    raw = {} if log_group_id is None else {"log_group_id": log_group_id}
    return ResourceRecord(
        identifier="log-id",
        resource_type="Log",
        resource_type_normalized="log",
        display_name="test-log",
        compartment_id="compartment-id",
        lifecycle_state="ACTIVE",
        time_created="",
        availability_domain="",
        raw=raw,
        priority=110,
    )


def test_log_handler_passes_parent_group_and_log_id(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple[str, str]] = []

    class Client:
        def delete_log(self, *, log_group_id: str, log_id: str) -> None:
            calls.append((log_group_id, log_id))

    context = CleanupContext({}, None, getLogger("test"), None, 0, 0, 1)
    monkeypatch.setattr(context, "client", lambda _client_class: Client())
    monkeypatch.setattr(
        logging_handler.runtime,
        "call_oci",
        lambda _logger, _description, function, **kwargs: function(**kwargs),
    )

    assert logging_handler.delete_log(_log_resource(), context)
    assert calls == [("group-id", "log-id")]


def test_log_handler_refuses_to_delete_without_parent_group() -> None:
    context = CleanupContext({}, None, getLogger("test"), None, 0, 0, 1)

    assert not logging_handler.delete_log(_log_resource(None), context)


def test_logging_enrichment_records_parent_group_for_logs(monkeypatch: pytest.MonkeyPatch) -> None:
    group = SimpleNamespace(
        id="group-id",
        display_name="test-group",
        lifecycle_state="ACTIVE",
        time_created="",
    )
    log = SimpleNamespace(
        id="log-id",
        log_group_id="group-id",
        display_name="test-log",
        lifecycle_state="ACTIVE",
        time_created="",
    )

    class Client:
        def list_log_groups(self, *, compartment_id: str) -> list[SimpleNamespace]:
            assert compartment_id == "compartment-id"
            return [group]

        def list_logs(self, *, log_group_id: str) -> list[SimpleNamespace]:
            assert log_group_id == "group-id"
            return [log]

    import oci_compartment_cleaner.runtime_discovery as discovery

    monkeypatch.setattr(discovery, "make_client", lambda *_args: Client())
    monkeypatch.setattr(
        discovery,
        "paged_sdk_list",
        lambda method, _logger, **kwargs: method(**kwargs),
    )
    records = augment_with_logging_resources([], "compartment-id", {}, None, getLogger("test"))

    log_record = next(item for item in records if item.resource_type == "Log")
    assert log_record.raw["log_group_id"] == "group-id"


def test_logging_manifest_orders_logs_before_groups() -> None:
    registry = load_registry()
    log_handler = registry.match_type("Log")
    group_handler = registry.match_type("LogGroup")

    assert log_handler.action == "logging_log_delete"
    assert log_handler.priority < group_handler.priority
    assert group_handler.method == "delete_log_group"
