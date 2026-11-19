# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from pathlib import Path

from cleaner_ui.log_analysis import find_error_entries


def test_finds_explicit_error_and_critical_log_entries(tmp_path: Path) -> None:
    log = tmp_path / "cleaner.log"
    log.write_text(
        "2026-08-26 INFO Started\n"
        "2026-08-26 ERROR Could not delete a resource\n"
        "2026-08-26 WARNING Something to review\n"
        "2026-08-26 CRITICAL Unexpected failure\n",
        encoding="utf-8",
    )

    assert find_error_entries(log) == [
        "2026-08-26 ERROR Could not delete a resource",
        "2026-08-26 CRITICAL Unexpected failure",
    ]


def test_missing_log_has_no_error_entries(tmp_path: Path) -> None:
    assert find_error_entries(tmp_path / "missing.log") == []
