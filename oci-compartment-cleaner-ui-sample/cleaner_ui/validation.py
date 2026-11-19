# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Validation for values that cross the UI-to-cleaner process boundary."""

from __future__ import annotations

from pathlib import Path


class ValidationError(ValueError):
    """Raised when UI input is unsuitable for invoking the cleaner."""


def require_compartment_ocid(value: str) -> str:
    normalized = value.strip()
    has_whitespace = any(char.isspace() for char in normalized)
    if not normalized.startswith("ocid1.compartment.") or has_whitespace:
        raise ValidationError("Select a valid OCI compartment OCID.")
    return normalized


def require_region(value: str) -> str:
    normalized = value.strip()
    if not normalized or any(char.isspace() for char in normalized):
        raise ValidationError("Select a valid OCI region.")
    return normalized


def require_existing_file(value: str | Path, description: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_file():
        raise ValidationError(f"{description} does not exist or is not a file: {path}")
    return path.resolve()
