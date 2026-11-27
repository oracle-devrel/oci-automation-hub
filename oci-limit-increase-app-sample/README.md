# OCI Limit Workbench — Python-based installation

This archive includes the Python application and prebuilt browser UI. It does
not contain a Python runtime, virtual environment, operational catalogs, user
data, or credentials. Use an approved Python 3.10+ installation and a browser.
Node.js, Git, Docker and compiler tools are not needed on the operator machine.
OCI CLI is only required if you run exported CLI submission commands separately.
Share the original release ZIP, not an installed folder containing `.venv`,
operator catalogs or user data.

## Install and start

Extract the entire archive into a writable local folder. Do not run it from
inside the ZIP or a shared/synchronized folder used by multiple operators.
Run these commands from the extracted `LimitWorkbench` folder.

macOS / Linux:

```sh
sh setup.sh
sh start.sh
```

Windows Command Prompt:

```bat
setup.cmd
start.cmd
```

Windows PowerShell (if permitted by your organization's policy):

```powershell
.\setup.ps1
.\start.ps1
```

Setup creates `.venv` here, installs constrained dependencies from PyPI (or your
configured approved pip mirror), checks dependencies, and performs a synthetic
offline self-test. It does not access OCI credentials, make OCI requests, or
replace catalogs/drafts. Internet access is normally needed for installation,
but not for offline operation after setup. Only prebuilt dependency wheels are
installed; setup does not attempt to install compilers or system packages.

Startup opens http://127.0.0.1:8765 in your browser. Keep the terminal open;
Ctrl+C stops the server. Startup never installs or updates dependencies.

## Supply catalogs and credentials separately

Copy these files into this folder, beside `start.sh` / `start.cmd`:

- `oci_sku_limit_catalog.json` — needed to create new BOM-based drafts.
- `oci_services.json` and `oci_limit_definitions.json` — offline mapping data;
  alternatively import/generate this pair through the app.

All three may be absent on first start. Existing draft import is still available.
Each operator provides their own OCI API-key config/profile for connected work.
Never distribute private keys, OCI config files, drafts or submission journals
with the application archive.

## Storage and upgrades

Drafts and submission records are stored separately by default:

- macOS/Linux: `~/.local/share/oci-limit-workbench`
- Windows: `%LOCALAPPDATA%\OCILimitWorkbench`

Use `--data-dir` to select another existing or new folder, for example:

```sh
sh start.sh --data-dir "/path/to/my drafts" --port 8767
```

```bat
start.cmd --data-dir "C:\Work\OCI drafts" --port 8767
```

To upgrade: stop the old app, extract the new release into a new folder, run its
setup, and copy your three catalog files across. Reuse the same data-dir if it
was customized. Back up drafts AND their `submissions` subfolder, and preserve
catalog backups in `.catalog-backups`. Do not copy `.venv` to another folder or
machine. Keep the previous app folder until the upgrade is verified. Never
overwrite or remove your user data as part of an application upgrade.

## Troubleshooting

- **Python not found / old Python:** install an approved Python 3.10+ with pip
  and venv. On Linux, the matching `python3-venv` package may be needed. Setup
  does not use sudo or change system Python. To select a different interpreter:
  `LIMIT_SETUP_PYTHON=/path/to/python3 sh setup.sh`, or
  `.\setup.ps1 -PythonPath 'C:\path\to\python.exe'`.
- **PowerShell script blocked:** use an IT-approved entry point such as the
  Command Prompt scripts or `py -3 scripts\setup_app.py`; do not disable OS policy.
- **Installation/network/certificate failure:** resolve proxy/trust/mirror access
  through your approved process, then rerun setup. Do not disable TLS validation.
- **No matching binary wheel:** the pinned dependencies may not support the
  selected Python/OS/CPU. Use a supported interpreter; do not assume every future
  Python release is compatible just because it is newer than 3.10.
- **Moved/incompatible/partial .venv:** stop the app, rename `.venv` aside and run
  setup in this folder. Leave catalogs, drafts and submissions untouched.
- **Setup incomplete / dependencies changed:** rerun setup. Startup will not
  silently continue with an incomplete installation.
- **Port occupied:** stop the other instance or pass `--port 8767` to start.
- **Diagnostic self-test:** after setup, run
  `.venv/bin/python scripts/run_app.py --self-test` on macOS/Linux or
  `.venv\Scripts\python.exe scripts\run_app.py --self-test` on Windows.
  This uses synthetic data and blocks network connections.

