<!-- Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved. -->
<!-- The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/ -->
# Post-Provisioning Runbook

Terraform creates the OCI layer, then Windows first-boot automation continues asynchronously. When Terraform prints the instance IPs, wait at least 10-15 minutes before testing. A fresh DC promotion can take roughly 20-25 minutes, and SQL Server/SSMS downloads can extend the SQL node time. Use the ready-marker checks below as the completion signal; do not treat the Terraform apply timestamp as bootstrap completion.

## 1. Domain Controller

This is now automated during `terraform apply` when these variables are set:

```hcl
auto_configure_domain_controller = true
auto_configure_windows_nodes     = true
auto_install_sql_server          = true
install_ssms                     = true
auto_configure_wsfc              = true
domain_name                      = "mssqlaoag.demo"
domain_netbios_name              = "MSSQLAOAG"
domain_admin_user                = "domainadmin"
local_admin_user                 = "opc"
sql_service_account_user         = "sqlsa"
domain_admin_password            = "<domainadmin password>"
sql_service_account_password     = "" # empty means reuse domain_admin_password for this POC
windows_admin_password           = "" # empty means reuse domain_admin_password for local Windows logins
```

Terraform injects `templates/dc-user-data.ps1.tftpl` into `DC-VM` as Windows user data. On first boot, the VM writes and runs:

```text
C:\AOAGAutomation\DC\01-configure-domain-controller.ps1
```

This script:

- Renames the computer to `DC-VM` if needed.
- Installs AD DS and DNS.
- Promotes the forest as `mssqlaoag.demo`.
- Creates `domainadmin`.
- Adds `domainadmin` to Domain Admins, Enterprise Admins, Administrators, and Remote Desktop Users.
- Creates `sqlsa` as the dedicated SQL Server service account.
- Creates the file share witness:
  - Path: `C:\ClusterWitness`
  - Share: `\\DC-VM.mssqlaoag.demo\ClusterWitness`
- Verifies the `domainadmin@mssqlaoag.demo` credential after restart.

After `terraform apply`, wait for the DC rename/promotion/reboot cycle to finish. Then verify with RDP or OCI Run Command:

```powershell
Get-Content C:\AOAGAutomation\DC\DOMAIN_READY.txt
Get-Content C:\AOAGAutomation\DC\DOMAIN_VERIFY.json
```

## 2. SQL Nodes

On `SQL1` and `SQL2`:

- Terraform first-boot user data sets the local `Administrator` and `opc` password, enables RDP, renames the computers to `SQL1` and `SQL2`, points DNS to `10.0.10.10`, joins `mssqlaoag.demo`, and adds `MSSQLAOAG\domainadmin` to local Administrators and Remote Desktop Users.
- If `auto_install_sql_server = true`, Terraform first-boot user data installs SQL Server 2025 Standard Developer after the domain join stage.
- SQL Server and SQL Server Agent are configured to run as `MSSQLAOAG\sqlsa`.
- `MSSQLAOAG\domainadmin` and `BUILTIN\Administrators` are SQL sysadmin accounts.
- SQL Server Management Studio is installed when `install_ssms = true`.
- Failover Clustering prerequisites and SQL Server Always On availability groups are enabled.
- Windows firewall is opened for:
  - TCP `1433`
  - TCP `5022`

Verify on each SQL node:

```powershell
Get-Content C:\AOAGAutomation\Windows\stage.txt
Get-Content C:\AOAGAutomation\Windows\WINDOWS_BOOTSTRAP_READY.txt
Get-Service MSSQLSERVER,SQLSERVERAGENT
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\MSSQLSERVER" | Select-Object ObjectName
```

## 3. WSFC

When `auto_configure_wsfc = true`, SQL1 launches:

```text
C:\AOAGAutomation\WSFC\03-configure-wsfc.ps1
```

This waits for SQL1 and SQL2, confirms Failover Clustering, enables Always On,
creates `SQLAGCLUSTER`, and configures the file-share witness:

```text
\\DC-VM.mssqlaoag.demo\ClusterWitness
```

The `.20` addresses are the WSFC cluster IPs reserved by Terraform:

```text
10.0.20.20
10.0.30.20
```

Verify on SQL1:

```powershell
Get-Content C:\AOAGAutomation\WSFC\configure-wsfc.log -Tail 120
Get-Content C:\AOAGAutomation\WSFC\WSFC_READY.txt
Get-Content C:\AOAGAutomation\WSFC\WSFC_VERIFY.json
Get-ClusterNode -Cluster SQLAGCLUSTER
Get-ClusterQuorum -Cluster SQLAGCLUSTER
```

Manual fallback from SQL1:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\AOAGAutomation\WSFC\03-configure-wsfc.ps1 `
  -DomainName mssqlaoag.demo `
  -DomainNetbiosName MSSQLAOAG `
  -DomainAdminUser domainadmin `
  -DomainAdminPassword '<domainadmin password>' `
  -ClusterName SQLAGCLUSTER `
  -ClusterNodes SQL1,SQL2 `
  -ClusterStaticAddresses 10.0.20.20,10.0.30.20 `
  -WitnessShare \\DC-VM.<domain_name>\<wsfc_witness_share_name> `
  -SkipClusterValidation
```

## 4. SQL Availability Group

Use backup/restore, not automatic seeding:

- Create the primary databases on SQL1.
- Full backup and log backup on SQL1.
- Restore on SQL2 with `NORECOVERY`.
- Create or join the AG with manual backup/restore seeding, synchronous commit,
  and automatic failover for SQL1 and SQL2.
- Wait for both replicas to be online, synchronized, and healthy, then configure the native listener using the reserved listener IPs.

The example reserves these listener-style IPs; use the values from your
`terraform.tfvars` for another deployment:

| Purpose | SQL1 subnet | SQL2 subnet |
| --- | --- | --- |
| WSFC cluster | `10.0.20.20` | `10.0.30.20` |
| AG listener IP | `aoag_listener_ip_sql1` | `aoag_listener_ip_sql2` |
| AGDemoDB2 / listener IP | `10.0.20.31` | `10.0.30.31` |

No OCI Load Balancer is part of this build.

The listener is automated as Task 5.5. Verify it on both SQL nodes:

```powershell
Get-Content C:\AOAGAutomation\WSFC\TASK_5_5_LISTENER_READY.txt
```

Then connect to `<aoag_listener_name>.<domain_name>,<aoag_listener_port>` from
SSMS using Windows Authentication. The listener must be tested only after Task
5.5 is marked complete.

For failover validation, run the guarded planned-failover script on the target
secondary. It waits up to 30 minutes for the target to report `SECONDARY`,
`CONNECTED`, `ONLINE`, `SYNCHRONIZED`, and `HEALTHY`:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\AOAGAutomation\WSFC\06-safe-planned-failover.ps1
```

For a planned test, use the guarded script above. For an unplanned outage test,
you may stop the primary VM, but expect SQL Server to perform crash recovery;
the former primary can temporarily enter `REVERTING` while it performs
undo-of-redo recovery. On restart, the installed
`AOAG-Reconcile-AvailabilityGroup` startup task waits for SQL Server and WSFC,
clears a lab quarantine if needed, and waits for the former primary to return as
an `ONLINE / SYNCHRONIZED / HEALTHY` secondary. Check
`C:\AOAGAutomation\WSFC\AG_RECONCILIATION_READY.txt` before running the guarded
script on that node to perform a planned failback.
