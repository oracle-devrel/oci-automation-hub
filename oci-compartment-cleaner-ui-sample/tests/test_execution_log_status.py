# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

from cleaner_ui.app import _last_nonempty_lines


def test_latest_execution_log_status_keeps_last_two_nonempty_lines() -> None:
    assert _last_nonempty_lines("first\n\nsecond\nthird\n", count=2) == ["second", "third"]
