# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
[CmdletBinding()]
param(
    [string]$AvailabilityGroupName = "TestAOAG",
    [string]$DatabaseName = "AdventureWorks2025",
    [string]$ClusterName = "SQLAGCLUSTER",
    [string]$ListenerName = "AOAG-LSN",
    [int]$ListenerPort = 1433,
    [string]$ListenerIps = "10.0.20.30,10.0.30.30",
    [int]$ReadinessTimeoutMinutes = 60,
    [string]$SetupDir = "C:\AOAGAutomation\WSFC"
)

$ErrorActionPreference = "Stop"
$LogPath = Join-Path $SetupDir "reconcile-availability-group.log"
$ReadyPath = Join-Path $SetupDir "AG_RECONCILIATION_READY.txt"
$ListenerIpList = @(
    $ListenerIps -split "," |
    ForEach-Object { "$($_)".Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

if ($ListenerIpList.Count -lt 2) {
    throw "ListenerIps must contain both SQL subnet listener addresses. Received: '$ListenerIps'."
}

function Write-Log {
    param([string]$Message)
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    Add-Content -Path $LogPath -Value ("{0:s} {1}" -f (Get-Date), $Message)
}

function Get-SqlCmdPath {
    $command = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidate = Get-ChildItem "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC" -Filter sqlcmd.exe -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $candidate) { throw "sqlcmd.exe was not found on $env:COMPUTERNAME." }
    $candidate.FullName
}

function SqlLiteral {
    param([string]$Value)
    "N'" + $Value.Replace("'", "''") + "'"
}

function Invoke-LocalSql {
    param([string]$Query)
    $output = & (Get-SqlCmdPath) -S localhost -E -C -b -r 0 -h -1 -W -w 65535 -l 60 -Q $Query 2>&1
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) -join " | "
        throw "SQL command failed on $env:COMPUTERNAME`: $details"
    }
    @($output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
}

function Wait-ForClusterNode {
    Import-Module FailoverClusters -ErrorAction Stop
    $deadline = (Get-Date).AddMinutes($ReadinessTimeoutMinutes)
    do {
        try {
            $clusterService = Get-Service -Name ClusSvc -ErrorAction Stop
            if ($clusterService.Status -ne "Running") {
                Start-Service -Name ClusSvc -ErrorAction Stop
                Start-Sleep -Seconds 10
            }
            $localNode = Get-ClusterNode -Cluster $ClusterName -Name $env:COMPUTERNAME -ErrorAction Stop
            if ($localNode.State -eq "Up") {
                Write-Log "Cluster node $env:COMPUTERNAME is Up."
                return
            }

            Write-Log "Cluster node state is $($localNode.State); clearing quarantine and starting the node."
            Start-ClusterNode -Name $env:COMPUTERNAME -ClearQuarantine -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Log "Waiting for WSFC node readiness: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 30
    } while ((Get-Date) -lt $deadline)

    throw "Cluster node $env:COMPUTERNAME did not reach Up within $ReadinessTimeoutMinutes minutes."
}

function Wait-ForSqlService {
    $deadline = (Get-Date).AddMinutes($ReadinessTimeoutMinutes)
    do {
        try {
            $service = Get-Service -Name MSSQLSERVER -ErrorAction Stop
            if ($service.Status -ne "Running") {
                Start-Service -Name MSSQLSERVER -ErrorAction Stop
            }
            if ((Get-Service -Name MSSQLSERVER).Status -eq "Running") {
                return
            }
        }
        catch {
            Write-Log "Waiting for SQL Server service: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)

    throw "SQL Server did not reach Running within $ReadinessTimeoutMinutes minutes."
}

function Wait-ForHealthyLocalReplica {
    $query = @"
SET NOCOUNT ON;
SELECT CONCAT(
    ar.replica_server_name COLLATE DATABASE_DEFAULT, N'|',
    ars.role_desc COLLATE DATABASE_DEFAULT, N'|',
    ars.connected_state_desc COLLATE DATABASE_DEFAULT, N'|',
    drs.database_state_desc COLLATE DATABASE_DEFAULT, N'|',
    drs.synchronization_state_desc COLLATE DATABASE_DEFAULT, N'|',
    drs.synchronization_health_desc COLLATE DATABASE_DEFAULT, N'|',
    CONVERT(nvarchar(5), drs.is_suspended)
)
FROM sys.availability_groups AS ag
JOIN sys.availability_replicas AS ar ON ar.group_id = ag.group_id
JOIN sys.dm_hadr_availability_replica_states AS ars
    ON ars.group_id = ar.group_id AND ars.replica_id = ar.replica_id AND ars.is_local = 1
JOIN sys.dm_hadr_database_replica_states AS drs
    ON drs.group_id = ag.group_id AND drs.replica_id = ar.replica_id
WHERE ag.name = $(SqlLiteral $AvailabilityGroupName)
  AND drs.database_id = DB_ID($(SqlLiteral $DatabaseName));
"@

    $deadline = (Get-Date).AddMinutes($ReadinessTimeoutMinutes)
    $last = "no AG/database status"
    do {
        try {
            $rows = Invoke-LocalSql -Query $query
            if ($rows.Count -gt 0) {
                $last = ($rows -join " | ").Trim()
                Write-Log "Local AG state: $last"
                if ($rows -match "\|(?:PRIMARY|SECONDARY)\|CONNECTED\|ONLINE\|SYNCHRONIZED\|HEALTHY\|0$") {
                    return
                }
            }
            else {
                Write-Log "AG/database status is not visible yet."
            }
        }
        catch {
            Write-Log "Waiting for AG recovery/synchronization: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 30
    } while ((Get-Date) -lt $deadline)

    throw "Local AG replica did not return to CONNECTED/ONLINE/SYNCHRONIZED/HEALTHY within $ReadinessTimeoutMinutes minutes. Last state: $last"
}

function Ensure-AvailabilityGroupListener {
    $ipClauses = ($ListenerIpList | ForEach-Object {
            "(N'$_', N'255.255.255.0')"
        }) -join ",`n        "

    $createQuery = @"
SET NOCOUNT ON;
IF NOT EXISTS (
    SELECT 1
    FROM sys.availability_group_listeners
    WHERE dns_name = N'$($ListenerName.Replace("'", "''"))'
)
BEGIN
    ALTER AVAILABILITY GROUP [$AvailabilityGroupName]
    ADD LISTENER N'$($ListenerName.Replace("'", "''"))'
    (
        WITH IP
        (
            $ipClauses
        ),
        PORT = $ListenerPort
    );
END;
"@

    $verifyQuery = @"
SET NOCOUNT ON;
SELECT CONCAT(
    dns_name COLLATE DATABASE_DEFAULT,
    N'|',
    CONVERT(nvarchar(10), port)
)
FROM sys.availability_group_listeners
WHERE dns_name = N'$($ListenerName.Replace("'", "''"))';
"@

    $listenerIpQuery = @"
SET NOCOUNT ON;
SELECT CONVERT(nvarchar(50), ip_address)
FROM sys.availability_group_listener_ip_addresses AS ip
JOIN sys.availability_group_listeners AS l
    ON l.listener_id = ip.listener_id
WHERE l.dns_name = N'$($ListenerName.Replace("'", "''"))';
"@

    $roleQuery = @"
SET NOCOUNT ON;
SELECT ars.role_desc
FROM sys.dm_hadr_availability_replica_states AS ars
WHERE ars.is_local = 1;
"@

    for ($attempt = 1; $attempt -le 36; $attempt++) {
        try {
            $role = [string]((Invoke-LocalSql -Query $roleQuery) | Select-Object -First 1)
            $role = $role.Trim()
            if ($role -eq "PRIMARY") {
                Write-Log "Ensuring listener $ListenerName from primary $env:COMPUTERNAME attempt $attempt"
                Invoke-LocalSql -Query $createQuery | Out-Null
            }
            else {
                Write-Log "Local replica role is '$role'; the primary owns listener creation. Verifying listener state locally."
            }

            $expected = "$ListenerName|$ListenerPort"
            $listener = Invoke-LocalSql -Query $verifyQuery
            if (-not ($listener | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() -eq $expected })) {
                throw "Listener name/port is not visible yet. Output: $($listener -join ' | ')"
            }

            $ipOutput = Invoke-LocalSql -Query $listenerIpQuery
            foreach ($listenerIp in $ListenerIpList) {
                if (-not ($ipOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() -eq $listenerIp })) {
                    throw "Listener IP $listenerIp is not visible yet. Output: $($ipOutput -join ' | ')"
                }
            }
            Write-Log "Listener $ListenerName verified with IPs $($ListenerIpList -join ', ')"
            return
        }
        catch {
            if ($attempt -eq 36) { throw }
            Write-Log "Listener reconciliation attempt $attempt failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 10
        }
    }
}

try {
    Write-Log "Post-reboot AG reconciliation started on $env:COMPUTERNAME."
    Wait-ForSqlService
    Wait-ForClusterNode
    Wait-ForHealthyLocalReplica
    Ensure-AvailabilityGroupListener
    Set-Content -Path $ReadyPath -Value "Local AG replica and listener $ListenerName are healthy and synchronized on $env:COMPUTERNAME." -Force
    Write-Log "Post-reboot AG reconciliation completed on $env:COMPUTERNAME."
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    throw
}
