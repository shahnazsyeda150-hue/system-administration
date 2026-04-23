# ============================================================
# Windows Weekly SysAdmin Tasks
# Run as: Administrator
# Schedule: Weekly (e.g., Sunday 6:00 AM via Task Scheduler)
# ============================================================

$LogDir  = "C:\SysAdmin\Logs"
$Date    = Get-Date -Format "yyyy-MM-dd"
$LogFile = "$LogDir\weekly_$Date.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Write-Log "========== WEEKLY SYSADMIN REPORT : $Date =========="

# ----------------------------------------------------------
# TASK 1: Apply Non-Critical Patches (Windows Update)
# ----------------------------------------------------------
Write-Log "--- TASK 1: Windows Update Check ---"

try {
    $UpdateSession = New-Object -ComObject Microsoft.Update.Session
    $UpdateSearcher = $UpdateSession.CreateUpdateSearcher()
    Write-Log "Searching for available updates..."
    $SearchResult = $UpdateSearcher.Search("IsInstalled=0 and Type='Software'")
    $total = $SearchResult.Updates.Count
    Write-Log "Available updates: $total"

    if ($total -gt 0) {
        $SearchResult.Updates | ForEach-Object {
            Write-Log "  Pending: $($_.Title)"
        }
        Write-Log "ACTION REQUIRED: Run Windows Update to apply $total pending update(s)" "WARN"
    } else {
        Write-Log "System is fully up to date."
    }
} catch {
    Write-Log "Windows Update COM check failed: $_" "WARN"
    # Fallback: use PSWindowsUpdate if available
    if (Get-Module -ListAvailable -Name PSWindowsUpdate) {
        Import-Module PSWindowsUpdate
        $updates = Get-WindowsUpdate -MicrosoftUpdate -ErrorAction SilentlyContinue
        Write-Log "PSWindowsUpdate found $($updates.Count) updates"
    }
}

# ----------------------------------------------------------
# TASK 2: Backup Verification (test restore readiness)
# ----------------------------------------------------------
Write-Log "--- TASK 2: Backup Verification ---"

try {
    $versions = wbadmin get versions 2>&1
    if ($versions -match "Backup time") {
        $allVersions = ($versions | Select-String "Backup time")
        $latest = $allVersions | Select-Object -Last 1
        Write-Log "Latest backup: $latest"
        $allVersions | ForEach-Object { Write-Log "  Version: $_" }
    } else {
        Write-Log "No backup versions found via wbadmin" "WARN"
    }
} catch {
    Write-Log "wbadmin check failed: $_" "WARN"
}

# Check VSS (Volume Shadow Copies)
$shadows = Get-WmiObject Win32_ShadowCopy -ErrorAction SilentlyContinue
if ($shadows) {
    Write-Log "Shadow copies available: $($shadows.Count)"
    $shadows | Select-Object -Last 3 | ForEach-Object {
        Write-Log "  VSS: $($_.InstallDate) on $($_.VolumeName)"
    }
} else {
    Write-Log "No VSS shadow copies found" "WARN"
}

# ----------------------------------------------------------
# TASK 3: Disk Space Management (cleanup temp/logs)
# ----------------------------------------------------------
Write-Log "--- TASK 3: Disk Cleanup ---"

$before = (Get-PSDrive C).Free
Write-Log "Disk C free space before cleanup: $([math]::Round($before/1GB,2))GB"

# Clean Windows temp folders
$cleanPaths = @(
    "$env:TEMP",
    "$env:SystemRoot\Temp",
    "$env:SystemRoot\Logs\CBS",
    "$env:SystemRoot\SoftwareDistribution\Download"
)

foreach ($path in $cleanPaths) {
    if (Test-Path $path) {
        $items = Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        $count = $items.Count
        $items | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Cleaned $path — $count items removed"
    }
}

# Run built-in Disk Cleanup silently
Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/sagerun:1" -Wait -ErrorAction SilentlyContinue

$after = (Get-PSDrive C).Free
$freed = [math]::Round(($after - $before) / 1MB, 2)
Write-Log "Disk C free space after cleanup: $([math]::Round($after/1GB,2))GB (freed: ${freed}MB)"

# ----------------------------------------------------------
# TASK 4: Service & Uptime Checks
# ----------------------------------------------------------
Write-Log "--- TASK 4: Service & Uptime Checks ---"

# System uptime
$os      = Get-CimInstance Win32_OperatingSystem
$uptime  = (Get-Date) - $os.LastBootUpTime
Write-Log "System uptime: $([math]::Floor($uptime.TotalDays))d $($uptime.Hours)h $($uptime.Minutes)m"

# Critical services
$criticalServices = @(
    "wuauserv",    # Windows Update
    "WinDefend",   # Windows Defender
    "EventLog",    # Event Log
    "Dnscache",    # DNS Client
    "LanmanServer",# File & Print Sharing
    "Schedule"     # Task Scheduler
)

foreach ($svc in $criticalServices) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        $status = $s.Status
        Write-Log "Service $($s.DisplayName): $status"
        if ($status -ne "Running") {
            Write-Log "WARNING: $($s.DisplayName) is NOT running — attempting restart" "WARN"
            Start-Service -Name $svc -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            $newStatus = (Get-Service -Name $svc).Status
            Write-Log "  Post-restart status: $newStatus"
        }
    } else {
        Write-Log "Service $svc not found on this system" "WARN"
    }
}

# ----------------------------------------------------------
# TASK 5: Review User Activity (inactive/suspicious accounts)
# ----------------------------------------------------------
Write-Log "--- TASK 5: User Activity Review ---"

$cutoff = (Get-Date).AddDays(-30)
$allUsers = Get-LocalUser

Write-Log "Total local accounts: $($allUsers.Count)"

$inactive = $allUsers | Where-Object {
    $_.Enabled -eq $true -and ($_.LastLogon -eq $null -or $_.LastLogon -lt $cutoff)
}
Write-Log "Active accounts with no login in 30+ days: $($inactive.Count)"
$inactive | ForEach-Object {
    Write-Log "  Inactive: $($_.Name) | Last logon: $($_.LastLogon)"
}

$admins = Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue
Write-Log "Members of local Administrators group: $($admins.Count)"
$admins | ForEach-Object { Write-Log "  Admin: $($_.Name)" }

Write-Log "========== WEEKLY REPORT COMPLETE — Log: $LogFile =========="
