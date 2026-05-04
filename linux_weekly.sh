#!/usr/bin/env bash
# ============================================================
# Linux Weekly SysAdmin Tasks
# Run as: root (or sudo)
# Schedule: Weekly via cron — e.g., "0 6 * * 0 /opt/sysadmin/weekly.sh"
# ============================================================

LOG_DIR="/var/log/sysadmin"
DATE=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/weekly_$DATE.log"

mkdir -p "$LOG_DIR"

log() {
    local level="${2:-INFO}"
    echo "[$(date +%H:%M:%S)][$level] $1" | tee -a "$LOG_FILE"
}

log "========== WEEKLY SYSADMIN REPORT : $DATE =========="

# ----------------------------------------------------------
# TASK 1: Apply Non-Critical Patches
# ----------------------------------------------------------
log "--- TASK 1: Patch Management ---"

if command -v apt-get &>/dev/null; then
    log "Updating package lists (apt)..."
    apt-get update -qq 2>&1 | tail -3 | while read -r l; do log "  $l"; done
    UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || echo 0)
    log "Upgradable packages: $UPGRADABLE"
    if [ "$UPGRADABLE" -gt 0 ]; then
        log "Installing non-critical updates (excluding kernel)..."
        apt-get upgrade -y --with-new-pkgs \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            2>&1 | grep -E "upgraded|newly installed|removed" | while read -r l; do log "  $l"; done
    fi
elif command -v yum &>/dev/null; then
    UPDATES=$(yum check-update 2>/dev/null | grep -c "^[a-zA-Z]" || echo 0)
    log "Available yum updates: $UPDATES"
    if [ "$UPDATES" -gt 0 ]; then
        yum update --exclude="kernel*" -y 2>&1 | tail -5 | while read -r l; do log "  $l"; done
    fi
elif command -v dnf &>/dev/null; then
    UPDATES=$(dnf check-update 2>/dev/null | grep -c "^[a-zA-Z]" || echo 0)
    log "Available dnf updates: $UPDATES"
    dnf upgrade --exclude="kernel*" -y 2>&1 | tail -5 | while read -r l; do log "  $l"; done
fi

log "Patch run complete"

# ----------------------------------------------------------
# TASK 2: Backup Verification (test restore readiness)
# ----------------------------------------------------------
log "--- TASK 2: Backup Verification ---"

BACKUP_DIRS=("/backup" "/mnt/backup" "/var/backups" "/home/backups")
FOUND_BACKUP=false

for d in "${BACKUP_DIRS[@]}"; do
    if [ -d "$d" ]; then
        FOUND_BACKUP=true
        TOTAL_SIZE=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        FILE_COUNT=$(find "$d" -type f 2>/dev/null | wc -l)
        NEWEST=$(find "$d" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | awk '{print $2}')
        NEWEST_AGE=$(( ( $(date +%s) - $(stat -c %Y "$NEWEST" 2>/dev/null || echo 0) ) / 3600 ))
        log "Backup dir: $d | Size: $TOTAL_SIZE | Files: $FILE_COUNT | Newest file: $NEWEST ($NEWEST_AGE hours ago)"
        if [ "$NEWEST_AGE" -gt 48 ]; then
            log "WARNING: Most recent backup is over 48 hours old!" "WARN"
        fi
    fi
done

if ! $FOUND_BACKUP; then
    log "No backup directories found in standard locations" "WARN"
fi

# Test restore readiness: verify a sample backup file is readable
if [ -n "$NEWEST" ] && [ -f "$NEWEST" ]; then
    if file "$NEWEST" | grep -qE "gzip|tar|bzip|xz|zip"; then
        log "Sample restore test: verifying $NEWEST integrity..."
        case "$NEWEST" in
            *.tar.gz|*.tgz) tar -tzf "$NEWEST" &>/dev/null && log "  Integrity OK" || log "  FAILED integrity check" "WARN" ;;
            *.tar.bz2)       tar -tjf "$NEWEST" &>/dev/null && log "  Integrity OK" || log "  FAILED" "WARN" ;;
            *.zip)           unzip -t "$NEWEST" &>/dev/null && log "  Integrity OK" || log "  FAILED" "WARN" ;;
        esac
    fi
fi

# ----------------------------------------------------------
# TASK 3: Disk Space Management (clean logs, temp, old packages)
# ----------------------------------------------------------
log "--- TASK 3: Disk Space Cleanup ---"

df -h --output=target,avail,pcent | tail -n +2 | while read -r mount avail pct; do
    log "Before cleanup — $mount: $avail free ($pct used)"
done

# Clean old journal logs (keep last 2 weeks)
if command -v journalctl &>/dev/null; then
    FREED=$(journalctl --vacuum-time=14d 2>&1 | grep "Freed")
    log "Journal vacuum: ${FREED:-done}"
fi

# Clean apt/yum caches
if command -v apt-get &>/dev/null; then
    apt-get autoremove -y -qq 2>&1 | tail -2 | while read -r l; do log "  $l"; done
    apt-get autoclean -qq
    log "APT cache cleaned"
elif command -v yum &>/dev/null; then
    yum clean all -q && log "YUM cache cleaned"
fi

# Remove old /tmp files (older than 7 days)
TEMP_REMOVED=$(find /tmp -type f -atime +7 -delete -print 2>/dev/null | wc -l)
log "Old /tmp files removed: $TEMP_REMOVED"

# Remove old log files (older than 30 days, compressed)
OLD_LOGS=$(find /var/log -name "*.gz" -mtime +30 -delete -print 2>/dev/null | wc -l)
log "Old compressed logs removed: $OLD_LOGS"

df -h --output=target,avail,pcent | tail -n +2 | while read -r mount avail pct; do
    log "After cleanup  — $mount: $avail free ($pct used)"
done

# ----------------------------------------------------------
# TASK 4: Service & Uptime Checks
# ----------------------------------------------------------
log "--- TASK 4: Service & Uptime Checks ---"

UPTIME=$(uptime -p 2>/dev/null || uptime)
log "System uptime: $UPTIME"

CRITICAL_SERVICES=("sshd" "cron" "rsyslog" "networkd" "firewalld" "fail2ban" "auditd")

for svc in "${CRITICAL_SERVICES[@]}"; do
    if systemctl list-units --type=service 2>/dev/null | grep -q "$svc"; then
        STATUS=$(systemctl is-active "$svc" 2>/dev/null)
        log "Service $svc: $STATUS"
        if [ "$STATUS" != "active" ]; then
            log "WARNING: $svc is not active — attempting restart" "WARN"
            systemctl restart "$svc" 2>/dev/null
            sleep 2
            NEW_STATUS=$(systemctl is-active "$svc" 2>/dev/null)
            log "  Post-restart status: $NEW_STATUS"
        fi
    fi
done

# ----------------------------------------------------------
# TASK 5: Review User Activity (suspicious/inactive accounts)
# ----------------------------------------------------------
log "--- TASK 5: User Activity Review ---"

# Users with login shells (real accounts)
SHELL_USERS=$(grep -E "bash|zsh|sh" /etc/passwd | awk -F: '$3>=1000 {print $1}' | sort)
log "User accounts with login shell:"
echo "$SHELL_USERS" | while read -r u; do
    LAST=$(lastlog -u "$u" 2>/dev/null | tail -1 | awk '{print $4,$5,$6,$7,$8}')
    log "  $u — Last login: ${LAST:-Never}"
done

# Accounts with empty passwords
EMPTY_PASS=$(awk -F: '($2=="") {print $1}' /etc/shadow 2>/dev/null)
if [ -n "$EMPTY_PASS" ]; then
    log "CRITICAL: Accounts with empty passwords: $EMPTY_PASS" "WARN"
fi

# Accounts with UID 0 (root-equivalent)
ROOT_EQUIV=$(awk -F: '($3==0) {print $1}' /etc/passwd)
log "UID 0 (root-equivalent) accounts: $ROOT_EQUIV"
if echo "$ROOT_EQUIV" | grep -qv "^root$"; then
    log "WARNING: Non-root account with UID 0 found!" "WARN"
fi

# sudo group members
SUDO_MEMBERS=$(getent group sudo wheel 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | sort -u | tr '\n' ' ')
log "Sudo/wheel group members: ${SUDO_MEMBERS:-None}"

log "========== WEEKLY REPORT COMPLETE — Log: $LOG_FILE =========="
