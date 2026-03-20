#!/usr/bin/env bash

# Copyright (c) 2024 LuMeX88
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://erpnext.com/ | Github: https://github.com/frappe/erpnext
# Description: Installs ERPNext v15 with Frappe Bench, MariaDB, Redis, Nginx, Supervisor

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────
SITE_NAME="erpnext.local"
ADMIN_PASS="admin@123"
DB_ROOT_PASS="erpnext-root-$(openssl rand -hex 4)"
FRAPPE_BRANCH="version-15"
ERPNEXT_BRANCH="version-15"
NODE_VERSION="20"
WKHTMLTOPDF_VERSION="0.12.6.1-3"

# ──────────────────────────────────────────────────────────────────────────────
# Step 1: Install system dependencies
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Installing Dependencies"
$STD apt-get install -y \
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
  nginx \
  pipx
msg_ok "Installed Dependencies"

# ──────────────────────────────────────────────────────────────────────────────
# Step 2: Install patched wkhtmltopdf
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Installing Patched wkhtmltopdf"
ARCH=$(dpkg --print-architecture)
WKHTML_DEB=""
case "$ARCH" in
  amd64) WKHTML_DEB="wkhtmltox_${WKHTMLTOPDF_VERSION}.bookworm_amd64.deb" ;;
  arm64) WKHTML_DEB="wkhtmltox_${WKHTMLTOPDF_VERSION}.bookworm_arm64.deb" ;;
esac

if [[ -n "$WKHTML_DEB" ]]; then
  TMPFILE=$(mktemp /tmp/wkhtmltox-XXXXXX.deb)
  if curl -fsSL -o "$TMPFILE" "https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOPDF_VERSION}/${WKHTML_DEB}"; then
    $STD apt-get install -y "$TMPFILE"
    rm -f "$TMPFILE"
  else
    rm -f "$TMPFILE"
    $STD apt-get install -y wkhtmltopdf
  fi
else
  $STD apt-get install -y wkhtmltopdf
fi
msg_ok "Installed wkhtmltopdf"

# ──────────────────────────────────────────────────────────────────────────────
# Step 3: Install Node.js
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Installing Node.js ${NODE_VERSION}"
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg
echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_VERSION}.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list
$STD apt-get update
$STD apt-get install -y nodejs
$STD npm install -g yarn
msg_ok "Installed Node.js $(node -v)"

# ──────────────────────────────────────────────────────────────────────────────
# Step 4: Configure MariaDB
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Configuring MariaDB"
cat > /etc/mysql/mariadb.conf.d/99-erpnext.cnf << 'EOF'
[mysqld]
innodb-file-per-table=1
character-set-client-handshake=FALSE
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci

[mysql]
default-character-set=utf8mb4
EOF

systemctl restart mariadb
systemctl enable -q mariadb

mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';"
mysql -u root -p"${DB_ROOT_PASS}" -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p"${DB_ROOT_PASS}" -e "FLUSH PRIVILEGES;"
msg_ok "Configured MariaDB"

# ──────────────────────────────────────────────────────────────────────────────
# Step 5: Configure Redis
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Configuring Redis"
systemctl start redis-server
systemctl enable -q redis-server
msg_ok "Configured Redis"

# ──────────────────────────────────────────────────────────────────────────────
# Step 6: Create frappe user
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Creating frappe User"
if ! id "frappe" &>/dev/null; then
  useradd -m -s /bin/bash frappe
  echo "frappe ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/frappe
  chmod 0440 /etc/sudoers.d/frappe
fi
msg_ok "Created frappe User"

# ──────────────────────────────────────────────────────────────────────────────
# Step 7: Install Frappe Bench CLI
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Installing Frappe Bench CLI"
sudo -u frappe bash -c "pipx install frappe-bench"
sudo -u frappe bash -c "pipx ensurepath" >/dev/null 2>&1
# Symlink from frappe's pipx path (not root's) so all users can reach it
ln -sf /home/frappe/.local/bin/bench /usr/local/bin/bench
msg_ok "Installed Frappe Bench CLI"

# ──────────────────────────────────────────────────────────────────────────────
# Step 8: Initialize Frappe Bench
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Initializing Frappe Bench (patience...)"
sudo -u frappe bash -c "
  cd /home/frappe
  bench init --frappe-branch ${FRAPPE_BRANCH} frappe-bench
"
msg_ok "Initialized Frappe Bench"

# ──────────────────────────────────────────────────────────────────────────────
# Step 9: Create ERPNext site
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Creating Site ${SITE_NAME}"
sudo -u frappe bash -c "
  cd /home/frappe/frappe-bench
  bench new-site '${SITE_NAME}' \
    --admin-password '${ADMIN_PASS}' \
    --mariadb-root-password '${DB_ROOT_PASS}'
"
msg_ok "Created Site ${SITE_NAME}"

# ──────────────────────────────────────────────────────────────────────────────
# Step 10: Download & install ERPNext
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Downloading ERPNext (patience...)"
sudo -u frappe bash -c "
  cd /home/frappe/frappe-bench
  bench get-app --branch ${ERPNEXT_BRANCH} erpnext
"
msg_ok "Downloaded ERPNext"

msg_info "Installing ERPNext on ${SITE_NAME}"
sudo -u frappe bash -c "
  cd /home/frappe/frappe-bench
  bench --site '${SITE_NAME}' install-app erpnext
"
msg_ok "Installed ERPNext"

# ──────────────────────────────────────────────────────────────────────────────
# Step 11: Build assets & set default site
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Building Assets"
sudo -u frappe bash -c "
  cd /home/frappe/frappe-bench
  bench build
"
msg_ok "Built Assets"

msg_info "Setting Default Site"
sudo -u frappe bash -c "
  cd /home/frappe/frappe-bench
  bench use '${SITE_NAME}'
"
msg_ok "Set Default Site"

# ──────────────────────────────────────────────────────────────────────────────
# Step 12: Setup production (Nginx + Supervisor)
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Setting Up Production"
sudo -u frappe bash -c "
  cd /home/frappe/frappe-bench
  sudo bench setup production frappe --yes
"
msg_ok "Set Up Production"

# ──────────────────────────────────────────────────────────────────────────────
# Step 13: Enable scheduler
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Enabling Scheduler"
sudo -u frappe bash -c "
  cd /home/frappe/frappe-bench
  bench --site '${SITE_NAME}' enable-scheduler
"
msg_ok "Enabled Scheduler"

# ──────────────────────────────────────────────────────────────────────────────
# Step 14: Create backup & restore scripts
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Creating Backup Scripts"
mkdir -p /home/frappe/backups
chown frappe:frappe /home/frappe/backups

cat > /home/frappe/backup-erpnext.sh << 'BACKUPSCRIPT'
#!/bin/bash
set -euo pipefail
BACKUP_DIR="/home/frappe/backups"
DATE=$(date +%Y%m%d_%H%M%S)

echo "[$(date)] Starting ERPNext backup..."
cd /home/frappe/frappe-bench
bench --site erpnext.local backup --with-files

LATEST_DB=$(ls -t sites/erpnext.local/private/backups/*-database.sql.gz 2>/dev/null | head -1)
LATEST_FILES=$(ls -t sites/erpnext.local/private/backups/*-files.tar 2>/dev/null | head -1)
LATEST_PRIVATE=$(ls -t sites/erpnext.local/private/backups/*-private-files.tar 2>/dev/null | head -1)

if [ -n "$LATEST_DB" ]; then
    BACKUP_FILE="$BACKUP_DIR/erpnext_full_backup_$DATE.tar.gz"
    TAR_ARGS=("$LATEST_DB" "sites/erpnext.local/site_config.json")
    [[ -n "${LATEST_FILES:-}" ]] && TAR_ARGS+=("$LATEST_FILES")
    [[ -n "${LATEST_PRIVATE:-}" ]] && TAR_ARGS+=("$LATEST_PRIVATE")
    tar -czf "$BACKUP_FILE" "${TAR_ARGS[@]}"
    echo "[$(date)] Backup completed: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
else
    echo "[$(date)] ERROR: No backup files found!"
    exit 1
fi

find "$BACKUP_DIR" -name "erpnext_full_backup_*.tar.gz" -mtime +7 -delete
echo "[$(date)] Old backups cleaned up"
BACKUPSCRIPT
chmod +x /home/frappe/backup-erpnext.sh
chown frappe:frappe /home/frappe/backup-erpnext.sh

cat > /home/frappe/restore-erpnext.sh << 'RESTORESCRIPT'
#!/bin/bash
set -euo pipefail
if [ -z "${1:-}" ]; then
    echo "Usage: $0 <database-backup.sql.gz> [files-backup.tar] [private-files-backup.tar]"
    echo ""; echo "Available backups:"
    ls -la /home/frappe/backups/ 2>/dev/null || echo "  No backups found"
    exit 1
fi
DB_FILE="$1"; PUBLIC_FILES="${2:-}"; PRIVATE_FILES="${3:-}"
[[ ! -f "$DB_FILE" ]] && echo "ERROR: File not found: $DB_FILE" && exit 1
echo "WARNING: This will overwrite the current database!"
read -r -p "Continue? (yes/no): " CONFIRM
[ "$CONFIRM" != "yes" ] && echo "Cancelled." && exit 0
cd /home/frappe/frappe-bench
bench --site erpnext.local backup
RESTORE_ARGS=(bench --site erpnext.local restore "$DB_FILE")
[[ -n "$PUBLIC_FILES" ]]  && RESTORE_ARGS+=(--with-public-files "$PUBLIC_FILES")
[[ -n "$PRIVATE_FILES" ]] && RESTORE_ARGS+=(--with-private-files "$PRIVATE_FILES")
"${RESTORE_ARGS[@]}"
bench --site erpnext.local migrate
bench --site erpnext.local clear-cache
echo "[$(date)] Restore completed!"
RESTORESCRIPT
chmod +x /home/frappe/restore-erpnext.sh
chown frappe:frappe /home/frappe/restore-erpnext.sh
msg_ok "Created Backup Scripts"

# ──────────────────────────────────────────────────────────────────────────────
# Step 15: Schedule daily backups (idempotent)
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Scheduling Daily Backups"
CRON_JOB="0 2 * * * /home/frappe/backup-erpnext.sh >> /home/frappe/backups/backup.log 2>&1"
EXISTING_CRON=$(crontab -u frappe -l 2>/dev/null || true)
if ! echo "$EXISTING_CRON" | grep -qF "backup-erpnext.sh"; then
  (echo "$EXISTING_CRON"; echo "$CRON_JOB") | crontab -u frappe -
fi
msg_ok "Scheduled Daily Backups (2 AM)"

# ──────────────────────────────────────────────────────────────────────────────
# Step 16: Save credentials
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Saving Credentials"
cat > /root/.erpnext-credentials << CREDS
# ERPNext Credentials - KEEP THIS FILE SAFE
# Generated on: $(date)
# ──────────────────────────────────────────
Site:               ${SITE_NAME}
Admin User:         Administrator
Admin Password:     ${ADMIN_PASS}
MariaDB Root Pass:  ${DB_ROOT_PASS}
# ──────────────────────────────────────────
CREDS
chmod 600 /root/.erpnext-credentials
msg_ok "Saved Credentials to /root/.erpnext-credentials"

# ──────────────────────────────────────────────────────────────────────────────
# Step 17: Restart services
# ──────────────────────────────────────────────────────────────────────────────
msg_info "Restarting Services"
systemctl restart nginx
systemctl restart supervisor
sudo -u frappe bash -c "cd /home/frappe/frappe-bench && bench restart" 2>/dev/null || true
msg_ok "Restarted Services"

motd_ssh
customize

msg_info "Cleaning Up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
