# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from pathlib import Path

from cleaner_ui.config_profiles import list_profiles


def test_lists_default_and_named_oci_profiles(tmp_path: Path) -> None:
    config = tmp_path / "config"
    config.write_text(
        "[DEFAULT]\ntenancy=ocid1.tenancy.oc1..example\n\n[LAB]\ntenancy=ocid1.tenancy.oc1..lab\n",
        encoding="utf-8",
    )

    assert list_profiles(config) == ["DEFAULT", "LAB"]
