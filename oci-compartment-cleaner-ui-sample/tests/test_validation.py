# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from pathlib import Path

import pytest

from cleaner_ui.validation import (
    ValidationError,
    require_compartment_ocid,
    require_existing_file,
    require_region,
)


def test_validates_compartment_ocid() -> None:
    compartment_ocid = "ocid1.compartment.oc1..example"
    assert require_compartment_ocid(compartment_ocid) == compartment_ocid


@pytest.mark.parametrize("value", ["", "ocid1.instance.oc1..example", "ocid1.compartment. bad"])
def test_rejects_invalid_compartment_ocid(value: str) -> None:
    with pytest.raises(ValidationError):
        require_compartment_ocid(value)


def test_validates_region() -> None:
    assert require_region("eu-frankfurt-1") == "eu-frankfurt-1"


def test_requires_existing_file(tmp_path: Path) -> None:
    existing = tmp_path / "config"
    existing.write_text("[DEFAULT]\n", encoding="utf-8")
    assert require_existing_file(existing, "config") == existing.resolve()
