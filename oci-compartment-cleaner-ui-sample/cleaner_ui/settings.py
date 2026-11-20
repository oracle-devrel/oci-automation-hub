# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Application settings loaded from the root-level non-secret INI file."""

from __future__ import annotations

import configparser
from dataclasses import dataclass
from pathlib import Path

from .validation import ValidationError

APP_ROOT = Path(__file__).resolve().parents[1]
SETTINGS_PATH = APP_ROOT / "app-config.ini"
DEFAULT_OUTPUT_DIRECTORY = "runs"
DEFAULT_CLEANER_ROOT = "oci-comp-cleaner"


@dataclass(frozen=True)
class AppSettings:
    output_directory: Path
    cleaner_root: Path


def load_settings(settings_path: Path = SETTINGS_PATH) -> AppSettings:
    """Load paths from settings_path, resolving relative values from app root."""
    parser = configparser.ConfigParser(interpolation=None)
    try:
        with settings_path.open(encoding="utf-8") as settings_file:
            parser.read_file(settings_file)
    except OSError as exc:
        raise ValidationError(
            f"Could not read application settings file {settings_path}: {exc}"
        ) from exc
    except configparser.Error as exc:
        raise ValidationError(f"Invalid application settings file {settings_path}: {exc}") from exc

    output_value = parser.get("paths", "output_directory", fallback=DEFAULT_OUTPUT_DIRECTORY)
    cleaner_value = parser.get("paths", "cleaner_root", fallback=DEFAULT_CLEANER_ROOT)
    return AppSettings(
        output_directory=_resolve_path(output_value),
        cleaner_root=_resolve_path(cleaner_value),
    )


def _resolve_path(value: str) -> Path:
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = APP_ROOT / path
    return path.resolve()
