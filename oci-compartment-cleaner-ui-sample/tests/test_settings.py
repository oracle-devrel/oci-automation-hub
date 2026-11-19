# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from pathlib import Path

from cleaner_ui.settings import APP_ROOT, load_settings


def test_default_root_settings_resolve_relative_to_application_root() -> None:
    settings = load_settings()

    assert settings.output_directory == APP_ROOT / "runs"
    assert settings.cleaner_root == APP_ROOT / "oci-comp-cleaner"


def test_supports_absolute_and_relative_settings_paths(tmp_path: Path) -> None:
    output_directory = tmp_path / "external-output"
    settings_file = tmp_path / "app-config.ini"
    settings_file.write_text(
        f"[paths]\noutput_directory = {output_directory}\ncleaner_root = relative-cleaner\n",
        encoding="utf-8",
    )

    settings = load_settings(settings_file)

    assert settings.output_directory == output_directory
    assert settings.cleaner_root == APP_ROOT / "relative-cleaner"
