# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

"""Install into a machine-local .venv; never install globally or alter user data."""
from __future__ import annotations

import sys
if sys.version_info < (3, 10):
    raise SystemExit('Python 3.10 or newer is required. Select an approved Python installation and run setup again.')

import argparse
import json
import os
import platform
import subprocess
import tempfile
import venv
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from scripts.install_support import check_location, environment_python, read_marker, write_marker


def probe_environment(root: Path):
    python = environment_python(root)
    if not python.is_file() or not (root / '.venv' / 'pyvenv.cfg').is_file():
        raise RuntimeError('The existing .venv is incomplete. Stop the app, rename .venv aside, and run setup again.')
    result = subprocess.run([str(python), '-c', 'import json,sys,platform; print(json.dumps({"prefix":sys.prefix,"base":sys.base_prefix,"version":list(sys.version_info[:2]),"platform":sys.platform,"arch":platform.machine()}))'],
                            capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError('The existing .venv cannot run on this machine. Rename it aside and rerun setup; keep your catalogs and drafts.')
    info = json.loads(result.stdout)
    if (Path(info['prefix']).resolve() != (root / '.venv').resolve() or info['prefix'] == info['base']
            or info['version'] != list(sys.version_info[:2]) or info['platform'] != sys.platform or info['arch'] != platform.machine()):
        raise RuntimeError('The existing .venv uses a different Python version, location, or platform. Use its original Python for setup, or rename .venv aside and recreate it.')


def check_pip_destination(python: Path):
    # Honor approved indexes/proxies, but do not let pip config redirect this
    # installation outside .venv. Never print config values (which may be secrets).
    result = subprocess.run([str(python), '-m', 'pip', '--disable-pip-version-check', 'config', 'list'],
                            capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError('Cannot inspect pip installation settings. Repair pip in .venv before rerunning setup.')
    for line in result.stdout.splitlines():
        name, _, value = line.partition('=')
        option = name.rsplit('.', 1)[-1].strip().lower()
        value = value.strip().strip("'\"")
        if option in {'target', 'prefix', 'root'} and value or option == 'user' and value.lower() not in {'', '0', 'false', 'no', 'off'}:
            raise RuntimeError('pip destination overrides are configured. Remove target/prefix/root/user overrides through your approved configuration process, then rerun setup. This installer only writes dependencies into the app .venv.')


def install(root: Path = ROOT):
    root = root.resolve()
    if not (root / 'frontend' / 'dist' / 'index.html').is_file():
        raise RuntimeError('The prebuilt UI is missing. Extract the complete release ZIP again; operators do not need npm.')
    for name in ('pyproject.toml', 'constraints.txt'):
        if not (root / name).is_file():
            raise RuntimeError(f'Release is incomplete: {name} is missing.')
    with tempfile.TemporaryFile(dir=root):
        pass  # Fail before setup if the application folder is not writable.
    folder = root / '.venv'
    if folder.is_symlink():
        raise RuntimeError('Use a real .venv directory inside this app folder, not a symlink to another environment.')
    if folder.exists():
        marker = read_marker(root)
        if marker:
            check_location(root, marker)
        probe_environment(root)
    else:
        print(f'Creating {folder} using Python {platform.python_version()} ({platform.machine()})', flush=True)
        try:
            venv.EnvBuilder(with_pip=True, symlinks=os.name != 'nt').create(folder)
        except Exception as exc:
            raise RuntimeError('Python could not create .venv with pip. On Linux, install the matching python3-venv component through your approved process. Rename any partial .venv aside before retrying.') from exc
    write_marker(root, 'incomplete')
    python = environment_python(root)
    check_pip_destination(python)
    print('Installing constrained dependencies. Internet or an approved pip mirror/cache is required. No catalogs or OCI credentials are accessed.', flush=True)
    subprocess.run([str(python), '-m', 'pip', '--disable-pip-version-check', 'install', '--only-binary=:all:',
                    '-c', str(root / 'constraints.txt'), '-e', str(root)], cwd=root, check=True)
    subprocess.run([str(python), '-m', 'pip', 'check'], cwd=root, check=True)
    # Exercise runtime dependencies, crypto and XLSX using only synthetic data.
    subprocess.run([str(python), '-c', 'from backend.launcher import self_test; self_test()'], cwd=root, check=True)
    write_marker(root, 'ready')
    print('Setup complete. Run start.cmd / start.ps1 on Windows, or sh start.sh on macOS/Linux. Supply catalogs separately in this app folder.', flush=True)


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    try:
        install()
    except subprocess.CalledProcessError as exc:
        print(f'Setup failed (exit {exc.returncode}). Review the error above, correct the network/proxy/Python issue, then rerun setup. Dependencies must have wheels for your Python/OS. The app is not ready yet; catalogs and drafts were not changed.', file=sys.stderr)
        raise SystemExit(1)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f'Setup failed: {exc}', file=sys.stderr)
        raise SystemExit(1)


if __name__ == '__main__':
    main()
