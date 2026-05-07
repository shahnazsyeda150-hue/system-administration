#!/usr/bin/env bash
# ============================================================
# Linux Yearly SysAdmin Tasks
# Run as: root (or sudo)
# Schedule: Yearly via cron — e.g., "0 5 1 1 * /opt/sysadmin/yearly.sh"
# ============================================================

LOG_DIR="/var/log/sysadmin"
YEAR=$(date +%Y)
LOG_FILE="$LOG_DIR/yearly_$YEAR.log"

mkdir -p "$LOG_DIR"

log() {
    local level="${2:-INFO}"
    echo "[$(date +%H:%M:%S)][$level] $1" | tee -a "$LOG_FILE"
}

log "========== YEARLY SYSADMIN REPORT : $YEAR =========="

# ----------------------------------------------------------
# TASK 1: Disaster Recovery (DR) Drill Simulation
# ----------------------------------------------------------
log "--- TASK 1: Disaster Recovery Drill ---"

# Test SSH connectivity to DR/backup site
DR_HOSTS=("backup-server" "dr-site" "offsite-nas")  # Replace with actual hostnames/IPs
for host in "${DR_HOSTS[@]}"; do
    if ping -c 2 -W 3 "$host" &>/dev/null; then
        log "DR host $host: reachable"
    else
        log "DR host $host: NOT reachable" "WARN"
    fi
done

# Test most recent backup restore readiness
BACKUP_DIRS=("/backup" "/mnt/backup" "/var/backups")
for d in "${BACKUP_DIRS[@]}"; do
    if [ -d "$d" ]; then
        NEWEST=$(find "$d" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | awk '{print $2}')
        if [ -n "$NEWEST" ]; then
            log "Testing restore readiness of: $NEWEST"
            RESTORE_TEST_DIR="/tmp/dr_restore_test_$$"
            mkdir -p "$RESTORE_TEST_DIR"
            case "$NEWEST" in
                *.tar.gz|*.tgz)
                    tar -tzf "$NEWEST" &>/dev/null && log "  tar.gz integrity: OK" || log "  tar.gz integrity: FAILED" "WARN"
                    ;;
                *.tar.bz2)
                    tar -tjf "$NEWEST" &>/dev/null && log "  tar.bz2 integrity: OK" || log "  tar.bz2: FAILED" "WARN"
                    ;;
                *.zip)
                    unzip -t "$NEWEST" &>/dev/null && log "  zip integrity: OK" || log "  zip: FAILED" "WARN"
                    ;;
                *)
                    file "$NEWEST" | while read -r l; do log "  File type: $l"; done
                    ;;
            esac
            rm -rf "$RESTORE_TEST_DIR"
        fi
    fi
done

# Check DR documentation
DR_DOCS=("/opt/sysadmin/DR-Plan.md" "/etc/sysadmin/dr-runbook.txt" "/var/sysadmin/dr-plan.pdf")
for doc in "${DR_DOCS[@]}"; do
    if [ -f "$doc" ]; then
        AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$doc") ) / 86400 ))
        log "DR document: $doc (last modified $AGE_DAYS days ago)"
        if [ "$AGE_DAYS" -gt 180 ]; then
            log "WARNING: DR document over 6 months old — update required!" "WARN"
        fi
    fi
done

log "ACTION: Perform live DR drill — restore a VM or critical service from backup." "INFO"

# ----------------------------------------------------------
# TASK 2: Infrastructure Upgrade Planning
# ----------------------------------------------------------
log "--- TASK 2: Infrastructure Upgrade Planning ---"

# OS version and EOL check
OS_NAME=$(grep "^PRETTY_NAME" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
OS_ID=$(grep "^ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
OS_VERSION=$(grep "^VERSION_ID" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
KERNEL=$(uname -r)
log "OS: $OS_NAME | Kernel: $KERNEL"

# Check if LTS/EOL info is available
if command -v ubuntu-security-status &>/dev/null; then
    ubuntu-security-status 2>/dev/null | head -5 | while read -r l; do log "  $l"; done
elif command -v dnf &>/dev/null; then
    log "Check https://endoflife.date/$OS_ID for EOL info"
fi

# Hardware age
log "Hardware inventory:"
if command -v dmidecode &>/dev/null; then
    dmidecode -t system 2>/dev/null | grep -E "Manufacturer|Product Name|Version|Serial" | \
        while read -r l; do log "  $l"; done
    BIOS_DATE=$(dmidecode -t bios 2>/dev/null | grep "Release Date" | awk -F: '{print $2}' | xargs)
    log "  BIOS Release Date: $BIOS_DATE"
fi

# Disk health (smartmontools)
log "Disk SMART health:"
if command -v smartctl &>/dev/null; then
    for disk in /dev/sd? /dev/nvme?; do
        [ -e "$disk" ] || continue
        HEALTH=$(smartctl -H "$disk" 2>/dev/null | grep "overall-health" | awk '{print $NF}')
        log "  $disk: $HEALTH"
        if [ "$HEALTH" != "PASSED" ] && [ -n "$HEALTH" ]; then
            log "  WARNING: $disk SMART status is $HEALTH — replace soon!" "WARN"
        fi
    done
else
    log "smartctl not found — install: apt install smartmontools" "WARN"
fi

# Memory slots used
if command -v dmidecode &>/dev/null; then
    MEM_SLOTS=$(dmidecode -t memory 2>/dev/null | grep "Size:" | grep -v "No Module" | wc -l)
    MEM_TOTAL=$(free -g | awk '/^Mem:/ {print $2}')
    log "RAM: ${MEM_TOTAL}GB across $MEM_SLOTS DIMM slots"
fi

# ----------------------------------------------------------
# TASK 3: Security Policy Review
# ----------------------------------------------------------
log "--- TASK 3: Security Policy Review ---"

# Password policy
log "Password policy (/etc/login.defs):"
grep -E "^PASS_MAX_DAYS|^PASS_MIN_DAYS|^PASS_MIN_LEN|^PASS_WARN_AGE" /etc/login.defs 2>/dev/null | \
    while read -r l; do log "  $l"; done

# PAM password quality
if [ -f /etc/security/pwquality.conf ]; then
    log "PAM pwquality settings:"
    grep -v "^#\|^$" /etc/security/pwquality.conf | while read -r l; do log "  $l"; done
fi

# SSH configuration review
log "SSH configuration highlights:"
SSHD_CONF="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONF" ]; then
    KEYS=(PermitRootLogin PasswordAuthentication PubkeyAuthentication MaxAuthTries Protocol AllowUsers DenyUsers)
    for key in "${KEYS[@]}"; do
        VAL=$(grep -i "^$key" "$SSHD_CONF" 2>/dev/null | awk '{print $2}')
        log "  SSH $key: ${VAL:-not set (using default)}"
    done
    # Flag risky settings
    if grep -qi "^PermitRootLogin yes" "$SSHD_CONF"; then
        log "  CRITICAL: Root SSH login is enabled!" "WARN"
    fi
    if grep -qi "^PasswordAuthentication yes" "$SSHD_CONF"; then
        log "  WARNING: Password authentication enabled — prefer key-only auth" "WARN"
    fi
fi

# Sudoers audit
log "Sudoers entries (non-comment):"
grep -v "^#\|^$" /etc/sudoers 2>/dev/null | while read -r l; do log "  $l"; done
ls /etc/sudoers.d/ 2>/dev/null | while read -r f; do log "  sudoers.d: $f"; done

# Lynis annual audit
if command -v lynis &>/dev/null; then
    log "Running Lynis annual security audit..."
    lynis audit system --quiet 2>/dev/null | grep -E "Hardening index|Warning|Suggestion" | head -20 | \
        while read -r l; do log "  $l"; done
fi

log "ACTION: Update Security Policy document based on new threats and compliance requirements." "INFO"

# ----------------------------------------------------------
# TASK 4: License Renewals & Compliance
# ----------------------------------------------------------
log "--- TASK 4: License Renewals & Compliance ---"

# SSL certificate audit (all cert files)
log "SSL certificates expiring in next 12 months:"
CERT_PATHS=("/etc/ssl" "/etc/pki" "/etc/letsencrypt" "/etc/nginx" "/etc/apache2" "/etc/httpd")
for cert_dir in "${CERT_PATHS[@]}"; do
    [ -d "$cert_dir" ] || continue
    find "$cert_dir" -name "*.crt" -o -name "*.pem" 2>/dev/null | while read -r cert; do
        EXPIRY=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
        [ -z "$EXPIRY" ] && continue
        EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null)
        NOW_EPOCH=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
        if [ "$DAYS_LEFT" -lt 365 ] 2>/dev/null; then
            SUBJECT=$(openssl x509 -subject -noout -in "$cert" 2>/dev/null | cut -d= -f2-)
            log "  $cert | Subject: $SUBJECT | Expires: $EXPIRY ($DAYS_LEFT days)" "WARN"
        fi
    done
done

# Let's Encrypt renewal check
if command -v certbot &>/dev/null; then
    log "Let's Encrypt certificates:"
    certbot certificates 2>/dev/null | grep -E "Domains:|Expiry|VALID|INVALID" | \
        while read -r l; do log "  $l"; done
fi

# Software license audit (key packages)
log "Key software versions:"
for pkg in apache2 nginx mysql-server postgresql openssl openssh-server fail2ban; do
    if command -v dpkg &>/dev/null; then
        VER=$(dpkg -l "$pkg" 2>/dev/null | grep "^ii" | awk '{print $3}')
    elif command -v rpm &>/dev/null; then
        VER=$(rpm -q "$pkg" 2>/dev/null)
    fi
    [ -n "$VER" ] && log "  $pkg: $VER"
done

log "ACTION: Renew SSL certificates, software subscriptions, and support contracts." "INFO"

# ----------------------------------------------------------
# TASK 5: Capacity Planning
# ----------------------------------------------------------
log "--- TASK 5: Capacity Planning ---"

log "=== Current Capacity ==="

# CPU
CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
CPU_CORES=$(nproc)
log "CPU: $CPU_MODEL | Physical cores: $(grep "^cpu cores" /proc/cpuinfo | head -1 | awk '{print $4}') | Logical: $CPU_CORES"

# Memory
MEM_TOTAL=$(free -g | awk '/^Mem:/ {print $2}')
MEM_USED=$(free  -g | awk '/^Mem:/ {print $3}')
log "RAM: ${MEM_USED}GB / ${MEM_TOTAL}GB used"
MEM_PCT=$(awk "BEGIN {printf \"%.1f\", ($MEM_USED/$MEM_TOTAL)*100}" 2>/dev/null)
if (( $(echo "$MEM_PCT > 75" | bc -l 2>/dev/null) )); then
    log "PLANNING: Memory consistently over 75% — consider expansion" "WARN"
fi

# Disk
log "Disk capacity:"
df -h --output=target,size,used,avail,pcent | tail -n +2 | while read -r l; do
    log "  $l"
    PCT=$(echo "$l" | awk '{print $5}' | tr -d '%')
    MOUNT=$(echo "$l" | awk '{print $1}')
    if [ "$PCT" -gt 70 ] 2>/dev/null; then
        log "  PLANNING NOTE: $MOUNT is >70% full — plan storage expansion" "WARN"
    fi
done

# Network interfaces
log "Network interfaces:"
ip -br addr 2>/dev/null | while read -r l; do log "  $l"; done

# Virtualization
if command -v virsh &>/dev/null; then
    log "KVM/libvirt VMs:"
    virsh list --all 2>/dev/null | while read -r l; do log "  $l"; done
fi

if command -v docker &>/dev/null; then
    CONTAINER_COUNT=$(docker ps -a --format "{{.Names}}" 2>/dev/null | wc -l)
    log "Docker containers: $CONTAINER_COUNT"
fi

log "=== 12-Month Planning Checklist ==="
log "  [ ] Hardware refresh for servers older than 5 years"
log "  [ ] Evaluate cloud migration for suitable workloads (AWS/GCP/Azure)"
log "  [ ] Storage forecast: add capacity if >70% consistently"
log "  [ ] Network upgrade: assess if bandwidth is saturated"
log "  [ ] Kernel upgrade planning (test on staging first)"
log "  [ ] Budget for infrastructure needs"
log "  [ ] Disaster recovery site capacity review"
log "  [ ] Containerization/Kubernetes adoption assessment"

log "========== YEARLY REPORT COMPLETE — Log: $LOG_FILE =========="
