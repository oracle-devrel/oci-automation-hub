<!-- Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved. -->
<!-- The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/ -->
# Automation Scripts

These scripts are the readable PowerShell automation used by Terraform
`user_data`. From the Terraform root, the scripts are organized by use case:

```text
scripts/
  dc/      Domain controller and witness share
  sql/     Shared SQL1/SQL2 bootstrap
  wsfc/    Failover cluster and Always On preparation
  aoag/    Database restore and availability group creation
```

The Terraform templates under `../templates` are intentionally thin launchers
that download these scripts from the private Object Storage automation bucket
and pass per-VM values. Terraform creates object-specific read-only PARs for
the downloads; the bucket itself is not public.

You normally do not run these manually. Manual runs are only for troubleshooting
from an elevated PowerShell session.

## 01-configure-domain-controller.ps1

This script is normally injected into `DC-VM` automatically through Terraform `user_data`.

Use case:

- Rename and configure `DC-VM`.
- Install AD DS and DNS.
- Promote `mssqlaoag.demo`.
- Create/update `MSSQLAOAG\domainadmin`.
- Create/update `MSSQLAOAG\sqlsa`.
- Create `\\DC-VM.mssqlaoag.demo\ClusterWitness`.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\dc\01-configure-domain-controller.ps1 -DomainAdminPasswordPlain '<domainadmin password>'
```

Default values:

- Domain: `mssqlaoag.demo`
- NetBIOS: `MSSQLAOAG`
- Domain admin user: `domainadmin`
- DC private IP: `10.0.10.10`
- Witness share: `\\DC-VM.mssqlaoag.demo\ClusterWitness`

The script may reboot more than once. It registers a temporary startup task named `AOAG-Configure-DomainController` and removes it after successful completion.

After the final restart, check:

```powershell
Get-Content C:\AOAGAutomation\DC\DOMAIN_READY.txt
Get-Content C:\AOAGAutomation\DC\DOMAIN_VERIFY.json
```

Successful RDP login should use either:

- `domainadmin@mssqlaoag.demo`
- `MSSQLAOAG\domainadmin`

## 02-configure-sql-node.ps1

This script is injected into both `SQL1` and `SQL2`; Terraform passes
`-TargetComputerName SQL1` or `-TargetComputerName SQL2`.

Use case:

- Set local `Administrator` and `opc` passwords.
- Enable RDP.
- Point DNS to `10.0.10.10`.
- Rename the VM to `SQL1` or `SQL2`.
- Wait until the domain is reachable.
- Join `mssqlaoag.demo`.
- Retry domain join and remove stale `SQL1$`/`SQL2$` AD computer objects from previous redeploys.
- Add `MSSQLAOAG\domainadmin` to local Administrators and Remote Desktop Users.
- Optionally install SQL Server 2025 and SSMS.
- Configure SQL Server and SQL Agent to use `MSSQLAOAG\sqlsa`.
- Open Windows firewall TCP `1433` and `5022`.
- Install Failover Clustering prerequisites.
- Enable SQL Server Always On availability groups.
- Reboot before WSFC when Windows reports pending reboot after SQL/SSMS/features.
- If this is SQL1 and `auto_configure_wsfc = true`, launch `03-configure-wsfc.ps1`.

The DC bootstrap configures DNS forwarding to the OCI VCN resolver and a public fallback. The SQL node bootstrap also retries Microsoft installer downloads with temporary public DNS and restores the DC DNS setting afterward.

Manual troubleshooting example for SQL1:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\sql\02-configure-sql-node.ps1 `
  -TargetComputerName SQL1 `
  -DomainName mssqlaoag.demo `
  -DomainNetbiosName MSSQLAOAG `
  -DomainAdminUser domainadmin `
  -DomainAdminPassword '<domainadmin password>' `
  -SqlServiceAccountUser sqlsa `
  -SqlServiceAccountPassword '<sql service account password>' `
  -DcPrivateIp 10.0.10.10
```

After the final restart, check on SQL1/SQL2:

```powershell
Get-Content C:\AOAGAutomation\Windows\stage.txt
Get-Content C:\AOAGAutomation\Windows\WINDOWS_BOOTSTRAP_STATUS.txt
Get-Content C:\AOAGAutomation\Windows\WINDOWS_BOOTSTRAP_READY.txt
Get-Service MSSQLSERVER,SQLSERVERAGENT
```

## 03-configure-wsfc.ps1

This script is written to `C:\AOAGAutomation\WSFC` on both SQL nodes. SQL1
launches it after SQL Server and SSMS are installed, SQL Always On is enabled,
and any pending reboot has completed when `auto_configure_wsfc` is true.

Use case:

- Relaunch itself as `domainadmin@mssqlaoag.demo` when started by LocalSystem.
- Wait for WinRM and SQL Server on SQL1 and SQL2.
- Install or confirm Failover Clustering management features on both nodes.
- Enable SQL Server Always On availability groups on both nodes.
- Create `SQLAGCLUSTER` with static IPs `10.0.20.20` and `10.0.30.20`.
- Configure quorum using `\\DC-VM.mssqlaoag.demo\ClusterWitness`.
- Restore the configured sample database on SQL1 from the configured backup URL, create full and log backups on the configured witness share, and restore SQL2 with `NORECOVERY`. This runs automatically on SQL1 when the Task 5.3 script is injected by Terraform.
- Create the configured HADR endpoint on both nodes, create the configured availability group with manual seeding, join SQL2, and attach the already-restored database. This is Task 5.4 and runs automatically after Task 5.3.
- Wait for both replicas to be synchronized and healthy, then create the configured native listener with the two configured listener IPs and port. This is Task 5.5 and runs automatically after Task 5.4.

Manual troubleshooting example from SQL1:

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

After completion, check on SQL1:

```powershell
Get-Content C:\AOAGAutomation\WSFC\WSFC_READY.txt
Get-Content C:\AOAGAutomation\WSFC\WSFC_STATUS.txt
Get-Content C:\AOAGAutomation\WSFC\WSFC_VERIFY.json
Get-ClusterNode -Cluster SQLAGCLUSTER
Get-ClusterQuorum -Cluster SQLAGCLUSTER
```

Task 5.3 verification:

```powershell
Get-Content C:\AOAGAutomation\WSFC\TASK_5_3_PRIMARY_READY.txt
Get-Content C:\AOAGAutomation\WSFC\TASK_5_3_SECONDARY_READY.txt
```

SQL1 should report the sample database online. SQL2 should report that the
database was restored with `NORECOVERY`; it will not be queryable on SQL2
until the availability group is created and the secondary is joined. After
Task 5.4, check the following markers on both nodes:

```powershell
Get-Content C:\AOAGAutomation\WSFC\TASK_5_4_AVAILABILITY_GROUP_READY.txt
```

After Task 5.5, check the listener marker on both nodes and verify the listener
catalog entries from SQL1:

```powershell
Get-Content C:\AOAGAutomation\WSFC\TASK_5_5_LISTENER_READY.txt
sqlcmd -E -C -S localhost -Q "SELECT dns_name, port, ip_configuration_string_from_cluster FROM sys.availability_group_listeners WHERE dns_name = 'AOAG-LSN'"
nslookup AOAG-LSN.mssqlaoag.demo
Test-NetConnection AOAG-LSN.mssqlaoag.demo -Port 1433
```

Connect in SSMS with Windows Authentication to `AOAG-LSN.mssqlaoag.demo` and
port `1433` after the marker exists. Failover testing is the next manual POC
step.

The Task 5.3 script is stored on SQL1 at:

```text
C:\AOAGAutomation\WSFC\04-prepare-sample-database.ps1
```

The Task 5.4 script is stored on SQL1 and SQL2 at:

```text
C:\AOAGAutomation\WSFC\05-configure-availability-group.ps1
```
