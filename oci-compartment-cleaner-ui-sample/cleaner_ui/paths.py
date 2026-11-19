# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Local filesystem locations used by the UI."""

from __future__ import annotations

import re
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from .settings import load_settings


def application_data_dir() -> Path:
    """Return the configured base directory for cleaner artifacts."""
    return load_settings().output_directory


def create_run_directory(
    *,
    tenancy_name: str,
    compartment_name: str,
    compartment_id: str,
    region: str,
    run_type: str | None = None,
) -> Path:
    """Create a unique, operator-searchable directory for one cleaner run."""
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    compartment_suffix = compartment_id.rsplit(".", maxsplit=1)[-1]
    name_parts = [
        timestamp,
        _safe_path_label(tenancy_name),
        _safe_path_label(compartment_name),
        _safe_path_label(region),
        _safe_path_label(compartment_suffix),
    ]
    if run_type:
        name_parts.insert(0, _safe_path_label(run_type))
    directory_name = "__".join(name_parts)
    output_directory = application_data_dir()
    directory = output_directory / directory_name
    try:
        directory.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        directory = output_directory / f"{directory_name}__{uuid4().hex[:8]}"
        directory.mkdir(parents=True, exist_ok=False)
    return directory


def _safe_path_label(value: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip(".-_")
    return normalized[:60] or "unknown"
