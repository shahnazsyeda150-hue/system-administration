#!/usr/bin/env bash
# ============================================================
# Linux SysAdmin Troubleshooting Toolkit
# Run as: root (or sudo)
# Usage: ./linux_troubleshoot.sh [mode]
#   Modes: full | rca | service | network | perf | security
# ============================================================

MODE="${1:-full}"
SERVICE_NAME="${2:-}"   # For targeted service checks
TARGET_HOST="${3:-}"    # For targeted network checks

LOG_DIR="/var/log/sysadmin"
TS=$(date +%Y-%m-%d_%H-%M-%S)
LOG_FILE="$LOG_DIR/troubleshoot_$TS.log"

mkdir -p "$LOG_DIR"

log() {
    local level="${2:-INFO}"
    echo "[$(date +%H:%M:%S)][$level] $1" | tee -a "$LOG_FILE"
}

log "========== LINUX TROUBLESHOOTING TOOLKIT — Mode: $MODE =========="
log "System: $(hostname) | $(uname -r) | $(date)"

# ----------------------------------------------------------
# TASK 1: Root Cause Analysis (logs, metrics, recent changes)
# ----------------------------------------------------------
if [[ "$MODE" == "full" || "$MODE" == "rca" ]]; then
    log "--- TASK 1: Root Cause Analysis ---"

    # System uptime & last boot
    log "Uptime: $(uptime)"
    LAST_BOOT=$(who -b 2>/dev/null | awk '{print $3, $4}')
    log "Last boot: $LAST_BOOT"

    # Kernel errors (last 4 hours)
    log "Recent kernel errors (dmesg):"
    dmesg --level=err,crit,emerg --since "4 hours ago" 2>/dev/null | tail -20 | \
        while read -r l; do log "  $l" "WARN"; done || \
        dmesg --level=err,crit,emerg 2>/dev/null | tail -20 | while read -r l; do log "  $l"; done

    # Journal errors (systemd)
    if command -v journalctl &>/dev/null; then
        log "Systemd journal errors (last 4h):"
        journalctl --since "4 hours ago" -p err..emerg --no-pager 2>/dev/null | \
            tail -30 | while read -r l; do log "  $l"; done
    fi

    # Syslog errors
    for logfile in /var/log/syslog /var/log/messages; do
        if [ -f "$logfile" ]; then
            ERR_COUNT=$(grep -c -i "error\|critical\|panic\|failed\|fatal" "$logfile" 2>/dev/null || echo 0)
            log "Errors in $logfile: $ERR_COUNT"
            grep -i "error\|critical\|panic" "$logfile" 2>/dev/null | tail -10 | \
                while read -r l; do log "  $l"; done
        fi
    done

    # Recently changed files (potential tampering or misconfiguration)
    log "Files changed in /etc last 24h:"
    find /etc -type f -newer /tmp -mtime -1 2>/dev/null | head -20 | \
        while read -r f; do log "  $f"; done

    # Recently installed packages
    log "Recently installed packages:"
    if command -v dpkg &>/dev/null; then
        grep "install " /var/log/dpkg.log 2>/dev/null | tail -10 | while read -r l; do log "  $l"; done
    elif command -v rpm &>/dev/null; then
        rpm -qa --queryformat "%{INSTALLTIME:date} %{NAME}-%{VERSION}\n" 2>/dev/null | \
            sort -r | head -10 | while read -r l; do log "  $l"; done
    fi
fi

# ----------------------------------------------------------
# TASK 2: Service Failure Resolution
# ----------------------------------------------------------
if [[ "$MODE" == "full" || "$MODE" == "service" ]]; then
    log "--- TASK 2: Service Failure Resolution ---"

    # Find all failed services
    log "Failed systemd services:"
    FAILED_SVCS=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}')
    if [ -n "$FAILED_SVCS" ]; then
        echo "$FAILED_SVCS" | while read -r svc; do
            log "  FAILED: $svc" "WARN"
            log "  Status output:"
            systemctl status "$svc" --no-pager -l 2>/dev/null | tail -15 | \
                while read -r l; do log "    $l"; done
            # Attempt restart
            log "  Attempting restart of $svc..."
            systemctl restart "$svc" 2>/dev/null
            sleep 3
            NEW_STATUS=$(systemctl is-active "$svc" 2>/dev/null)
            log "  Post-restart status: $NEW_STATUS"
        done
    else
        log "  No failed services found"
    fi

    # Targeted service check
    if [ -n "$SERVICE_NAME" ]; then
        log "Targeted investigation: $SERVICE_NAME"
        systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null | while read -r l; do log "  $l"; done

        log "  Journal logs for $SERVICE_NAME (last 2h):"
        journalctl -u "$SERVICE_NAME" --since "2 hours ago" --no-pager 2>/dev/null | \
            tail -30 | while read -r l; do log "  $l"; done

        log "  Dependencies:"
        systemctl list-dependencies "$SERVICE_NAME" --no-pager 2>/dev/null | head -15 | \
            while read -r l; do log "  $l"; done
    fi

    # Check for zombie processes
    ZOMBIES=$(ps aux 2>/dev/null | awk '$8=="Z" {print $2,$11}')
    if [ -n "$ZOMBIES" ]; then
        log "Zombie processes found:" "WARN"
        echo "$ZOMBIES" | while read -r l; do log "  $l"; done
    else
        log "No zombie processes"
    fi
fi

# ----------------------------------------------------------
# TASK 3: Network Troubleshooting
# ----------------------------------------------------------
if [[ "$MODE" == "full" || "$MODE" == "network" ]]; then
    log "--- TASK 3: Network Troubleshooting ---"

    # Interface status
    log "Network interfaces:"
    ip -br link 2>/dev/null | while read -r l; do log "  $l"; done

    # IP addresses
    log "IP addresses:"
    ip -br addr 2>/dev/null | while read -r l; do log "  $l"; done

    # Default routes
    log "Default routes:"
    ip route show default 2>/dev/null | while read -r l; do log "  $l"; done

    # Ping default gateway
    GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -1)
    if [ -n "$GW" ]; then
        if ping -c 3 -W 2 "$GW" &>/dev/null; then
            RTT=$(ping -c 3 -W 2 "$GW" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
            log "Gateway $GW: reachable (avg RTT: ${RTT}ms)"
        else
            log "Gateway $GW: UNREACHABLE" "WARN"
        fi
    fi

    # DNS resolution tests
    DNS_TESTS=("google.com" "8.8.8.8" "1.1.1.1")
    [ -n "$TARGET_HOST" ] && DNS_TESTS+=("$TARGET_HOST")
    for host in "${DNS_TESTS[@]}"; do
        if nslookup "$host" &>/dev/null || dig "$host" +short &>/dev/null; then
            RESOLVED=$(dig +short "$host" 2>/dev/null | head -1)
            log "DNS $host → ${RESOLVED:-resolved}"
        else
            log "DNS $host: RESOLUTION FAILED" "WARN"
        fi
    done

    # DNS servers in use
    log "DNS servers configured:"
    grep "^nameserver" /etc/resolv.conf 2>/dev/null | while read -r l; do log "  $l"; done

    # Traceroute
    if [ -n "$TARGET_HOST" ]; then
        log "Traceroute to $TARGET_HOST:"
        traceroute -n -m 15 "$TARGET_HOST" 2>/dev/null | while read -r l; do log "  $l"; done
    fi

    # Listening ports
    log "Listening ports:"
    if command -v ss &>/dev/null; then
        ss -tlnup 2>/dev/null | tail -n +2 | while read -r l; do log "  $l"; done
    else
        netstat -tlnup 2>/dev/null | tail -n +3 | while read -r l; do log "  $l"; done
    fi

    # Established connections
    log "Established connections (top 20):"
    ss -tnp state established 2>/dev/null | head -21 | tail -20 | while read -r l; do log "  $l"; done

    # Firewall status
    log "Firewall status:"
    if command -v ufw &>/dev/null; then
        ufw status 2>/dev/null | while read -r l; do log "  $l"; done
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --state 2>/dev/null | while read -r l; do log "  $l"; done
    fi

    # Bandwidth usage (if tools available)
    if command -v iftop &>/dev/null; then
        log "Run 'iftop -t -s 5' for live bandwidth monitoring"
    fi
fi

# ----------------------------------------------------------
# TASK 4: Performance Bottleneck Analysis
# ----------------------------------------------------------
if [[ "$MODE" == "full" || "$MODE" == "perf" ]]; then
    log "--- TASK 4: Performance Bottleneck Analysis ---"

    # Load average
    LOAD=$(cat /proc/loadavg)
    CORES=$(nproc)
    LOAD_1=$(echo "$LOAD" | awk '{print $1}')
    log "Load average (1m/5m/15m): $LOAD | CPU cores: $CORES"
    if (( $(echo "$LOAD_1 > $CORES" | bc -l 2>/dev/null) )); then
        log "WARNING: Load average exceeds core count — system overloaded!" "WARN"
    fi

    # CPU usage snapshot
    log "CPU usage (top 10 processes):"
    ps aux --sort=-%cpu 2>/dev/null | head -11 | tail -10 | \
        awk '{printf "  %-25s %5s%% CPU  %5s%% MEM  PID:%-7s\n", $11, $3, $4, $2}' | \
        while read -r l; do log "$l"; done

    # Memory usage
    log "Memory summary:"
    free -h | while read -r l; do log "  $l"; done

    log "Top 10 memory-consuming processes:"
    ps aux --sort=-%mem 2>/dev/null | head -11 | tail -10 | \
        awk '{printf "  %-25s %5s%% MEM  %5s%% CPU  PID:%-7s\n", $11, $4, $3, $2}' | \
        while read -r l; do log "$l"; done

    # Swap
    SWAP_USED=$(free -m | awk '/^Swap:/ {print $3}')
    SWAP_TOTAL=$(free -m | awk '/^Swap:/ {print $2}')
    log "Swap: ${SWAP_USED}MB / ${SWAP_TOTAL}MB used"
    if [ "$SWAP_TOTAL" -gt 0 ] && [ "$SWAP_USED" -gt 0 ]; then
        SWAP_PCT=$(awk "BEGIN {printf \"%.1f\", ($SWAP_USED/$SWAP_TOTAL)*100}" 2>/dev/null)
        if (( $(echo "$SWAP_PCT > 50" | bc -l 2>/dev/null) )); then
            log "WARNING: Heavy swap usage (${SWAP_PCT}%) — RAM pressure detected!" "WARN"
        fi
    fi

    # Disk I/O
    log "Disk I/O (iostat):"
    if command -v iostat &>/dev/null; then
        iostat -dx 1 3 2>/dev/null | tail -n +4 | while read -r l; do log "  $l"; done
    else
        log "  iostat not available — install sysstat: apt install sysstat"
    fi

    # Disk space critical check
    log "Disk space:"
    df -h 2>/dev/null | while read -r l; do
        PCT=$(echo "$l" | awk 'NR>1 {print $5}' | tr -d '%')
        [ -z "$PCT" ] && { log "  $l"; continue; }
        log "  $l"
        if [ "$PCT" -gt 90 ] 2>/dev/null; then
            MOUNT=$(echo "$l" | awk '{print $6}')
            log "  CRITICAL: $MOUNT is ${PCT}% full — immediate action needed!" "WARN"
        fi
    done

    # Open file descriptors
    log "Open file descriptors:"
    FD_USED=$(cat /proc/sys/fs/file-nr 2>/dev/null | awk '{print $1}')
    FD_MAX=$(cat /proc/sys/fs/file-max 2>/dev/null)
    log "  In use: $FD_USED / Max: $FD_MAX"

    # Top FD consumers
    if [ -x "$(command -v lsof)" ]; then
        log "Top 5 FD-consuming processes:"
        lsof 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -5 | \
            while read -r l; do log "  $l"; done
    fi
fi

# ----------------------------------------------------------
# TASK 5: Security Incident Response
# ----------------------------------------------------------
if [[ "$MODE" == "full" || "$MODE" == "security" ]]; then
    log "--- TASK 5: Security Incident Response ---"

    # Determine auth log
    if   [ -f /var/log/auth.log  ]; then AUTH_LOG="/var/log/auth.log"
    elif [ -f /var/log/secure    ]; then AUTH_LOG="/var/log/secure"
    else AUTH_LOG=""
    fi

    # Failed SSH logins (last 4h)
    if [ -n "$AUTH_LOG" ]; then
        FAILED=$(grep "Failed password" "$AUTH_LOG" 2>/dev/null | \
            awk -v ts="$(date -d '4 hours ago' '+%b %e %H' 2>/dev/null || date '+%b %e %H')" \
            '$0 >= ts' | wc -l)
        log "Failed SSH logins (last 4h): $FAILED"
        if [ "$FAILED" -gt 20 ]; then log "WARNING: Possible brute-force attack!" "WARN"; fi

        log "Top attacking IPs:"
        grep "Failed password" "$AUTH_LOG" 2>/dev/null | \
            grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort | uniq -c | sort -rn | head -10 | \
            while read -r l; do log "  $l"; done

        # Successful logins
        log "Successful SSH logins (last 4h):"
        grep "Accepted" "$AUTH_LOG" 2>/dev/null | tail -10 | while read -r l; do log "  $l"; done
    fi

    # New user accounts created
    log "Checking for recently created users:"
    NEW_USERS=$(awk -F: '($3 >= 1000 && $3 < 65534) {print $1,$3}' /etc/passwd)
    echo "$NEW_USERS" | while read -r u; do log "  User: $u"; done

    # UID 0 accounts (root-equivalent)
    ROOT_EQUIV=$(awk -F: '$3==0 {print $1}' /etc/passwd)
    log "UID 0 (root-equivalent) accounts: $ROOT_EQUIV"
    if echo "$ROOT_EQUIV" | grep -qv "^root$"; then
        log "CRITICAL: Non-root account with UID 0 detected!" "WARN"
    fi

    # SUID files changed recently
    log "Recently modified SUID files (last 7 days):"
    find / -perm /4000 -newer /var/log/sysadmin -mtime -7 -type f 2>/dev/null | \
        while read -r f; do log "  SUID modified: $f" "WARN"; done

    # Active network connections (possible C2 beaconing)
    log "Established external connections:"
    ss -tnp state established 2>/dev/null | grep -v "127.0.0.1\|::1" | \
        while read -r l; do log "  $l"; done

    # Processes running from unusual locations
    log "Processes running from /tmp, /dev/shm (suspicious):"
    ls /proc/*/exe 2>/dev/null | xargs -I{} readlink {} 2>/dev/null | \
        grep -E "^/tmp|^/dev/shm|^/var/tmp" | while read -r l; do log "  SUSPICIOUS: $l" "WARN"; done

    # ClamAV scan
    if command -v clamscan &>/dev/null; then
        log "Running ClamAV scan on /tmp and /home..."
        CLAM=$(clamscan --quiet --infected --recursive /tmp /home 2>&1)
        if [ -n "$CLAM" ]; then
            log "ClamAV threats found:" "WARN"
            echo "$CLAM" | while read -r l; do log "  $l" "WARN"; done
        else
            log "ClamAV: No threats found"
        fi
    fi

    # Rootkit check
    if command -v rkhunter &>/dev/null; then
        log "Running rkhunter check..."
        rkhunter --check --skip-keypress --quiet 2>/dev/null | grep -E "Warning|Infected" | \
            while read -r l; do log "  $l" "WARN"; done
    fi

    log "INCIDENT RESPONSE CHECKLIST:"
    log "  [ ] 1. Contain: isolate system (block internet, disable SSH if needed)"
    log "  [ ] 2. Preserve: take memory dump & disk image before changes"
    log "  [ ] 3. Identify: determine root cause using logs above"
    log "  [ ] 4. Eradicate: remove malware, close vulnerability"
    log "  [ ] 5. Recover: restore from clean backup, verify integrity"
    log "  [ ] 6. Document: write incident report and update runbook"
fi

log "========== TROUBLESHOOTING COMPLETE — Log: $LOG_FILE =========="
log "Full log saved to: $LOG_FILE"
