# =============================================================================
# Builds the OU structure, test users, and security groups described in the
# Day 3 Hybrid Identity guide (Section 7): a top-level OU containing Users,
# Groups, Computers, ServiceAccounts, Admins, and SyncUsers — with SyncUsers
# being the scope Entra Connect's OU filtering will later sync to the cloud.
#
# Fully idempotent — safe to re-run. Anything that already exists is skipped
# rather than duplicated or erroring out.
#
# WHERE TO RUN THIS: on app010w001 (the Domain Controller), from an elevated
# PowerShell console, logged in as a Domain Admin. The ActiveDirectory module
# is already present on a DC — no extra install needed.
#
# SAVE THIS FILE AS: C:\Scripts\New-OUStructure.ps1
# RUN IT AS:          C:\Scripts\New-OUStructure.ps1
# =============================================================================

# ==================== FILL THESE IN BEFORE RUNNING ====================

$OuRoot = "MinjTech"   # <<< FILL IN if you want a different top-level OU name

$SubOUs = @("Users", "Groups", "Computers", "ServiceAccounts", "Admins", "SyncUsers")

# Lab test accounts — created inside OU=SyncUsers. Edit names/logons as needed.
$TestUsers = @(
    @{ First = "Nishant"; Last = "Minj";    Logon = "nishant" }
    @{ First = "Test";    Last = "User01";  Logon = "testuser01" }
    @{ First = "Test";    Last = "User02";  Logon = "testuser02" }
    @{ First = "Cloud";   Last = "Admin";   Logon = "cloudadmin" }
)

$DefaultPassword = "ChangeMe#12345"   # <<< FILL IN: password for the accounts above — LAB USE ONLY, change this

# Security groups — created inside OU=Groups. Members reference the Logon
# values above; add/remove names as needed.
$Groups = @(
    @{ Name = "GG-Hybrid-Users"; Members = @("nishant", "testuser01", "testuser02") }
    @{ Name = "GG-DevOps";       Members = @("testuser01", "testuser02") }
    @{ Name = "GG-CloudUsers";   Members = @("nishant", "cloudadmin") }
)

$ProtectTopOuFromDeletion = $true   # recommended; set $false only if you have a reason to allow accidental deletion

# ==================== Internals — no need to edit below this line ====================
$ErrorActionPreference = "Stop"

$LogDir = "C:\Scripts"
if (-not (Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
$LogFile = Join-Path $LogDir "New-OUStructure.log"

function Write-Log {
    param ([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp - $message"
    Write-Host $line
    $line | Out-File -FilePath $LogFile -Append
}

Write-Log "================================================================"
Write-Log "OU/User/Group build starting."
Write-Log "================================================================"

Import-Module ActiveDirectory

$adDomain  = Get-ADDomain
$domainDN  = $adDomain.DistinguishedName
$upnSuffix = $adDomain.DNSRoot
Write-Log "Domain: $upnSuffix ($domainDN)"

# ---------- Top-level OU ----------
$topOuDN = "OU=$OuRoot,$domainDN"
if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$OuRoot'" -SearchBase $domainDN -SearchScope OneLevel -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name $OuRoot -Path $domainDN -ProtectedFromAccidentalDeletion:$ProtectTopOuFromDeletion
    Write-Log "Created top-level OU: $topOuDN"
} else {
    Write-Log "Top-level OU already exists: $topOuDN"
}

# ---------- Sub-OUs ----------
foreach ($sub in $SubOUs) {
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$sub'" -SearchBase $topOuDN -SearchScope OneLevel -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $sub -Path $topOuDN -ProtectedFromAccidentalDeletion:$ProtectTopOuFromDeletion
        Write-Log "Created OU: OU=$sub,$topOuDN"
    } else {
        Write-Log "OU already exists: OU=$sub,$topOuDN"
    }
}

$syncUsersOuDN = "OU=SyncUsers,$topOuDN"
$groupsOuDN    = "OU=Groups,$topOuDN"

# ---------- Test users ----------
$securePassword = ConvertTo-SecureString $DefaultPassword -AsPlainText -Force

foreach ($u in $TestUsers) {
    $existing = Get-ADUser -Filter "SamAccountName -eq '$($u.Logon)'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "User already exists, skipping: $($u.Logon)"
        continue
    }

    New-ADUser `
        -Name "$($u.First) $($u.Last)" `
        -GivenName $u.First `
        -Surname $u.Last `
        -SamAccountName $u.Logon `
        -UserPrincipalName "$($u.Logon)@$upnSuffix" `
        -Path $syncUsersOuDN `
        -AccountPassword $securePassword `
        -Enabled $true `
        -ChangePasswordAtLogon $false `
        -PasswordNeverExpires $true   # LAB ONLY — do not use PasswordNeverExpires in production

    Write-Log "Created user: $($u.Logon) ($($u.Logon)@$upnSuffix) in $syncUsersOuDN"
}

# ---------- Groups ----------
foreach ($g in $Groups) {
    $existingGroup = Get-ADGroup -Filter "Name -eq '$($g.Name)'" -ErrorAction SilentlyContinue
    if (-not $existingGroup) {
        New-ADGroup -Name $g.Name -GroupScope Global -GroupCategory Security -Path $groupsOuDN
        Write-Log "Created group: $($g.Name) in $groupsOuDN"
    } else {
        Write-Log "Group already exists: $($g.Name)"
    }

    $currentMembers = @(Get-ADGroupMember -Identity $g.Name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName)
    foreach ($m in $g.Members) {
        if ($currentMembers -contains $m) {
            Write-Log "  $m already a member of $($g.Name)"
        } else {
            $memberExists = Get-ADUser -Filter "SamAccountName -eq '$m'" -ErrorAction SilentlyContinue
            if ($memberExists) {
                Add-ADGroupMember -Identity $g.Name -Members $m
                Write-Log "  Added $m to $($g.Name)"
            } else {
                Write-Log "  SKIPPED adding $m to $($g.Name) — no such user exists"
            }
        }
    }
}

# ---------- Summary ----------
Write-Log "================================================================"
Write-Log "Summary — users in $syncUsersOuDN :"
Get-ADUser -Filter * -SearchBase $syncUsersOuDN -Properties UserPrincipalName |
    ForEach-Object { Write-Log "  $($_.SamAccountName)  ->  $($_.UserPrincipalName)" }

Write-Log "Summary — groups in $groupsOuDN :"
foreach ($g in $Groups) {
    $members = (Get-ADGroupMember -Identity $g.Name | Select-Object -ExpandProperty SamAccountName) -join ", "
    Write-Log "  $($g.Name)  ->  $members"
}
Write-Log "================================================================"
Write-Log "Done. Full OU tree, test users, and groups are ready."
