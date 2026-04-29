#!/usr/bin/env bash
# ============================================================
# Linux Monthly SysAdmin Tasks
# Run as: root (or sudo)
# Schedule: Monthly via cron — e.g., "0 5 1 * * /opt/sysadmin/monthly.sh"
# ============================================================

LOG_DIR="/var/log/sysadmin"
DATE=$(date +%Y-%m)
LOG_FILE="$LOG_DIR/monthly_$DATE.log"

mkdir -p "$LOG_DIR"

log() {
    local level="${2:-INFO}"
    echo "[$(date +%H:%M:%S)][$level] $1" | tee -a "$LOG_FILE"
}

log "========== MONTHLY SYSADMIN REPORT : $DATE =========="

# ----------------------------------------------------------
# TASK 1: Apply Major Updates & Patches (kernel, firmware, all)
# ----------------------------------------------------------
log "--- TASK 1: Major Updates & Patches ---"

if command -v apt-get &>/dev/null; then
    log "Running full system upgrade (apt)..."
    apt-get update -qq
    BEFORE=$(dpkg -l | grep "^ii" | wc -l)
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" 2>&1 \
        | grep -E "upgraded|newly installed|removed|not upgraded" \
        | while read -r l; do log "  $l"; done
    apt-get autoremove -y -qq
    AFTER=$(dpkg -l | grep "^ii" | wc -l)
    log "Packages before: $BEFORE | After: $AFTER"

elif command -v dnf &>/dev/null; then
    log "Running full system upgrade (dnf)..."
    dnf upgrade -y 2>&1 | tail -10 | while read -r l; do log "  $l"; done
elif command -v yum &>/dev/null; then
    log "Running full system upgrade (yum)..."
    yum update -y 2>&1 | tail -10 | while read -r l; do log "  $l"; done
fi

# Check if reboot is required
if [ -f /var/run/reboot-required ]; then
    log "NOTICE: System reboot required after kernel update" "WARN"
    cat /var/run/reboot-required.pkgs 2>/dev/null | while read -r p; do log "  Requires reboot: $p"; done
fi

# Firmware updates
if command -v fwupdmgr &>/dev/null; then
    log "Checking firmware updates..."
    fwupdmgr get-updates 2>&1 | grep -E "Upgrade|Update|Version" | while read -r l; do log "  $l"; done
fi

# ----------------------------------------------------------
# TASK 2: Security Audit (firewall, open ports, vuln scanner)
# ----------------------------------------------------------
log "--- TASK 2: Security Audit ---"

# Firewall status
if command -v ufw &>/dev/null; then
    UFW_STATUS=$(ufw status verbose 2>/dev/null)
    log "UFW Firewall Status:"
    echo "$UFW_STATUS" | head -20 | while read -r l; do log "  $l"; done
elif command -v firewall-cmd &>/dev/null; then
    log "firewalld active zones:"
    firewall-cmd --list-all 2>/dev/null | while read -r l; do log "  $l"; done
elif command -v iptables &>/dev/null; then
    RULE_COUNT=$(iptables -L 2>/dev/null | wc -l)
    log "iptables rules: $RULE_COUNT lines"
fi

# Open listening ports
log "Listening ports (ss/netstat):"
if command -v ss &>/dev/null; then
    ss -tlnup 2>/dev/null | tail -n +2 | while read -r l; do log "  $l"; done
else
    netstat -tlnup 2>/dev/null | tail -n +3 | while read -r l; do log "  $l"; done
fi

# SUID/SGID files (potential privilege escalation)
log "SUID binaries (unexpected ones are a risk):"
find / -perm /4000 -type f 2>/dev/null | grep -v -E "^/(usr|bin|sbin)" | while read -r f; do
    log "  SUID outside /usr|/bin|/sbin: $f" "WARN"
done
SUID_COUNT=$(find /usr /bin /sbin -perm /4000 -type f 2>/dev/null | wc -l)
log "SUID files in standard paths: $SUID_COUNT"

# Vulnerability scanner
if command -v lynis &>/dev/null; then
    log "Running Lynis security audit..."
    LYNIS_SCORE=$(lynis audit system --quiet 2>/dev/null | grep "Hardening index" | awk '{print $NF}')
    log "Lynis Hardening Index: ${LYNIS_SCORE:-N/A}"
elif command -v openvas &>/dev/null || command -v gvmd &>/dev/null; then
    log "OpenVAS/Greenbone found — run scan via web UI at https://localhost:9392"
else
    log "No vuln scanner (lynis/openvas) found — consider: apt install lynis" "WARN"
fi

# ----------------------------------------------------------
# TASK 3: Performance Tuning
# ----------------------------------------------------------
log "--- TASK 3: Performance Tuning ---"

# CPU info
CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | awk -F: '{print $2}' | xargs)
CPU_CORES=$(nproc)
log "CPU: $CPU_MODEL | Cores: $CPU_CORES"

# Load average trends
LOAD=$(cat /proc/loadavg)
log "Load average (1m/5m/15m): $LOAD"
LOAD_1=$(echo "$LOAD" | awk '{print $1}')
if (( $(echo "$LOAD_1 > $CPU_CORES" | bc -l) )); then
    log "WARNING: Load average exceeds core count — system is overloaded!" "WARN"
fi

# Top memory consumers
log "Top 10 memory-consuming processes:"
ps aux --sort=-%mem 2>/dev/null | head -11 | tail -10 | \
    awk '{printf "  %-20s %5s%% MEM  %5s%% CPU  PID: %s\n", $11, $4, $3, $2}' | \
    while read -r l; do log "$l"; done

# Swap usage
SWAP_TOTAL=$(free -m | awk '/^Swap:/ {print $2}')
SWAP_USED=$(free  -m | awk '/^Swap:/ {print $3}')
if [ "$SWAP_TOTAL" -gt 0 ] 2>/dev/null; then
    SWAP_PCT=$(awk "BEGIN {printf \"%.1f\", ($SWAP_USED/$SWAP_TOTAL)*100}")
    log "Swap: ${SWAP_USED}MB / ${SWAP_TOTAL}MB used (${SWAP_PCT}%)"
    if (( $(echo "$SWAP_PCT > 50" | bc -l) )); then
        log "WARNING: Heavy swap usage — consider adding RAM or tuning swappiness" "WARN"
    fi
else
    log "No swap configured"
fi

# I/O stats
if command -v iostat &>/dev/null; then
    log "Disk I/O stats (iostat):"
    iostat -dx 1 1 2>/dev/null | tail -n +4 | while read -r l; do log "  $l"; done
fi

# ----------------------------------------------------------
# TASK 4: Backup Policy Review
# ----------------------------------------------------------
log "--- TASK 4: Backup Policy Review ---"

BACKUP_DIRS=("/backup" "/mnt/backup" "/var/backups" "/home/backups")
for d in "${BACKUP_DIRS[@]}"; do
    if [ -d "$d" ]; then
        SIZE=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        FILES=$(find "$d" -type f 2>/dev/null | wc -l)
        OLDEST=$(find "$d" -type f -printf '%T+ %p\n' 2>/dev/null | sort | head -1 | awk '{print $1}')
        NEWEST=$(find "$d" -type f -printf '%T+ %p\n' 2>/dev/null | sort | tail -1 | awk '{print $1}')
        log "Backup dir: $d | Size: $SIZE | Files: $FILES | Oldest: $OLDEST | Newest: $NEWEST"
    fi
done

# Crontab backup jobs
log "Cron-based backup jobs:"
crontab -l 2>/dev/null | grep -i "backup\|rsync\|dump\|tar" | while read -r l; do log "  $l"; done
for f in /etc/cron.d/* /etc/cron.daily/* /etc/cron.weekly/*; do
    [ -f "$f" ] && grep -li "backup\|rsync\|dump" "$f" 2>/dev/null | while read -r cf; do log "  Found backup job: $cf"; done
done

log "ACTION: Verify offsite backup replication and test a restore this month." "INFO"

# ----------------------------------------------------------
# TASK 5: Inventory & Asset Audit
# ----------------------------------------------------------
log "--- TASK 5: Inventory & Asset Audit ---"

# Hardware summary
log "Hardware Inventory:"
if command -v dmidecode &>/dev/null; then
    SYSTEM=$(dmidecode -t system 2>/dev/null | grep -E "Manufacturer|Product|Version|Serial" | head -4)
    echo "$SYSTEM" | while read -r l; do log "  $l"; done
fi

MEM_GB=$(free -g | awk '/^Mem:/ {print $2}')
log "RAM: ${MEM_GB}GB"

log "Disk inventory:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE 2>/dev/null | while read -r l; do log "  $l"; done

# OS details
OS_INFO=$(cat /etc/os-release 2>/dev/null | grep -E "^NAME|^VERSION=" | tr '\n' ' ')
KERNEL=$(uname -r)
log "OS: $OS_INFO | Kernel: $KERNEL"

# Expiring SSL certificates
log "Checking SSL certificates for expiry (next 60 days)..."
find /etc/ssl /etc/pki /etc/letsencrypt 2>/dev/null -name "*.crt" -o -name "*.pem" | while read -r cert; do
    EXPIRY=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
    if [ -n "$EXPIRY" ]; then
        EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null)
        NOW_EPOCH=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
        if [ "$DAYS_LEFT" -lt 60 ] 2>/dev/null; then
            log "EXPIRING SOON: $cert | Expires: $EXPIRY ($DAYS_LEFT days)" "WARN"
        fi
    fi
done

# Installed package count
if command -v dpkg &>/dev/null; then
    PKG_COUNT=$(dpkg -l | grep "^ii" | wc -l)
    log "Installed packages (dpkg): $PKG_COUNT"
elif command -v rpm &>/dev/null; then
    PKG_COUNT=$(rpm -qa | wc -l)
    log "Installed packages (rpm): $PKG_COUNT"
fi

log "========== MONTHLY REPORT COMPLETE — Log: $LOG_FILE =========="
