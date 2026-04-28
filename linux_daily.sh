#!/usr/bin/env bash
# ============================================================
# Linux Daily SysAdmin Tasks
# Run as: root (or sudo)
# Schedule: Daily via cron — e.g., "0 7 * * * /opt/sysadmin/daily.sh"
# ============================================================

LOG_DIR="/var/log/sysadmin"
DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/daily_$DATE.log"

mkdir -p "$LOG_DIR"

log() {
    local level="${2:-INFO}"
    echo "[$(date +%H:%M:%S)][$level] $1" | tee -a "$LOG_FILE"
}

log "========== DAILY SYSADMIN REPORT : $DATE =========="

# ----------------------------------------------------------
# TASK 1: System Health Check (CPU, Memory, Disk)
# ----------------------------------------------------------
log "--- TASK 1: System Health ---"

CPU_IDLE=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | tr -d '%id,')
CPU_USED=$(echo "100 - ${CPU_IDLE:-0}" | bc 2>/dev/null || echo "N/A")
log "CPU Usage: ${CPU_USED}%"
if [[ "$CPU_USED" =~ ^[0-9]+$ ]] && [ "$CPU_USED" -gt 85 ]; then
    log "WARNING: CPU usage is high!" "WARN"
fi

MEM_TOTAL=$(free -m | awk '/^Mem:/ {print $2}')
MEM_USED=$(free  -m | awk '/^Mem:/ {print $3}')
MEM_PCT=$(awk "BEGIN {printf \"%.1f\", ($MEM_USED/$MEM_TOTAL)*100}")
log "Memory: ${MEM_USED}MB / ${MEM_TOTAL}MB used (${MEM_PCT}%)"
if (( $(echo "$MEM_PCT > 90" | bc -l) )); then
    log "WARNING: Memory usage is high!" "WARN"
fi

df -h --output=target,pcent,avail | tail -n +2 | while read -r mount pct avail; do
    pct_val="${pct//%/}"
    log "Disk $mount: ${pct} used | ${avail} free"
    if [ "$pct_val" -gt 85 ] 2>/dev/null; then
        log "WARNING: Disk $mount is almost full!" "WARN"
    fi
done

# ----------------------------------------------------------
# TASK 2: Review Logs (/var/log — errors & auth failures)
# ----------------------------------------------------------
log "--- TASK 2: Log Review (Last 24 Hours) ---"

SINCE=$(date -d "24 hours ago" "+%b %e %H:%M" 2>/dev/null || date -v-24H "+%b %e %H:%M")

# Syslog errors
if [ -f /var/log/syslog ]; then
    ERR_COUNT=$(grep -c -i "error\|critical\|failed" /var/log/syslog 2>/dev/null || echo 0)
    log "Syslog errors/criticals today: $ERR_COUNT"
elif [ -f /var/log/messages ]; then
    ERR_COUNT=$(grep -c -i "error\|critical\|failed" /var/log/messages 2>/dev/null || echo 0)
    log "Messages errors today: $ERR_COUNT"
fi

# Kernel errors
KERN_ERR=$(dmesg --level=err,crit,emerg 2>/dev/null | wc -l)
log "Kernel errors (dmesg): $KERN_ERR"
if [ "$KERN_ERR" -gt 5 ]; then log "WARNING: Kernel errors detected!" "WARN"; fi

# Journald summary (systemd systems)
if command -v journalctl &>/dev/null; then
    JOURNAL_ERR=$(journalctl --since "24 hours ago" -p err..emerg --no-pager 2>/dev/null | wc -l)
    log "Journald errors (last 24h): $JOURNAL_ERR"
fi

# ----------------------------------------------------------
# TASK 3: Backup Status
# ----------------------------------------------------------
log "--- TASK 3: Backup Status ---"

# Check common backup tools
if command -v rsnapshot &>/dev/null; then
    LAST_SNAP=$(find /var/cache/rsnapshot -maxdepth 1 -type d | sort | tail -1)
    log "Last rsnapshot backup dir: ${LAST_SNAP:-None found}"
elif command -v duplicati &>/dev/null; then
    log "Duplicati installed — check GUI/logs for last run status"
else
    # Generic: find most recently modified backup files in common locations
    BACKUP_DIRS=("/backup" "/mnt/backup" "/home/backups" "/var/backups")
    for d in "${BACKUP_DIRS[@]}"; do
        if [ -d "$d" ]; then
            LATEST=$(find "$d" -type f -newer /tmp/.daily_marker 2>/dev/null | head -5)
            if [ -n "$LATEST" ]; then
                log "Recent backup files in $d:"
                echo "$LATEST" | while read -r f; do log "  $f"; done
            else
                log "No recent backup files found in $d" "WARN"
            fi
        fi
    done
fi
touch /tmp/.daily_marker

# ----------------------------------------------------------
# TASK 4: User & Access Management
# ----------------------------------------------------------
log "--- TASK 4: User & Access Management ---"

# Locked accounts
LOCKED=$(passwd -Sa 2>/dev/null | awk '$2=="L" {print $1}')
if [ -n "$LOCKED" ]; then
    log "Locked accounts: $(echo "$LOCKED" | tr '\n' ' ')"
else
    log "No locked accounts found"
fi

# Users with active sessions
ACTIVE_USERS=$(who | awk '{print $1}' | sort -u | tr '\n' ' ')
log "Currently logged-in users: ${ACTIVE_USERS:-None}"

# Recently added users (last 24h entry in /etc/passwd)
NEW_USERS=$(find /home -maxdepth 1 -mindepth 1 -type d -newer /tmp/.daily_marker 2>/dev/null)
if [ -n "$NEW_USERS" ]; then
    log "New home directories (possible new users): $NEW_USERS" "WARN"
else
    log "No new home directories created in last 24h"
fi

# ----------------------------------------------------------
# TASK 5: Security Check (failed SSH logins, rootkit quick scan)
# ----------------------------------------------------------
log "--- TASK 5: Security Check ---"

# Failed SSH logins
if [ -f /var/log/auth.log ]; then
    AUTH_LOG="/var/log/auth.log"
elif [ -f /var/log/secure ]; then
    AUTH_LOG="/var/log/secure"
else
    AUTH_LOG=""
fi

if [ -n "$AUTH_LOG" ]; then
    FAILED_SSH=$(grep "Failed password" "$AUTH_LOG" 2>/dev/null | grep "$(date +%b %e)" | wc -l)
    log "Failed SSH login attempts today: $FAILED_SSH"
    if [ "$FAILED_SSH" -gt 20 ]; then log "WARNING: High number of failed SSH attempts!" "WARN"; fi

    TOP_IPS=$(grep "Failed password" "$AUTH_LOG" 2>/dev/null | grep "$(date +%b %e)" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort | uniq -c | sort -rn | head -5)
    if [ -n "$TOP_IPS" ]; then
        log "Top attacking IPs:"
        echo "$TOP_IPS" | while read -r line; do log "  $line"; done
    fi
fi

# Antivirus (ClamAV) quick check
if command -v clamscan &>/dev/null; then
    CLAM_RESULT=$(clamscan --quiet --infected /tmp 2>&1 | tail -3)
    log "ClamAV /tmp scan: ${CLAM_RESULT:-Clean}"
else
    log "ClamAV not installed — consider installing for AV scanning" "WARN"
fi

log "========== DAILY REPORT COMPLETE — Log: $LOG_FILE =========="
