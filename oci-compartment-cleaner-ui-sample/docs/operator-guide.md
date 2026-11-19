# Operator Guide — OCI Compartment Cleaner UI

## Scope

The UI creates dry-run plans by default. Execute mode creates its own plan,
pauses for the operator to review that exact plan, and requires typed `DELETE`
before it can continue.

## Prerequisites

- Python 3.10 or newer.
- An OCI config/profile and its accessible API-key file (normally created with
  OCI CLI under `~/.oci/config`).
- Permission to list accessible compartments and subscribed regions, and to run
  the cleaner's read-only resource discovery.

## Install and start

Run the commands for your operating system from this repository's root
directory.

### macOS or Linux — first-time setup

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python run-ui.py
```

For later starts, only run:

```bash
.venv/bin/python run-ui.py
```

### Windows PowerShell — first-time setup

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe run-ui.py
```

For later starts, only run:

```powershell
.\.venv\Scripts\python.exe run-ui.py
```

The Windows commands deliberately call the virtual-environment Python directly;
they do not require activating it. If you prefer activation in a PowerShell
session, run `.\.venv\Scripts\Activate.ps1` after creating the environment,
then use `python` instead of the full `.venv` path for the remaining commands.

Use a project-local `.venv` for every installation. Homebrew-managed Python on
macOS can reject system-wide `pip install` requests because that interpreter is
maintained by Homebrew. The virtual environment has its own package directory,
so installing the UI dependencies there cannot alter the managed Python
installation. Do not use `python3 -m venv .`, which places environment folders
such as `bin/` directly in the application root.

### Alternative: Python not managed by Homebrew or another package manager

If `python3 -m pip install --user -r requirements.txt` works on the operator's
approved Python installation, a virtual environment is not required. Use:

```bash
python3 -m pip install --user -r requirements.txt
python3 run-ui.py
```

The `--user` option installs packages only for the current user. If this command
returns the `externally-managed-environment` error, use the `.venv` method above
instead.

The application starts a Streamlit server bound only to `127.0.0.1` and opens
in the local browser. It does not transmit the OCI config or private key to a
remote service.

## Run a dry-run

1. Enter the normal OCI config file path and select **Load profiles**.
2. Choose the OCI profile. Its subscribed regions and accessible compartment
   hierarchy load automatically; use **Refresh regions and compartments** when
   OCI changes after the page loaded.
3. Select a region, search the expandable compartment tree if needed, and select
   the intended target compartment.
4. Verify the displayed compartment OCID, then select **Create dry-run plan**.
5. Monitor the fixed-height, scrollable cleaner-log and process-output panes,
   then inspect the generated text/JSON plan at the end.

Cleaner artifacts are written to a unique directory under the application
root's configured output directory. By default this is the repository's
`runs/` directory. New folder names include the UTC run time, tenancy name,
target compartment name, region, and
compartment-OCID suffix, for example
`20260825T145212Z__my-tenancy__demo-lab__eu-frankfurt-1__wdmemntd54qzueqa`.
Their exact path is shown in the UI.

## Application paths

[app-config.ini](../app-config.ini) is the non-secret settings file in the
application root. Its defaults are relative to that root:

```ini
[paths]
output_directory = runs
cleaner_root = oci-comp-cleaner
```

Set either value to an absolute path when needed, then restart the UI. Do not
place OCI API keys or other secrets in this file; credentials remain in the
selected OCI config profile.

## Run a network usage audit

After selecting the target compartment and region, use **Run network usage
audit**. The audit is read-only: it looks for accessible resources in other
compartments that reference the target's VCNs, subnets, NSGs, or local peering
gateways.

- Leave **External compartments to scan** empty to scan all accessible external
  compartments, or select one or more compartments to restrict the scan.
- Watch the audit log while it runs and inspect the text/JSON reports afterwards.
- The audit log, process output, and text report are fixed-height scrollable
  panes; the text report appears above the audit summary.
- **Completed with external network-usage findings** is a normal completed audit
  result, not an execution failure. Review its findings before cleaning the
  target compartment.
- Scan errors mean the audit may be incomplete because some OCI resources could
  not be inspected.

Audit folders use the same readable naming scheme as dry-runs, with a
`network-usage-audit` prefix.

## Safety notes

- Confirm the selected compartment OCID before every run.
- A dry-run plan is a discovery snapshot; it does not prove a future execute
  run will see exactly the same resources.
- Cancelling the UI process does not roll back OCI operations. This is most
  important during execution.

## Execute deletion

Execution is destructive and uses a new resource discovery and plan; it does
not reuse the prior dry-run plan.

1. A dry-run is optional and remains an independent preview. Open **Execute
   deletion** and recheck the tenancy, region, target path, and target OCID.
   Review the network-usage audit if you chose to run it; audit findings are
   advisory.
2. Choose **Create Resource Manager discovery stack** (the default) and select
   a distinct accessible backup-stack compartment and region. This stack is
   resource-discovery output, not a recoverable data backup. If creation fails,
   the cleaner stops before deletion.
3. Alternatively, select **Skip Resource Manager discovery stack** only when
   you deliberately accept operating without that discovery output.
4. Select **Start execute discovery**. The cleaner discovers resources once,
   writes an execution plan, and pauses. No Resource Manager stack or deletion
   has started at this point.
5. Review this exact execution plan. Type `DELETE` and select **Confirm
   deletion of this execution plan**, or select **Abort execute plan**. Abort
   exits before stack creation and deletion.
6. Watch the fixed-height, scrollable execution log and process-output panes.
   A green process status does not mean every resource was deleted: inspect
   per-resource errors and remaining-resource verification messages in the log.

Closing the browser tab does not cancel an execution. If the local UI server
stops or its heartbeat expires, its local supervisor interrupts the cleaner;
OCI calls already accepted by OCI cannot be rolled back. Use **Cancel
destructive execution** to request an interruption and then inspect the final
artifacts.
