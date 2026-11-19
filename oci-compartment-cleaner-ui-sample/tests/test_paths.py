# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from pathlib import Path

from cleaner_ui import paths


def test_creates_meaningful_run_directory(tmp_path: Path, monkeypatch: object) -> None:
    monkeypatch.setattr(paths, "application_data_dir", lambda: tmp_path)

    directory = paths.create_run_directory(
        tenancy_name="My Tenancy",
        compartment_name="Demo / Lab",
        compartment_id="ocid1.compartment.oc1..wdmemntd54qzueqa",
        region="eu-frankfurt-1",
    )

    assert directory.is_dir()
    assert "My-Tenancy" in directory.name
    assert "Demo-Lab" in directory.name
    assert "eu-frankfurt-1" in directory.name
    assert directory.name.endswith("wdmemntd54qzueqa")
