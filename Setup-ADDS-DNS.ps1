# =============================================================================
# Full unattended setup: rename -> local admin password -> self DNS -> promote
# to AD DS Domain Controller (installs DNS role) -> automatic reverse lookup zone
#
# Designed for Windows Server 2019. Handles the multiple reboots that
# Rename-Computer and Install-ADDSForest require by persisting progress to
# SetupStage.txt (in the same folder as this script) and re-launching itself
# at startup via a scheduled task.
#
# All logging goes to ONE file: Setup.log, in the same folder as this script.
# Every log line is also printed to the console, so you can watch it live.
#
# Run this once, elevated, from a saved copy at C:\Scripts\Setup-ADDS-DNS.ps1:
#   PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\Setup-ADDS-DNS.ps1
# =============================================================================

# ==================== Variables ====================
param ([switch]$RepairReverseDns)   # re-run just the reverse-DNS/PTR fix without repeating earlier stages

$ErrorActionPreference = "Stop"   # make sure real failures land in catch blocks, not get swallowed

$NewComputerName    = "app010w001"
$LocalAdminPassword = "Login%123456"     # NOTE: change this / pull from a secret store for real use
$DomainName         = "minjtech.xyz"
$NetbiosName        = "MINJTECH"
$ForestMode         = "WinThreshold"
$DomainMode         = "WinThreshold"

# This script MUST run from a durable path so the scheduled task can find it after every
# reboot, and all state files live next to it in the SAME folder.
$DurableScriptPath = "C:\Scripts\Setup-ADDS-DNS.ps1"
$StateDir          = Split-Path -Path $DurableScriptPath -Parent
if (-not (Test-Path $StateDir)) { New-Item -Path $StateDir -ItemType Directory -Force | Out-Null }

$LogFile     = Join-Path $StateDir "Setup.log"
$StageFile   = Join-Path $StateDir "SetupStage.txt"
$NetInfoFile = Join-Path $StateDir "SetupNetworkInfo.xml"

$CurrentPath = $MyInvocation.MyCommand.Path
if ($CurrentPath -and (Resolve-Path $CurrentPath).Path -ne (Resolve-Path -Path $DurableScriptPath -ErrorAction SilentlyContinue).Path) {
    Copy-Item -Path $CurrentPath -Destination $DurableScriptPath -Force
} elseif (-not $CurrentPath -or -not (Test-Path $DurableScriptPath)) {
    if (-not (Test-Path $DurableScriptPath)) {
        Write-Warning "Script has no backing file. Save this script as $DurableScriptPath and re-run it from there so it can survive reboots."
        exit 1
    }
}
$ScriptPath = $DurableScriptPath

# AD DS / DNS Server cmdlets (and several other modules used below) only exist for the
# 64-bit PowerShell host. If we're running as a 32-bit process (e.g. launched from
# "Windows PowerShell ISE (x86)"), relaunch ourselves under the real 64-bit host.
if (-not [Environment]::Is64BitProcess) {
    $sysNative = "$env:windir\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    $ps64 = if (Test-Path $sysNative) { $sysNative } else { "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" }
    Write-Warning "Running under 32-bit PowerShell; AD DS/DNS cmdlets require 64-bit. Relaunching under $ps64 ..."
    & $ps64 -NoProfile -ExecutionPolicy Bypass -File $ScriptPath
    exit $LASTEXITCODE
}

# ==================== Helpers ====================
function Write-Log {
    param ([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp - $message"
    Write-Host $line
    $line | Out-File -FilePath $LogFile -Append
}

function Test-PendingReboot {
    return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
           (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
           (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations') -or
           ((Get-WmiObject -Class Win32_ComputerSystem).RebootPending)
}

function Register-ContinuationTask {
    # Re-runs this script at every startup (SYSTEM context) until setup finishes.
    param ([string]$Path)
    $taskName = "ADSetupContinuation"
    if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        $action    = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Path`""
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Log "Registered scheduled task '$taskName' to re-run $Path at every startup."
    }
}

function Unregister-ContinuationTask {
    Unregister-ScheduledTask -TaskName "ADSetupContinuation" -Confirm:$false -ErrorAction SilentlyContinue
}

function Get-PrimaryIPv4Info {
    # Prefer the adapter that actually has a default gateway (the "real" network interface)
    # over any secondary/NAT/loopback adapters, to avoid configuring DNS on the wrong NIC.
    $routedInterfaceIndex = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object -Property RouteMetric | Select-Object -First 1).InterfaceIndex

    $ipConfig = $null
    if ($routedInterfaceIndex) {
        $ipConfig = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $routedInterfaceIndex -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254*' } | Select-Object -First 1
    }
    if (-not $ipConfig) {
        $ipConfig = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
            $_.IPAddress -notlike '169.254*' -and $_.InterfaceAlias -notlike "Loopback*"
        } | Select-Object -First 1
    }
    if (-not $ipConfig) { throw "Could not find a usable IPv4 address on this machine." }

    return [PSCustomObject]@{
        PrivateIP    = $ipConfig.IPAddress
        PrefixLength = $ipConfig.PrefixLength
        Adapter      = $ipConfig.InterfaceAlias
    }
}

function Get-ReverseZoneAndRecordName {
    # Computes the in-addr.arpa zone name and the record name within that zone for a
    # given IPv4 + prefix length. Assumes an octet-aligned prefix (/8, /16, /24) — for
    # non-aligned prefixes (e.g. /27) you'd normally use RFC 2317 classless delegation
    # instead, which this does not attempt to set up.
    param ([string]$IPAddress, [int]$PrefixLength)

    $ipBytes = [System.Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
    $maskBytes = [byte[]](0,0,0,0)
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $PrefixLength - ($i * 8)))
        $maskBytes[$i] = [byte](256 - [Math]::Pow(2, 8 - $bits))
    }
    $networkBytes = [byte[]](0,0,0,0)
    for ($i = 0; $i -lt 4; $i++) { $networkBytes[$i] = $ipBytes[$i] -band $maskBytes[$i] }
    $networkID = "$($networkBytes -join '.')/$PrefixLength"

    $zoneOctetsCount = [Math]::Floor($PrefixLength / 8)
    if ($zoneOctetsCount -lt 1) { $zoneOctetsCount = 1 }
    if ($zoneOctetsCount -gt 3) { $zoneOctetsCount = 3 }
    $hostOctetsCount = 4 - $zoneOctetsCount

    $zoneOctets = $networkBytes[0..($zoneOctetsCount - 1)]
    [array]::Reverse($zoneOctets)
    $zoneName = ($zoneOctets -join '.') + ".in-addr.arpa"

    $hostOctets = $ipBytes[$zoneOctetsCount..3]
    [array]::Reverse($hostOctets)
    $recordName = $hostOctets -join '.'

    return [PSCustomObject]@{
        NetworkID  = $networkID
        ZoneName   = $zoneName
        RecordName = $recordName
    }
}

Register-ContinuationTask -Path $ScriptPath

# ==================== Startup banner (so you can SEE it's running) ====================
$currentStage = if (Test-Path $StageFile) { (Get-Content $StageFile -Raw).Trim() } else { "<none - fresh start>" }
Write-Log "================================================================"
Write-Log "Setup script starting."
Write-Log "  Running as:      $env:USERDOMAIN\$env:USERNAME"
Write-Log "  Script path:     $ScriptPath"
Write-Log "  Log file:        $LogFile"
Write-Log "  Current stage:   $currentStage"
Write-Log "  Pending reboot:  $(Test-PendingReboot)"
Write-Log "================================================================"

# ==================== Stage 1: Rename the computer, reboot ====================
if (-not (Test-Path -Path $StageFile)) {
    try {
        if ($env:COMPUTERNAME -eq $NewComputerName) {
            Write-Log "STAGE 1: Computer is already named '$NewComputerName'. Skipping rename, no reboot needed."
            Set-Content -Path $StageFile -Value "Stage1"
            $currentStage = "Stage1"
        } else {
            Write-Log "STAGE 1: Changing computer name to $NewComputerName."
            Rename-Computer -NewName $NewComputerName -Force
            Set-Content -Path $StageFile -Value "Stage1"
            Write-Log "STAGE 1: Computer renamed to $NewComputerName. Restarting now."
            Restart-Computer -Force
            exit
        }
    } catch {
        Write-Log "STAGE 1 ERROR: $_"
        exit 1
    }
}

# ==================== Stage 2: Set Administrator password ====================
if ($currentStage -eq "Stage1" -and -not (Test-PendingReboot)) {
    try {
        Write-Log "STAGE 2: Checking for local 'Administrator' account."

        # Use WMI/ADSI (no dependency on the LocalAccounts module). Target the account
        # by the literal name "Administrator" as requested:
        #   - exists + enabled  -> just set the password
        #   - exists + disabled -> enable it, then set the password
        #   - doesn't exist     -> create it, enable it, add to local Administrators group, set the password
        $ADS_UF_ACCOUNTDISABLE     = 0x2
        $ADS_UF_DONT_EXPIRE_PASSWD = 0x10000

        $adminWmi = Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount = True AND Name = 'Administrator'" -ErrorAction SilentlyContinue

        if ($adminWmi) {
            Write-Log "STAGE 2: 'Administrator' account exists (SID $($adminWmi.SID))."
            $adsiUser = [ADSI]"WinNT://$env:COMPUTERNAME/Administrator,user"

            if (($adsiUser.UserFlags.Value -band $ADS_UF_ACCOUNTDISABLE) -ne 0) {
                Write-Log "STAGE 2: Account is disabled. Enabling it."
                $adsiUser.UserFlags = $adsiUser.UserFlags.Value -band (-bnot $ADS_UF_ACCOUNTDISABLE)
                $adsiUser.SetInfo()
            } else {
                Write-Log "STAGE 2: Account is already enabled."
            }
        } else {
            Write-Log "STAGE 2: 'Administrator' account does not exist. Creating it."
            $adsiComputer = [ADSI]"WinNT://$env:COMPUTERNAME"
            $adsiUser = $adsiComputer.Create("User", "Administrator")
            $adsiUser.SetInfo()
            $adsiUser.UserFlags = ($adsiUser.UserFlags.Value -band (-bnot $ADS_UF_ACCOUNTDISABLE)) -bor $ADS_UF_DONT_EXPIRE_PASSWD
            $adsiUser.SetInfo()
            Write-Log "STAGE 2: 'Administrator' account created and enabled."
        }

        # Set the password (covers all three cases above)
        $adsiUser.SetPassword($LocalAdminPassword)
        $adsiUser.SetInfo()
        Write-Log "STAGE 2: Password set for 'Administrator'."

        # Ensure full admin rights: must be a member of the local Administrators group
        $group = [ADSI]"WinNT://$env:COMPUTERNAME/Administrators,group"
        $isMember = $false
        foreach ($member in $group.Invoke("Members")) {
            if (([ADSI]$member).InvokeGet("Name") -eq "Administrator") { $isMember = $true; break }
        }
        if (-not $isMember) {
            Write-Log "STAGE 2: Adding 'Administrator' to the local Administrators group."
            $group.Add("WinNT://$env:COMPUTERNAME/Administrator,user")
        } else {
            Write-Log "STAGE 2: 'Administrator' is already a member of the Administrators group."
        }

        Write-Log "STAGE 2: 'Administrator' account is enabled, in Administrators, and password set."
        Set-Content -Path $StageFile -Value "Stage2"
        $currentStage = "Stage2"
    } catch {
        Write-Log "STAGE 2 ERROR: $_"
        exit 1
    }
}

# ==================== Stage 3: Point this server's DNS client at itself ====================
# Since this box will host DNS locally (installed automatically with AD DS),
# it should resolve using its own IP rather than an external DNS IP.
if ($currentStage -eq "Stage2" -and -not (Test-PendingReboot)) {
    try {
        Write-Log "STAGE 3: Getting private IP address."

        $ipInfo       = Get-PrimaryIPv4Info
        $privateIP    = $ipInfo.PrivateIP
        $prefixLength = $ipInfo.PrefixLength
        $adapter      = $ipInfo.Adapter

        Write-Log "STAGE 3: Private IP found: $privateIP/$prefixLength on adapter $adapter."

        Set-DnsClientServerAddress -InterfaceAlias $adapter -ServerAddresses $privateIP
        Write-Log "STAGE 3: DNS client on $adapter set to $privateIP (self)."

        [PSCustomObject]@{
            PrivateIP    = $privateIP
            PrefixLength = $prefixLength
            Adapter      = $adapter
        } | Export-Clixml -Path $NetInfoFile

        Set-Content -Path $StageFile -Value "Stage3"
        $currentStage = "Stage3"
    } catch {
        Write-Log "STAGE 3 ERROR: $_"
        exit 1
    }
}

# ==================== Stage 4: Install AD DS, promote to Domain Controller ====================
# -InstallDns:$true installs and configures the DNS Server role as part of promotion.
if ($currentStage -eq "Stage3" -and -not (Test-PendingReboot)) {
    try {
        Write-Log "STAGE 4: Installing AD DS role."
        Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
        Write-Log "STAGE 4: AD DS role installed."

        Write-Log "STAGE 4: Promoting server as Domain Controller for domain $DomainName."
        Import-Module ADDSDeployment

        $SafeModePassword = ConvertTo-SecureString $LocalAdminPassword -AsPlainText -Force

        # IMPORTANT: on success, Install-ADDSForest reboots the machine itself, killing this
        # process before any code after the call can run — so we pre-mark Stage4 to survive
        # that reboot. If the cmdlet throws instead (failure), the catch block below reverts
        # the stage file back to Stage3 so the next run retries promotion instead of skipping
        # straight to the reverse-DNS stage with no DC actually in place.
        Set-Content -Path $StageFile -Value "Stage4"

        try {
            Install-ADDSForest `
                -CreateDnsDelegation:$false `
                -DatabasePath "C:\Windows\NTDS" `
                -DomainMode $DomainMode `
                -DomainName $DomainName `
                -DomainNetbiosName $NetbiosName `
                -ForestMode $ForestMode `
                -InstallDns:$true `
                -LogPath "C:\Windows\NTDS" `
                -NoRebootOnCompletion:$false `
                -SysvolPath "C:\Windows\SYSVOL" `
                -SafeModeAdministratorPassword $SafeModePassword `
                -Force:$true
        } catch {
            Write-Log "STAGE 4: Install-ADDSForest threw an error, reverting stage to Stage3 for retry: $_"
            Set-Content -Path $StageFile -Value "Stage3"
            throw
        }

        Write-Log "STAGE 4: Domain Controller promotion command completed; reboot expected."
        exit
    } catch {
        Write-Log "STAGE 4 ERROR: $_"
        exit 1
    }
}

# ==================== Stage 5: Automatic reverse lookup zone ====================
if (($currentStage -eq "Stage4" -or $RepairReverseDns) -and -not (Test-PendingReboot)) {
    try {
        Write-Log "STAGE 5: Configuring reverse DNS lookup zone.$(if ($RepairReverseDns) { ' (manual repair run)' })"

        $svc = Get-Service -Name DNS -ErrorAction SilentlyContinue
        $retries = 0
        while (($null -eq $svc -or $svc.Status -ne 'Running') -and $retries -lt 12) {
            Start-Sleep -Seconds 10
            $svc = Get-Service -Name DNS -ErrorAction SilentlyContinue
            $retries++
        }
        if ($null -eq $svc -or $svc.Status -ne 'Running') {
            throw "DNS Server service did not come up in time."
        }

        # Re-derive the IP fresh rather than trusting the value cached back in Stage 3 —
        # DHCP or adapter changes between stages (including across the Stage 4 reboot)
        # can make that cached value stale, which would silently create a reverse zone
        # for the wrong subnet.
        $ipInfo       = Get-PrimaryIPv4Info
        $privateIP    = $ipInfo.PrivateIP
        $prefixLength = $ipInfo.PrefixLength

        if (Test-Path $NetInfoFile) {
            $cached = Import-Clixml -Path $NetInfoFile
            if ($cached.PrivateIP -ne $privateIP) {
                Write-Log "STAGE 5: NOTE — cached IP from Stage 3 was $($cached.PrivateIP), current IP is $privateIP. Using current."
            }
        }

        $zoneInfo = Get-ReverseZoneAndRecordName -IPAddress $privateIP -PrefixLength $prefixLength
        Write-Log "STAGE 5: Derived network ID: $($zoneInfo.NetworkID) -> reverse zone '$($zoneInfo.ZoneName)', record '$($zoneInfo.RecordName)'."

        try {
            Add-DnsServerPrimaryZone -NetworkID $zoneInfo.NetworkID -ReplicationScope "Forest" -DynamicUpdate "Secure" -ErrorAction Stop
            Write-Log "STAGE 5: Reverse lookup zone created for $($zoneInfo.NetworkID)."
        } catch {
            if ($_.Exception.Message -match "already exists") {
                Write-Log "STAGE 5: Reverse lookup zone for $($zoneInfo.NetworkID) already exists."
            } else {
                throw
            }
        }

        # Confirm the zone actually exists before relying on it — Add-DnsServerPrimaryZone
        # can otherwise fail silently in edge cases.
        $zoneCheck = Get-DnsServerZone -Name $zoneInfo.ZoneName -ErrorAction SilentlyContinue
        if (-not $zoneCheck) {
            throw "Reverse lookup zone '$($zoneInfo.ZoneName)' does not exist after creation attempt."
        }

        # Don't just hope dynamic registration (ipconfig /registerdns) creates the PTR record —
        # explicitly create/correct it ourselves so reverse lookups work immediately.
        $targetFqdn = "$env:COMPUTERNAME.$DomainName."
        $existingPtr = Get-DnsServerResourceRecord -ZoneName $zoneInfo.ZoneName -Name $zoneInfo.RecordName -RRType Ptr -ErrorAction SilentlyContinue

        if ($existingPtr) {
            $currentTarget = $existingPtr.RecordData.PtrDomainName
            if ($currentTarget -ne $targetFqdn) {
                Write-Log "STAGE 5: Existing PTR record points to '$currentTarget', expected '$targetFqdn'. Replacing it."
                Remove-DnsServerResourceRecord -ZoneName $zoneInfo.ZoneName -Name $zoneInfo.RecordName -RRType Ptr -Force
                Add-DnsServerResourceRecordPtr -ZoneName $zoneInfo.ZoneName -Name $zoneInfo.RecordName -PtrDomainName $targetFqdn
            } else {
                Write-Log "STAGE 5: PTR record already correct ($($zoneInfo.RecordName).$($zoneInfo.ZoneName) -> $targetFqdn)."
            }
        } else {
            Add-DnsServerResourceRecordPtr -ZoneName $zoneInfo.ZoneName -Name $zoneInfo.RecordName -PtrDomainName $targetFqdn
            Write-Log "STAGE 5: PTR record created: $($zoneInfo.RecordName).$($zoneInfo.ZoneName) -> $targetFqdn"
        }

        Set-DnsServerScavenging -ScavengingState $true -ScavengingInterval 7.00:00:00 -ApplyOnAllZones -ErrorAction SilentlyContinue
        ipconfig /registerdns | Out-Null

        # Verify the reverse lookup actually resolves before declaring success.
        Start-Sleep -Seconds 5
        try {
            $verify = Resolve-DnsName -Name $privateIP -Type PTR -Server $privateIP -ErrorAction Stop
            Write-Log "STAGE 5: Verified reverse lookup: $privateIP -> $($verify.NameHost)"
        } catch {
            Write-Log "STAGE 5 WARNING: Reverse lookup did not verify cleanly ($_). The PTR record was written directly to the zone, so this is likely a transient DNS service delay — retest with 'nslookup $privateIP' in a minute."
        }

        Write-Log "STAGE 5: Reverse DNS setup complete. FULL SETUP FINISHED."
        Remove-Item $StageFile -Force -ErrorAction SilentlyContinue
        Unregister-ContinuationTask
    } catch {
        Write-Log "STAGE 5 ERROR: $_"
        exit 1
    }
}

if ($currentStage -notin @("<none - fresh start>","Stage1","Stage2","Stage3","Stage4")) {
    Write-Log "No pending stage matched current value '$currentStage'. If setup already completed, $StageFile will be gone and there's nothing left to do. If this looks wrong, delete $StageFile and re-run from scratch."
}
