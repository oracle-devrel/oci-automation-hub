# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
[CmdletBinding()]
param(
    [string]$DomainName = "mssqlaoag.demo",
    [string]$DomainNetbiosName = "MSSQLAOAG",
    [string]$DomainAdminUser = "domainadmin",
    [string]$DomainAdminPassword,
    [string]$SqlServiceAccountUser = "sqlsa",
    [string]$SqlServiceAccountPassword,
    [string]$AutoInstallSqlServer = "true",
    [string]$InstallSsms = "true",
    [string]$SqlServerDownloadUrl = "https://go.microsoft.com/fwlink/?linkid=2344626",
    [string]$SsmsDownloadUrl = "https://aka.ms/ssms/22/release/vs_SSMS.exe",
    [string]$AutoConfigureWsfc = "true",
    [string]$WsfcClusterName = "SQLAGCLUSTER",
    [string]$WsfcPrimaryNode = "SQL1",
    [string]$WsfcClusterNodes = "SQL1,SQL2",
    [string]$WsfcClusterStaticAddresses = "10.0.20.20,10.0.30.20",
    [string]$WsfcWitnessShare = "\\DC-VM.mssqlaoag.demo\ClusterWitness",
    [string]$SkipClusterValidation = "true",
    [string]$AoagDatabaseName = "AdventureWorks2025",
    [string]$AoagAvailabilityGroupName = "TestAOAG",
    [string]$AoagListenerName = "AOAG-LSN",
    [string]$AoagListenerPort = "1433",
    [string]$AoagListenerIps = "10.0.20.30,10.0.30.30",
    [string]$HadrEndpointName = "Hadr_endpoint",
    [string]$HadrEndpointPort = "5022",
    [string]$SampleDatabaseDownloadUrl = "https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2025.bak",
    [string]$WsfcScriptPath = "C:\AOAGAutomation\WSFC\03-configure-wsfc.ps1",
    [string]$SampleScriptPath = "C:\AOAGAutomation\WSFC\04-prepare-sample-database.ps1",
    [string]$AgScriptPath = "C:\AOAGAutomation\WSFC\05-configure-availability-group.ps1",
    [string]$ReconcileScriptPath = "C:\AOAGAutomation\WSFC\07-reconcile-availability-group.ps1",
    [string]$LocalAdminUser = "opc",
    [string]$LocalAdminPassword,
    [string]$TargetComputerName = "SQL1",
    [string]$DcHostName = "DC-VM",
    [string]$DcPrivateIp = "10.0.10.10",
    [string]$SqlDataDriveLetter = "F",
    [string]$SetupDir = "C:\AOAGAutomation\Windows"
)

$ErrorActionPreference = "Stop"

$LogPath = Join-Path $SetupDir "windows-bootstrap.log"
$ReadyPath = Join-Path $SetupDir "WINDOWS_BOOTSTRAP_READY.txt"
$StatusPath = Join-Path $SetupDir "WINDOWS_BOOTSTRAP_STATUS.txt"
$StagePath = Join-Path $SetupDir "stage.txt"
$InstalledScriptPath = Join-Path $SetupDir "02-configure-sql-node.ps1"
$TaskName = "AOAG-Configure-WindowsNode"
$BootstrapMutexName = "Global\AOAG-$TargetComputerName-WindowsBootstrap"
$BootstrapMutex = $null
$BootstrapMutexAcquired = $false

$DomainJoinSettleSeconds = 30
$PostInstallSettleSeconds = 60
$PreWsfcSettleSeconds = 30
$AutoInstallSqlServerEnabled = [System.Convert]::ToBoolean($AutoInstallSqlServer)
$InstallSsmsEnabled = [System.Convert]::ToBoolean($InstallSsms)
$AutoConfigureWsfcEnabled = [System.Convert]::ToBoolean($AutoConfigureWsfc)
$SkipClusterValidationEnabled = [System.Convert]::ToBoolean($SkipClusterValidation)
$InstallerDir = Join-Path $SetupDir "Installers"
$SqlMediaDir = Join-Path $SetupDir "SQLMedia"
# The persistent OCI block volume may not be initialized or assigned a drive
# letter when this script starts. These paths are populated after the volume
# is available so a missing F: cannot prevent the domain-join stage.
$SqlDataRoot = $null
$SqlDataDir = $null
$SqlBackupDir = $null
$SqlLogDir = $null

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

function Enter-BootstrapMutex {
    $script:BootstrapMutex = [Threading.Mutex]::new($false, $BootstrapMutexName)
    $script:BootstrapMutexAcquired = $script:BootstrapMutex.WaitOne(0)

    if (-not $script:BootstrapMutexAcquired) {
        $skipPath = Join-Path $SetupDir "duplicate-bootstrap-skipped.log"
        Add-Content -Path $skipPath -Value ("{0:s} Another SQL node bootstrap instance is already running; exiting duplicate launch." -f (Get-Date)) -ErrorAction SilentlyContinue
        exit 0
    }
}

function Exit-BootstrapMutex {
    if ($script:BootstrapMutexAcquired -and $script:BootstrapMutex) {
        $script:BootstrapMutex.ReleaseMutex()
        $script:BootstrapMutex.Dispose()
    }
}

function Set-StrictAcl {
    param([string]$Path)
    & icacls.exe $Path /inheritance:r /grant:r "SYSTEM:(F)" "Administrators:(F)" | Out-Null
}

function Get-Stage {
    if (Test-Path $StagePath) {
        return (Get-Content -Path $StagePath -Raw).Trim()
    }

    "rename"
}

function Set-Stage {
    param([string]$Stage)
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    Set-Content -Path $StagePath -Value $Stage -Force
    Write-Status "stage=$Stage"
    Write-Log "Stage set to $Stage"
}

function Wait-ForBootstrapSettle {
    param(
        [Parameter(Mandatory)]
        [string]$Phase,
        [Parameter(Mandatory)]
        [int]$Seconds
    )

    Write-Status "settling-$Phase seconds=$Seconds"
    Write-Log "Waiting $Seconds seconds for $Phase services and network state to settle."
    Start-Sleep -Seconds $Seconds
}

function Write-CommandOutput {
    param(
        [string]$Label,
        [object[]]$Output
    )

    foreach ($line in $Output) {
        if ($null -ne $line -and "$line" -ne "") {
            Write-Log "$Label $line"
        }
    }
}

function Invoke-NetCommand {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & net.exe @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Convert-SecureStringToPlainText {
    param([securestring]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Write-ErrorDetails {
    param(
        [string]$Context,
        [object]$ErrorRecord
    )

    Write-Log "$($Context): $($ErrorRecord.Exception.Message)"
    $details = $ErrorRecord | Out-String
    foreach ($line in ($details -split "`r?`n")) {
        if ($line.Trim()) {
            Write-Log "$($Context) detail: $line"
        }
    }
}

function Add-LocalGroupMemberByNet {
    param(
        [string]$Group,
        [string]$Member
    )

    $groupResult = Invoke-NetCommand -Arguments @("localgroup", $Group, $Member, "/add")
    Write-CommandOutput -Label "net localgroup $($Group):" -Output $groupResult.Output

    $groupOutput = ($groupResult.Output -join "`n")
    $alreadyMember = ($groupResult.ExitCode -eq 1378) -or
        ($groupOutput -match "System error 1378") -or
        ($groupOutput -match "already a member of the group")

    if ($alreadyMember) {
        Write-Log "$Member is already a member of $Group; continuing."
    }
    elseif ($groupResult.ExitCode -ne 0) {
        throw "Failed to add $Member to $Group. net.exe exit code $($groupResult.ExitCode)."
    }
}

function Set-LocalAdminPassword {
    if ([string]::IsNullOrWhiteSpace($LocalAdminPassword)) {
        throw "LocalAdminPassword was not supplied. Set windows_admin_password or provide LocalAdminPassword."
    }

    $adminResult = Invoke-NetCommand -Arguments @("user", "Administrator", $LocalAdminPassword, "/logonpasswordchg:no", "/active:yes")
    Write-CommandOutput -Label "net user Administrator:" -Output $adminResult.Output
    if ($adminResult.ExitCode -ne 0) {
        throw "Failed to configure local Administrator account. net.exe exit code $($adminResult.ExitCode)."
    }

    if ($LocalAdminUser -and $LocalAdminUser -ne "Administrator") {
        $userResult = Invoke-NetCommand -Arguments @("user", $LocalAdminUser, $LocalAdminPassword, "/logonpasswordchg:no", "/active:yes")
        Write-CommandOutput -Label "net user $($LocalAdminUser):" -Output $userResult.Output

        if ($userResult.ExitCode -ne 0) {
            $addUserResult = Invoke-NetCommand -Arguments @("user", $LocalAdminUser, $LocalAdminPassword, "/add", "/logonpasswordchg:no", "/active:yes")
            Write-CommandOutput -Label "net user $LocalAdminUser /add:" -Output $addUserResult.Output
            if ($addUserResult.ExitCode -ne 0) {
                throw "Failed to create local $LocalAdminUser account. net.exe exit code $($addUserResult.ExitCode)."
            }
        }

        Add-LocalGroupMemberByNet -Group "Administrators" -Member $LocalAdminUser
        Add-LocalGroupMemberByNet -Group "Remote Desktop Users" -Member $LocalAdminUser
    }
}

function Enable-LabRdp {
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null
    Write-Log "Enabled Remote Desktop firewall rules"
}

function Enable-LabWinRm {
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service -Name WinRM -ErrorAction SilentlyContinue
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    foreach ($displayGroup in @("Windows Remote Management", "Remote Service Management")) {
        Enable-NetFirewallRule -DisplayGroup $displayGroup -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Log "Enabled WinRM and PowerShell remoting"
}

function Set-DomainDns {
    Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses @($DcPrivateIp)
            Set-DnsClient -InterfaceIndex $_.ifIndex -ConnectionSpecificSuffix $DomainName -RegisterThisConnectionsAddress $true -ErrorAction SilentlyContinue
            Write-Log "Set DNS server on adapter $($_.Name) to $DcPrivateIp"
        }
        catch {
            Write-Log "DNS update warning on adapter $($_.Name): $($_.Exception.Message)"
        }
    }

    try {
        Set-DnsClientGlobalSetting -SuffixSearchList @($DomainName) -ErrorAction SilentlyContinue
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        Write-Log "Set DNS suffix search list to $DomainName and cleared DNS cache"
    }
    catch {
        Write-Log "DNS suffix/cache warning: $($_.Exception.Message)"
    }
}

function Register-ResumeTask {
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null

    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath) -and ($PSCommandPath -ne $InstalledScriptPath)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $InstalledScriptPath -Force
        Set-StrictAcl -Path $InstalledScriptPath
        Write-Log "Persisted Windows node automation script to $InstalledScriptPath"
    }

    $scriptPath = if (Test-Path -LiteralPath $InstalledScriptPath) { $InstalledScriptPath } else { $PSCommandPath }
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        throw "Unable to determine Windows node automation script path for resume task."
    }

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy Bypass",
        "-File `"$scriptPath`"",
        "-DomainName `"$DomainName`"",
        "-DomainNetbiosName `"$DomainNetbiosName`"",
        "-DomainAdminUser `"$DomainAdminUser`"",
        "-DomainAdminPassword `"$DomainAdminPassword`"",
        "-SqlServiceAccountUser `"$SqlServiceAccountUser`"",
        "-SqlServiceAccountPassword `"$SqlServiceAccountPassword`"",
        "-AutoInstallSqlServer `"$AutoInstallSqlServer`"",
        "-InstallSsms `"$InstallSsms`"",
        "-SqlServerDownloadUrl `"$SqlServerDownloadUrl`"",
        "-SsmsDownloadUrl `"$SsmsDownloadUrl`"",
        "-AutoConfigureWsfc `"$AutoConfigureWsfc`"",
        "-WsfcClusterName `"$WsfcClusterName`"",
        "-WsfcPrimaryNode `"$WsfcPrimaryNode`"",
        "-WsfcClusterNodes `"$WsfcClusterNodes`"",
        "-WsfcClusterStaticAddresses `"$WsfcClusterStaticAddresses`"",
        "-WsfcWitnessShare `"$WsfcWitnessShare`"",
        "-SkipClusterValidation `"$SkipClusterValidation`"",
        "-AoagDatabaseName `"$AoagDatabaseName`"",
        "-AoagAvailabilityGroupName `"$AoagAvailabilityGroupName`"",
        "-AoagListenerName `"$AoagListenerName`"",
        "-AoagListenerPort `"$AoagListenerPort`"",
        "-AoagListenerIps `"$AoagListenerIps`"",
        "-HadrEndpointName `"$HadrEndpointName`"",
        "-HadrEndpointPort `"$HadrEndpointPort`"",
        "-SampleDatabaseDownloadUrl `"$SampleDatabaseDownloadUrl`"",
        "-WsfcScriptPath `"$WsfcScriptPath`"",
        "-SampleScriptPath `"$SampleScriptPath`"",
        "-AgScriptPath `"$AgScriptPath`"",
        "-ReconcileScriptPath `"$ReconcileScriptPath`"",
        "-LocalAdminUser `"$LocalAdminUser`"",
        "-LocalAdminPassword `"$LocalAdminPassword`"",
        "-TargetComputerName `"$TargetComputerName`"",
        "-DcHostName `"$DcHostName`"",
        "-DcPrivateIp `"$DcPrivateIp`"",
        "-SqlDataDriveLetter `"$SqlDataDriveLetter`"",
        "-SetupDir `"$SetupDir`""
    ) -join " "

    $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $args
    $trigger = New-ScheduledTaskTrigger -AtStartup
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -User "SYSTEM" -RunLevel Highest -Force | Out-Null
    Write-Log "Registered resume task $TaskName"
}

function Remove-ResumeTask {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Get-DomainCredentials {
    if ([string]::IsNullOrWhiteSpace($DomainAdminPassword)) {
        throw "DomainAdminPassword was not supplied. Set domain_admin_password before enabling SQL node automation."
    }

    $securePassword = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
    $userNames = @(
        "$DomainAdminUser@$DomainName",
        "$DomainNetbiosName\$DomainAdminUser"
    ) | Select-Object -Unique

    foreach ($userName in $userNames) {
        [pscredential]::new($userName, $securePassword)
    }
}

function Get-DomainDistinguishedName {
    ($DomainName -split "\." | ForEach-Object { "DC=$_" }) -join ","
}

function Remove-StaleComputerAccount {
    param([pscredential]$Credential)

    try {
        Add-Type -AssemblyName System.DirectoryServices
        $plainPassword = Convert-SecureStringToPlainText -SecureString $Credential.Password
        $domainDn = Get-DomainDistinguishedName
        $root = [System.DirectoryServices.DirectoryEntry]::new(
            "LDAP://$DomainName/$domainDn",
            $Credential.UserName,
            $plainPassword,
            [System.DirectoryServices.AuthenticationTypes]::Secure
        )
        $searcher = [System.DirectoryServices.DirectorySearcher]::new($root)
        $searcher.Filter = "(&(objectCategory=computer)(sAMAccountName=$TargetComputerName`$))"
        $searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
        $result = $searcher.FindOne()

        if ($result) {
            $entry = $result.GetDirectoryEntry()
            if ($entry -and $entry.Parent) {
                $parent = $entry.Parent
                Write-Log "Removing stale domain computer account $TargetComputerName`$ before domain join retry"
                $parent.Children.Remove($entry)
                $parent.CommitChanges()
            }
            else {
                Write-Log "Stale domain computer account $TargetComputerName`$ was found, but its parent container was not available; continuing without cleanup."
            }
        }
        else {
            Write-Log "No stale domain computer account found for $TargetComputerName`$"
        }
    }
    catch {
        Write-ErrorDetails -Context "Stale computer account cleanup warning" -ErrorRecord $_
    }
}

function Test-DomainReachable {
    Set-DomainDns

    try {
        $dns = Test-NetConnection -ComputerName $DcPrivateIp -Port 53 -WarningAction SilentlyContinue
        if (-not $dns.TcpTestSucceeded) {
            Write-Log "DNS TCP 53 to $DcPrivateIp is not reachable yet."
            return $false
        }

        $ldap = Test-NetConnection -ComputerName $DcPrivateIp -Port 389 -WarningAction SilentlyContinue
        if (-not $ldap.TcpTestSucceeded) {
            Write-Log "LDAP TCP 389 to $DcPrivateIp is not reachable yet."
            return $false
        }
    }
    catch {
        Write-Log "Domain port reachability check failed: $($_.Exception.Message)"
        return $false
    }

    $srvName = "_ldap._tcp.dc._msdcs.$DomainName"
    try {
        Resolve-DnsName -Name $srvName -Type SRV -Server $DcPrivateIp -ErrorAction Stop | Out-Null
        Write-Log "Resolved AD DC locator SRV record $srvName"
        return $true
    }
    catch {
        Write-Log "AD DC locator SRV record $srvName is not resolvable yet: $($_.Exception.Message)"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $nltestOutput = & nltest.exe "/dsgetdc:$DomainName" "/server:$DcPrivateIp" 2>&1
        $nltestExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    Write-CommandOutput -Label "nltest:" -Output $nltestOutput
    if ($nltestExitCode -eq 0) {
        Write-Log "nltest found a domain controller for $DomainName"
        return $true
    }

    Write-Log "nltest could not find a domain controller for $DomainName. Exit code $nltestExitCode."
    return $false
}

function Wait-ForDomain {
    for ($i = 1; $i -le 120; $i++) {
        if (Test-DomainReachable) {
            Write-Log "Domain $DomainName is reachable through DC $DcPrivateIp"
            return
        }

        Write-Status "waiting-for-domain attempt=$i"
        Write-Log "Waiting for domain $DomainName attempt $($i)"
        Start-Sleep -Seconds 15
    }

    throw "Domain $DomainName did not become reachable through $DcPrivateIp in time."
}

function Test-DomainAdminCredential {
    param([pscredential]$Credential)

    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
        $context = [System.DirectoryServices.AccountManagement.PrincipalContext]::new(
            [System.DirectoryServices.AccountManagement.ContextType]::Domain,
            $DomainName
        )
        try {
            $plainPassword = Convert-SecureStringToPlainText -SecureString $Credential.Password
            foreach ($userName in @($DomainAdminUser, $Credential.UserName)) {
                try {
                    if ($context.ValidateCredentials(
                            $userName,
                            $plainPassword,
                            [System.DirectoryServices.AccountManagement.ContextOptions]::Negotiate
                        )) {
                        return $true
                    }
                }
                catch {
                    Write-Log "Credential validation warning for $($userName): $($_.Exception.Message)"
                }
            }
        }
        finally {
            $context.Dispose()
        }
    }
    catch {
        Write-Log "Domain credential validation could not run yet: $($_.Exception.Message)"
    }

    return $false
}

function Test-JoinedToDomain {
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    $computerSystem.PartOfDomain -and ($computerSystem.Domain -ieq $DomainName)
}

function Add-DomainAdminToLocalGroups {
    $domainMember = "$DomainNetbiosName\$DomainAdminUser"
    Add-LocalGroupMemberByNet -Group "Administrators" -Member $domainMember
    Add-LocalGroupMemberByNet -Group "Remote Desktop Users" -Member $domainMember
}

function Join-DomainWithRetry {
    $credentials = @(Get-DomainCredentials)
    $maxAttempts = 18

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        Wait-ForDomain

        $validCredential = $false
        foreach ($credential in $credentials) {
            if (Test-DomainAdminCredential -Credential $credential) {
                $validCredential = $true
                break
            }
        }
        if (-not $validCredential) {
            # PrincipalContext can reject a credential from a workgroup host even
            # when the same credential is valid for Add-Computer. Do not make this
            # advisory check a gate; Add-Computer provides the definitive result.
            Write-Log "Credential pre-check did not validate $DomainAdminUser; proceeding with Add-Computer so the domain join can provide the authoritative error."
        }

        if (Test-JoinedToDomain) {
            Write-Log "$TargetComputerName is already joined to $DomainName"
            return
        }

        foreach ($credential in $credentials) {
            Remove-StaleComputerAccount -Credential $credential

            try {
                Write-Status "joining-domain attempt=$attempt credential=$($credential.UserName)"
                Write-Log "Joining $TargetComputerName to domain $DomainName through $($DcHostName).$DomainName as $($credential.UserName). Attempt $attempt of $maxAttempts."
                & w32tm.exe /resync /force 2>&1 | ForEach-Object { Write-Log "w32tm: $_" }
                Add-Computer `
                    -DomainName $DomainName `
                    -Server "$DcHostName.$DomainName" `
                    -Credential $credential `
                    -Force `
                    -ErrorAction Stop
                Write-Log "Domain join command succeeded for $TargetComputerName as $($credential.UserName)"
                return
            }
            catch {
                Write-ErrorDetails -Context "Domain join through $($DcHostName).$DomainName attempt $attempt with $($credential.UserName) failed" -ErrorRecord $_
                try {
                    Write-Log "Retrying domain join without an explicit domain controller."
                    Add-Computer -DomainName $DomainName -Credential $credential -Force -ErrorAction Stop
                    Write-Log "Domain join command succeeded without explicit domain controller for $TargetComputerName as $($credential.UserName)"
                    return
                }
                catch {
                    Write-ErrorDetails -Context "Domain join fallback attempt $attempt with $($credential.UserName) failed" -ErrorRecord $_
                }
            }
        }

        if ($attempt -eq $maxAttempts) {
            throw "All domain join attempts failed for $TargetComputerName. Check that $DomainNetbiosName\$DomainAdminUser can log in with the password used by Terraform."
        }

        Set-DomainDns
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        Write-Log "Waiting 60 seconds before retrying domain join"
        Start-Sleep -Seconds 60
    }
}

function Invoke-FileDownload {
    param(
        [string]$Url,
        [string]$Destination
    )

    if (Test-Path $Destination) {
        Write-Log "Installer already exists: $Destination"
        return
    }

    New-Item -ItemType Directory -Path (Split-Path -Path $Destination -Parent) -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Log "Downloading $Url to $Destination"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-Log "Download failed with domain DNS; temporarily using OCI/public DNS: $($_.Exception.Message)"
        $adapters = @(Get-NetAdapter | Where-Object { $_.Status -eq "Up" })
        try {
            foreach ($adapter in $adapters) {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @("169.254.169.254", "1.1.1.1")
            }
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
        }
        finally {
            Set-DomainDns
        }
    }
}

function Invoke-InstallerProcess {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$Label,
        [int[]]$SuccessExitCodes = @(0, 3010, 1641)
    )

    Write-Log "Starting $Label"
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru
    Write-Log "$Label finished with exit code $($process.ExitCode)"

    if ($SuccessExitCodes -notcontains $process.ExitCode) {
        throw "$Label failed with exit code $($process.ExitCode)"
    }

    return $process.ExitCode
}

function Test-SqlServerInstalled {
    $service = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
    return $null -ne $service
}

function Enable-SqlFirewallRules {
    $rules = @(
        @{ Name = "SQL Server TCP 1433"; Port = 1433 },
        @{ Name = "SQL AlwaysOn Endpoint TCP 5022"; Port = 5022 }
    )

    foreach ($rule in $rules) {
        if (-not (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Protocol TCP -LocalPort $rule.Port -Action Allow -Profile Any | Out-Null
            Write-Log "Created firewall rule $($rule.Name)"
        }
        else {
            Enable-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Confirmed firewall rule $($rule.Name)"
        }
    }
}

function Enable-WsfcFirewallRules {
    foreach ($displayGroup in @("Failover Clusters", "Remote Service Management", "Windows Remote Management")) {
        Enable-NetFirewallRule -DisplayGroup $displayGroup -ErrorAction SilentlyContinue | Out-Null
    }
}

function Install-WsfcPrerequisites {
    Write-Log "Installing or confirming Failover Clustering features"
    Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools | Out-Null
    Install-WindowsFeature -Name RSAT-Clustering-PowerShell -IncludeAllSubFeature | Out-Null
    Enable-WsfcFirewallRules
    Write-Log "Failover Clustering features confirmed"
}

function Enable-SqlTcpStaticPort {
    $instanceNamesPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"
    if (-not (Test-Path $instanceNamesPath)) {
        Write-Log "SQL instance registry path was not found yet; skipping TCP static port registry configuration."
        return
    }

    $instanceId = (Get-ItemProperty -Path $instanceNamesPath).MSSQLSERVER
    if (-not $instanceId) {
        Write-Log "Default SQL instance name was not found yet; skipping TCP static port registry configuration."
        return
    }

    $tcpPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\SuperSocketNetLib\Tcp"
    $ipAllPath = "$tcpPath\IPAll"
    if (Test-Path $tcpPath) {
        Set-ItemProperty -Path $tcpPath -Name Enabled -Value 1 -ErrorAction SilentlyContinue
    }
    if (Test-Path $ipAllPath) {
        Set-ItemProperty -Path $ipAllPath -Name TcpDynamicPorts -Value "" -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $ipAllPath -Name TcpPort -Value "1433" -ErrorAction SilentlyContinue
        Write-Log "Configured SQL Server default instance TCP port 1433"
    }
}

function Initialize-SqlDataVolume {
    $drive = $SqlDataDriveLetter.TrimEnd(":").ToUpperInvariant()
    if ($drive -notmatch "^[A-Z]$") {
        throw "SqlDataDriveLetter must be one alphabetic drive letter. Received '$SqlDataDriveLetter'."
    }

    $driveRoot = "${drive}:\"
    for ($attempt = 1; $attempt -le 60; $attempt++) {
        if (($attempt -eq 1) -or (($attempt % 6) -eq 0)) {
            $storageCacheCommand = Get-Command Update-HostStorageCache -ErrorAction SilentlyContinue
            if ($storageCacheCommand) {
                Update-HostStorageCache -ErrorAction SilentlyContinue
            }
        }

        $volume = Get-Volume -DriveLetter $drive -ErrorAction SilentlyContinue
        if ($volume) {
            if ($volume.FileSystem -and $volume.FileSystem -ne "NTFS") {
                throw "SQL data drive $drive`: is already formatted as $($volume.FileSystem); refusing to reformat it."
            }

            $script:SqlDataRoot = $driveRoot
            $script:SqlDataDir = Join-Path $script:SqlDataRoot "SQLData"
            $script:SqlBackupDir = Join-Path $script:SqlDataRoot "SQLBackups"
            $script:SqlLogDir = Join-Path $script:SqlDataRoot "SQLLogs"
            Write-Log "SQL data volume is available at $driveRoot."
            New-Item -ItemType Directory -Path $SqlDataDir, $SqlBackupDir, $SqlLogDir -Force | Out-Null
            $sqlServiceAccount = "${DomainNetbiosName}\${SqlServiceAccountUser}"
            foreach ($path in @($SqlDataDir, $SqlBackupDir, $SqlLogDir)) {
                & icacls.exe $path /grant "${sqlServiceAccount}:(OI)(CI)(M)" /T /C | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Could not grant $sqlServiceAccount modify access to $path. icacls exit code=$LASTEXITCODE"
                }
            }
            return
        }

        # A persistent volume may already be NTFS-formatted but have no drive
        # letter after being attached to a replacement instance. Reuse it and
        # assign the configured letter instead of waiting for a RAW disk.
        $formattedDataPartition = Get-Disk -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Size -ge 60GB -and
                -not $_.IsBoot -and
                -not $_.IsSystem
            } |
            ForEach-Object {
                Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue |
                    Where-Object { $_.Size -ge 60GB } |
                    ForEach-Object {
                        $partition = $_
                        $partitionVolume = Get-Volume -Partition $partition -ErrorAction SilentlyContinue
                        if ($partitionVolume -and $partitionVolume.FileSystem -eq "NTFS") {
                            [pscustomobject]@{
                                DiskNumber     = $partition.DiskNumber
                                PartitionNumber = $partition.PartitionNumber
                                DriveLetter    = $partition.DriveLetter
                                Volume         = $partitionVolume
                            }
                        }
                    }
            } |
            Sort-Object { $_.Volume.Size } -Descending |
            Select-Object -First 1

        if ($formattedDataPartition) {
            if ($formattedDataPartition.DriveLetter -and
                $formattedDataPartition.DriveLetter.ToString().ToUpperInvariant() -ne $drive) {
                $occupiedVolume = Get-Volume -DriveLetter $drive -ErrorAction SilentlyContinue
                if ($occupiedVolume) {
                    throw "SQL data drive letter $drive`: is occupied by an existing volume; refusing to move the formatted data volume."
                }
            }

            if (-not $formattedDataPartition.DriveLetter -or
                $formattedDataPartition.DriveLetter.ToString().ToUpperInvariant() -ne $drive) {
                Write-Log "Reusing formatted SQL data disk $($formattedDataPartition.DiskNumber), partition $($formattedDataPartition.PartitionNumber) as drive $drive."
                Set-Partition `
                    -DiskNumber $formattedDataPartition.DiskNumber `
                    -PartitionNumber $formattedDataPartition.PartitionNumber `
                    -NewDriveLetter $drive `
                    -ErrorAction Stop
            }

            continue
        }

        $rawDisk = Get-Disk -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PartitionStyle -eq "RAW" -and
                $_.Size -ge 60GB
            } |
            Sort-Object Size -Descending |
            Select-Object -First 1

        if ($rawDisk) {
            Write-Log "Initializing raw SQL data disk number $($rawDisk.Number) as drive $drive."
            if ($rawDisk.IsOffline) {
                Set-Disk -Number $rawDisk.Number -IsOffline $false -ErrorAction Stop
            }
            if ($rawDisk.IsReadOnly) {
                Set-Disk -Number $rawDisk.Number -IsReadOnly $false -ErrorAction Stop
            }
            Initialize-Disk -Number $rawDisk.Number -PartitionStyle GPT -ErrorAction Stop | Out-Null
            $partition = New-Partition -DiskNumber $rawDisk.Number -UseMaximumSize -DriveLetter $drive -ErrorAction Stop
            Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel "SQLData" -AllocationUnitSize 65536 -Confirm:$false -ErrorAction Stop | Out-Null
            continue
        }

        Write-Status "waiting-for-sql-data-volume attempt=$attempt"
        Start-Sleep -Seconds 10
    }

    throw "The ${drive}: SQL data volume was not attached and initialized within 10 minutes."
}

function Install-SqlServerEngine {
    if ([string]::IsNullOrWhiteSpace($SqlServiceAccountPassword)) {
        throw "SqlServiceAccountPassword was not supplied. Set sql_service_account_password or reuse domain_admin_password through Terraform."
    }

    Initialize-SqlDataVolume

    if (Test-SqlServerInstalled) {
        Write-Status "sql-server-already-installed"
        Write-Log "SQL Server default instance is already installed."
        Enable-SqlFirewallRules
        Enable-SqlTcpStaticPort
        return
    }

    New-Item -ItemType Directory -Path $InstallerDir, $SqlMediaDir, $SqlDataDir, $SqlBackupDir, $SqlLogDir -Force | Out-Null

    $sqlBootstrapper = Join-Path $InstallerDir "SQL2025-SSEI-StdDev.exe"
    Write-Status "downloading-sql-server-bootstrapper"
    Invoke-FileDownload -Url $SqlServerDownloadUrl -Destination $sqlBootstrapper

    $downloadArgs = @(
        "/ACTION=Download",
        "/MEDIATYPE=ISO",
        "/MEDIAPATH=$SqlMediaDir",
        "/QUIET"
    )
    Write-Status "downloading-sql-server-media"
    Invoke-InstallerProcess -FilePath $sqlBootstrapper -ArgumentList $downloadArgs -Label "SQL Server 2025 media download" -SuccessExitCodes @(0)

    $mountedImage = $null
    $setupExe = $null
    $sqlIso = Get-ChildItem -Path $SqlMediaDir -Filter "*.iso" -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if ($sqlIso) {
        Write-Log "Mounting SQL Server ISO $($sqlIso.FullName)"
        $mountedImage = Mount-DiskImage -ImagePath $sqlIso.FullName -PassThru
        Start-Sleep -Seconds 5
        $volume = $mountedImage | Get-Volume
        $setupExe = "$($volume.DriveLetter):\setup.exe"
    }
    else {
        $setupExe = (Get-ChildItem -Path $SqlMediaDir -Filter "setup.exe" -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    }

    if (-not $setupExe -or -not (Test-Path $setupExe)) {
        throw "Could not locate SQL Server setup.exe under $SqlMediaDir"
    }

    $sqlServiceAccount = "$DomainNetbiosName\$SqlServiceAccountUser"
    $sqlSysAdminAccounts = "`"$DomainNetbiosName\$DomainAdminUser`" `"BUILTIN\Administrators`""

    try {
        $setupArgs = @(
            "/Q",
            "/IACCEPTSQLSERVERLICENSETERMS",
            "/SUPPRESSPRIVACYSTATEMENTNOTICE",
            "/ACTION=Install",
            "/FEATURES=SQLENGINE",
            "/INSTANCENAME=MSSQLSERVER",
            "/SQLSVCACCOUNT=`"$sqlServiceAccount`"",
            "/SQLSVCPASSWORD=`"$SqlServiceAccountPassword`"",
            "/SQLSVCSTARTUPTYPE=Automatic",
            "/AGTSVCACCOUNT=`"$sqlServiceAccount`"",
            "/AGTSVCPASSWORD=`"$SqlServiceAccountPassword`"",
            "/AGTSVCSTARTUPTYPE=Automatic",
            "/SQLSYSADMINACCOUNTS=$sqlSysAdminAccounts",
            "/TCPENABLED=1",
            "/NPENABLED=0",
            "/BROWSERSVCSTARTUPTYPE=Disabled",
            "/SQLBACKUPDIR=$SqlBackupDir",
            "/SQLUSERDBDIR=$SqlDataDir",
            "/SQLUSERDBLOGDIR=$SqlLogDir",
            "/UpdateEnabled=False"
        )

        Write-Status "installing-sql-server-engine"
        Invoke-InstallerProcess -FilePath $setupExe -ArgumentList $setupArgs -Label "SQL Server 2025 Database Engine install"
    }
    finally {
        if ($mountedImage) {
            Dismount-DiskImage -ImagePath $sqlIso.FullName -ErrorAction SilentlyContinue
            Write-Log "Dismounted SQL Server ISO"
        }
    }

    Enable-SqlFirewallRules
    Enable-SqlTcpStaticPort

    foreach ($serviceName in @("MSSQLSERVER", "SQLSERVERAGENT")) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            Set-Service -Name $serviceName -StartupType Automatic
            Restart-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            Write-Log "Confirmed SQL service $serviceName is automatic and restarted"
        }
    }
}

function Test-SsmsInstalled {
    $paths = @(
        "C:\Program Files\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\Ssms.exe",
        "C:\Program Files (x86)\Microsoft SQL Server Management Studio 22\Release\Common7\IDE\Ssms.exe"
    )

    foreach ($path in $paths) {
        if (Test-Path $path) {
            return $true
        }
    }

    return $false
}

function Install-Ssms {
    if (-not $InstallSsmsEnabled) {
        Write-Status "ssms-install-disabled"
        Write-Log "SSMS install disabled by variable."
        return
    }

    if (Test-SsmsInstalled) {
        Write-Status "ssms-already-installed"
        Write-Log "SSMS is already installed."
        return
    }

    New-Item -ItemType Directory -Path $InstallerDir -Force | Out-Null
    $ssmsBootstrapper = Join-Path $InstallerDir "vs_SSMS.exe"

    try {
        if (-not (Test-Path -LiteralPath $ssmsBootstrapper)) {
            Write-Status "downloading-ssms"
            Invoke-FileDownload -Url $SsmsDownloadUrl -Destination $ssmsBootstrapper
        }
        else {
            Write-Log "SSMS installer already exists: $ssmsBootstrapper"
        }

        $ssmsArgs = @(
            "--quiet",
            "--wait",
            "--norestart",
            "--addProductLang", "en-US"
        )

        Write-Status "installing-ssms"
        Invoke-InstallerProcess -FilePath $ssmsBootstrapper -ArgumentList $ssmsArgs -Label "SQL Server Management Studio install"

        if (-not (Test-SsmsInstalled)) {
            throw "SSMS installer returned success, but Ssms.exe was not found afterward."
        }
    }
    catch {
        # SSMS is a management client and is not required by SQL Server,
        # WSFC, Always On, or the database restore. Keep those stages running.
        $warningPath = Join-Path $SetupDir "SSMS_INSTALL_WARNING.txt"
        $warning = "SSMS installation did not complete on ${TargetComputerName}: $($_.Exception.Message)"
        Set-Content -Path $warningPath -Value $warning -Force
        Write-Status "ssms-install-warning-continue"
        Write-ErrorDetails -Context "SSMS installation warning; continuing bootstrap" -ErrorRecord $_
    }
}

function Test-PendingReboot {
    $rebootPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"
    )

    foreach ($path in $rebootPaths) {
        if (Test-Path $path) {
            Write-Log "Pending reboot detected from $path"
            return $true
        }
    }

    try {
        $sessionManager = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($sessionManager.PendingFileRenameOperations) {
            Write-Log "Pending reboot detected from Session Manager PendingFileRenameOperations"
            return $true
        }
    }
    catch {
        Write-Log "Pending reboot check warning: $($_.Exception.Message)"
    }

    return $false
}

function Invoke-WsfcAutomationIfNeeded {
    if (-not $AutoConfigureWsfcEnabled) {
        Write-Status "wsfc-automation-disabled"
        Write-Log "WSFC automation disabled by variable."
        return
    }

    if ($TargetComputerName -ine $WsfcPrimaryNode) {
        Write-Status "wsfc-orchestrated-by-$WsfcPrimaryNode"
        Write-Log "WSFC automation will be orchestrated by $WsfcPrimaryNode; current node is $TargetComputerName."
        return
    }

    if (-not (Test-Path $WsfcScriptPath)) {
        throw "WSFC script was not found at $WsfcScriptPath"
    }

    $wsfcArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $WsfcScriptPath,
        "-DomainName", $DomainName,
        "-DomainNetbiosName", $DomainNetbiosName,
        "-DomainAdminUser", $DomainAdminUser,
        "-DomainAdminPassword", $DomainAdminPassword,
        "-ClusterName", $WsfcClusterName,
        "-ClusterNodes", $WsfcClusterNodes,
        "-ClusterStaticAddresses", $WsfcClusterStaticAddresses,
        "-WitnessShare", $WsfcWitnessShare,
        "-SqlInstanceName", "MSSQLSERVER",
        "-SqlServiceAccountUser", $SqlServiceAccountUser,
        "-AoagDatabaseName", $AoagDatabaseName,
        "-AoagAvailabilityGroupName", $AoagAvailabilityGroupName,
        "-AoagListenerName", $AoagListenerName,
        "-AoagListenerPort", $AoagListenerPort,
        "-AoagListenerIps", $AoagListenerIps,
        "-HadrEndpointName", $HadrEndpointName,
        "-HadrEndpointPort", $HadrEndpointPort,
        "-SampleDatabaseDownloadUrl", $SampleDatabaseDownloadUrl,
        "-SampleScriptPath", $SampleScriptPath,
        "-AgScriptPath", $AgScriptPath,
        "-SetupDir", "C:\AOAGAutomation\WSFC"
    )

    if ($SkipClusterValidationEnabled) {
        $wsfcArgs += "-SkipClusterValidation"
    }

    Write-Status "starting-wsfc-automation"
    Write-Log "Starting WSFC automation from $WsfcScriptPath"
    $process = Start-Process -FilePath "PowerShell.exe" -ArgumentList $wsfcArgs -Wait -PassThru
    Write-Log "WSFC automation finished with exit code $($process.ExitCode)"

    if ($process.ExitCode -ne 0) {
        foreach ($wsfcLog in @("C:\AOAGAutomation\WSFC\configure-wsfc.log")) {
            if (Test-Path $wsfcLog) {
                Write-Log "Last lines from $wsfcLog"
                Get-Content -Path $wsfcLog -Tail 80 -ErrorAction SilentlyContinue | ForEach-Object {
                    Write-Log "WSFC: $_"
                }
            }
            else {
                Write-Log "WSFC log not found: $wsfcLog"
            }
        }
        throw "WSFC automation failed with exit code $($process.ExitCode). Check C:\AOAGAutomation\WSFC\configure-wsfc.log."
    }
}

function Install-AvailabilityGroupReconciliationTask {
    if (-not (Test-Path -LiteralPath $ReconcileScriptPath)) {
        throw "Availability group reconciliation script was not found at $ReconcileScriptPath"
    }

    $taskName = "AOAG-Reconcile-AvailabilityGroup"
    $taskArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$ReconcileScriptPath`"",
        "-AvailabilityGroupName", "`"$AoagAvailabilityGroupName`"",
        "-DatabaseName", "`"$AoagDatabaseName`"",
        "-ClusterName", "`"$WsfcClusterName`"",
        "-ListenerName", "`"$AoagListenerName`"",
        "-ListenerPort", "$AoagListenerPort",
        "-ListenerIps", "`"$AoagListenerIps`"",
        "-ReadinessTimeoutMinutes", "60"
    ) -join " "

    $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $taskArgs
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -User "$DomainAdminUser@$DomainName" -Password $DomainAdminPassword -RunLevel Highest -Force | Out-Null
    Write-Log "Registered $taskName as $DomainAdminUser@$DomainName to reconcile the local SQL/WSFC/AG/listener state after every reboot."
    try {
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        Write-Log "Started $taskName immediately so it can repair the AG/listener during the initial deployment."
    }
    catch {
        Write-Log "Warning: could not start $taskName immediately; it will run at the next startup. $($_.Exception.Message)"
    }
}

try {
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    Enter-BootstrapMutex
    Write-Status "starting target=$TargetComputerName"
    Write-Log "Starting Windows/domain bootstrap for $TargetComputerName"

    Register-ResumeTask
    if (-not (Test-Path $StagePath)) {
        Set-Stage -Stage "rename"
    }
    Set-LocalAdminPassword
    Enable-LabRdp
    Enable-LabWinRm
    Set-DomainDns

    $stage = Get-Stage
    Write-Log "Current stage: $stage"

    if ($stage -eq "rename") {
        Set-Stage -Stage "join-domain"
        if ($env:COMPUTERNAME -ne $TargetComputerName) {
            Write-Log "Renaming computer from $env:COMPUTERNAME to $TargetComputerName"
            Rename-Computer -NewName $TargetComputerName -Force
            Restart-Computer -Force
            exit 0
        }
    }

    if ((Get-Stage) -eq "join-domain") {
        if (-not (Test-JoinedToDomain)) {
            Join-DomainWithRetry
            Set-Stage -Stage "post-join"
            Restart-Computer -Force
            exit 0
        }

        Write-Log "$TargetComputerName is already joined to $DomainName"
        Set-Stage -Stage "post-join"
    }

    if ((Get-Stage) -eq "post-join") {
        Wait-ForDomain
        Add-DomainAdminToLocalGroups
        Wait-ForBootstrapSettle -Phase "after-domain-join" -Seconds $DomainJoinSettleSeconds
        if ($AutoInstallSqlServerEnabled) {
            Set-Stage -Stage "install-sql"
        }
        else {
            Set-Content -Path $ReadyPath -Value "Windows/domain bootstrap completed for $TargetComputerName. Domain login: $DomainAdminUser@$DomainName" -Force
            Set-Stage -Stage "complete"
            Remove-ResumeTask
            Write-Log "Windows/domain bootstrap completed for $TargetComputerName"
        }
    }

    if ((Get-Stage) -eq "install-sql") {
        Wait-ForDomain
        Add-DomainAdminToLocalGroups
        Write-Status "installing-sql-server"
        Install-SqlServerEngine
        Write-Status "installing-wsfc-prerequisites"
        Install-WsfcPrerequisites
        # SSMS is optional tooling. Keep it after the cluster prerequisites so
        # a management-client installer issue cannot delay WSFC/Always On.
        Write-Status "installing-ssms"
        Install-Ssms
        Wait-ForBootstrapSettle -Phase "after-sql-install" -Seconds $PostInstallSettleSeconds
        Set-Stage -Stage "configure-wsfc"

        if (Test-PendingReboot) {
            Write-Status "pending-reboot-before-wsfc"
            Write-Log "Rebooting $TargetComputerName before WSFC automation because Windows reports a pending reboot."
            Restart-Computer -Force
            exit 0
        }
    }

    if ((Get-Stage) -eq "configure-wsfc") {
        Wait-ForDomain
        Add-DomainAdminToLocalGroups
        Wait-ForBootstrapSettle -Phase "before-wsfc" -Seconds $PreWsfcSettleSeconds
        Install-AvailabilityGroupReconciliationTask
        Invoke-WsfcAutomationIfNeeded
        Set-Content -Path $ReadyPath -Value "Windows/domain/SQL/WSFC bootstrap completed for $TargetComputerName. Domain login: $DomainAdminUser@$DomainName. SQL service account: $DomainNetbiosName\$SqlServiceAccountUser" -Force
        Write-Status "complete"
        Set-Stage -Stage "complete"
        Remove-ResumeTask
        Write-Log "Windows/domain/SQL/WSFC bootstrap completed for $TargetComputerName"
    }
}
catch {
    Write-Status "failed: $($_.Exception.Message)"
    Write-Log "ERROR: $($_.Exception.Message)"
    throw
}
finally {
    Exit-BootstrapMutex
}
