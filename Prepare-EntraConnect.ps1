# =============================================================================
# Prepares AADCONNECT01's network (static IP + DNS pointed at the DC), verifies
# connectivity to the Domain Controller on every port Entra Connect will need,
# then domain-joins it to your AD domain. Reboot-resilient like Setup-ADDS-DNS.ps1
# — if the domain-join reboot happens, it re-launches itself and finishes the
# verification step automatically.
#
# WHERE TO RUN THIS: on AADCONNECT01 itself (not app010w001), from an elevated
# PowerShell console, AFTER AADCONNECT01 has been created as a VM and you've
# fixed app010w001's own static IP/DNS (see the earlier conversation).
#
# SAVE THIS FILE AS: C:\Scripts\Join-AADCONNECT01-Domain.ps1
# RUN IT AS:          C:\Scripts\Join-AADCONNECT01-Domain.ps1
# =============================================================================

# ==================== FILL THESE IN BEFORE RUNNING ====================
# Every value below MUST be checked/edited to match your actual environment
# before you run this script.


$NewComputerName = "AADCONNECT01"          # <<< FILL IN if you want a different name
$StaticIP        = "10.10.1.5"            # <<< FILL IN: a free IP in app010w001's subnet
$PrefixLength    = 24                      # <<< FILL IN: subnet prefix length (match app010w001 — /24 shown here)
$DefaultGateway  = "10.10.1.1"             # <<< FILL IN: same default gateway as app010w001
$DnsServerIP     = "10.10.1.4"            # <<< FILL IN: app010w001's own static IP (it IS the DNS server)
$DomainFqdn      = "nishant360.online"     # <<< FILL IN: your AD domain name


# You will be prompted for Domain Admin credentials interactively when this
# script reaches the domain-join step — they are never stored in this file.

# ==================== Internals — no need to edit below this line ====================
$ErrorActionPreference = "Stop"

$DurableScriptPath = "C:\Scripts\Join-AADCONNECT01-Domain.ps1"
$StateDir          = Split-Path -Path $DurableScriptPath -Parent
if (-not (Test-Path $StateDir)) { New-Item -Path $StateDir -ItemType Directory -Force | Out-Null }

$LogFile   = Join-Path $StateDir "JoinDomain.log"
$StageFile = Join-Path $StateDir "JoinDomainStage.txt"

$CurrentPath = $MyInvocation.MyCommand.Path
if ($CurrentPath -and (Resolve-Path $CurrentPath).Path -ne (Resolve-Path -Path $DurableScriptPath -ErrorAction SilentlyContinue).Path) {
    Copy-Item -Path $CurrentPath -Destination $DurableScriptPath -Force
} elseif (-not (Test-Path $DurableScriptPath)) {
    Write-Warning "Script has no backing file. Save this script as $DurableScriptPath and re-run it from there so it can survive the domain-join reboot."
    exit 1
}
$ScriptPath = $DurableScriptPath

if (-not [Environment]::Is64BitProcess) {
    $sysNative = "$env:windir\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    $ps64 = if (Test-Path $sysNative) { $sysNative } else { "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" }
    Write-Warning "Running under 32-bit PowerShell; relaunching under $ps64 ..."
    & $ps64 -NoProfile -ExecutionPolicy Bypass -File $ScriptPath
    exit $LASTEXITCODE
}

function Write-Log {
    param ([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp - $message"
    Write-Host $line
    $line | Out-File -FilePath $LogFile -Append
}

function Register-ContinuationTask {
    param ([string]$Path)
    $taskName = "AADConnectJoinContinuation"
    if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        $action    = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Path`""
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Log "Registered scheduled task '$taskName' to resume after reboot."
    }
}

function Unregister-ContinuationTask {
    Unregister-ScheduledTask -TaskName "AADConnectJoinContinuation" -Confirm:$false -ErrorAction SilentlyContinue
}

Register-ContinuationTask -Path $ScriptPath

$currentStage = if (Test-Path $StageFile) { (Get-Content $StageFile -Raw).Trim() } else { "<none - fresh start>" }
Write-Log "================================================================"
Write-Log "AADCONNECT01 domain-join script starting."
Write-Log "  Running as:    $env:USERDOMAIN\$env:USERNAME"
Write-Log "  Script path:   $ScriptPath"
Write-Log "  Log file:      $LogFile"
Write-Log "  Current stage: $currentStage"
Write-Log "================================================================"

# ==================== Stage 1: Static IP, DNS, connectivity check ====================
if ($currentStage -eq "<none - fresh start>") {
    try {
        Write-Log "STAGE 1: Configuring static IP $StaticIP/$PrefixLength, gateway $DefaultGateway."

        $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
        if (-not $adapter) { throw "No active network adapter found." }
        $ifIndex = $adapter.ifIndex

        # Remove any existing DHCP-assigned IPv4 address on this interface before adding a static one
        Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -eq 'Dhcp' } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        Set-NetIPInterface -InterfaceIndex $ifIndex -Dhcp Disabled -ErrorAction SilentlyContinue

        $existing = Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $StaticIP }
        if (-not $existing) {
            New-NetIPAddress -InterfaceIndex $ifIndex -IPAddress $StaticIP -PrefixLength $PrefixLength -DefaultGateway $DefaultGateway | Out-Null
            Write-Log "STAGE 1: Static IP $StaticIP/$PrefixLength set on interface $ifIndex."
        } else {
            Write-Log "STAGE 1: Static IP $StaticIP already present on interface $ifIndex."
        }

        Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses $DnsServerIP
        Write-Log "STAGE 1: DNS client set to $DnsServerIP (app010w001)."

        Write-Log "STAGE 1: Verifying connectivity to the Domain Controller ($DnsServerIP) on required ports..."
        $ports = @(53, 88, 135, 389, 445, 464, 636)
        $failed = @()
        foreach ($port in $ports) {
            $result = Test-NetConnection -ComputerName $DnsServerIP -Port $port -WarningAction SilentlyContinue
            $status = if ($result.TcpTestSucceeded) { "OK" } else { "FAILED" }
            Write-Log ("STAGE 1:   Port {0,-5} -> {1}" -f $port, $status)
            if (-not $result.TcpTestSucceeded) { $failed += $port }
        }

        if ($failed.Count -gt 0) {
            throw "Connectivity check failed on port(s): $($failed -join ', '). Fix networking/NSG/firewall to $DnsServerIP before joining the domain. Not proceeding."
        }

        Write-Log "STAGE 1: All connectivity checks passed."
        Set-Content -Path $StageFile -Value "Stage1"
        $currentStage = "Stage1"
    } catch {
        Write-Log "STAGE 1 ERROR: $_"
        exit 1
    }
}

# ==================== Stage 2: Rename (if needed) and domain join ====================
if ($currentStage -eq "Stage1") {
    try {
        if ($env:COMPUTERNAME -ne $NewComputerName) {
            Write-Log "STAGE 2: Renaming computer to $NewComputerName."
            Rename-Computer -NewName $NewComputerName -Force
            Set-Content -Path $StageFile -Value "Stage1-Renamed"
            Write-Log "STAGE 2: Renamed. Restarting before domain join."
            Restart-Computer -Force
            exit
        } else {
            Write-Log "STAGE 2: Computer already named $NewComputerName, skipping rename."
            Set-Content -Path $StageFile -Value "Stage1-Renamed"
            $currentStage = "Stage1-Renamed"
        }
    } catch {
        Write-Log "STAGE 2 ERROR: $_"
        exit 1
    }
}

if ($currentStage -eq "Stage1-Renamed") {
    try {
        Write-Log "STAGE 3: Ready to domain-join to $DomainFqdn."
        Write-Log "STAGE 3: You will be prompted for Domain Admin credentials now (not stored in this script)."

        $cred = Get-Credential -Message "Enter Domain Admin credentials for $DomainFqdn (e.g. $DomainFqdn\youradmin)"

        Set-Content -Path $StageFile -Value "Stage2-Joining"
        Add-Computer -DomainName $DomainFqdn -Credential $cred -Force -Restart
        # Add-Computer with -Restart reboots immediately on success; anything after this line
        # only runs if it failed without rebooting.
        Write-Log "STAGE 3: Add-Computer returned without rebooting — check for errors above."
    } catch {
        Write-Log "STAGE 3 ERROR: $_"
        Write-Log "STAGE 3: Reverting stage to Stage1-Renamed so you can retry the domain join."
        Set-Content -Path $StageFile -Value "Stage1-Renamed"
        exit 1
    }
}

# ==================== Stage 4: Post-reboot verification ====================
if ($currentStage -eq "Stage2-Joining") {
    try {
        Write-Log "STAGE 4: Verifying domain join."
        $cs = Get-CimInstance Win32_ComputerSystem
        if ($cs.PartOfDomain -and $cs.Domain -eq $DomainFqdn) {
            Write-Log "STAGE 4: SUCCESS — $env:COMPUTERNAME is joined to $($cs.Domain)."
            Write-Log "STAGE 4: whoami -> $(whoami)"
            Write-Log "STAGE 4: Domain join complete. Next: run Prepare-EntraConnect.ps1, then follow the manual Entra Connect wizard steps."
            Remove-Item $StageFile -Force -ErrorAction SilentlyContinue
            Unregister-ContinuationTask
        } else {
            throw "Computer does not appear to be joined to $DomainFqdn (current domain/workgroup: $($cs.Domain))."
        }
    } catch {
        Write-Log "STAGE 4 ERROR: $_"
        exit 1
    }
}
