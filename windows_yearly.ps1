# ============================================================
# Windows Yearly SysAdmin Tasks
# Run as: Administrator
# Schedule: Yearly (e.g., January 1st via Task Scheduler)
# ============================================================

$LogDir  = "C:\SysAdmin\Logs"
$Year    = Get-Date -Format "yyyy"
$LogFile = "$LogDir\yearly_$Year.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Write-Log "========== YEARLY SYSADMIN REPORT : $Year =========="

# ----------------------------------------------------------
# TASK 1: Disaster Recovery (DR) Drill Simulation
# ----------------------------------------------------------
Write-Log "--- TASK 1: Disaster Recovery Drill ---"

# Test restore from most recent backup
Write-Log "Locating most recent backup..."
$wbVersions = wbadmin get versions 2>&1
if ($wbVersions -match "Backup time") {
    $latestVersion = ($wbVersions | Select-String "Backup version identifier") | Select-Object -Last 1
    Write-Log "Most recent backup version: $latestVersion"
    Write-Log "ACTION: Initiate a test restore of critical files using:"
    Write-Log "  wbadmin start recovery /version:<ID> /itemType:File /items:C:\critical-folder /recoveryTarget:D:\TestRestore"
} else {
    Write-Log "No backup versions found! DR drill CANNOT proceed!" "WARN"
}

# Verify DR documentation exists
$drDocs = @("C:\SysAdmin\DR-Plan.docx", "C:\SysAdmin\DR-Runbook.pdf", "\\server\DR\runbook.docx")
foreach ($doc in $drDocs) {
    if (Test-Path $doc) {
        $age = ((Get-Date) - (Get-Item $doc).LastWriteTime).Days
        Write-Log "DR document found: $doc (last modified $age days ago)"
        if ($age -gt 180) { Write-Log "WARNING: DR document is over 6 months old — update it!" "WARN" }
    }
}

# Network connectivity to backup/DR site
$drSites = @("8.8.8.8", "1.1.1.1")  # Replace with actual DR site IPs
foreach ($site in $drSites) {
    $ping = Test-Connection -ComputerName $site -Count 2 -ErrorAction SilentlyContinue
    if ($ping) {
        Write-Log "DR connectivity to $site: OK (avg $([math]::Round(($ping | Measure-Object -Property ResponseTime -Average).Average))ms)"
    } else {
        Write-Log "DR connectivity to $site: FAILED" "WARN"
    }
}

# ----------------------------------------------------------
# TASK 2: Infrastructure Upgrade Planning
# ----------------------------------------------------------
Write-Log "--- TASK 2: Infrastructure Upgrade Planning ---"

# OS end-of-life check
$os = Get-CimInstance Win32_OperatingSystem
$osName    = $os.Caption
$osBuild   = $os.BuildNumber
$osVersion = $os.Version
Write-Log "Current OS: $osName | Build: $osBuild | Version: $osVersion"

# Known EOL dates (update these as Microsoft announcements change)
$eolMap = @{
    "10240" = "2025-10-14"  # Windows 10 1507
    "19041" = "2025-10-14"  # Windows 10 2004
    "19044" = "2025-10-14"  # Windows 10 21H2
    "22621" = "2027-11-02"  # Windows 11 22H2
}

if ($eolMap.ContainsKey($osBuild)) {
    $eolDate = [datetime]::ParseExact($eolMap[$osBuild], "yyyy-MM-dd", $null)
    $daysLeft = ($eolDate - (Get-Date)).Days
    Write-Log "OS EOL Date: $($eolMap[$osBuild]) | Days remaining: $daysLeft"
    if ($daysLeft -lt 365) { Write-Log "WARNING: OS EOL within 12 months — plan upgrade!" "WARN" }
}

# Hardware age
$bios = Get-CimInstance Win32_BIOS
$cs   = Get-CimInstance Win32_ComputerSystem
Write-Log "Hardware: $($cs.Manufacturer) $($cs.Model)"
Write-Log "BIOS: $($bios.SMBIOSBIOSVersion) | Date: $($bios.ReleaseDate)"

# Storage health (SMART via WMI)
Write-Log "Storage health:"
Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Log "  $($_.FriendlyName) | Health: $($_.HealthStatus) | Size: $([math]::Round($_.Size/1GB,1))GB | Type: $($_.MediaType)"
    if ($_.HealthStatus -ne "Healthy") { Write-Log "  WARNING: Disk health is $($_.HealthStatus)!" "WARN" }
}

# ----------------------------------------------------------
# TASK 3: Security Policy Review
# ----------------------------------------------------------
Write-Log "--- TASK 3: Security Policy Review ---"

# Local security policy export
Write-Log "Exporting local security policy..."
secedit /export /cfg "$LogDir\secpolicy_$Year.cfg" /quiet 2>&1
if (Test-Path "$LogDir\secpolicy_$Year.cfg") {
    Write-Log "Security policy exported to $LogDir\secpolicy_$Year.cfg"
    # Key policy checks
    $policy = Get-Content "$LogDir\secpolicy_$Year.cfg" -ErrorAction SilentlyContinue
    $minPwdLen = ($policy | Select-String "MinimumPasswordLength").ToString()
    $maxPwdAge = ($policy | Select-String "MaximumPasswordAge").ToString()
    $lockout   = ($policy | Select-String "LockoutBadCount").ToString()
    Write-Log "  $minPwdLen"
    Write-Log "  $maxPwdAge"
    Write-Log "  $lockout"
}

# Password policy
Write-Log "Password policy (net accounts):"
net accounts 2>&1 | ForEach-Object { Write-Log "  $_" }

# Audit policy
Write-Log "Audit policy:"
auditpol /get /category:* 2>&1 | Where-Object { $_ -match "Success|Failure" } | Select-Object -First 15 | ForEach-Object {
    Write-Log "  $_"
}

# Check for Windows Hello / MFA
Write-Log "ACTION: Verify MFA is enforced for all admin accounts and remote access." "INFO"
Write-Log "ACTION: Review and update the Information Security Policy document." "INFO"

# ----------------------------------------------------------
# TASK 4: License Renewals & Compliance
# ----------------------------------------------------------
Write-Log "--- TASK 4: License Renewals & Compliance ---"

# Windows activation status
$licenseStatus = (Get-WmiObject SoftwareLicensingProduct | Where-Object {
    $_.PartialProductKey -and $_.Name -match "Windows"
} | Select-Object Name, LicenseStatus | Select-Object -First 1)

if ($licenseStatus) {
    $status = switch ($licenseStatus.LicenseStatus) {
        0 { "Unlicensed" } 1 { "Licensed" } 2 { "OOBGrace" } 3 { "OOTGrace" }
        4 { "NonGenuineGrace" } 5 { "Notification" } 6 { "ExtendedGrace" }
    }
    Write-Log "Windows License: $($licenseStatus.Name) | Status: $status"
    if ($licenseStatus.LicenseStatus -ne 1) { Write-Log "WARNING: Windows is NOT properly licensed!" "WARN" }
}

# SSL Certificate expiry check (all stores)
Write-Log "SSL Certificates expiring in next 12 months:"
$stores = @("LocalMachine\My", "LocalMachine\Root", "LocalMachine\WebHosting")
foreach ($store in $stores) {
    Get-ChildItem "Cert:\$store" -ErrorAction SilentlyContinue | Where-Object {
        $_.NotAfter -lt (Get-Date).AddDays(365)
    } | ForEach-Object {
        $daysLeft = ([datetime]$_.NotAfter - (Get-Date)).Days
        Write-Log "  [$store] $($_.Subject) | Expires: $($_.NotAfter.ToShortDateString()) ($daysLeft days)" "WARN"
    }
}

# Installed software license audit
Write-Log "Installed software audit (all users):"
$allSoftware  = Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*
$allSoftware += Get-ItemProperty HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue
$allSoftware | Where-Object { $_.DisplayName } | Sort-Object DisplayName | ForEach-Object {
    Write-Log "  $($_.DisplayName) $($_.DisplayVersion)"
}

# ----------------------------------------------------------
# TASK 5: Capacity Planning
# ----------------------------------------------------------
Write-Log "--- TASK 5: Capacity Planning ---"

# Current resource summary
$cs  = Get-CimInstance Win32_ComputerSystem
$os  = Get-CimInstance Win32_OperatingSystem
$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1

Write-Log "=== Current Capacity ==="
Write-Log "CPU: $($cpu.Name) | Cores: $($cpu.NumberOfCores) | Logical CPUs: $($cpu.NumberOfLogicalProcessors)"
Write-Log "RAM: ${ramGB}GB"

Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used } | ForEach-Object {
    $totalGB = [math]::Round(($_.Used + $_.Free) / 1GB, 2)
    $usedGB  = [math]::Round($_.Used / 1GB, 2)
    $freeGB  = [math]::Round($_.Free / 1GB, 2)
    $pct     = [math]::Round(($usedGB / $totalGB) * 100, 1)
    Write-Log "Disk $($_.Name): ${totalGB}GB total | ${usedGB}GB used ($pct%) | ${freeGB}GB free"
    if ($pct -gt 70) { Write-Log "  PLANNING NOTE: $($_.Name) drive is over 70% full — plan expansion" "WARN" }
}

# Network adapter info
Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
    Write-Log "NIC: $($_.Name) | Speed: $([math]::Round($_.LinkSpeed/1Gb,1))Gbps | MAC: $($_.MacAddress)"
}

Write-Log "=== 12-Month Planning Checklist ==="
Write-Log "  [ ] Hardware refresh cycle review (servers >5 years old)"
Write-Log "  [ ] Cloud migration assessment (workloads suitable for Azure/AWS)"
Write-Log "  [ ] Storage growth forecast (add capacity if >70% used)"
Write-Log "  [ ] Network bandwidth review (upgrade NICs/switches if saturated)"
Write-Log "  [ ] Virtualization consolidation opportunities"
Write-Log "  [ ] Budget submission for infrastructure needs"

Write-Log "========== YEARLY REPORT COMPLETE — Log: $LogFile =========="
