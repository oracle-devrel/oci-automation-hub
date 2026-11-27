# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Standard-library-only checks shared by setup and normal Python startup."""
from __future__ import annotations

import hashlib
import json
import os
import platform
import sys
import tempfile
from pathlib import Path

MARKER = 'limit-workbench-install.json'


def environment_python(root: Path, windows: bool | None = None) -> Path:
    windows = os.name == 'nt' if windows is None else windows
    return root / '.venv' / ('Scripts/python.exe' if windows else 'bin/python')


def dependency_fingerprint(root: Path) -> str:
    return hashlib.sha256((root / 'pyproject.toml').read_bytes() + b'\0' + (root / 'constraints.txt').read_bytes()).hexdigest()


def read_marker(root: Path):
    path = root / '.venv' / MARKER
    if not path.exists():
        return None
    try:
        value = json.loads(path.read_text(encoding='utf-8'))
        if not isinstance(value, dict) or value.get('schema_version') != 1:
            raise ValueError()
        return value
    except (ValueError, OSError) as exc:
        raise RuntimeError('The installation record is unreadable. Stop the app, rename .venv aside, and run setup again. Do not remove catalogs or drafts.') from exc


def check_location(root: Path, marker: dict):
    if (marker.get('app_directory') != str(root.resolve()) or marker.get('platform') != sys.platform
            or marker.get('architecture') != platform.machine() or marker.get('python_version') != list(sys.version_info[:2])):
        raise RuntimeError('This .venv belongs to a different app location, Python version, OS, or architecture. Stop the app, rename .venv aside, then run setup in this folder. Do not copy .venv between machines.')


def write_marker(root: Path, state: str):
    folder = root / '.venv'
    value = {'schema_version': 1, 'state': state, 'app_directory': str(root.resolve()),
             'platform': sys.platform, 'architecture': platform.machine(),
             'python_version': list(sys.version_info[:2]),
             'dependencies_sha256': dependency_fingerprint(root)}
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=folder, suffix='.tmp', delete=False) as file:
            temporary = file.name
            file.write((json.dumps(value, indent=2) + '\n').encode('utf-8')); file.flush(); os.fsync(file.fileno())
        os.replace(temporary, folder / MARKER)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def check_startup(root: Path):
    marker = read_marker(root)
    if marker is None:
        # Preserve the existing manually installed developer workflow.
        if (root / 'BUILD-INFO.json').exists():
            raise RuntimeError('This release has not completed setup. Run setup.sh, setup.cmd, or scripts/setup_app.py first.')
        return
    check_location(root, marker)
    if Path(sys.prefix).resolve() != (root / '.venv').resolve():
        raise RuntimeError('Use start.sh, start.cmd, or start.ps1 to run with this application\'s local .venv Python.')
    if marker.get('state') != 'ready' or marker.get('dependencies_sha256') != dependency_fingerprint(root):
        raise RuntimeError('Setup is incomplete or application dependencies changed. Stop the app and run setup again. No catalogs or drafts will be replaced.')
