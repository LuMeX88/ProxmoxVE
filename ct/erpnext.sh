#!/usr/bin/env bash

# Copyright (c) 2024 LuMeX88
# License: MIT
# https://github.com/LuMeX88/ProxmoxVE/blob/main/LICENSE
#
# ERPNext LXC Installation Script for Proxmox
# Installs ERPNext with Frappe Bench (v15) in a single LXC container
# Components: Frappe Bench, ERPNext, MariaDB, Redis, Nginx, Supervisor
# v1.1 — Fixed for Debian 12+ / Ubuntu 24.04+

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Color codes
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ──────────────────────────────────────────────────────────────────────────────
# Helper functions
# ──────────────────────────────────────────────────────────────────────────────
function msg_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

function msg_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

function msg_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function msg_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Pre-flight checks
# ──────────────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root"
fi

if ! grep -qi 'debian\|ubuntu' /etc/os-release 2>/dev/null; then
    msg_error "This script requires Debian or Ubuntu"
fi

echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          ERPNext LXC Installation Script v1.1               ║${NC}"
echo -e "${GREEN}║          Frappe Bench + MariaDB + Redis + Nginx             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"

# ──────────────────────────────────────────────────────────────────────────────
# Configuration variables
# ──────────────────────────────────────────────────────────────────────────────
SITE_NAME="erpnext.local"
ADMIN_PASS="admin@123"
DB_ROOT_PASS="erpnext-root-$(openssl rand -hex 4)"
DB_PASS="erpnext-db-$(openssl rand -hex 4)"
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
NODE_VERSION="20"
WKHTMLTOPDF_VERSION="0.12.6.1-3"

msg_info "Configuration:"
echo -e "  Site Name:       ${SITE_NAME}"
echo -e "  Frappe Branch:   ${FRAPPE_BRANCH}"
echo -e "  ERPNext Branch:  ${ERPNEXT_BRANCH}"
echo -e "  Node.js:         v${NODE_VERSION}"
echo -e ""

# ──────────────────────────────────────────────────────────────────────────────
# Step 1: Update system
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq
msg_ok "System updated"

# ──────────────────────────────────────────────────────────────────────────────
# Step 2: Install system dependencies
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Installing system dependencies..."
apt-get install -y -qq \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    python3-setuptools \
    git \
    curl \
    wget \
    build-essential \
    libssl-dev \
    libffi-dev \
    libxslt1-dev \
    libxml2-dev \
    zlib1g-dev \
    libjpeg-dev \
    libpng-dev \
    libfreetype6-dev \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    supervisor \
    redis-server \
    mariadb-server \
    mariadb-client \
    libmariadb-dev \
    xvfb \
    cron \
    nano \
    htop \
    nginx
msg_ok "System dependencies installed"

# ──────────────────────────────────────────────────────────────────────────────
# Step 3: Install patched wkhtmltopdf
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Installing patched wkhtmltopdf..."
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64)
        WKHTML_DEB="wkhtmltox_${WKHTMLTOPDF_VERSION}.bookworm_amd64.deb"
        ;;
    arm64)
        WKHTML_DEB="wkhtmltox_${WKHTMLTOPDF_VERSION}.bookworm_arm64.deb"
        ;;
    *)
        msg_warn "No patched wkhtmltopdf for ${ARCH}, falling back to distro package"
        apt-get install -y -qq wkhtmltopdf
        WKHTML_DEB=""
        ;;
esac

if [[ -n "$WKHTML_DEB" ]]; then
    WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/${WKHTML_DEB}"
    TMPFILE=$(mktemp /tmp/wkhtmltox-XXXXXX.deb)
    if curl -fsSL -o "$TMPFILE" "$WKHTML_URL"; then
        apt-get install -y -qq "$TMPFILE"
        rm -f "$TMPFILE"
    else
        msg_warn "Failed to download patched wkhtmltopdf, falling back to distro package"
        rm -f "$TMPFILE"
        apt-get install -y -qq wkhtmltopdf
    fi
fi
msg_ok "wkhtmltopdf installed"

# ──────────────────────────────────────────────────────────────────────────────
# Step 4: Install Node.js
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Installing Node.js ${NODE_VERSION}..."
if ! command -v node &>/dev/null || [[ "$(node -v | cut -d. -f1 | tr -d 'v')" -ne "$NODE_VERSION" ]]; then
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg
    echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_VERSION}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq
    apt-get install -y -qq nodejs
fi
npm install -g yarn > /dev/null 2>&1
msg_ok "Node.js $(node -v) installed"

# ──────────────────────────────────────────────────────────────────────────────
# Step 5: Configure MariaDB
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Configuring MariaDB..."

# Detect MariaDB major version to decide on deprecated options
MARIADB_VER=$(mysqld --version 2>/dev/null | grep -oP 'Ver\s+\K[0-9]+\.[0-9]+' || echo "10.11")
MARIADB_MAJOR=$(echo "$MARIADB_VER" | cut -d. -f1)
MARIADB_MINOR=$(echo "$MARIADB_VER" | cut -d. -f2)

cat > /etc/mysql/mariadb.conf.d/99-erpnext.cnf << MARIACONF
[mysqld]
innodb-file-per-table=1
character-set-client-handshake=FALSE
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
MARIACONF

# Only add legacy options for MariaDB < 10.6
if [[ "$MARIADB_MAJOR" -lt 10 ]] || { [[ "$MARIADB_MAJOR" -eq 10 ]] && [[ "$MARIADB_MINOR" -lt 6 ]]; }; then
    sed -i '/\[mysqld\]/a innodb-file-format=barracuda\ninnodb-large-prefix=1' \
        /etc/mysql/mariadb.conf.d/99-erpnext.cnf
fi

cat >> /etc/mysql/mariadb.conf.d/99-erpnext.cnf << 'MARIACONF2'

[mysql]
default-character-set=utf8mb4
MARIACONF2

systemctl restart mariadb
systemctl enable mariadb > /dev/null 2>&1

# Secure MariaDB
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';"
mysql -u root -p"${DB_ROOT_PASS}" -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p"${DB_ROOT_PASS}" -e "FLUSH PRIVILEGES;"
msg_ok "MariaDB configured (version ${MARIADB_VER})"

# ──────────────────────────────────────────────────────────────────────────────
# Step 6: Configure Redis
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Configuring Redis..."
systemctl start redis-server
systemctl enable redis-server > /dev/null 2>&1
msg_ok "Redis configured"

# ──────────────────────────────────────────────────────────────────────────────
# Step 7: Create frappe user
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Creating frappe user..."
if id "frappe" &>/dev/null; then
    msg_warn "User frappe already exists, skipping"
else
    useradd -m -s /bin/bash frappe
    echo "frappe ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/frappe
    chmod 0440 /etc/sudoers.d/frappe
    msg_ok "User frappe created"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 8: Install Frappe Bench CLI
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Installing Frappe Bench CLI..."
pip3 install --break-system-packages frappe-bench
msg_ok "Frappe Bench CLI installed"

# ──────────────────────────────────────────────────────────────────────────────
# Step 9: Initialize Frappe Bench
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Initializing Frappe Bench (this may take several minutes)..."
sudo -u frappe bash -c "
    cd /home/frappe
    bench init --frappe-branch ${FRAPPE_BRANCH} frappe-bench
" 2>&1 | tail -5
msg_ok "Frappe Bench initialized"

# ──────────────────────────────────────────────────────────────────────────────
# Step 10: Create ERPNext site
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Creating ERPNext site: ${SITE_NAME}..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench new-site '${SITE_NAME}' \
        --admin-password '${ADMIN_PASS}' \
        --mariadb-root-password '${DB_ROOT_PASS}'
"
msg_ok "Site ${SITE_NAME} created"

# ──────────────────────────────────────────────────────────────────────────────
# Step 11: Install ERPNext app
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Downloading ERPNext (this may take several minutes)..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench get-app --branch ${ERPNEXT_BRANCH} erpnext
" 2>&1 | tail -5
msg_ok "ERPNext downloaded"

msg_info "Installing ERPNext on site ${SITE_NAME}..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench --site '${SITE_NAME}' install-app erpnext
"
msg_ok "ERPNext installed"

# ──────────────────────────────────────────────────────────────────────────────
# Step 12: Build assets
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Building assets..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench build
"
msg_ok "Assets built"

# ──────────────────────────────────────────────────────────────────────────────
# Step 13: Set site as default
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Setting ${SITE_NAME} as default site..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench use '${SITE_NAME}'
"
msg_ok "Default site set"

# ──────────────────────────────────────────────────────────────────────────────
# Step 14: Setup production (Nginx + Supervisor via bench)
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Setting up production configuration..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    sudo bench setup production frappe --yes
" 2>&1 | tail -5
msg_ok "Production setup complete"

# ──────────────────────────────────────────────────────────────────────────────
# Step 15: Enable scheduler
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Enabling scheduler..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench --site '${SITE_NAME}' enable-scheduler
"
msg_ok "Scheduler enabled"

# ──────────────────────────────────────────────────────────────────────────────
# Step 16: Create backup & restore scripts
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Creating backup scripts..."
mkdir -p /home/frappe/backups
chown frappe:frappe /home/frappe/backups

# Backup script
cat > /home/frappe/backup-erpnext.sh << 'BACKUPSCRIPT'
#!/bin/bash
set -euo pipefail

BACKUP_DIR="/home/frappe/backups"
DATE=$(date +%Y%m%d_%H%M%S)

echo "[$(date)] Starting ERPNext backup..."
cd /home/frappe/frappe-bench
bench --site erpnext.local backup --with-files

# Find latest backup files
LATEST_DB=$(ls -t sites/erpnext.local/private/backups/*-database.sql.gz 2>/dev/null | head -1)
LATEST_FILES=$(ls -t sites/erpnext.local/private/backups/*-files.tar 2>/dev/null | head -1)
LATEST_PRIVATE=$(ls -t sites/erpnext.local/private/backups/*-private-files.tar 2>/dev/null | head -1)

if [ -n "$LATEST_DB" ]; then
    BACKUP_FILE="$BACKUP_DIR/erpnext_full_backup_$DATE.tar.gz"

    TAR_ARGS=("$LATEST_DB" "sites/erpnext.local/site_config.json")
    [[ -n "${LATEST_FILES:-}" ]] && TAR_ARGS+=("$LATEST_FILES")
    [[ -n "${LATEST_PRIVATE:-}" ]] && TAR_ARGS+=("$LATEST_PRIVATE")

    tar -czf "$BACKUP_FILE" "${TAR_ARGS[@]}"
    echo "[$(date)] Backup completed: $BACKUP_FILE"
    echo "Size: $(du -h "$BACKUP_FILE" | cut -f1)"
else
    echo "[$(date)] ERROR: No backup files found!"
    exit 1
fi

# Keep only last 7 backups
find "$BACKUP_DIR" -name "erpnext_full_backup_*.tar.gz" -mtime +7 -delete
echo "[$(date)] Old backups cleaned up"
BACKUPSCRIPT

chmod +x /home/frappe/backup-erpnext.sh
chown frappe:frappe /home/frappe/backup-erpnext.sh

# Restore script
cat > /home/frappe/restore-erpnext.sh << 'RESTORESCRIPT'
#!/bin/bash
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <database-backup.sql.gz> [files-backup.tar] [private-files-backup.tar]"
    echo ""
    echo "Example:"
    echo "  $0 /path/to/20240101_120000-erpnext_local-database.sql.gz"
    echo ""
    echo "Available backups:"
    ls -la /home/frappe/backups/ 2>/dev/null || echo "  No backups found"
    exit 1
fi

DB_FILE="$1"
PUBLIC_FILES="${2:-}"
PRIVATE_FILES="${3:-}"

# Validate that the database backup file exists
if [[ ! -f "$DB_FILE" ]]; then
    echo "ERROR: Database backup file not found: $DB_FILE"
    exit 1
fi

echo "[$(date)] Starting restore..."
echo "WARNING: This will overwrite the current database!"
read -r -p "Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Restore cancelled."
    exit 0
fi

cd /home/frappe/frappe-bench

# Create safety backup first
echo "[$(date)] Creating safety backup before restore..."
bench --site erpnext.local backup

# Build restore command as an array (no eval)
RESTORE_ARGS=(bench --site erpnext.local restore "$DB_FILE")
[[ -n "$PUBLIC_FILES" ]]  && RESTORE_ARGS+=(--with-public-files "$PUBLIC_FILES")
[[ -n "$PRIVATE_FILES" ]] && RESTORE_ARGS+=(--with-private-files "$PRIVATE_FILES")

"${RESTORE_ARGS[@]}"

echo "[$(date)] Running migrations..."
bench --site erpnext.local migrate

echo "[$(date)] Clearing cache..."
bench --site erpnext.local clear-cache

echo "[$(date)] Restore completed!"
RESTORESCRIPT

chmod +x /home/frappe/restore-erpnext.sh
chown frappe:frappe /home/frappe/restore-erpnext.sh
msg_ok "Backup scripts created"

# ──────────────────────────────────────────────────────────────────────────────
# Step 17: Schedule daily backups (idempotent — won't duplicate)
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Scheduling daily backups (2 AM)..."
CRON_JOB="0 2 * * * /home/frappe/backup-erpnext.sh >> /home/frappe/backups/backup.log 2>&1"
EXISTING_CRON=$(crontab -u frappe -l 2>/dev/null || true)
if echo "$EXISTING_CRON" | grep -qF "backup-erpnext.sh"; then
    msg_warn "Backup cron job already exists, skipping"
else
    (echo "$EXISTING_CRON"; echo "$CRON_JOB") | crontab -u frappe -
    msg_ok "Daily backups scheduled"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 18: Save credentials
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Saving credentials..."
cat > /root/.erpnext-credentials << CREDS
# ERPNext Credentials - KEEP THIS FILE SAFE
# Generated on: $(date)
# ──────────────────────────────────────────
Site:               ${SITE_NAME}
Admin User:         Administrator
Admin Password:     ${ADMIN_PASS}
MariaDB Root Pass:  ${DB_ROOT_PASS}
MariaDB ERPNext:    (managed by bench)
# ──────────────────────────────────────────
CREDS
chmod 600 /root/.erpnext-credentials
msg_ok "Credentials saved to /root/.erpnext-credentials"

# ──────────────────────────────────────────────────────────────────────────────
# Step 19: Final restart of services
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Restarting all services..."
systemctl restart nginx
systemctl restart supervisor
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench restart
" 2>/dev/null || true
msg_ok "All services restarted"

# ──────────────────────────────────────────────────────────────────────────────
# Installation complete
# ──────────────────────────────────────────────────────────────────────────────
LXC_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       ERPNext Installation Completed Successfully!          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Access Information:${NC}"
echo -e "  URL:              http://${LXC_IP}"
echo -e "  Site:             ${SITE_NAME}"
echo -e "  Admin User:       Administrator"
echo -e "  Admin Password:   ${ADMIN_PASS}"
echo ""
echo -e "${GREEN}Important Paths:${NC}"
echo -e "  Bench:            /home/frappe/frappe-bench"
echo -e "  Sites:            /home/frappe/frappe-bench/sites"
echo -e "  Backups:          /home/frappe/backups"
echo -e "  Credentials:      /root/.erpnext-credentials"
echo ""
echo -e "${GREEN}Useful Commands:${NC}"
echo -e "  Create Backup:    sudo -u frappe /home/frappe/backup-erpnext.sh"
echo -e "  Restore:          sudo -u frappe /home/frappe/restore-erpnext.sh <file>"
echo -e "  Bench Restart:    cd /home/frappe/frappe-bench && sudo -u frappe bench restart"
echo -e "  Bench Update:     cd /home/frappe/frappe-bench && sudo -u frappe bench update"
echo -e "  Bench Console:    cd /home/frappe/frappe-bench && sudo -u frappe bench console"
echo -e "  Migrate:          cd /home/frappe/frappe-bench && sudo -u frappe bench --site ${SITE_NAME} migrate"
echo ""
echo -e "${GREEN}Services:${NC}"
echo -e "  Nginx:            $(systemctl is-active nginx)"
echo -e "  MariaDB:          $(systemctl is-active mariadb)"
echo -e "  Redis:            $(systemctl is-active redis-server)"
echo -e "  Supervisor:       $(systemctl is-active supervisor)"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo -e "  1. Change the admin password immediately!"
echo -e "  2. Configure your domain in Nginx"
echo -e "  3. Set up SSL (Let's Encrypt recommended)"
echo -e "  4. Test backup/restore process"
echo -e "  5. Review /root/.erpnext-credentials for DB passwords"
echo ""
echo -e "${YELLOW}Portable Backups:${NC}"
echo -e "  Run:  sudo -u frappe /home/frappe/backup-erpnext.sh"
echo -e "  Copy: /home/frappe/backups/ to external storage"
echo -e "  Auto: Daily backup runs at 2:00 AM"
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo ""
