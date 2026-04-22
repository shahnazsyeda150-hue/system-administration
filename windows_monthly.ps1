# ============================================================
# Windows Monthly SysAdmin Tasks
# Run as: Administrator
# Schedule: Monthly (e.g., 1st of month, 5:00 AM via Task Scheduler)
# ============================================================

$LogDir  = "C:\SysAdmin\Logs"
$Date    = Get-Date -Format "yyyy-MM"
$LogFile = "$LogDir\monthly_$Date.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Write-Log "========== MONTHLY SYSADMIN REPORT : $Date =========="

# ----------------------------------------------------------
# TASK 1: Apply Major Updates & Patches (OS + firmware)
# ----------------------------------------------------------
Write-Log "--- TASK 1: Major Updates & Patches ---"

try {
    $UpdateSession  = New-Object -ComObject Microsoft.Update.Session
    $UpdateSearcher = $UpdateSession.CreateUpdateSearcher()

    # Search all updates including drivers and firmware
    $result = $UpdateSearcher.Search("IsInstalled=0")
    Write-Log "Total pending updates (all categories): $($result.Updates.Count)"

    $result.Updates | ForEach-Object {
        $cats = ($_.Categories | ForEach-Object { $_.Name }) -join ", "
        Write-Log "  [$cats] $($_.Title)"
    }

    if ($result.Updates.Count -gt 0) {
        Write-Log "ACTION: Review above and apply all critical/security updates via WSUS or Windows Update." "WARN"
    }
} catch {
    Write-Log "Update check error: $_" "WARN"
}

# Check firmware via UEFI (modern systems)
$fwUpdates = Get-WmiObject -Namespace "root\WMI" -Class "MSStorageDriver_FailurePredictStatus" -ErrorAction SilentlyContinue
if ($fwUpdates) {
    Write-Log "Storage health check complete"
}

# ----------------------------------------------------------
# TASK 2: Security Audit (firewall, open ports, vulnerability scan)
# ----------------------------------------------------------
Write-Log "--- TASK 2: Security Audit ---"

# Windows Firewall status
$profiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
if ($profiles) {
    $profiles | ForEach-Object {
        Write-Log "Firewall Profile [$($_.Name)]: Enabled=$($_.Enabled) | DefaultInbound=$($_.DefaultInboundAction) | DefaultOutbound=$($_.DefaultOutboundAction)"
    }
} else {
    Write-Log "Could not retrieve firewall profile info" "WARN"
}

# Open listening ports
Write-Log "Listening TCP ports:"
$listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Sort-Object LocalPort
$listeners | ForEach-Object {
    $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
    Write-Log "  Port $($_.LocalPort) — Process: $($proc.Name) (PID $($_.OwningProcess))"
}

# Open UDP ports
$udpListeners = Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Sort-Object LocalPort | Select-Object -First 20
Write-Log "Top UDP endpoints: $($udpListeners.Count)"

# Shared folders audit
Write-Log "Network shares:"
Get-SmbShare -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Log "  Share: $($_.Name) | Path: $($_.Path) | Description: $($_.Description)"
}

# Windows Defender full scan trigger (runs asynchronously)
Write-Log "Triggering Windows Defender full scan..."
Start-MpScan -ScanType FullScan -ErrorAction SilentlyContinue
Write-Log "Defender scan initiated (runs in background)"

# ----------------------------------------------------------
# TASK 3: Performance Tuning (trend analysis)
# ----------------------------------------------------------
Write-Log "--- TASK 3: Performance Tuning ---"

# Top CPU-consuming processes
Write-Log "Top 10 processes by CPU time:"
Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 | ForEach-Object {
    Write-Log ("  {0,-30} CPU:{1,8}s  Mem:{2,8}MB" -f $_.Name, [math]::Round($_.CPU,1), [math]::Round($_.WorkingSet64/1MB,1))
}

# Top memory consumers
Write-Log "Top 5 processes by memory:"
Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object {
    Write-Log ("  {0,-30} Mem:{1,8}MB" -f $_.Name, [math]::Round($_.WorkingSet64/1MB,1))
}

# Page file usage
$pageFile = Get-WmiObject Win32_PageFileUsage -ErrorAction SilentlyContinue
if ($pageFile) {
    $pageFile | ForEach-Object {
        Write-Log "PageFile: $($_.Name) | Current: $($_.CurrentUsage)MB | Peak: $($_.PeakUsage)MB | Size: $($_.AllocatedBaseSize)MB"
    }
}

# ----------------------------------------------------------
# TASK 4: Backup Policy Review
# ----------------------------------------------------------
Write-Log "--- TASK 4: Backup Policy Review ---"

$wbSummary = wbadmin get status 2>&1
Write-Log "WBAdmin Status: $($wbSummary | Select-Object -First 5 | Out-String)"

$wbVersions = wbadmin get versions 2>&1
$versionCount = ($wbVersions | Select-String "Backup time").Count
Write-Log "Total backup versions on record: $versionCount"

# VSS shadow copy inventory
$shadows = Get-WmiObject Win32_ShadowCopy -ErrorAction SilentlyContinue
if ($shadows) {
    Write-Log "Shadow copies: $($shadows.Count)"
    $shadows | ForEach-Object {
        Write-Log "  $($_.InstallDate) | Volume: $($_.VolumeName) | ID: $($_.ID)"
    }
} else {
    Write-Log "No shadow copies found" "WARN"
}

Write-Log "ACTION: Review retention policy, offsite backup status, and recovery point objectives (RPO)." "INFO"

# ----------------------------------------------------------
# TASK 5: Inventory & Asset Audit
# ----------------------------------------------------------
Write-Log "--- TASK 5: Inventory & Asset Audit ---"

# Hardware summary
$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
Write-Log "Computer: $($cs.Name) | Model: $($cs.Model) | Manufacturer: $($cs.Manufacturer)"
Write-Log "BIOS Version: $($bios.SMBIOSBIOSVersion) | Release: $($bios.ReleaseDate)"

$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
Write-Log "CPU: $($cpu.Name) | Cores: $($cpu.NumberOfCores) | Logical: $($cpu.NumberOfLogicalProcessors)"

$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 2)
Write-Log "RAM: ${ramGB}GB"

# Disk inventory
Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Log "Disk: $($_.FriendlyName) | Size: $([math]::Round($_.Size/1GB,1))GB | Health: $($_.HealthStatus) | Type: $($_.MediaType)"
}

# Installed software inventory (top 30 by install date)
Write-Log "Recently installed software:"
$software = Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue
$software += Get-ItemProperty HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue
$software | Where-Object { $_.DisplayName } | Sort-Object InstallDate -Descending | Select-Object -First 20 | ForEach-Object {
    Write-Log "  $($_.DisplayName) v$($_.DisplayVersion) [Installed: $($_.InstallDate)]"
}

# Expiring SSL certificates (check if certutil available)
Write-Log "Checking local machine certificates for expiry..."
Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
    $_.NotAfter -lt (Get-Date).AddDays(60)
} | ForEach-Object {
    Write-Log "EXPIRING SOON: $($_.Subject) | Expires: $($_.NotAfter.ToShortDateString())" "WARN"
}

Write-Log "========== MONTHLY REPORT COMPLETE — Log: $LogFile =========="
