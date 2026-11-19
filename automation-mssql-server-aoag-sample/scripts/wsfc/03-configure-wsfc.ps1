# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
[CmdletBinding()]
param(
    [string]$DomainName = "mssqlaoag.demo",
    [string]$DomainNetbiosName = "MSSQLAOAG",
    [string]$DomainAdminUser = "domainadmin",
    [string]$DomainAdminPassword,
    [string]$ClusterName = "SQLAGCLUSTER",
    [string]$ClusterNodes = "SQL1,SQL2",
    [string]$ClusterStaticAddresses = "10.0.20.20,10.0.30.20",
    [string]$WitnessShare = "\\DC-VM.mssqlaoag.demo\ClusterWitness",
    [string]$SqlInstanceName = "MSSQLSERVER",
    [string]$SqlServiceAccountUser = "sqlsa",
    [string]$AoagDatabaseName = "AdventureWorks2025",
    [string]$AoagAvailabilityGroupName = "TestAOAG",
    [string]$AoagListenerName = "AOAG-LSN",
    [int]$AoagListenerPort = 1433,
    [string]$AoagListenerIps = "10.0.20.30,10.0.30.30",
    [string]$HadrEndpointName = "Hadr_endpoint",
    [int]$HadrEndpointPort = 5022,
    [string]$SampleDatabaseDownloadUrl = "https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2025.bak",
    [string]$SetupDir = "C:\AOAGAutomation\WSFC",
    [switch]$SkipClusterValidation,
    [string]$SampleScriptPath = "C:\AOAGAutomation\WSFC\04-prepare-sample-database.ps1",
    [string]$AgScriptPath = "C:\AOAGAutomation\WSFC\05-configure-availability-group.ps1",
    [string]$SqlDataDriveLetter = "F",
    [switch]$RunAsDomainAdminChild
)

$ErrorActionPreference = "Stop"

$TaskName = "AOAG-Configure-WSFC"
$InstalledScriptPath = Join-Path $SetupDir "03-configure-wsfc.ps1"
$LogPath = Join-Path $SetupDir "configure-wsfc.log"
$ReadyPath = Join-Path $SetupDir "WSFC_READY.txt"
$AdPermissionReadyPath = Join-Path $SetupDir "TASK_5_1_AD_PERMISSION_READY.txt"
$StatusPath = Join-Path $SetupDir "WSFC_STATUS.txt"
$VerifyPath = Join-Path $SetupDir "WSFC_VERIFY.json"
$SecretPath = Join-Path $SetupDir "domainadmin-password.dpapi"
$SecretEntropy = "mssql-aoag-wsfc-bootstrap-v1"
$ClusterSettleSeconds = 30
$AlwaysOnSettleSeconds = 30
$AlwaysOnReadyTimeoutAttempts = 60
$FinalReadySettleSeconds = 30

$ClusterNodeList = @(
    $ClusterNodes -split "," |
    ForEach-Object { "$($_)".Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
$ClusterAddressList = @(
    $ClusterStaticAddresses -split "," |
    ForEach-Object { "$($_)".Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)

if ($ClusterNodeList.Count -lt 2) {
    throw "ClusterNodes must contain at least two non-empty node names. Received: '$ClusterNodes'."
}

function Write-Log {
    param([string]$Message)
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    $line = "{0:s} {1}" -f (Get-Date), $Message
    for ($i = 1; $i -le 20; $i++) {
        try {
            Add-Content -Path $LogPath -Value $line -ErrorAction Stop
            return
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
    }
}

function Write-Status {
    param([string]$Message)
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    for ($i = 1; $i -le 20; $i++) {
        try {
            Set-Content -Path $StatusPath -Value ("{0:s} {1}" -f (Get-Date), $Message) -Force -ErrorAction Stop
            break
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
    }
    Write-Log "STATUS: $Message"
}

function Wait-ForWsfcSettle {
    param(
        [Parameter(Mandatory)]
        [string]$Phase,
        [Parameter(Mandatory)]
        [int]$Seconds
    )

    Write-Status "settling-$Phase seconds=$Seconds"
    Write-Log "Waiting $Seconds seconds for $Phase cluster state to settle."
    Start-Sleep -Seconds $Seconds
}

function Set-StrictAcl {
    param([string]$Path)
    & icacls.exe $Path /inheritance:r /grant:r "SYSTEM:(F)" "Administrators:(F)" | Out-Null
}

function Protect-PlainText {
    param([string]$PlainText)
    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    $entropy = [Text.Encoding]::UTF8.GetBytes($SecretEntropy)
    $protected = [Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        $entropy,
        [Security.Cryptography.DataProtectionScope]::LocalMachine
    )
    [Convert]::ToBase64String($protected)
}

function Unprotect-PlainText {
    param([string]$ProtectedText)
    Add-Type -AssemblyName System.Security
    $bytes = [Convert]::FromBase64String($ProtectedText)
    $entropy = [Text.Encoding]::UTF8.GetBytes($SecretEntropy)
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $bytes,
        $entropy,
        [Security.Cryptography.DataProtectionScope]::LocalMachine
    )
    [Text.Encoding]::UTF8.GetString($plainBytes)
}

function Save-Secret {
    param([string]$PlainText)
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    Set-Content -Path $SecretPath -Value (Protect-PlainText -PlainText $PlainText) -Force
    Set-StrictAcl -Path $SecretPath
}

function Get-PlainPassword {
    if ($DomainAdminPassword) {
        Save-Secret -PlainText $DomainAdminPassword
        return $DomainAdminPassword
    }

    if (Test-Path $SecretPath) {
        return Unprotect-PlainText -ProtectedText (Get-Content -Path $SecretPath -Raw)
    }

    throw "DomainAdminPassword was not supplied and no stored domain-admin secret exists."
}

function Get-DomainCredential {
    $plain = Get-PlainPassword
    $secure = ConvertTo-SecureString $plain -AsPlainText -Force
    [pscredential]::new("$DomainAdminUser@$DomainName", $secure)
}

function Test-RunningAsDomainAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $domainSam = "$DomainNetbiosName\$DomainAdminUser"
    $domainUpn = "$DomainAdminUser@$DomainName"
    Write-Log "Running as $($identity.Name)"
    ($identity.Name -ieq $domainSam) -or ($identity.Name -ieq $domainUpn)
}

function Ensure-InstalledCopy {
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath) -and ($PSCommandPath -ne $InstalledScriptPath)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $InstalledScriptPath -Force
    }
    Set-StrictAcl -Path $InstalledScriptPath
}

function Start-AsDomainAdminIfNeeded {
    if ($RunAsDomainAdminChild -or (Test-RunningAsDomainAdmin)) {
        Write-Status "running-as-domain-admin"
        return
    }

    Write-Status "scheduling-domain-admin-child-task"
    $plain = Get-PlainPassword
    Ensure-InstalledCopy

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy Bypass",
        "-File `"$InstalledScriptPath`"",
        "-DomainName `"$DomainName`"",
        "-DomainNetbiosName `"$DomainNetbiosName`"",
        "-DomainAdminUser `"$DomainAdminUser`"",
        "-ClusterName `"$ClusterName`"",
        "-ClusterNodes `"$ClusterNodes`"",
        "-ClusterStaticAddresses `"$ClusterStaticAddresses`"",
        "-WitnessShare `"$WitnessShare`"",
        "-SqlInstanceName `"$SqlInstanceName`"",
        "-SqlServiceAccountUser `"$SqlServiceAccountUser`"",
        "-AoagDatabaseName `"$AoagDatabaseName`"",
        "-AoagAvailabilityGroupName `"$AoagAvailabilityGroupName`"",
        "-AoagListenerName `"$AoagListenerName`"",
        "-AoagListenerPort $AoagListenerPort",
        "-AoagListenerIps `"$AoagListenerIps`"",
        "-HadrEndpointName `"$HadrEndpointName`"",
        "-HadrEndpointPort $HadrEndpointPort",
        "-SampleDatabaseDownloadUrl `"$SampleDatabaseDownloadUrl`"",
        "-SetupDir `"$SetupDir`"",
        "-SampleScriptPath `"$SampleScriptPath`"",
        "-AgScriptPath `"$AgScriptPath`"",
        "-SqlDataDriveLetter `"$SqlDataDriveLetter`"",
        "-RunAsDomainAdminChild"
    )

    if ($SkipClusterValidation) {
        $args += "-SkipClusterValidation"
    }

    $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument ($args -join " ")
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
    $registeredAs = $null
    foreach ($runUser in @("$DomainAdminUser@$DomainName", "$DomainNetbiosName\$DomainAdminUser")) {
        try {
            Register-ScheduledTask `
                -TaskName $TaskName `
                -Action $action `
                -Trigger $trigger `
                -User $runUser `
                -Password $plain `
                -RunLevel Highest `
                -Force `
                -ErrorAction Stop | Out-Null
            $registeredAs = $runUser
            break
        }
        catch {
            Write-Log "Registering $TaskName as $runUser failed: $($_.Exception.Message)"
        }
    }

    if (-not $registeredAs) {
        throw "Could not register $TaskName as $DomainAdminUser. Check the domain admin password and account logon rights."
    }

    Write-Log "Registered $TaskName to run as $registeredAs"
    Start-ScheduledTask -TaskName $TaskName

    for ($i = 1; $i -le 240; $i++) {
        Start-Sleep -Seconds 30
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue

        if ($task -and $task.State -ne "Running" -and $info.LastTaskResult -ne 267009) {
            if ($info.LastTaskResult -eq 0) {
                Write-Status "domain-admin-child-task-complete"
                Write-Log "$TaskName completed successfully"
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
                exit 0
            }

            Write-Status "domain-admin-child-task-failed result=$($info.LastTaskResult)"
            throw "$TaskName failed. LastTaskResult=$($info.LastTaskResult). See $LogPath."
        }

        Write-Status "waiting-for-domain-admin-child-task attempt=$i"
        Write-Log "Waiting for $TaskName to finish. Attempt $i."
    }

    throw "$TaskName did not finish in time."
}

function Invoke-NodeCommand {
    param(
        [string]$Node,
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    $localNames = @($env:COMPUTERNAME, "localhost", "$env:COMPUTERNAME.$DomainName")
    if ($localNames -contains $Node) {
        & $ScriptBlock @ArgumentList
        return
    }

    $credential = Get-DomainCredential
    Invoke-Command -ComputerName $Node -Credential $credential -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
}

function Wait-ForNodeWinRm {
    param([string]$Node)

    $localNames = @($env:COMPUTERNAME, "localhost", "$env:COMPUTERNAME.$DomainName")
    if ($localNames -contains $Node) {
        return
    }

    $credential = Get-DomainCredential
    for ($i = 1; $i -le 120; $i++) {
        try {
            Test-WSMan -ComputerName $Node -Credential $credential -Authentication Kerberos -ErrorAction Stop | Out-Null
            Write-Log "WinRM is reachable on $Node"
            return
        }
        catch {
            Write-Status "waiting-for-winrm node=$Node attempt=$i"
            Write-Log "Waiting for WinRM on $Node. Attempt ${i}: $($_.Exception.Message)"
            Start-Sleep -Seconds 30
        }
    }

    throw "WinRM did not become reachable on $Node."
}

function Wait-ForSqlService {
    param([string]$Node)

    for ($i = 1; $i -le 180; $i++) {
        try {
            Invoke-NodeCommand -Node $Node -ScriptBlock {
                param($InstanceName)
                $serviceName = if ($InstanceName -eq "MSSQLSERVER") { "MSSQLSERVER" } else { "MSSQL`$$InstanceName" }
                $service = Get-Service -Name $serviceName -ErrorAction Stop
                if ($service.Status -ne "Running") {
                    Start-Service -Name $serviceName -ErrorAction Stop
                }
            } -ArgumentList @($SqlInstanceName)

            Write-Log "SQL Server service is available on $Node"
            return
        }
        catch {
            Write-Status "waiting-for-sql-service node=$Node attempt=$i"
            Write-Log "Waiting for SQL Server service on $Node. Attempt ${i}: $($_.Exception.Message)"
            Start-Sleep -Seconds 30
        }
    }

    throw "SQL Server service did not become available on $Node."
}

function Enable-NodePrerequisites {
    param([string]$Node)

    Write-Status "enabling-node-prerequisites node=$Node"
    Invoke-NodeCommand -Node $Node -ScriptBlock {
        Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools | Out-Null
        Install-WindowsFeature -Name RSAT-Clustering-PowerShell -IncludeAllSubFeature | Out-Null

        Set-Service -Name WinRM -StartupType Automatic
        Start-Service -Name WinRM -ErrorAction SilentlyContinue
        Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null

        foreach ($displayGroup in @("Failover Clusters", "Remote Service Management", "Windows Remote Management")) {
            Enable-NetFirewallRule -DisplayGroup $displayGroup -ErrorAction SilentlyContinue | Out-Null
        }

        foreach ($rule in @(
            @{ Name = "SQL Server TCP 1433"; Port = 1433 },
            @{ Name = "SQL AlwaysOn Endpoint TCP 5022"; Port = 5022 }
        )) {
            if (-not (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Protocol TCP -LocalPort $rule.Port -Action Allow -Profile Any | Out-Null
            }
            else {
                Enable-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }

    Write-Log "WSFC prerequisites confirmed on $Node"
}

function Enable-SqlAlwaysOn {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName
    )

    Write-Status "enabling-sql-always-on node=$ComputerName"
    Invoke-NodeCommand -Node $ComputerName -ScriptBlock {
        param($InstanceName, $ExpectedAccount, $ReadyTimeoutAttempts)

        $alwaysOnMarkerPath = "C:\AOAGAutomation\WSFC\TASK_5_2_ALWAYS_ON_READY.txt"
        Remove-Item -LiteralPath $alwaysOnMarkerPath -Force -ErrorAction SilentlyContinue

        $serviceName = if ($InstanceName -eq "MSSQLSERVER") { "MSSQLSERVER" } else { "MSSQL`$$InstanceName" }
        $actualAccount = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$serviceName").ObjectName
        if ($actualAccount -ine $ExpectedAccount) {
            throw "SQL Server service account is $actualAccount; expected $ExpectedAccount"
        }

        # Use the SQL Server WMI configuration provider, which is the API used
        # by SQL Server Configuration Manager. The registry key is not a
        # supported substitute on every SQL Server build.
        $enableSucceeded = $false
        $wmiFailure = $null
        try {
            $wmiAssembly = [Reflection.Assembly]::LoadWithPartialName("Microsoft.SqlServer.SqlWmiManagement")
            if (-not $wmiAssembly) {
                throw "Microsoft.SqlServer.SqlWmiManagement.dll was not found."
            }

            $managedComputer = New-Object -TypeName "Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer"
            $sqlService = @($managedComputer.Services | Where-Object { $_.Name -ieq $serviceName } | Select-Object -First 1)
            if (-not $sqlService) {
                throw "SQL Server WMI service $serviceName was not found."
            }

            if (-not [bool]$sqlService[0].IsHadrEnabled) {
                Write-Output "Enabling Always On through SQL Server WMI on $env:COMPUTERNAME."
                $sqlService[0].ChangeHadrServiceSetting($true)
                $sqlService[0].Refresh()
            }
            $enableSucceeded = [bool]$sqlService[0].IsHadrEnabled
        }
        catch {
            $wmiFailure = $_
        }

        if (-not $enableSucceeded) {
            # SQL Server PowerShell is the supported fallback when the WMI
            # assembly is not available in the installed shared tools.
            Import-Module SqlServer -Force -ErrorAction SilentlyContinue
            Import-Module SQLPS -Force -ErrorAction SilentlyContinue
            $enableCommand = Get-Command Enable-SqlAlwaysOn -ErrorAction SilentlyContinue
            if ($enableCommand -and $enableCommand.Parameters.ContainsKey("ServerInstance") -and $enableCommand.Parameters.ContainsKey("Force")) {
                $serverInstance = if ($InstanceName -eq "MSSQLSERVER") { $env:COMPUTERNAME } else { "$env:COMPUTERNAME\$InstanceName" }
                Write-Output "Enabling Always On through Enable-SqlAlwaysOn on $serverInstance."
                & $enableCommand.Name -ServerInstance $serverInstance -Force -ErrorAction Stop
                $enableSucceeded = $true
            }
        }

        if (-not $enableSucceeded) {
            $wmiMessage = if ($wmiFailure) { $wmiFailure.Exception.Message } else { "not available" }
            throw "Could not enable Always On on $env:COMPUTERNAME. SQL Server WMI failure: $wmiMessage. Enable-SqlAlwaysOn was also unavailable or did not complete."
        }

        Restart-Service -Name $serviceName -Force

        $agent = Get-Service -Name SQLSERVERAGENT -ErrorAction SilentlyContinue
        if ($agent) {
            Set-Service -Name SQLSERVERAGENT -StartupType Automatic
            Start-Service -Name SQLSERVERAGENT -ErrorAction SilentlyContinue
        }
        if ((Get-Service -Name $serviceName).Status -ne "Running") {
            throw "SQL Server service did not restart successfully"
        }

        $hadrValue = $null
        $hadrOutput = @()
        for ($attempt = 1; $attempt -le $ReadyTimeoutAttempts; $attempt++) {
            $hadrOutput = & sqlcmd.exe -E -C -S localhost -h -1 -W -Q "SET NOCOUNT ON; SELECT CONVERT(int, SERVERPROPERTY('IsHadrEnabled'));" 2>&1
            $hadrExitCode = $LASTEXITCODE
            $hadrValue = @(
                $hadrOutput |
                ForEach-Object { [string]$_ } |
                Where-Object { $_ -match '^\s*[01]\s*$' } |
                Select-Object -First 1
            )
            if ($hadrExitCode -eq 0 -and $hadrValue.Count -eq 1 -and $hadrValue[0].Trim() -eq "1") {
                break
            }

            Write-Output "Always On is not ready on $env:COMPUTERNAME after SQL restart; waiting attempt $attempt of $ReadyTimeoutAttempts."
            Start-Sleep -Seconds 10
        }

        if ($hadrValue.Count -ne 1 -or $hadrValue[0].Trim() -ne "1") {
            throw "SQL Server Always On verification failed on $env:COMPUTERNAME after waiting $ReadyTimeoutAttempts attempts. Expected an exact IsHadrEnabled value of 1; output: $($hadrOutput -join ' | ')"
        }

        Set-Content -Path $alwaysOnMarkerPath -Value "Task 5.2 complete: Always On enabled; service account $actualAccount" -Force
    } -ArgumentList @($SqlInstanceName, "$DomainNetbiosName\$SqlServiceAccountUser", $AlwaysOnReadyTimeoutAttempts)

    Write-Log "Always On availability groups enabled for $SqlInstanceName on $ComputerName"
}

function Prepare-SampleDatabase {
    if (-not (Test-Path -LiteralPath $SampleScriptPath)) {
        throw "Task 5.3 script was not injected at $SampleScriptPath; sample database preparation cannot continue."
    }

    Write-Status "preparing-sample-database"
    $backupShare = Join-Path -Path $WitnessShare -ChildPath "SampleBackups"
    & $SampleScriptPath `
        -SecondaryNode $ClusterNodeList[1] `
        -DatabaseName $AoagDatabaseName `
        -DownloadUrl $SampleDatabaseDownloadUrl `
        -BackupShare $backupShare `
        -SqlServiceAccount "$DomainNetbiosName\$SqlServiceAccountUser" `
        -SqlDataDriveLetter $SqlDataDriveLetter `
        -SetupDir $SetupDir

    $primaryMarker = Join-Path $SetupDir "TASK_5_3_PRIMARY_READY.txt"
    $secondaryMarker = Invoke-Command `
        -ComputerName $ClusterNodeList[1] `
        -Authentication Kerberos `
        -ErrorAction Stop `
        -ScriptBlock { Test-Path -LiteralPath "C:\AOAGAutomation\WSFC\TASK_5_3_SECONDARY_READY.txt" }

    if (-not (Test-Path -LiteralPath $primaryMarker)) {
        throw "Task 5.3 did not create $primaryMarker"
    }
    if (-not $secondaryMarker) {
        throw "Task 5.3 did not create the secondary NORECOVERY marker on $($ClusterNodeList[1])"
    }

    Write-Log "Task 5.3 sample database script completed."
}

function Configure-AvailabilityGroup {
    if (-not (Test-Path -LiteralPath $AgScriptPath)) {
        throw "Task 5.4/5.5 script was not injected at $AgScriptPath; availability group and listener configuration cannot continue."
    }

    Write-Status "creating-availability-group-and-listener"
    & $AgScriptPath `
        -PrimaryNode $ClusterNodeList[0] `
        -SecondaryNode $ClusterNodeList[1] `
        -DomainName $DomainName `
        -AvailabilityGroupName $AoagAvailabilityGroupName `
        -DatabaseName $AoagDatabaseName `
        -EndpointName $HadrEndpointName `
        -EndpointPort $HadrEndpointPort `
        -ListenerName $AoagListenerName `
        -ListenerPort $AoagListenerPort `
        -ListenerIps $AoagListenerIps `
        -SqlServiceAccount "$DomainNetbiosName\$SqlServiceAccountUser" `
        -SetupDir $SetupDir

    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "Task 5.4/5.5 availability group and listener script failed with exit code $LASTEXITCODE. See $SetupDir\configure-availability-group.log."
    }

    Write-Log "Task 5.4/5.5 availability group and listener script completed."
}

function Get-DomainDistinguishedName {
    ($DomainName -split "\." | ForEach-Object { "DC=$_" }) -join ","
}

function Get-WitnessServerName {
    $match = [regex]::Match($WitnessShare, '^\\\\([^\\]+)\\')
    if (-not $match.Success) {
        throw "WitnessShare must be a UNC path such as \\DC-VM.$DomainName\ClusterWitness"
    }

    $match.Groups[1].Value
}

function Remove-StaleClusterComputerAccount {
    $credential = Get-DomainCredential
    $dcHost = Get-WitnessServerName

    try {
        Write-Log "Checking DC $dcHost for stale cluster computer account $ClusterName`$"
        $result = Invoke-Command `
            -ComputerName $dcHost `
            -Credential $credential `
            -Authentication Kerberos `
            -ErrorAction Stop `
            -ScriptBlock {
                param([string]$Name)

                Import-Module ActiveDirectory -ErrorAction Stop
                $ldapFilter = "(sAMAccountName=$Name`$)"
                $computer = Get-ADComputer -LDAPFilter $ldapFilter -ErrorAction SilentlyContinue

                if (-not $computer) {
                    return [pscustomobject]@{
                        Found   = $false
                        Removed = $false
                        Name    = $Name
                    }
                }

                $distinguishedName = $computer.DistinguishedName
                Disable-ADAccount -Identity $computer -ErrorAction SilentlyContinue
                Remove-ADComputer -Identity $computer -Confirm:$false -ErrorAction Stop

                for ($attempt = 1; $attempt -le 6; $attempt++) {
                    if (-not (Get-ADComputer -LDAPFilter $ldapFilter -ErrorAction SilentlyContinue)) {
                        return [pscustomobject]@{
                            Found               = $true
                            Removed             = $true
                            Name                = $Name
                            DistinguishedName   = $distinguishedName
                        }
                    }
                    Start-Sleep -Seconds 2
                }

                throw "AD computer account $Name`$ still exists after removal"
            } `
            -ArgumentList $ClusterName

        if ($result.Removed) {
            Write-Log "Removed stale cluster computer account $ClusterName`$ from $dcHost"
        }
        elseif ($result.Found) {
            throw "Stale cluster computer account $ClusterName`$ was found but was not removed"
        }
        else {
            Write-Log "No stale cluster computer account found for $ClusterName`$"
        }
    }
    catch {
        throw "Stale cluster computer account cleanup failed on $($dcHost): $($_.Exception.Message)"
    }
}

function Grant-ClusterCreateComputerPermission {
    Write-Status "granting-cluster-ad-permission"
    Add-Type -AssemblyName System.DirectoryServices
    $domainDn = Get-DomainDistinguishedName
    for ($attempt = 1; $attempt -le 18; $attempt++) {
        try {
            $container = [DirectoryServices.DirectoryEntry]::new("LDAP://CN=Computers,$domainDn")
            $identity = [Security.Principal.NTAccount]::new("$DomainNetbiosName\$ClusterName`$")
            $rule = [DirectoryServices.ActiveDirectoryAccessRule]::new(
                $identity,
                [DirectoryServices.ActiveDirectoryRights]::CreateChild,
                [Security.AccessControl.AccessControlType]::Allow,
                [Guid]"bf967a86-0de6-11d0-a285-00aa003049e2"
            )
            $acl = $container.ObjectSecurity
            $acl.AddAccessRule($rule)
            $acl.AddAccessRule([DirectoryServices.ActiveDirectoryAccessRule]::new(
                    $identity,
                    [DirectoryServices.ActiveDirectoryRights]::ReadProperty,
                    [Security.AccessControl.AccessControlType]::Allow,
                    [DirectoryServices.ActiveDirectorySecurityInheritance]::All
                ))
            $container.ObjectSecurity = $acl
            $container.CommitChanges()
            Set-Content -Path $AdPermissionReadyPath -Value "Task 5.1 complete: Create Computer objects and Read all properties" -Force
            Write-Log "Granted $ClusterName`$ Create Computer objects and Read all properties in CN=Computers"
            return
        }
        catch {
            if ($attempt -eq 18) { throw }
            Write-Log "Waiting to grant cluster AD permission. Attempt $attempt. $($_.Exception.Message)"
            Start-Sleep -Seconds 10
        }
    }
}

function Ensure-Cluster {
    Import-Module FailoverClusters -ErrorAction Stop

    $existing = Get-Cluster -Name $ClusterName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Remove-StaleClusterComputerAccount

        if (-not $SkipClusterValidation) {
            Write-Status "running-cluster-validation"
            Write-Log "Running cluster validation for $($ClusterNodeList -join ', ')"
            Test-Cluster -Node $ClusterNodeList -WarningAction SilentlyContinue | Out-Null
        }
        else {
            Write-Log "Skipping cluster validation by request"
        }

        Write-Status "creating-cluster name=$ClusterName"
        Write-Log "Creating cluster $ClusterName with nodes $($ClusterNodeList -join ', ') and IPs $($ClusterAddressList -join ', ')"
        New-Cluster -Name $ClusterName -Node $ClusterNodeList -StaticAddress $ClusterAddressList -NoStorage | Out-Null
    }
    else {
        Write-Status "cluster-already-exists name=$ClusterName"
        Write-Log "Cluster $ClusterName already exists"
    }

    Write-Status "configuring-file-share-witness"
    Write-Log "Configuring file share witness $WitnessShare"
    for ($attempt = 1; $attempt -le 18; $attempt++) {
        try {
            Set-ClusterQuorum -FileShareWitness $WitnessShare -ErrorAction Stop | Out-Null
            break
        }
        catch {
            if ($attempt -eq 18) { throw }
            Write-Status "waiting-for-cluster-quorum attempt=$attempt"
            Write-Log "Cluster is not ready for quorum configuration. Attempt $attempt. $($_.Exception.Message)"
            Start-Sleep -Seconds 10
        }
    }
}

try {
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    Write-Log "WSFC automation started"
    Write-Status "starting"

    Start-AsDomainAdminIfNeeded

    foreach ($node in $ClusterNodeList) {
        Write-Status "processing-node node=$node"
        Wait-ForNodeWinRm -Node $node
        Wait-ForSqlService -Node $node
        Enable-NodePrerequisites -Node $node
    }

    Ensure-Cluster
    Grant-ClusterCreateComputerPermission
    Wait-ForWsfcSettle -Phase "after-cluster-and-witness" -Seconds $ClusterSettleSeconds

    Write-Log "Always On target nodes: $($ClusterNodeList -join ', ')"
    foreach ($clusterNode in $ClusterNodeList) {
        $targetNode = "$clusterNode".Trim()
        if ([string]::IsNullOrWhiteSpace($targetNode)) {
            throw "A blank node name was found while enabling Always On. ClusterNodes='$ClusterNodes'."
        }
        Enable-SqlAlwaysOn -ComputerName $targetNode
    }

    Wait-ForWsfcSettle -Phase "after-always-on" -Seconds $AlwaysOnSettleSeconds
    Prepare-SampleDatabase
    Configure-AvailabilityGroup

    $verify = [ordered]@{
        cluster_name              = $ClusterName
        cluster_nodes             = $ClusterNodeList
        cluster_static_addresses  = $ClusterAddressList
        witness_share             = $WitnessShare
        sql_instance_name         = $SqlInstanceName
        completed_utc             = (Get-Date).ToUniversalTime().ToString("o")
    }
    Wait-ForWsfcSettle -Phase "before-ready-marker" -Seconds $FinalReadySettleSeconds
    $verify | ConvertTo-Json | Set-Content -Path $VerifyPath -Force
    Set-Content -Path $ReadyPath -Value "WSFC $ClusterName ready. Witness: $WitnessShare" -Force
    Write-Status "complete"
    Remove-Item -Path $SecretPath -Force -ErrorAction SilentlyContinue
    Write-Log "WSFC automation complete"
}
catch {
    Write-Status "failed: $($_.Exception.Message)"
    Write-Log "ERROR: $($_ | Out-String -Width 65535)"
    throw
}
