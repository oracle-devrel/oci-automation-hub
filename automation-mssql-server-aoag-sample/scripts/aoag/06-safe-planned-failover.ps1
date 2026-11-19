# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
[CmdletBinding()]
param(
    [string]$AvailabilityGroupName = "TestAOAG",
    [string]$DatabaseName = "AdventureWorks2025",
    [int]$ReadinessTimeoutMinutes = 30
)

$ErrorActionPreference = "Stop"

function Get-SqlCmdPath {
    $command = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $candidate = Get-ChildItem "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC" -Filter sqlcmd.exe -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $candidate) { throw "sqlcmd.exe was not found on $env:COMPUTERNAME." }
    $candidate.FullName
}

function ConvertTo-SqlLiteral {
    param([string]$Value)
    "N'" + $Value.Replace("'", "''") + "'"
}

function Invoke-LocalSql {
    param([string]$Query)

    $arguments = @(
        "-S", "localhost", "-E", "-C", "-b", "-r", "0",
        "-h", "-1", "-W", "-w", "65535", "-l", "60", "-Q", $Query
    )
    $output = & (Get-SqlCmdPath) @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) -join " | "
        throw "SQL command failed on $env:COMPUTERNAME`: $details"
    }
    @($output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
}

function Invoke-RemoteSql {
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,
        [Parameter(Mandatory)]
        [string]$Query
    )

    Invoke-Command -ComputerName $ComputerName -Authentication Kerberos -ErrorAction Stop -ScriptBlock {
        param([string]$RemoteQuery)
        $ErrorActionPreference = "Stop"
        $command = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
        if (-not $command) {
            $command = Get-ChildItem "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC" -Filter sqlcmd.exe -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
        if (-not $command) { throw "sqlcmd.exe was not found on $env:COMPUTERNAME." }
        $sqlcmdPath = if ($command -is [System.IO.FileInfo]) { $command.FullName } else { $command.Source }
        $output = & $sqlcmdPath -S localhost -E -C -b -r 0 -h -1 -W -w 65535 -l 60 -Q $RemoteQuery 2>&1
        if ($LASTEXITCODE -ne 0) {
            $details = ($output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) -join " | "
            throw "SQL command failed on $env:COMPUTERNAME`: $details"
        }
        @($output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
    } -ArgumentList $Query
}

$statusQuery = @"
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
WHERE ag.name = $(ConvertTo-SqlLiteral $AvailabilityGroupName)
  AND drs.database_id = DB_ID($(ConvertTo-SqlLiteral $DatabaseName));
"@

$partnerQuery = @"
SET NOCOUNT ON;
SELECT TOP (1) replica_server_name
FROM sys.availability_replicas
WHERE group_id = (SELECT group_id FROM sys.availability_groups WHERE name = $(ConvertTo-SqlLiteral $AvailabilityGroupName))
  AND replica_server_name <> @@SERVERNAME;
"@

function Get-StatusLine {
    param([string[]]$Output)
    $Output | ForEach-Object { [string]$_ } | Where-Object { $_ -match "\|" } | Select-Object -First 1
}

function Wait-ForLocalState {
    param(
        [Parameter(Mandatory)] [ValidateSet("PRIMARY", "SECONDARY")] [string]$ExpectedRole,
        [Parameter(Mandatory)] [string]$Node
    )

    $deadline = (Get-Date).AddMinutes($ReadinessTimeoutMinutes)
    $last = "no status"
    do {
        try {
            $output = if ($Node -ieq $env:COMPUTERNAME -or $Node -ieq "localhost") {
                Invoke-LocalSql -Query $statusQuery
            }
            else {
                Invoke-RemoteSql -ComputerName $Node -Query $statusQuery
            }
            $line = Get-StatusLine -Output $output
            if ($line) {
                $last = $line.Trim()
                Write-Host "$Node AG state: $last"
                if ($last -match "\|$ExpectedRole\|CONNECTED\|ONLINE\|SYNCHRONIZED\|HEALTHY\|0$") {
                    return $last
                }
            }
        }
        catch {
            Write-Host "Waiting for $Node to reach $ExpectedRole/CONNECTED/ONLINE/SYNCHRONIZED/HEALTHY: $($_.Exception.Message)"
        }

        if ((Get-Date) -ge $deadline) {
            throw "$Node did not reach $ExpectedRole/CONNECTED/ONLINE/SYNCHRONIZED/HEALTHY within $ReadinessTimeoutMinutes minutes. Last state: $last"
        }
        Start-Sleep -Seconds 30
    } while ($true)
}

# The command must be run on the synchronized target secondary. It is deliberately
# guarded so an unplanned outage cannot be mistaken for a safe planned failover.
$preflightDeadline = (Get-Date).AddMinutes($ReadinessTimeoutMinutes)
$preflightLast = "no local AG/database status"
do {
    try {
        $line = Get-StatusLine -Output (Invoke-LocalSql -Query $statusQuery)
        if ($line) {
            $preflightLast = $line.Trim()
            $fields = $preflightLast -split "\|", -1
            if ($fields.Count -ge 7) {
                $role = $fields[1]
                $connected = $fields[2]
                $databaseState = $fields[3]
                $syncState = $fields[4]
                $health = $fields[5]
                $suspended = $fields[6]
                Write-Host "Local preflight: role=$role connected=$connected database=$databaseState sync=$syncState health=$health suspended=$suspended"
                if ($role -eq "SECONDARY" -and $connected -eq "CONNECTED" -and
                    $databaseState -eq "ONLINE" -and $syncState -eq "SYNCHRONIZED" -and
                    $health -eq "HEALTHY" -and $suspended -eq "0") {
                    break
                }
            }
        }
    }
    catch {
        Write-Host "Waiting for a healthy secondary: $($_.Exception.Message)"
    }

    if ((Get-Date) -ge $preflightDeadline) {
        throw "Planned failover refused after $ReadinessTimeoutMinutes minutes. The local replica must be SECONDARY, CONNECTED, ONLINE, SYNCHRONIZED, HEALTHY, and not suspended. Current state: $preflightLast"
    }
    Start-Sleep -Seconds 30
} while ($true)

$partnerNode = (Invoke-LocalSql -Query $partnerQuery | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
if ([string]::IsNullOrWhiteSpace($partnerNode)) {
    throw "Could not identify the former primary replica from availability group $AvailabilityGroupName."
}

Write-Host "Preflight passed. Performing planned failover of $AvailabilityGroupName to $env:COMPUTERNAME."
Invoke-LocalSql -Query "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] FAILOVER;" | Out-Null

Wait-ForLocalState -ExpectedRole "PRIMARY" -Node $env:COMPUTERNAME | Out-Null
Wait-ForLocalState -ExpectedRole "SECONDARY" -Node $partnerNode | Out-Null

Write-Host "Planned failover completed. $env:COMPUTERNAME is primary and $partnerNode has rejoined as a synchronized secondary."
