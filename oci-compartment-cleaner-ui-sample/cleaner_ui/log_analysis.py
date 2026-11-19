# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Small, transparent post-run analysis of cleaner log files."""

from __future__ import annotations

import re
from pathlib import Path

ERROR_PATTERN = re.compile(r"\b(?:ERROR|CRITICAL)\b|Traceback \(most recent call last\)")


def find_error_entries(log_path: Path | None) -> list[str]:
    """Return log lines explicitly marked as errors, without interpreting OCI results."""
    if log_path is None or not log_path.is_file():
        return []
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    return [line for line in lines if ERROR_PATTERN.search(line)]
