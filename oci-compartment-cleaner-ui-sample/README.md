# OCI Compartment Cleaner UI

A local Streamlit application for operating the included OCI compartment
cleaner more safely than from a terminal alone.

It uses an existing OCI API-key profile from the operator's local OCI config,
helps the operator select a tenancy compartment and region, and runs the
included cleaner as a local subprocess. The UI does not reimplement OCI
deletion logic.

> [!WARNING]
> This tool can delete OCI resources. Use it only for compartments that are
> explicitly approved for cleanup. OCI operations already accepted by OCI
> cannot be rolled back by cancelling the UI or the local process.

## What it provides

- Profile-based OCI authentication from the operator's existing `~/.oci/config`.
- Automatically refreshed subscribed-region list and searchable compartment
  tree, with OCIDs shown for verification.
- Independent, read-only dry-run plans.
- Read-only network-usage audit for references to target VCNs, subnets, NSGs,
  and local peering gateways from other accessible compartments.
- A separate execute workflow that creates one execution plan, pauses for
  review, and deletes only that same in-memory plan after typed `DELETE`.
- Optional Resource Manager resource-discovery stack creation before deletion.
- Live logs, process output, plan artifacts, completion status, and simple
  error-level log analysis.
- A local supervisor that interrupts an execute process if the UI/server pipe
  closes or its heartbeat stops unexpectedly.

## Requirements

- Python 3.10 or newer.
- An OCI config profile with an API-key-based authentication configuration,
  normally at `~/.oci/config`.
- OCI permissions appropriate for listing and deleting resources in the chosen
  compartment and region. Resource Manager permissions are also required when
  creating the optional discovery stack.

The application never stores OCI private keys, passphrases, or config-profile
secrets in this repository.

## Install and start

Run these commands from the repository root.

### macOS or Linux

First-time setup:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python run-ui.py
```

Later starts:

```bash
.venv/bin/python run-ui.py
```

### Windows PowerShell

First-time setup:

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe run-ui.py
```

Later starts:

```powershell
.\.venv\Scripts\python.exe run-ui.py
```

The server listens only on `127.0.0.1`; Streamlit usage statistics are disabled
by the launcher; OCI config and private-key material remain on the local
machine.

If a Homebrew-managed Python reports `externally-managed-environment`, use the
virtual-environment commands above. Do not use `--break-system-packages`.

## Configure local paths

[app-config.ini](app-config.ini) contains non-secret local paths. Relative
paths are resolved from the repository root.

```ini
[paths]
output_directory = runs
cleaner_root = oci-comp-cleaner
```

- `output_directory` stores generated local artifacts.
- `cleaner_root` is the directory containing the included cleaner source.

Use absolute paths if your organization requires artifacts or the cleaner
source elsewhere. Restart the UI after changing this file.

## Use the UI

### 1. Select OCI scope

1. Enter the OCI config path and choose **Load profiles**.
2. Select a profile. The UI loads its tenancy name, subscribed regions, and
   accessible compartments.
3. Select the region and intended target compartment.
4. Verify the displayed full compartment path and OCID.

### 2. Create a dry-run plan

Select **Create dry-run plan**. This is read-only and does not commit you to
any later action. Review the plan and log before considering execute mode.

### 3. Optional network-usage audit

Select **Run network usage audit** to identify accessible resources in other
compartments that refer to networking resources in the selected target.

Audit findings are advisory: they do not block deletion automatically. Review
findings and scan errors before proceeding.

### 4. Execute deletion

The execution plan is deliberately separate from a prior dry-run:

1. In **Execute deletion**, choose whether to create a Resource Manager
   discovery stack. This is discovery output, not a recoverable data backup.
2. If creating one, choose a distinct backup-stack compartment and region.
   If stack creation fails, the cleaner stops before deletion.
3. Select **Start execute discovery**. The cleaner discovers resources once,
   writes the execution plan, and pauses. No Resource Manager stack or deletion
   has started at this stage.
4. Review that exact execution plan.
5. Type `DELETE` and select **Confirm deletion of this execution plan** to
   continue, or choose **Abort execute plan** to exit without stack creation or
   deletion.

The typed confirmation is sent through a local supervisor pipe to the
already-paused cleaner process. It does not start a second discovery and does
not use a confirmation file.

During execution, the selected profile, region, target, and backup settings are
locked. **Cancel destructive execution** requests interruption, but cannot roll
back OCI calls already accepted by OCI.

## Artifacts and logs

Every dry-run, audit, and execute action receives a distinct folder beneath the
configured output directory. Folder names include UTC timestamp, tenancy,
compartment, region, and compartment-OCID suffix.

Examples:

```text
20260907T101530Z__my-tenancy__demo__eu-frankfurt-1__abc123
network-usage-audit__20260907T101700Z__my-tenancy__demo__eu-frankfurt-1__abc123
execute__20260907T102000Z__my-tenancy__demo__eu-frankfurt-1__abc123
```

Each cleaner run contains a log plus plan text and JSON. Execute folders also
contain an internal `.ui-heartbeat` file used by the local process supervisor.
Artifact folders are ignored by Git by default.

A successful process exit does not prove that every resource was deleted.
Always review the final log, error-level log analysis, and remaining-resource
verification output.

## Resource support

The cleaner supports many OCI resource types through
[`oci-comp-cleaner/oci_compartment_cleaner/resource_support.json`](oci-comp-cleaner/oci_compartment_cleaner/resource_support.json).
Some services require explicit support because their OCI SDK delete operation
needs more than one identifier or a pre-delete step. Unsupported resources are
reported in the log and remain in final verification results.

Before extending support, use a dry-run and verify the official OCI SDK method,
required parameters, resource dependencies, and wait behavior. Test changes in
a disposable compartment before any production-like use.

## Development checks

Install development dependencies and run checks:

```bash
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python -m ruff check cleaner_ui tests run-ui.py
.venv/bin/python -m pytest
```

On Windows PowerShell, replace `.venv/bin/python` with
`.\.venv\Scripts\python.exe`.

## Repository hygiene

Do not commit OCI credentials, private keys, local `runs/` artifacts, virtual
environments, or Streamlit secrets. The included [.gitignore](.gitignore)
excludes these local-only files.
