# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
<#
.SYNOPSIS
Configures DC-VM as the first domain controller for the AOAG lab.

.DESCRIPTION
This script is intentionally separate from Terraform so domain passwords are
not stored in Terraform state. It runs in stages and registers a temporary
startup task so it can continue after the AD DS promotion reboot.

.EXAMPLE
powershell.exe -ExecutionPolicy Bypass -File .\01-configure-domain-controller.ps1 -DomainAdminPasswordPlain '<domainadmin password>'
#>

[CmdletBinding()]
param(
    [string]$DomainName = "mssqlaoag.demo",
    [string]$NetbiosName = "MSSQLAOAG",
    [string]$DomainAdminUser = "domainadmin",
    [string]$SqlServiceAccountUser = "sqlsa",
    [string]$LocalAdminUser = "opc",
    [string]$TargetComputerName = "DC-VM",
    [string]$DcPrivateIp = "10.0.10.10",
    [string]$BootstrapDnsServer = "169.254.169.254",
    [string]$WitnessPath = "C:\ClusterWitness",
    [string]$WitnessShareName = "ClusterWitness",
    [string]$SetupDir = "C:\AOAGAutomation\DC",
    [string]$DomainAdminPasswordPlain,
    [string]$SqlServiceAccountPasswordPlain,
    [string]$LocalAdminPasswordPlain,
    [switch]$UseStoredSecret,
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"
$TaskName = "AOAG-Configure-DomainController"
$InstalledScriptPath = Join-Path $SetupDir "01-configure-domain-controller.ps1"
$StagePath = Join-Path $SetupDir "stage.txt"
$SecretPath = Join-Path $SetupDir "domainadmin-password.dpapi"
$SqlServiceSecretPath = Join-Path $SetupDir "sql-service-password.dpapi"
$LogPath = Join-Path $SetupDir "configure-dc.log"
$ReadyPath = Join-Path $SetupDir "DOMAIN_READY.txt"
$VerifyPath = Join-Path $SetupDir "DOMAIN_VERIFY.json"
$SecretEntropy = "mssql-aoag-dc-bootstrap-v1"
$PostPromotionSettleSeconds = 60

function Wait-ForBootstrapSettle {
    param(
        [Parameter(Mandatory)]
        [string]$Phase,
        [Parameter(Mandatory)]
        [int]$Seconds
    )

    Write-Log "STATUS: settling-$Phase seconds=$Seconds"
    Write-Log "Waiting $Seconds seconds for $Phase services and DNS state to settle."
    Start-Sleep -Seconds $Seconds
}

function Write-Log {
    param([string]$Message)
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    Add-Content -Path $LogPath -Value ("{0:s} {1}" -f (Get-Date), $Message)
}

function Assert-RunningElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $isSystem = $identity.Name -eq "NT AUTHORITY\SYSTEM"

    Write-Log "Running as $($identity.Name). IsAdmin=$isAdmin IsSystem=$isSystem"

    if (-not ($isAdmin -or $isSystem)) {
        throw "DC automation must run elevated or as LocalSystem."
    }
}

function Set-StrictAcl {
    param([string]$Path)
    & icacls.exe $Path /inheritance:r /grant:r "SYSTEM:(F)" "Administrators:(F)" | Out-Null
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
        Write-Log "Local group membership warning for $Member in $Group. net.exe exit code $($groupResult.ExitCode)."
    }
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

function Save-Secret {
    param([string]$PlainText)
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    Set-Content -Path $SecretPath -Value (Protect-PlainText -PlainText $PlainText) -Force
    Set-StrictAcl -Path $SecretPath
}

function Save-SqlServiceSecret {
    param([string]$PlainText)
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    Set-Content -Path $SqlServiceSecretPath -Value (Protect-PlainText -PlainText $PlainText) -Force
    Set-StrictAcl -Path $SqlServiceSecretPath
}

function Get-PlainPassword {
    if ($DomainAdminPasswordPlain) {
        Save-Secret -PlainText $DomainAdminPasswordPlain
        return $DomainAdminPasswordPlain
    }

    if (Test-Path $SecretPath) {
        return Unprotect-PlainText -ProtectedText (Get-Content -Path $SecretPath -Raw)
    }

    if ($NonInteractive -or $UseStoredSecret) {
        throw "DomainAdminPasswordPlain was not supplied and no stored domain-admin secret exists."
    }

    $secure = Read-Host -Prompt "Password for $DomainName\$DomainAdminUser" -AsSecureString
    $plain = Convert-SecureStringToPlainText -SecureString $secure
    Save-Secret -PlainText $plain
    return $plain
}

function Get-SqlServicePlainPassword {
    param([string]$DefaultPlainPassword)

    if ($SqlServiceAccountPasswordPlain) {
        Save-SqlServiceSecret -PlainText $SqlServiceAccountPasswordPlain
        return $SqlServiceAccountPasswordPlain
    }

    if (Test-Path $SqlServiceSecretPath) {
        return Unprotect-PlainText -ProtectedText (Get-Content -Path $SqlServiceSecretPath -Raw)
    }

    if (-not $DefaultPlainPassword) {
        throw "SqlServiceAccountPasswordPlain was not supplied and no stored SQL service secret exists."
    }

    Write-Log "SQL service account password was not supplied; reusing the supplied domain-admin password."
    Save-SqlServiceSecret -PlainText $DefaultPlainPassword
    return $DefaultPlainPassword
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
    Write-Log "Stage set to $Stage"
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

function Ensure-LocalAdminAccess {
    param([string]$PlainPassword)

    if ([string]::IsNullOrWhiteSpace($PlainPassword)) {
        Write-Log "Local Windows admin password was not supplied; skipping local admin password setup"
        return
    }

    Write-Log "Configuring local Administrator and $LocalAdminUser for bootstrap RDP access"

    $adminResult = Invoke-NetCommand -Arguments @("user", "Administrator", $PlainPassword, "/logonpasswordchg:no", "/active:yes")
    Write-CommandOutput -Label "net user Administrator:" -Output $adminResult.Output
    if ($adminResult.ExitCode -ne 0) {
        throw "Failed to configure local Administrator account. net.exe exit code $($adminResult.ExitCode)."
    }

    if ($LocalAdminUser -and $LocalAdminUser -ne "Administrator") {
        $userResult = Invoke-NetCommand -Arguments @("user", $LocalAdminUser, $PlainPassword, "/logonpasswordchg:no", "/active:yes")
        Write-CommandOutput -Label "net user $($LocalAdminUser):" -Output $userResult.Output

        if ($userResult.ExitCode -ne 0) {
            $addUserResult = Invoke-NetCommand -Arguments @("user", $LocalAdminUser, $PlainPassword, "/add", "/logonpasswordchg:no", "/active:yes")
            Write-CommandOutput -Label "net user $LocalAdminUser /add:" -Output $addUserResult.Output
            if ($addUserResult.ExitCode -ne 0) {
                throw "Failed to create local $LocalAdminUser account. net.exe exit code $($addUserResult.ExitCode)."
            }
        }

        Add-LocalGroupMemberByNet -Group "Administrators" -Member $LocalAdminUser
        Add-LocalGroupMemberByNet -Group "Remote Desktop Users" -Member $LocalAdminUser
    }
}

function Register-ResumeTask {
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null

    $currentScript = $PSCommandPath
    if ($currentScript -and ($currentScript -ne $InstalledScriptPath)) {
        Copy-Item -LiteralPath $currentScript -Destination $InstalledScriptPath -Force
    }

    Set-StrictAcl -Path $InstalledScriptPath

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy Bypass",
        "-File `"$InstalledScriptPath`"",
        "-DomainName `"$DomainName`"",
        "-NetbiosName `"$NetbiosName`"",
        "-DomainAdminUser `"$DomainAdminUser`"",
        "-SqlServiceAccountUser `"$SqlServiceAccountUser`"",
        "-LocalAdminUser `"$LocalAdminUser`"",
        "-TargetComputerName `"$TargetComputerName`"",
        "-DcPrivateIp `"$DcPrivateIp`"",
        "-WitnessPath `"$WitnessPath`"",
        "-WitnessShareName `"$WitnessShareName`"",
        "-SetupDir `"$SetupDir`"",
        "-UseStoredSecret",
        "-NonInteractive"
    ) -join " "

    $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $args
    $trigger = New-ScheduledTaskTrigger -AtStartup
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -User "SYSTEM" -RunLevel Highest -Force | Out-Null
    Write-Log "Registered resume task $TaskName"
}

function Remove-ResumeTask {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Enable-LabRdp {
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null
    Write-Log "Enabled Remote Desktop firewall rules"
}

function Set-DcDns {
    param([switch]$DomainReady)

    $servers = if ($DomainReady) {
        @($DcPrivateIp, "127.0.0.1")
    }
    else {
        # Do not point the new DC at itself before DNS is installed. The OCI
        # resolver keeps the instance reachable during feature installation and
        # the AD DS promotion reboot.
        @($BootstrapDnsServer)
    }

    Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses $servers
            Write-Log "Set DNS servers on adapter $($_.Name) to $($servers -join ', ')"
        }
        catch {
            Write-Log "DNS update warning on adapter $($_.Name): $($_.Exception.Message)"
        }
    }
}

function Ensure-DnsForwarders {
    if (-not (Get-Command Set-DnsServerForwarder -ErrorAction SilentlyContinue)) {
        Write-Log "DNS Server cmdlets are not available yet; skipping forwarder configuration."
        return
    }

    Write-Log "Configuring DNS forwarders after core domain setup"
    try {
        Set-DnsServerForwarder -IPAddress @("169.254.169.254", "1.1.1.1") -UseRootHint:$false -ErrorAction Stop
        Clear-DnsServerCache -ErrorAction SilentlyContinue
        Write-Log "Configured DNS forwarders to OCI VCN resolver and Cloudflare DNS."
    }
    catch {
        Write-Log "DNS forwarder configuration warning: $($_.Exception.Message)"
    }
}

function Test-DomainReady {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        Get-ADDomain -Identity $DomainName -Server "localhost" -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Wait-ForDomain {
    for ($i = 1; $i -le 80; $i++) {
        if (Test-DomainReady) {
            Write-Log "Domain $DomainName is available"
            return
        }

        Write-Log "Waiting for AD DS readiness attempt $($i): Active Directory is not available yet."
        Start-Sleep -Seconds 15
    }

    throw "AD DS did not become ready in time."
}

function Ensure-DomainAdmin {
    param([securestring]$Password)

    Import-Module ActiveDirectory -ErrorAction Stop
    $upn = "$DomainAdminUser@$DomainName"
    $existing = Get-ADUser -LDAPFilter "(sAMAccountName=$DomainAdminUser)" -Server "localhost" -ErrorAction SilentlyContinue

    if (-not $existing) {
        New-ADUser `
            -Name $DomainAdminUser `
            -SamAccountName $DomainAdminUser `
            -UserPrincipalName $upn `
            -AccountPassword $Password `
            -Enabled $true `
            -ChangePasswordAtLogon $false `
            -CannotChangePassword $false `
            -PasswordNeverExpires $true `
            -Description "AOAG lab domain administrator"
        Write-Log "Created domain user $upn"
    }
    else {
        Set-ADAccountPassword -Identity $DomainAdminUser -Reset -NewPassword $Password
        Enable-ADAccount -Identity $DomainAdminUser -ErrorAction Stop
        Unlock-ADAccount -Identity $DomainAdminUser -ErrorAction SilentlyContinue
        Set-ADAccountControl `
            -Identity $DomainAdminUser `
            -Enabled $true `
            -PasswordNeverExpires $true `
            -CannotChangePassword $false `
            -PasswordNotRequired $false
        Set-ADUser `
            -Identity $DomainAdminUser `
            -PasswordNeverExpires $true `
            -ChangePasswordAtLogon $false `
            -CannotChangePassword $false `
            -UserPrincipalName $upn `
            -Description "AOAG lab domain administrator"
        Write-Log "Updated domain user $upn"
    }

    foreach ($group in @("Domain Admins", "Enterprise Admins", "Administrators", "Remote Desktop Users")) {
        $isMember = Get-ADGroupMember -Identity $group -Recursive -ErrorAction Stop |
            Where-Object { $_.SamAccountName -ieq $DomainAdminUser }

        if (-not $isMember) {
            Add-ADGroupMember -Identity $group -Members $DomainAdminUser -ErrorAction Stop
            Write-Log "Added $DomainAdminUser to $group"
        }
        else {
            Write-Log "$DomainAdminUser is already a member of $group"
        }
    }

    $account = Get-ADUser -Identity $DomainAdminUser -Server "localhost" -Properties Enabled, LockedOut, PasswordExpired, PasswordNeverExpires, UserPrincipalName
    if (-not $account.Enabled -or $account.LockedOut -or $account.PasswordExpired -or -not $account.PasswordNeverExpires -or $account.UserPrincipalName -ine $upn) {
        throw "Domain administrator account verification failed. Enabled=$($account.Enabled); LockedOut=$($account.LockedOut); PasswordExpired=$($account.PasswordExpired); PasswordNeverExpires=$($account.PasswordNeverExpires); UPN=$($account.UserPrincipalName)."
    }

    foreach ($group in @("Domain Admins", "Enterprise Admins", "Administrators", "Remote Desktop Users")) {
        $verifiedMember = Get-ADGroupMember -Identity $group -Recursive -ErrorAction Stop |
            Where-Object { $_.SamAccountName -ieq $DomainAdminUser }
        if (-not $verifiedMember) {
            throw "Domain administrator account is not a member of $group."
        }
    }

    Write-Log "Verified $upn is enabled, unlocked, password-valid, and a member of the required administrative and RDP groups"
}

function Ensure-SqlServiceAccount {
    param([securestring]$Password)

    Import-Module ActiveDirectory -ErrorAction Stop
    $upn = "$SqlServiceAccountUser@$DomainName"
    $existing = Get-ADUser -LDAPFilter "(sAMAccountName=$SqlServiceAccountUser)" -ErrorAction SilentlyContinue

    if (-not $existing) {
        New-ADUser `
            -Name $SqlServiceAccountUser `
            -SamAccountName $SqlServiceAccountUser `
            -UserPrincipalName $upn `
            -AccountPassword $Password `
            -Enabled $true `
            -PasswordNeverExpires $true `
            -Description "AOAG lab SQL Server service account"
        Write-Log "Created SQL Server service account $upn"
    }
    else {
        Set-ADAccountPassword -Identity $SqlServiceAccountUser -Reset -NewPassword $Password
        Enable-ADAccount -Identity $SqlServiceAccountUser
        Set-ADUser -Identity $SqlServiceAccountUser -PasswordNeverExpires $true -UserPrincipalName $upn -Description "AOAG lab SQL Server service account"
        Write-Log "Updated SQL Server service account $upn"
    }
}

function Ensure-WitnessShare {
    New-Item -ItemType Directory -Path $WitnessPath -Force | Out-Null
    $sqlServiceAcl = "$NetbiosName\$SqlServiceAccountUser" + ":(OI)(CI)(M)"
    & icacls.exe $WitnessPath /inheritance:e /grant "Administrators:(OI)(CI)(F)" "Domain Admins:(OI)(CI)(F)" "Everyone:(OI)(CI)(M)" $sqlServiceAcl | Out-Null

    $existingShare = Get-SmbShare -Name $WitnessShareName -ErrorAction SilentlyContinue
    if (-not $existingShare) {
        New-SmbShare -Name $WitnessShareName -Path $WitnessPath -FullAccess "Administrators", "Domain Admins" -ChangeAccess "Everyone", "$NetbiosName\$SqlServiceAccountUser" -CachingMode None | Out-Null
        Write-Log "Created witness share \\$TargetComputerName\$WitnessShareName"
    }
    else {
        Grant-SmbShareAccess -Name $WitnessShareName -AccountName "Everyone" -AccessRight Change -Force | Out-Null
        Grant-SmbShareAccess -Name $WitnessShareName -AccountName "$NetbiosName\$SqlServiceAccountUser" -AccessRight Change -Force | Out-Null
        Write-Log "Witness share already exists: \\$TargetComputerName\$WitnessShareName"
    }
}

function Test-DomainAdminCredential {
    param([securestring]$Password)

    Import-Module ActiveDirectory -ErrorAction Stop
    $credential = [pscredential]::new("$DomainAdminUser@$DomainName", $Password)
    Get-ADUser -Identity $DomainAdminUser -Credential $credential -Server "localhost" -ErrorAction Stop | Out-Null
    Write-Log "Credential validation succeeded for $DomainAdminUser@$DomainName"
}

try {
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    Write-Log "DC automation script entered"
    Assert-RunningElevated

    $stage = Get-Stage
    $plainPassword = Get-PlainPassword
    $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
    $sqlServicePlainPassword = Get-SqlServicePlainPassword -DefaultPlainPassword $plainPassword
    $sqlServiceSecurePassword = ConvertTo-SecureString $sqlServicePlainPassword -AsPlainText -Force
    $localAdminPassword = if ($LocalAdminPasswordPlain) { $LocalAdminPasswordPlain } elseif ($plainPassword) { $plainPassword } else { throw "LocalAdminPasswordPlain was not supplied." }

    if ($stage -eq "complete") {
        Write-Log "DC automation already complete; reconciling domain service account and witness share"
        Wait-ForDomain
        Ensure-DomainAdmin -Password $securePassword
        Ensure-SqlServiceAccount -Password $sqlServiceSecurePassword
        Ensure-WitnessShare
        Test-DomainAdminCredential -Password $securePassword
        $verify = [ordered]@{
            computer_name         = $env:COMPUTERNAME
            domain_name           = $DomainName
            netbios_name          = $NetbiosName
            domain_admin_user     = "$NetbiosName\$DomainAdminUser"
            sql_service_user      = "$NetbiosName\$SqlServiceAccountUser"
            user_principal_name   = "$DomainAdminUser@$DomainName"
            witness_share         = "\\$TargetComputerName.$DomainName\$WitnessShareName"
            rdp_firewall_enabled  = $true
            completed_utc         = (Get-Date).ToUniversalTime().ToString("o")
        }
        $verify | ConvertTo-Json | Set-Content -Path $VerifyPath -Force
        Remove-Item -Path $SecretPath, $SqlServiceSecretPath -Force -ErrorAction SilentlyContinue
        Remove-ResumeTask
        exit 0
    }

    if (@("rename", "features", "promote") -contains $stage) {
        Ensure-LocalAdminAccess -PlainPassword $localAdminPassword
    }

    Register-ResumeTask
    Enable-LabRdp
    if (@("post-promote", "complete") -contains $stage) {
        Set-DcDns -DomainReady
    }
    else {
        Set-DcDns
    }

    Write-Log "Starting DC configuration stage: $stage"

    if ($stage -eq "rename") {
        Set-Stage -Stage "features"
        if ($env:COMPUTERNAME -ne $TargetComputerName) {
            Write-Log "Renaming computer from $env:COMPUTERNAME to $TargetComputerName"
            Rename-Computer -NewName $TargetComputerName -Force
            Restart-Computer -Force
            exit 0
        }
    }

    if ((Get-Stage) -eq "features") {
        Write-Log "Installing AD DS and DNS roles"
        foreach ($feature in @("AD-Domain-Services", "DNS", "RSAT-ADDS", "RSAT-DNS-Server")) {
            Install-WindowsFeature -Name $feature -IncludeManagementTools | Out-Null
            Write-Log "Installed or confirmed Windows feature $feature"
        }

        Set-DcDns
        Set-Stage -Stage "promote"
    }

    if ((Get-Stage) -eq "promote") {
        if (-not (Test-DomainReady)) {
            Write-Log "Promoting first domain controller for $DomainName"
            Import-Module ADDSDeployment -ErrorAction Stop
            Install-ADDSForest `
                -DomainName $DomainName `
                -DomainNetbiosName $NetbiosName `
                -InstallDNS `
                -CreateDnsDelegation:$false `
                -SafeModeAdministratorPassword $securePassword `
                -Force `
                -NoRebootOnCompletion:$true

            Set-Stage -Stage "post-promote"
            Restart-Computer -Force
            exit 0
        }

        Write-Log "Domain $DomainName is already available; skipping forest promotion"
        Set-Stage -Stage "post-promote"
    }

    if ((Get-Stage) -eq "post-promote") {
        Set-DcDns -DomainReady
        Wait-ForDomain
        Wait-ForBootstrapSettle -Phase "after-domain-promotion" -Seconds $PostPromotionSettleSeconds
        Write-Log "Post-promotion: ensuring domain administrator"
        Ensure-DomainAdmin -Password $securePassword
        Write-Log "Post-promotion: ensuring SQL service account"
        Ensure-SqlServiceAccount -Password $sqlServiceSecurePassword
        Write-Log "Post-promotion: ensuring witness share"
        Ensure-WitnessShare
        Write-Log "Post-promotion: validating domain administrator credential"
        Test-DomainAdminCredential -Password $securePassword

        $verify = [ordered]@{
            computer_name         = $env:COMPUTERNAME
            domain_name           = $DomainName
            netbios_name          = $NetbiosName
            domain_admin_user     = "$NetbiosName\$DomainAdminUser"
            sql_service_user      = "$NetbiosName\$SqlServiceAccountUser"
            user_principal_name   = "$DomainAdminUser@$DomainName"
            witness_share         = "\\$TargetComputerName.$DomainName\$WitnessShareName"
            rdp_firewall_enabled  = $true
            completed_utc         = (Get-Date).ToUniversalTime().ToString("o")
        }

        $verify | ConvertTo-Json | Set-Content -Path $VerifyPath -Force
        Set-Content -Path $ReadyPath -Value "Domain $DomainName ready. Login test passed for $DomainAdminUser@$DomainName." -Force
        Set-Stage -Stage "complete"
        Write-Log "Core domain setup complete; domain login marker written"

        # DNS forwarding is useful for installer downloads but is not required
        # for AD account creation or domain joins, so keep it outside the
        # critical post-promotion path.
        Ensure-DnsForwarders

        Remove-Item -Path $SecretPath, $SqlServiceSecretPath -Force -ErrorAction SilentlyContinue
        Remove-ResumeTask
        Write-Log "DC automation complete"
    }
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    throw
}
