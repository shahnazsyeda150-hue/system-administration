# ============================================================
# Windows Daily SysAdmin Tasks
# Run as: Administrator
# Schedule: Daily (e.g., 7:00 AM via Task Scheduler)
# ============================================================

$LogDir  = "C:\SysAdmin\Logs"
$Date    = Get-Date -Format "yyyy-MM-dd"
$LogFile = "$LogDir\daily_$Date.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Write-Log "========== DAILY SYSADMIN REPORT : $Date =========="

# ----------------------------------------------------------
# TASK 1: System Health Check (CPU, Memory, Disk)
# ----------------------------------------------------------
Write-Log "--- TASK 1: System Health ---"

$cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
Write-Log "CPU Usage: $cpu%"
if ($cpu -gt 85) { Write-Log "WARNING: CPU usage is high!" "WARN" }

$os  = Get-CimInstance Win32_OperatingSystem
$memUsedGB   = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
$memTotalGB  = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$memPct      = [math]::Round(($memUsedGB / $memTotalGB) * 100, 1)
Write-Log "Memory: ${memUsedGB}GB / ${memTotalGB}GB used ($memPct%)"
if ($memPct -gt 90) { Write-Log "WARNING: Memory usage is high!" "WARN" }

Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } | ForEach-Object {
    $usedGB  = [math]::Round($_.Used  / 1GB, 2)
    $freeGB  = [math]::Round($_.Free  / 1GB, 2)
    $totalGB = $usedGB + $freeGB
    if ($totalGB -gt 0) {
        $pct = [math]::Round(($usedGB / $totalGB) * 100, 1)
        Write-Log "Disk $($_.Name): ${usedGB}GB used / ${totalGB}GB total ($pct% used, ${freeGB}GB free)"
        if ($pct -gt 85) { Write-Log "WARNING: Disk $($_.Name) is almost full!" "WARN" }
    }
}

# ----------------------------------------------------------
# TASK 2: Review Event Logs (Errors & Warnings in last 24h)
# ----------------------------------------------------------
Write-Log "--- TASK 2: Event Log Review (Last 24 Hours) ---"

$since = (Get-Date).AddHours(-24)
foreach ($log in @("System","Application","Security")) {
    try {
        $errors   = (Get-EventLog -LogName $log -EntryType Error   -After $since -ErrorAction SilentlyContinue).Count
        $warnings = (Get-EventLog -LogName $log -EntryType Warning -After $since -ErrorAction SilentlyContinue).Count
        Write-Log "$log Log — Errors: $errors | Warnings: $warnings"
        if ($errors -gt 10) { Write-Log "WARNING: High error count in $log log!" "WARN" }
    } catch {
        Write-Log "Could not read $log log: $_" "WARN"
    }
}

# ----------------------------------------------------------
# TASK 3: Backup Status (check last backup job via Windows Backup)
# ----------------------------------------------------------
Write-Log "--- TASK 3: Backup Status ---"

try {
    $wbAdmin = wbadmin get versions 2>&1
    if ($wbAdmin -match "Backup time") {
        $lastLine = ($wbAdmin | Select-String "Backup time") | Select-Object -Last 1
        Write-Log "Last Backup: $lastLine"
    } else {
        Write-Log "No Windows Backup versions found or wbadmin unavailable." "WARN"
    }
} catch {
    Write-Log "Backup check failed: $_" "WARN"
}

# ----------------------------------------------------------
# TASK 4: User & Access Management (locked accounts, recent changes)
# ----------------------------------------------------------
Write-Log "--- TASK 4: User & Access Management ---"

$lockedUsers = Get-LocalUser | Where-Object { $_.Enabled -eq $false }
Write-Log "Disabled local accounts: $($lockedUsers.Count)"
$lockedUsers | ForEach-Object { Write-Log "  - Disabled: $($_.Name)" }

$recentUsers = Get-LocalUser | Where-Object {
    $_.LastLogon -ne $null -and $_.LastLogon -gt (Get-Date).AddDays(-1)
}
Write-Log "Users logged in last 24h: $($recentUsers.Count)"
$recentUsers | ForEach-Object { Write-Log "  - $($_.Name) last logon: $($_.LastLogon)" }

# ----------------------------------------------------------
# TASK 5: Security Check (failed logins, Windows Defender status)
# ----------------------------------------------------------
Write-Log "--- TASK 5: Security Check ---"

try {
    $failedLogins = Get-EventLog -LogName Security -InstanceId 4625 -After $since -ErrorAction SilentlyContinue
    Write-Log "Failed login attempts (Event 4625) in last 24h: $($failedLogins.Count)"
    if ($failedLogins.Count -gt 20) { Write-Log "WARNING: Excessive failed login attempts detected!" "WARN" }
} catch {
    Write-Log "Failed login check skipped (may require elevated privileges)" "WARN"
}

try {
    $defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($defender) {
        Write-Log "Defender Real-Time Protection: $($defender.RealTimeProtectionEnabled)"
        Write-Log "Antivirus Signature Age (days): $($defender.AntivirusSignatureAge)"
        if ($defender.AntivirusSignatureAge -gt 3) { Write-Log "WARNING: Antivirus signatures are outdated!" "WARN" }
    }
} catch {
    Write-Log "Defender status check skipped" "WARN"
}

Write-Log "========== DAILY REPORT COMPLETE — Log: $LogFile =========="
