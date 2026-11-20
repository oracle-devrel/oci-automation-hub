# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
[CmdletBinding()]
param(
    [string]$SecondaryNode = "SQL2",
    [string]$DatabaseName = "AdventureWorks2025",
    [string]$DownloadUrl = "https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2025.bak",
    [string]$BackupShare = "\\DC-VM.mssqlaoag.demo\ClusterWitness\SampleBackups",
    [string]$SetupDir = "C:\AOAGAutomation\WSFC",
    [string]$SqlServiceAccount = "MSSQLAOAG\sqlsa",
    [string]$SqlDataDriveLetter = "F"
)

$ErrorActionPreference = "Stop"
$DataLogicalName = "AdventureWorks2025_data"
$LogLogicalName = "AdventureWorks2025_Log"
$SampleDir = "C:\AOAGAutomation\WSFC\SampleDatabase"
$DataDir = "${SqlDataDriveLetter}:\SQLData"
$LogDir = "${SqlDataDriveLetter}:\SQLLogs"
$DataFile = Join-Path $DataDir "$DatabaseName.mdf"
$LogFile = Join-Path $LogDir "${DatabaseName}_log.ldf"
$LogPath = Join-Path $SetupDir "sample-database.log"

function Write-Log {
    param([string]$Message)
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    Add-Content -Path $LogPath -Value ("{0:s} {1}" -f (Get-Date), $Message)
}

function Get-SqlCmd {
    $command = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidate = Get-ChildItem "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC" -Filter sqlcmd.exe -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $candidate) { throw "sqlcmd.exe was not found on $env:COMPUTERNAME." }
    $candidate.FullName
}

function Invoke-Sql {
    param(
        [string]$Server,
        [string]$Query,
        [string]$Label = "SQL command",
        [switch]$Delimited
    )
    # Keep SQLCMD progress messages on stdout. With -r 1, normal STATS
    # messages are written to stderr and PowerShell treats them as errors
    # when ErrorActionPreference is Stop.
    $arguments = @("-S", $Server, "-E", "-C", "-b", "-r", "0", "-h", "-1", "-W", "-w", "65535", "-Q", $Query, "-l", "60")
    if ($Delimited) { $arguments += @("-s", "|") }
    $output = & (Get-SqlCmd) @arguments 2>&1
    $outputText = ($output | ForEach-Object { $_ | Out-String -Width 65535 } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join " | "
    if ($outputText) { Write-Log "$Label output on $Server`: $outputText" }
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed on $($Server). sqlcmd exit code=$LASTEXITCODE. Output: $outputText"
    }
    $output
}

function SqlLiteral {
    param([string]$Value)
    "N'" + $Value.Replace("'", "''") + "'"
}

function Get-BackupLogicalFiles {
    param([string]$BackupPath)

    $rows = Invoke-Sql `
        -Server "localhost" `
        -Query "RESTORE FILELISTONLY FROM DISK = $(SqlLiteral $BackupPath);" `
        -Delimited

    $files = foreach ($row in $rows) {
        $columns = ([string]$row).Trim() -split "\|", -1 | ForEach-Object { $_.Trim() }
        if ($columns.Count -ge 3 -and $columns[0] -and $columns[2] -in @("D", "L")) {
            [pscustomobject]@{
                LogicalName = $columns[0]
                Type        = $columns[2]
            }
        }
    }

    $dataFile = $files | Where-Object Type -eq "D" | Select-Object -First 1
    $logFile = $files | Where-Object Type -eq "L" | Select-Object -First 1
    if (-not $dataFile -or -not $logFile) {
        throw "Could not identify data and log logical files in backup $BackupPath. RESTORE FILELISTONLY output: $($rows -join ' | ')"
    }

    [pscustomobject]@{
        DataLogicalName = $dataFile.LogicalName
        LogLogicalName  = $logFile.LogicalName
    }
}

function Restore-Secondary {
    param(
        [string]$FullBackup,
        [string]$LogBackup,
        [string]$DataLogicalName,
        [string]$LogLogicalName
    )
    Invoke-Command -ComputerName $SecondaryNode -Authentication Kerberos -ErrorAction Stop -ScriptBlock {
        param($DbName, $FullPath, $LogPath, $DataFilePath, $LogFilePath, $DataLogicalFileName, $LogLogicalFileName, $SqlServiceAccountName)
        $ErrorActionPreference = "Stop"
        function Get-SqlCmdLocal {
            $command = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
            if ($command) { return $command.Source }
            $candidate = Get-ChildItem "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC" -Filter sqlcmd.exe -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $candidate) { throw "sqlcmd.exe was not found on $env:COMPUTERNAME." }
            $candidate.FullName
        }
        function Grant-SqlDirectoryAccess {
            param([string[]]$Paths, [string]$Account)
            foreach ($path in $Paths) {
                New-Item -ItemType Directory -Path $path -Force | Out-Null
                & icacls.exe $path /grant "${Account}:(OI)(CI)(M)" /T /C | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Could not grant $Account modify access to $path. icacls exit code=$LASTEXITCODE"
                }
            }
        }
        function Invoke-SqlLocal {
            param([string]$Query, [string]$Label = "SQL command", [switch]$Delimited)
            $arguments = @("-S", "localhost", "-E", "-C", "-b", "-r", "0", "-h", "-1", "-W", "-w", "65535", "-Q", $Query, "-l", "60")
            if ($Delimited) { $arguments += @("-s", "|") }
            $output = & (Get-SqlCmdLocal) @arguments 2>&1
            $outputText = ($output | ForEach-Object { $_ | Out-String -Width 65535 } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join " | "
            if ($LASTEXITCODE -ne 0) {
                throw "$Label failed on $($env:COMPUTERNAME). sqlcmd exit code=$LASTEXITCODE. Output: $outputText"
            }
            $output
        }
        function SqlLiteralLocal {
            param([string]$Value)
            "N'" + $Value.Replace("'", "''") + "'"
        }
        Remove-Item -LiteralPath "C:\AOAGAutomation\WSFC\TASK_5_3_SECONDARY_READY.txt" -Force -ErrorAction SilentlyContinue
        Grant-SqlDirectoryAccess -Paths @((Split-Path $DataFilePath), (Split-Path $LogFilePath)) -Account $SqlServiceAccountName
        $dropQuery = "IF DB_ID($(SqlLiteralLocal $DbName)) IS NOT NULL BEGIN ALTER DATABASE [$DbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DbName]; END;"
        Invoke-SqlLocal -Query $dropQuery -Label "Prepare secondary database $DbName" | Out-Null
        $restoreFullQuery = "RESTORE DATABASE [$DbName] FROM DISK = $(SqlLiteralLocal $FullPath) WITH FILE = 1, MOVE $(SqlLiteralLocal $DataLogicalFileName) TO $(SqlLiteralLocal $DataFilePath), MOVE $(SqlLiteralLocal $LogLogicalFileName) TO $(SqlLiteralLocal $LogFilePath), NORECOVERY, REPLACE, STATS = 5;"
        Invoke-SqlLocal -Query $restoreFullQuery -Label "Restore full backup of $DbName on secondary" | Out-Null
        $restoreLogQuery = "RESTORE LOG [$DbName] FROM DISK = $(SqlLiteralLocal $LogPath) WITH NORECOVERY, STATS = 5;"
        Invoke-SqlLocal -Query $restoreLogQuery -Label "Restore log backup of $DbName on secondary" | Out-Null
        Set-Content -Path "C:\AOAGAutomation\WSFC\TASK_5_3_SECONDARY_READY.txt" -Value "Task 5.3 complete: $DbName restored on $env:COMPUTERNAME with NORECOVERY." -Force
    } -ArgumentList @($DatabaseName, $FullBackup, $LogBackup, $DataFile, $LogFile, $DataLogicalName, $LogLogicalName, $SqlServiceAccount)
}

try {
    New-Item -ItemType Directory -Path $SampleDir, $DataDir, $LogDir, $BackupShare -Force | Out-Null
    Remove-Item -LiteralPath (Join-Path $SetupDir "TASK_5_3_PRIMARY_READY.txt") -Force -ErrorAction SilentlyContinue
    & icacls.exe $DataDir /grant "${SqlServiceAccount}:(OI)(CI)(M)" /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not grant $SqlServiceAccount modify access to $DataDir. icacls exit code=$LASTEXITCODE" }
    & icacls.exe $LogDir /grant "${SqlServiceAccount}:(OI)(CI)(M)" /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not grant $SqlServiceAccount modify access to $LogDir. icacls exit code=$LASTEXITCODE" }
    $sampleBak = Join-Path $SampleDir "$DatabaseName.bak"
    $fullBackup = Join-Path $BackupShare "$DatabaseName.full.bak"
    $logBackup = Join-Path $BackupShare "$DatabaseName.log.trn"
    if (-not (Test-Path $sampleBak)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $DownloadUrl -OutFile $sampleBak
    }
    try {
        $logicalFiles = Get-BackupLogicalFiles -BackupPath $sampleBak
    }
    catch {
        Write-Log "Existing sample backup could not be inspected; downloading a fresh copy. $($_.Exception.Message)"
        Remove-Item -LiteralPath $sampleBak -Force -ErrorAction SilentlyContinue
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $DownloadUrl -OutFile $sampleBak
        $logicalFiles = Get-BackupLogicalFiles -BackupPath $sampleBak
    }

    $DataLogicalName = $logicalFiles.DataLogicalName
    $LogLogicalName = $logicalFiles.LogLogicalName
    Write-Log "Backup logical files detected: data=$DataLogicalName, log=$LogLogicalName"
    $restoreQuery = "IF DB_ID($(SqlLiteral $DatabaseName)) IS NULL BEGIN RESTORE DATABASE [$DatabaseName] FROM DISK = $(SqlLiteral $sampleBak) WITH FILE = 1, MOVE $(SqlLiteral $DataLogicalName) TO $(SqlLiteral $DataFile), MOVE $(SqlLiteral $LogLogicalName) TO $(SqlLiteral $LogFile), RECOVERY, REPLACE, STATS = 5; END; ALTER DATABASE [$DatabaseName] SET RECOVERY FULL;"
    Invoke-Sql -Server "localhost" -Label "Prepare primary database $DatabaseName" -Query $restoreQuery | Out-Null
    $fullBackupQuery = "BACKUP DATABASE [$DatabaseName] TO DISK = $(SqlLiteral $fullBackup) WITH INIT, COMPRESSION, STATS = 5;"
    Invoke-Sql -Server "localhost" -Label "Create full backup of $DatabaseName" -Query $fullBackupQuery | Out-Null
    $logBackupQuery = "BACKUP LOG [$DatabaseName] TO DISK = $(SqlLiteral $logBackup) WITH INIT, COMPRESSION, STATS = 5;"
    Invoke-Sql -Server "localhost" -Label "Create log backup of $DatabaseName" -Query $logBackupQuery | Out-Null
    if (-not (Test-Path -LiteralPath $fullBackup)) { throw "Full backup was not created at $fullBackup" }
    if (-not (Test-Path -LiteralPath $logBackup)) { throw "Log backup was not created at $logBackup" }
    Restore-Secondary `
        -FullBackup $fullBackup `
        -LogBackup $logBackup `
        -DataLogicalName $DataLogicalName `
        -LogLogicalName $LogLogicalName
    Set-Content -Path (Join-Path $SetupDir "TASK_5_3_PRIMARY_READY.txt") -Value "Task 5.3 complete: $DatabaseName online on SQL1; full and log backups are on $BackupShare." -Force
    Write-Log "Task 5.3 complete. $DatabaseName is online on SQL1 and restoring on $SecondaryNode."
}
catch {
    Write-Log "ERROR: $($_ | Out-String -Width 65535)"
    throw
}
