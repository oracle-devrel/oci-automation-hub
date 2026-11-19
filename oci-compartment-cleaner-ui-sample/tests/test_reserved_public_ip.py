# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

import sys
from pathlib import Path

CLEANER_ROOT = Path(__file__).resolve().parents[1] / "oci-comp-cleaner"
sys.path.insert(0, str(CLEANER_ROOT))

from oci_compartment_cleaner.registry import load_registry  # noqa: E402
from oci_compartment_cleaner.runtime_core import ResourceRecord  # noqa: E402
from oci_compartment_cleaner.runtime_planning_rules import skip_reason_for_resource  # noqa: E402


def _public_ip(lifetime: str) -> ResourceRecord:
    return ResourceRecord(
        identifier="ocid1.publicip.oc1..example",
        resource_type="PublicIp",
        resource_type_normalized="public_ip",
        display_name="198.51.100.5",
        compartment_id="ocid1.compartment.oc1..example",
        lifecycle_state="AVAILABLE",
        time_created="",
        availability_domain="",
        raw={"lifetime": lifetime},
        priority=190,
    )


def test_only_reserved_public_ips_are_plannable() -> None:
    assert skip_reason_for_resource(_public_ip("RESERVED")) is None
    assert "only reserved" in (skip_reason_for_resource(_public_ip("EPHEMERAL")) or "")
    assert "only reserved" in (skip_reason_for_resource(_public_ip("")) or "")


def test_public_ip_manifest_uses_existing_dynamic_delete_path() -> None:
    handler = load_registry().match_type("PublicIp")

    assert handler.key == "reserved_public_ip"
    assert handler.action == "dynamic_delete"
    assert handler.method == "delete_public_ip"
    assert handler.priority == 190
    assert handler.wait_method == "get_public_ip"
