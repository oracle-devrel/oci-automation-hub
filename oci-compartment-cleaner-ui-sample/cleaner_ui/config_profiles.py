# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""OCI config profile discovery and non-secret validation."""

from __future__ import annotations

import configparser
from pathlib import Path

from .validation import ValidationError, require_existing_file


def default_config_path() -> Path:
    return Path.home() / ".oci" / "config"


def list_profiles(config_path: str | Path) -> list[str]:
    """List OCI config sections without loading their credential values."""
    path = require_existing_file(config_path, "OCI config file")
    parser = configparser.ConfigParser(interpolation=None)
    try:
        with path.open(encoding="utf-8") as config_file:
            parser.read_file(config_file)
    except (OSError, configparser.Error) as exc:
        raise ValidationError(f"Could not read OCI config file: {exc}") from exc

    profiles = parser.sections()
    if parser.defaults():
        profiles.append(parser.default_section)
    if not profiles:
        raise ValidationError("The OCI config file does not contain any profiles.")
    return sorted(profiles, key=str.casefold)


def load_profile(config_path: str | Path, profile: str) -> dict[str, str]:
    """Load a selected profile through the OCI SDK and validate its key path."""
    path = require_existing_file(config_path, "OCI config file")
    if not profile.strip():
        raise ValidationError("Select an OCI config profile.")
    try:
        import oci

        config = oci.config.from_file(str(path), profile_name=profile)
    except ImportError as exc:
        raise ValidationError(
            "The OCI Python SDK is not installed. Run pip install -r requirements.txt."
        ) from exc
    except Exception as exc:
        raise ValidationError(f"Could not load OCI profile '{profile}': {exc}") from exc

    key_file = config.get("key_file")
    if not key_file or not Path(key_file).expanduser().is_file():
        raise ValidationError("The selected OCI profile's key_file is missing or cannot be read.")
    return config
