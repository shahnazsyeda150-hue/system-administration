# ============================================================
# Windows SysAdmin Troubleshooting Toolkit
# Run as: Administrator
# Usage: Run on-demand during incidents
# ============================================================

param(
    [string]$Mode = "full",     # Options: full | rca | service | network | perf | security
    [string]$ServiceName = "",  # For targeted service checks
    [string]$TargetHost  = ""   # For targeted network checks
)

$LogDir  = "C:\SysAdmin\Logs"
$TS      = Get-Date -Format "yyyy-MM-dd_HH-mm"
$LogFile = "$LogDir\troubleshoot_$TS.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Write-Log "========== WINDOWS TROUBLESHOOTING TOOLKIT — Mode: $Mode =========="

# ----------------------------------------------------------
# TASK 1: Root Cause Analysis (RCA) — Logs, Metrics, Changes
# ----------------------------------------------------------
if ($Mode -in @("full","rca")) {
    Write-Log "--- TASK 1: Root Cause Analysis ---"

    $since = (Get-Date).AddHours(-4)  # Last 4 hours

    # Critical system events
    Write-Log "Critical events (last 4 hours):"
    @("System","Application") | ForEach-Object {
        $logName = $_
        Get-EventLog -LogName $logName -EntryType Error,Warning -After $since -Newest 20 `
            -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Log "  [$logName] ID:$($_.EventID) | $($_.Source) | $($_.Message.Split("`n")[0])"
        }
    }

    # Recent system changes (installed software, driver updates)
    Write-Log "Recent system changes (last 7 days):"
    Get-EventLog -LogName System -Source "msiinstaller","Windows Installer" -After (Get-Date).AddDays(-7) `
        -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object {
        Write-Log "  $($_.TimeGenerated): $($_.Message.Split("`n")[0])"
    }

    # Windows Update history (recent)
    Write-Log "Recent Windows Updates:"
    Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10 | ForEach-Object {
        Write-Log "  $($_.InstalledOn) | $($_.HotFixID) | $($_.Description)"
    }

    # System uptime & last boot
    $os     = Get-CimInstance Win32_OperatingSystem
    $uptime = (Get-Date) - $os.LastBootUpTime
    Write-Log "Last boot: $($os.LastBootUpTime) | Uptime: $([math]::Floor($uptime.TotalDays))d $($uptime.Hours)h $($uptime.Minutes)m"
}

# ----------------------------------------------------------
# TASK 2: Service Failure Resolution
# ----------------------------------------------------------
if ($Mode -in @("full","service")) {
    Write-Log "--- TASK 2: Service Failure Resolution ---"

    # Find all stopped services that should be running (auto-start)
    $stoppedAuto = Get-Service | Where-Object {
        $_.StartType -eq "Automatic" -and $_.Status -ne "Running"
    }

    if ($stoppedAuto.Count -gt 0) {
        Write-Log "Stopped AUTO-START services ($($stoppedAuto.Count) found):" "WARN"
        $stoppedAuto | ForEach-Object {
            Write-Log "  STOPPED: $($_.DisplayName) [$($_.Name)]" "WARN"
            # Attempt restart
            try {
                Start-Service -Name $_.Name -ErrorAction Stop
                Start-Sleep -Seconds 3
                $newStatus = (Get-Service -Name $_.Name).Status
                Write-Log "  Restart attempt → New status: $newStatus"
            } catch {
                Write-Log "  Restart FAILED: $_" "WARN"
            }
        }
    } else {
        Write-Log "All auto-start services are running"
    }

    # Targeted service check
    if ($ServiceName -ne "") {
        Write-Log "Targeted service investigation: $ServiceName"
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Log "  Status: $($svc.Status) | StartType: $($svc.StartType)"
            Write-Log "  DependentServices: $($svc.DependentServices.Name -join ', ')"
            Write-Log "  ServicesDependedOn: $($svc.ServicesDependedOn.Name -join ', ')"

            # Check event log for service errors
            Get-EventLog -LogName System -Source "Service Control Manager" -After (Get-Date).AddHours(-24) `
                -ErrorAction SilentlyContinue | Where-Object { $_.Message -match $ServiceName } | `
                Select-Object -First 5 | ForEach-Object {
                Write-Log "  Event $($_.EventID): $($_.Message.Split("`n")[0])"
            }
        } else {
            Write-Log "  Service '$ServiceName' not found!" "WARN"
        }
    }
}

# ----------------------------------------------------------
# TASK 3: Network Troubleshooting
# ----------------------------------------------------------
if ($Mode -in @("full","network")) {
    Write-Log "--- TASK 3: Network Troubleshooting ---"

    # NIC status
    Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Log "NIC: $($_.Name) | Status: $($_.Status) | Speed: $($_.LinkSpeed) | MAC: $($_.MacAddress)"
        if ($_.Status -ne "Up") { Write-Log "  WARNING: NIC $($_.Name) is DOWN!" "WARN" }
    }

    # IP configuration
    Write-Log "IP Configuration:"
    Get-NetIPAddress -ErrorAction SilentlyContinue | Where-Object { $_.AddressFamily -eq "IPv4" } | ForEach-Object {
        Write-Log "  $($_.InterfaceAlias): $($_.IPAddress)/$($_.PrefixLength)"
    }

    # Default gateway
    $gateways = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
    $gateways | ForEach-Object { Write-Log "  Default Gateway: $($_.NextHop) via $($_.InterfaceAlias)" }

    # Ping gateway
    $gw = $gateways | Select-Object -First 1 -ExpandProperty NextHop
    if ($gw) {
        $ping = Test-Connection -ComputerName $gw -Count 3 -ErrorAction SilentlyContinue
        if ($ping) {
            Write-Log "Gateway $gw ping: OK (avg $([math]::Round(($ping | Measure-Object -Property ResponseTime -Average).Average))ms)"
        } else {
            Write-Log "Gateway $gw ping: FAILED" "WARN"
        }
    }

    # DNS resolution
    $dnsTests = @("google.com","8.8.8.8","1.1.1.1")
    if ($TargetHost -ne "") { $dnsTests += $TargetHost }
    foreach ($host in $dnsTests) {
        try {
            $resolved = Resolve-DnsName -Name $host -ErrorAction Stop | Select-Object -First 1
            Write-Log "DNS $host → $($resolved.IPAddress ?? $resolved.IP4Address)"
        } catch {
            Write-Log "DNS resolution FAILED for $host" "WARN"
        }
    }

    # Traceroute to external
    if ($TargetHost -ne "") {
        Write-Log "Traceroute to $TargetHost:"
        tracert -d -h 15 $TargetHost 2>&1 | Select-Object -First 20 | ForEach-Object { Write-Log "  $_" }
    }

    # Firewall rules check
    Write-Log "Active firewall rules (blocking):"
    Get-NetFirewallRule | Where-Object { $_.Action -eq "Block" -and $_.Enabled -eq "True" } | `
        Select-Object -First 10 | ForEach-Object {
        Write-Log "  BLOCK: $($_.DisplayName)"
    }

    # Active connections
    Write-Log "Established connections:"
    Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | `
        Select-Object -First 20 | ForEach-Object {
        $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        Write-Log "  $($_.LocalAddress):$($_.LocalPort) → $($_.RemoteAddress):$($_.RemotePort) [$($proc.Name)]"
    }
}

# ----------------------------------------------------------
# TASK 4: Performance Bottleneck Analysis
# ----------------------------------------------------------
if ($Mode -in @("full","perf")) {
    Write-Log "--- TASK 4: Performance Bottleneck Analysis ---"

    # CPU
    $cpu = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average
    Write-Log "CPU Load: $([math]::Round($cpu.Average,1))%"
    if ($cpu.Average -gt 85) { Write-Log "WARNING: CPU is heavily loaded!" "WARN" }

    # Top CPU processes
    Write-Log "Top 10 CPU processes:"
    Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 | ForEach-Object {
        Write-Log ("  {0,-30} CPU:{1,8}s  Mem:{2,8}MB  PID:{3}" -f $_.Name, [math]::Round($_.CPU,1), [math]::Round($_.WorkingSet64/1MB,1), $_.Id)
    }

    # Memory
    $os = Get-CimInstance Win32_OperatingSystem
    $memUsed  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 2)
    $memTotal = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $memPct   = [math]::Round(($memUsed / $memTotal) * 100, 1)
    Write-Log "Memory: ${memUsed}GB / ${memTotal}GB ($memPct%)"
    if ($memPct -gt 90) { Write-Log "WARNING: Memory pressure is critical!" "WARN" }

    # Disk I/O
    Write-Log "Disk I/O counters:"
    $diskCounters = Get-Counter '\PhysicalDisk(*)\Disk Reads/sec','\PhysicalDisk(*)\Disk Writes/sec' `
        -SampleInterval 1 -MaxSamples 3 -ErrorAction SilentlyContinue
    if ($diskCounters) {
        $diskCounters.CounterSamples | ForEach-Object {
            Write-Log "  $($_.Path): $([math]::Round($_.CookedValue,2))"
        }
    }

    # Page file
    $pf = Get-WmiObject Win32_PageFileUsage -ErrorAction SilentlyContinue
    $pf | ForEach-Object {
        Write-Log "PageFile $($_.Name): Used=$($_.CurrentUsage)MB Peak=$($_.PeakUsage)MB Allocated=$($_.AllocatedBaseSize)MB"
        if ($_.PeakUsage -gt ($_.AllocatedBaseSize * 0.8)) {
            Write-Log "WARNING: Page file near capacity — system swapping heavily" "WARN"
        }
    }
}

# ----------------------------------------------------------
# TASK 5: Security Incident Response
# ----------------------------------------------------------
if ($Mode -in @("full","security")) {
    Write-Log "--- TASK 5: Security Incident Response ---"

    $since4h = (Get-Date).AddHours(-4)

    # Brute force / failed logins
    Write-Log "Failed login attempts (last 4h):"
    $failedLogins = Get-EventLog -LogName Security -InstanceId 4625 -After $since4h `
        -ErrorAction SilentlyContinue
    Write-Log "  Total failed logins: $($failedLogins.Count)"
    if ($failedLogins.Count -gt 10) { Write-Log "  WARNING: Possible brute-force attack!" "WARN" }

    # Successful logins (verify expected)
    Write-Log "Successful logins (last 4h):"
    Get-EventLog -LogName Security -InstanceId 4624 -After $since4h -Newest 10 `
        -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Log "  $($_.TimeGenerated): $($_.ReplacementStrings[5]) from $($_.ReplacementStrings[18])"
    }

    # New user accounts created
    Write-Log "New accounts created (last 24h):"
    Get-EventLog -LogName Security -InstanceId 4720 -After (Get-Date).AddHours(-24) `
        -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Log "  NEW USER: $($_.Message.Split("`n")[0])" "WARN"
    }

    # Privilege escalation events
    Write-Log "Privilege escalation events (last 4h):"
    Get-EventLog -LogName Security -InstanceId 4672,4673 -After $since4h -Newest 10 `
        -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Log "  $($_.TimeGenerated) EventID $($_.EventID): $($_.Message.Split("`n")[0])"
    }

    # Suspicious processes (common malware process names)
    $suspiciousNames = @("mimikatz","meterpreter","nc","ncat","psexec","wce","fgdump","pwdump")
    Write-Log "Checking for suspicious processes:"
    Get-Process | Where-Object { $suspiciousNames -contains $_.Name.ToLower() } | ForEach-Object {
        Write-Log "  SUSPICIOUS PROCESS: $($_.Name) (PID $($_.Id))" "WARN"
    }

    # Windows Defender threat history
    Write-Log "Defender threats detected:"
    Get-MpThreatDetection -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object {
        Write-Log "  Threat: $($_.ThreatID) | Time: $($_.InitialDetectionTime) | Action: $($_.ActionSuccess)"
    }

    # Firewall logging check
    $fwLog = "C:\Windows\System32\LogFiles\Firewall\pfirewall.log"
    if (Test-Path $fwLog) {
        $blocked = (Select-String -Path $fwLog -Pattern "DROP" -ErrorAction SilentlyContinue).Count
        Write-Log "Firewall DROP entries in log: $blocked"
    }

    Write-Log "ACTION CHECKLIST:"
    Write-Log "  [ ] Isolate affected system (disable NIC if compromised)"
    Write-Log "  [ ] Preserve memory dump: notmyfault or ProcDump"
    Write-Log "  [ ] Collect logs before rebooting"
    Write-Log "  [ ] Notify security team and document timeline"
    Write-Log "  [ ] Patch vulnerability and restore from clean backup"
}

Write-Log "========== TROUBLESHOOTING COMPLETE — Log: $LogFile =========="
Write-Log "Full log saved to: $LogFile"
