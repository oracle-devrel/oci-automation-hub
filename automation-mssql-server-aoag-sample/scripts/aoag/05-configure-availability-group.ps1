# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
[CmdletBinding()]
param(
    [string]$PrimaryNode = "SQL1",
    [string]$SecondaryNode = "SQL2",
    [string]$DomainName = "mssqlaoag.demo",
    [string]$AvailabilityGroupName = "TestAOAG",
    [string]$DatabaseName = "AdventureWorks2025",
    [string]$EndpointName = "Hadr_endpoint",
    [int]$EndpointPort = 5022,
    [string]$ListenerName = "AOAG-LSN",
    [int]$ListenerPort = 1433,
    [string]$ListenerIps = "10.0.20.30,10.0.30.30",
    [string]$SqlServiceAccount = "MSSQLAOAG\sqlsa",
    [string]$SetupDir = "C:\AOAGAutomation\WSFC"
)

$ErrorActionPreference = "Stop"
$LogPath = Join-Path $SetupDir "configure-availability-group.log"
$PrimaryReadyPath = Join-Path $SetupDir "TASK_5_4_AVAILABILITY_GROUP_READY.txt"
$ListenerReadyPath = Join-Path $SetupDir "TASK_5_5_LISTENER_READY.txt"

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
    if ($command) {
        return $command.Source
    }

    $candidate = Get-ChildItem "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC" -Filter sqlcmd.exe -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $candidate) {
        throw "sqlcmd.exe was not found on $env:COMPUTERNAME."
    }

    $candidate.FullName
}

function ConvertTo-SqlLiteral {
    param([string]$Value)
    "N'" + $Value.Replace("'", "''") + "'"
}

function Invoke-LocalSql {
    param([string]$Query)

    $arguments = @(
        "-S", "localhost",
        "-E",
        "-C",
        "-b",
        "-r", "0",
        "-h", "-1",
        "-W",
        "-w", "65535",
        "-l", "60",
        "-Q", $Query
    )
    $output = & (Get-SqlCmdPath) @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) -join " | "
        throw "SQL command failed on $env:COMPUTERNAME`: $details"
    }

    $output
}

function Invoke-RemoteSql {
    param(
        [string]$Node,
        [string]$Query
    )

    Invoke-Command -ComputerName $Node -Authentication Kerberos -ErrorAction Stop -ScriptBlock {
        param([string]$RemoteQuery)

        $ErrorActionPreference = "Stop"
        $command = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
        if (-not $command) {
            $command = Get-ChildItem "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC" -Filter sqlcmd.exe -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
        }
        if (-not $command) {
            throw "sqlcmd.exe was not found on $env:COMPUTERNAME."
        }

        $sqlcmdPath = if ($command -is [System.IO.FileInfo]) { $command.FullName } else { $command.Source }
        $arguments = @(
            "-S", "localhost",
            "-E",
            "-C",
            "-b",
            "-r", "0",
            "-h", "-1",
            "-W",
            "-w", "65535",
            "-l", "60",
            "-Q", $RemoteQuery
        )
        $output = & $sqlcmdPath @arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            $details = ($output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) -join " | "
            throw "SQL command failed on $env:COMPUTERNAME`: $details"
        }

        $output
    } -ArgumentList $Query
}

function Ensure-HadrEndpoint {
    param([string]$Node)

    Write-Log "Ensuring $EndpointName on $Node"
    $query = @"
IF NOT EXISTS (SELECT 1 FROM sys.endpoints WHERE name = $(ConvertTo-SqlLiteral $EndpointName))
BEGIN
    CREATE ENDPOINT [$EndpointName]
        STATE = STARTED
        AS TCP (LISTENER_PORT = $EndpointPort)
        FOR DATABASE_MIRRORING
        (
            AUTHENTICATION = WINDOWS NEGOTIATE,
            ENCRYPTION = REQUIRED ALGORITHM AES,
            ROLE = ALL
        );
END
ELSE IF EXISTS (SELECT 1 FROM sys.endpoints WHERE name = $(ConvertTo-SqlLiteral $EndpointName) AND state_desc <> N'STARTED')
BEGIN
    ALTER ENDPOINT [$EndpointName] STATE = STARTED;
END;

IF SUSER_ID($(ConvertTo-SqlLiteral $SqlServiceAccount)) IS NULL
BEGIN
    CREATE LOGIN [$SqlServiceAccount] FROM WINDOWS;
END;

IF SUSER_ID($(ConvertTo-SqlLiteral $SqlServiceAccount)) IS NOT NULL
BEGIN
    GRANT CONNECT ON ENDPOINT::[$EndpointName] TO [$SqlServiceAccount];
END;
"@

    if ($Node -ieq $env:COMPUTERNAME -or $Node -ieq "localhost") {
        Invoke-LocalSql -Query $query | Out-Null
    }
    else {
        Invoke-RemoteSql -Node $Node -Query $query | Out-Null
    }
}

function Test-HadrEndpoint {
    param([string]$Node)

    $query = @"
SELECT CONCAT(
    e.name COLLATE DATABASE_DEFAULT,
    N'|',
    e.state_desc COLLATE DATABASE_DEFAULT,
    N'|',
    CONVERT(nvarchar(10), te.port)
)
FROM sys.endpoints AS e
INNER JOIN sys.tcp_endpoints AS te ON te.endpoint_id = e.endpoint_id
WHERE e.name = $(ConvertTo-SqlLiteral $EndpointName);
"@
    $output = if ($Node -ieq $env:COMPUTERNAME -or $Node -ieq "localhost") {
        Invoke-LocalSql -Query $query
    }
    else {
        Invoke-RemoteSql -Node $Node -Query $query
    }

    $line = ($output | ForEach-Object { [string]$_ } | Where-Object { $_ -match "\|STARTED\|$EndpointPort" } | Select-Object -First 1)
    if (-not $line) {
        throw "HADR endpoint $EndpointName is not STARTED on $Node at port $EndpointPort. Output: $($output -join ' | ')"
    }
}

function Wait-ForDatabaseState {
    param(
        [string]$Node,
        [string]$ExpectedState
    )

    $query = "SELECT state_desc FROM sys.databases WHERE name = $(ConvertTo-SqlLiteral $DatabaseName);"
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $output = if ($Node -ieq $env:COMPUTERNAME -or $Node -ieq "localhost") {
                Invoke-LocalSql -Query $query
            }
            else {
                Invoke-RemoteSql -Node $Node -Query $query
            }
            if (($output -join " ") -match "\b$([regex]::Escape($ExpectedState))\b") {
                Write-Log "$DatabaseName is $ExpectedState on $Node"
                return
            }
        }
        catch {
            Write-Log "Waiting for $DatabaseName on $Node attempt $attempt`: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 10
    }

    throw "$DatabaseName did not reach $ExpectedState on $Node."
}

function Create-AvailabilityGroup {
    $primaryEndpoint = "TCP://$PrimaryNode.$DomainName`:$EndpointPort"
    $secondaryEndpoint = "TCP://$SecondaryNode.$DomainName`:$EndpointPort"
    $query = @"
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = $(ConvertTo-SqlLiteral $AvailabilityGroupName))
BEGIN
    CREATE AVAILABILITY GROUP [$AvailabilityGroupName]
    WITH (CLUSTER_TYPE = WSFC)
    FOR DATABASE [$DatabaseName]
    REPLICA ON
        N'$PrimaryNode' WITH
        (
            ENDPOINT_URL = N'$primaryEndpoint',
            AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
            FAILOVER_MODE = AUTOMATIC,
            SEEDING_MODE = MANUAL
        ),
        N'$SecondaryNode' WITH
        (
            ENDPOINT_URL = N'$secondaryEndpoint',
            AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
            FAILOVER_MODE = AUTOMATIC,
            SEEDING_MODE = MANUAL
        );
END
"@
    Invoke-LocalSql -Query $query | Out-Null
}

function Join-SecondaryReplica {
    Write-Log "Joining $SecondaryNode to availability group $AvailabilityGroupName"
    $joinQuery = @"
IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = $(ConvertTo-SqlLiteral $AvailabilityGroupName))
BEGIN
    ALTER AVAILABILITY GROUP [$AvailabilityGroupName] JOIN WITH (CLUSTER_TYPE = WSFC);
END
"@
    Invoke-RemoteSql -Node $SecondaryNode -Query $joinQuery | Out-Null

    $databaseQuery = @"
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = $(ConvertTo-SqlLiteral $DatabaseName) AND state_desc = N'RESTORING')
BEGIN
    ALTER DATABASE [$DatabaseName] SET HADR AVAILABILITY GROUP = [$AvailabilityGroupName];
END
"@
    Invoke-RemoteSql -Node $SecondaryNode -Query $databaseQuery | Out-Null
}

function Wait-ForSynchronization {
    $query = @"
SELECT CONCAT(
    ar.replica_server_name COLLATE DATABASE_DEFAULT,
    N'|',
    ars.role_desc COLLATE DATABASE_DEFAULT,
    N'|',
    drs.database_state_desc COLLATE DATABASE_DEFAULT,
    N'|',
    drs.synchronization_state_desc COLLATE DATABASE_DEFAULT,
    N'|',
    drs.synchronization_health_desc COLLATE DATABASE_DEFAULT
)
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = drs.replica_id
WHERE drs.database_id = DB_ID($(ConvertTo-SqlLiteral $DatabaseName));
"@

    for ($attempt = 1; $attempt -le 60; $attempt++) {
        $output = Invoke-LocalSql -Query $query
        Write-Log "AG health attempt $attempt`: $($output -join ' | ')"
        $healthText = $output -join " "
        if ($healthText -match "$PrimaryNode\|PRIMARY\|ONLINE\|SYNCHRONIZED\|HEALTHY" -and
            $healthText -match "$SecondaryNode\|SECONDARY\|ONLINE\|SYNCHRONIZED\|HEALTHY") {
            return
        }
        Start-Sleep -Seconds 10
    }

    throw "Availability group $AvailabilityGroupName did not reach synchronized/healthy state. See $LogPath."
}

function Enable-AutomaticFailover {
    $query = @"
ALTER AVAILABILITY GROUP [$AvailabilityGroupName]
MODIFY REPLICA ON N'$PrimaryNode'
WITH (FAILOVER_MODE = AUTOMATIC);

ALTER AVAILABILITY GROUP [$AvailabilityGroupName]
MODIFY REPLICA ON N'$SecondaryNode'
WITH (FAILOVER_MODE = AUTOMATIC);
"@

    Write-Log "Enabling automatic failover after synchronized/healthy state was confirmed"
    Invoke-LocalSql -Query $query | Out-Null
}

function Verify-AutomaticFailover {
    $query = @"
SELECT CONCAT(
    replica_server_name COLLATE DATABASE_DEFAULT,
    N'|',
    failover_mode_desc COLLATE DATABASE_DEFAULT
)
FROM sys.availability_replicas
WHERE group_id = (SELECT group_id FROM sys.availability_groups WHERE name = $(ConvertTo-SqlLiteral $AvailabilityGroupName));
"@

    $output = Invoke-LocalSql -Query $query
    $text = ($output -join " ")
    Write-Log "Automatic failover verification: $text"
    if ($text -notmatch "$PrimaryNode\|AUTOMATIC" -or $text -notmatch "$SecondaryNode\|AUTOMATIC") {
        throw "Automatic failover verification failed. Expected AUTOMATIC for $PrimaryNode and $SecondaryNode; output: $text"
    }
}

function Ensure-AvailabilityGroupListener {
    $ipClauses = ($ListenerIpList | ForEach-Object {
            "(N'$_', N'255.255.255.0')"
        }) -join ",`n        "

    $query = @"
SET NOCOUNT ON;
IF NOT EXISTS (
    SELECT 1
    FROM sys.availability_group_listeners
    WHERE dns_name = $(ConvertTo-SqlLiteral $ListenerName)
)
BEGIN
    ALTER AVAILABILITY GROUP [$AvailabilityGroupName]
    ADD LISTENER N'$ListenerName'
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
WHERE dns_name = $(ConvertTo-SqlLiteral $ListenerName);
"@

    $listenerIpQuery = @"
SET NOCOUNT ON;
SELECT CONVERT(nvarchar(50), ip_address)
FROM sys.availability_group_listener_ip_addresses AS ip
JOIN sys.availability_group_listeners AS l
    ON l.listener_id = ip.listener_id
WHERE l.dns_name = $(ConvertTo-SqlLiteral $ListenerName);
"@

    $lastError = $null
    for ($attempt = 1; $attempt -le 36; $attempt++) {
        try {
            Write-Log "Stage 5.5.1: ensuring listener $ListenerName attempt $attempt with IPs $($ListenerIpList -join ', ')"
            Invoke-LocalSql -Query $query | Out-Null

            $output = Invoke-LocalSql -Query $verifyQuery
            $expected = "$ListenerName|$ListenerPort"
            $line = $output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() -eq $expected } | Select-Object -First 1
            if (-not $line) {
                throw "Listener name/port was not visible yet. Output: $($output -join ' | ')"
            }

            $ipOutput = Invoke-LocalSql -Query $listenerIpQuery
            foreach ($listenerIp in $ListenerIpList) {
                if (-not ($ipOutput | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() -eq $listenerIp })) {
                    throw "Listener IP $listenerIp was not visible yet. Output: $($ipOutput -join ' | ')"
                }
            }

            Write-Log "Stage 5.5.2: listener $ListenerName verified with IPs $($ListenerIpList -join ', ')"
            return
        }
        catch {
            $lastError = $_.Exception.Message
            if ($attempt -eq 36) {
                throw "Availability group listener $ListenerName was not created or verified after 6 minutes. Last error: $lastError"
            }
            Write-Log "Listener is not ready yet; retrying in 10 seconds: $lastError"
            Start-Sleep -Seconds 10
        }
    }
}

try {
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    Write-Log "Task 5.4/5.5 availability group and listener automation started"
    Write-Log "Stage 5.4.1: verifying database states"
    Wait-ForDatabaseState -Node $PrimaryNode -ExpectedState "ONLINE"
    Wait-ForDatabaseState -Node $SecondaryNode -ExpectedState "RESTORING"

    Write-Log "Stage 5.4.2: ensuring HADR endpoints"
    Ensure-HadrEndpoint -Node $PrimaryNode
    Ensure-HadrEndpoint -Node $SecondaryNode
    Write-Log "Stage 5.4.3: validating HADR endpoints"
    Test-HadrEndpoint -Node $PrimaryNode
    Test-HadrEndpoint -Node $SecondaryNode

    Write-Log "Stage 5.4.4: creating availability group $AvailabilityGroupName"
    Create-AvailabilityGroup
    Write-Log "Stage 5.4.5: joining secondary replica and database"
    Join-SecondaryReplica
    Write-Log "Stage 5.4.6: waiting for synchronization"
    Wait-ForSynchronization
    Write-Log "Stage 5.4.7: enabling automatic failover after synchronization"
    Enable-AutomaticFailover
    Verify-AutomaticFailover

    # Create the listener before publishing readiness markers. A failure here
    # must be visible in the WSFC task instead of leaving a healthy AG with no
    # client endpoint.
    Ensure-AvailabilityGroupListener

    Set-Content -Path $PrimaryReadyPath -Value "Task 5.4 complete: $AvailabilityGroupName created with $PrimaryNode primary and $SecondaryNode synchronized for $DatabaseName. Automatic failover verified." -Force
    try {
        Invoke-Command -ComputerName $SecondaryNode -Authentication Kerberos -ErrorAction Stop -ScriptBlock {
            param($MarkerPath, $Message)
            Set-Content -Path $MarkerPath -Value $Message -Force
        } -ArgumentList @(
            "C:\AOAGAutomation\WSFC\TASK_5_4_AVAILABILITY_GROUP_READY.txt",
            "Task 5.4 complete: $AvailabilityGroupName joined on $env:COMPUTERNAME and synchronized for $DatabaseName. Automatic failover verified."
        )
    }
    catch {
        Write-Log "Warning: could not publish the Task 5.4 marker to ${SecondaryNode}: $($_.Exception.Message)"
    }
    Write-Log "Task 5.4 availability group automation completed"

    Set-Content -Path $ListenerReadyPath -Value "Task 5.5 complete: $ListenerName configured on port $ListenerPort with IPs $($ListenerIpList -join ', ')." -Force
    try {
        Invoke-Command -ComputerName $SecondaryNode -Authentication Kerberos -ErrorAction Stop -ScriptBlock {
            param($MarkerPath, $Message)
            Set-Content -Path $MarkerPath -Value $Message -Force
        } -ArgumentList @(
            "C:\AOAGAutomation\WSFC\TASK_5_5_LISTENER_READY.txt",
            "Task 5.5 complete: $ListenerName configured on port $ListenerPort with IPs $($ListenerIpList -join ', ')."
        )
    }
    catch {
        Write-Log "Warning: could not publish the Task 5.5 marker to ${SecondaryNode}: $($_.Exception.Message)"
    }
    Write-Log "Task 5.5 listener automation completed"
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    throw
}
