#!/bin/bash
set -e

# Set correct permissions
msg_info "Setting permissions..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench build
"

# Create Nginx configuration
msg_info "Creating Nginx configuration..."
cat > /etc/nginx/sites-available/erpnext << 'EOF'
upstream frappe-bench {
    server 127.0.0.1:8000;
}

server {
    listen 80;
    server_name _;
    client_max_body_size 0;
    root /home/frappe/frappe-bench;

    location / {
        proxy_pass http://frappe-bench;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
    }

    location ~* ^/files/ {
        try_files $uri =404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/erpnext /etc/nginx/sites-enabled/erpnext
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx
systemctl enable nginx

# Configure Supervisor for background workers
msg_info "Configuring Supervisor..."
cat > /etc/supervisor/conf.d/frappe-bench.conf << 'EOF'
[program:frappe-bench-web]
command=/home/frappe/frappe-bench/env/bin/gunicorn --workers 2 --worker-class sync --timeout 120 --bind 127.0.0.1:8000 frappe.app:application
directory=/home/frappe/frappe-bench
user=frappe
autostart=true
autorestart=true
stderr_logfile=/var/log/frappe-bench-web.err.log
stdout_logfile=/var/log/frappe-bench-web.out.log

[program:frappe-bench-worker-default]
command=/home/frappe/frappe-bench/env/bin/python -m frappe.celery_app worker -l info -Q default
directory=/home/frappe/frappe-bench
user=frappe
autostart=true
autorestart=true
stderr_logfile=/var/log/frappe-bench-worker-default.err.log
stdout_logfile=/var/log/frappe-bench-worker-default.out.log

[program:frappe-bench-worker-short]
command=/home/frappe/frappe-bench/env/bin/python -m frappe.celery_app worker -l info -Q short,default
directory=/home/frappe/frappe-bench
user=frappe
autostart=true
autorestart=true
stderr_logfile=/var/log/frappe-bench-worker-short.err.log
stdout_logfile=/var/log/frappe-bench-worker-short.out.log

[program:frappe-bench-worker-long]
command=/home/frappe/frappe-bench/env/bin/python -m frappe.celery_app worker -l info -Q long,default
directory=/home/frappe/frappe-bench
user=frappe
autostart=true
autorestart=true
stderr_logfile=/var/log/frappe-bench-worker-long.err.log
stdout_logfile=/var/log/frappe-bench-worker-long.out.log

[program:frappe-bench-schedule]
command=/home/frappe/frappe-bench/env/bin/python -m frappe.celery_app beat -l info
directory=/home/frappe/frappe-bench
user=frappe
autostart=true
autorestart=true
stderr_logfile=/var/log/frappe-bench-schedule.err.log
stdout_logfile=/var/log/frappe-bench-schedule.out.log
EOF

supervisorctl reread
supervisorctl update

# Create backup script
msg_info "Creating backup script..."
mkdir -p /home/frappe/backups
cat > /home/frappe/backup-erpnext.sh << 'EOF'
#!/bin/bash
BACKUP_DIR="/home/frappe/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/erpnext_backup_$DATE.tar.gz"

echo "Creating backup..."
cd /home/frappe/frappe-bench
bench backup

echo "Compressing backup..."
tar -czf "$BACKUP_FILE" sites/

echo "Backup completed: $BACKUP_FILE"
echo "Size: $(du -h $BACKUP_FILE | cut -f1)"

# Keep only last 7 backups
find $BACKUP_DIR -name "erpnext_backup_*.tar.gz" -mtime +7 -delete
EOF

chmod +x /home/frappe/backup-erpnext.sh
chown frappe:frappe /home/frappe/backup-erpnext.sh
chown frappe:frappe /home/frappe/backups

# Schedule daily backup
msg_info "Scheduling daily backup..."
echo "0 2 * * * /home/frappe/backup-erpnext.sh" | sudo tee -a /var/spool/cron/crontabs/frappe > /dev/null

# Create restore script
cat > /home/frappe/restore-erpnext.sh << 'EOF'
#!/bin/bash
if [ -z "$1" ]; then
    echo "Usage: $0 /path/to/backup.tar.gz"
    exit 1
fi

BACKUP_FILE="$1"
echo "Restoring from $BACKUP_FILE..."

cd /home/frappe/frappe-bench
sudo -u frappe bash -c "bench backup"

echo "Extracting backup..."
tar -xzf "$BACKUP_FILE" -C sites/

echo "Running migrate..."
sudo -u frappe bash -c "bench --site erpnext.local migrate"

echo "Restore completed!"
EOF

chmod +x /home/frappe/restore-erpnext.sh
chown frappe:frappe /home/frappe/restore-erpnext.sh

# Final setup
msg_info "Starting services..."
supervisorctl start all

# Display setup information
clear
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "${GREEN}✓ ERPNext Installation Completed Successfully!${NC}"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "${GREEN}Access Information:${NC}"
echo "  URL:           http://$(hostname -I | awk '{print $1}')"
echo "  Site:          erpnext.local"
echo "  Admin User:    Administrator"
echo "  Admin Password: admin@123"
echo ""
echo "${GREEN}Important Paths:${NC}"
echo "  Bench:         /home/frappe/frappe-bench"
echo "  Sites:         /home/frappe/frappe-bench/sites"
echo "  Backups:       /home/frappe/backups"
echo ""
echo "${GREEN}Useful Commands:${NC}"
echo "  Start Bench:    sudo -u frappe bash -c 'cd /home/frappe/frappe-bench && bench start'"
echo "  Create Backup:  /home/frappe/backup-erpnext.sh"
echo "  Restore:        /home/frappe/restore-erpnext.sh /path/to/backup.tar.gz"
echo "  Bench Console:  bench console erpnext.local"
echo "  Migrate:        bench --site erpnext.local migrate"
echo ""
echo "${GREEN}Services:${NC}"
echo "  Nginx:         Active (reverse proxy)"
echo "  Redis:         Active (cache)"
echo "  MariaDB:       Active (database)"
echo "  Supervisor:    Active (workers)"
echo ""
echo "${YELLOW}⚠ Next Steps:${NC}"
echo "  1. Change the admin password immediately"
echo "  2. Configure your domain in Nginx"
echo "  3. Set up SSL certificate (Let's Encrypt recommended)"
echo "  4. Test backup/restore process"
echo ""
echo "${YELLOW}⚠ IMPORTANT - Portable Backups:${NC}"
echo "  • Run backup script: /home/frappe/backup-erpnext.sh"
echo "  • Copy /home/frappe/backups/ to external storage"
echo "  • Keep database dumps for disaster recovery"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""PNext LXC Installation Script for Proxmox
# Based on community-scripts.org standards
# Installs ERPNext with Frappe Bench in a single LXC container

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions
msg_info() {
    local msg="$1"
    echo -e "${GREEN}[INFO]${NC} $msg"
}

msg_warn() {
    local msg="$1"
    echo -e "${YELLOW}[WARN]${NC} $msg"
}

msg_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg"
}

# Start installation
msg_info "Starting ERPNext LXC Installation"

# Update system
msg_info "Updating system packages..."
apt-get update
apt-get upgrade -y

# Install dependencies
msg_info "Installing dependencies..."
apt-get install -y \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    git \
    curl \
    wget \
    build-essential \
    libssl-dev \
    libffi-dev \
    libxslt1-dev \
    libxml2-dev \
    libz-dev \
    libjpeg-dev \
    zlib1g-dev \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    supervisor \
    redis-server \
    mariadb-server \
    mariadb-client \
    nodejs \
    npm \
    wkhtmltopdf \
    nano \
    htop

# Configure MariaDB
msg_info "Configuring MariaDB..."
systemctl start mariadb
systemctl enable mariadb

mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'root';"
mysql -e "FLUSH PRIVILEGES;"

# Create ERPNext database user
msg_info "Creating ERPNext database user..."
mysql -uroot -proot -e "CREATE USER 'erpnext'@'localhost' IDENTIFIED BY 'erpnext123';"
mysql -uroot -proot -e "GRANT ALL PRIVILEGES ON \`erpnext%\`.* TO 'erpnext'@'localhost';"
mysql -uroot -proot -e "FLUSH PRIVILEGES;"

# Configure Redis
msg_info "Configuring Redis..."
systemctl start redis-server
systemctl enable redis-server

# Create frappe user
msg_info "Creating frappe user..."
useradd -m -s /bin/bash frappe || msg_warn "frappe user already exists"
usermod -aG sudo frappe

# Install Frappe Bench
msg_info "Installing Frappe Bench..."
sudo -u frappe bash -c "
    cd /home/frappe
    python3 -m venv frappe-bench
    source frappe-bench/bin/activate
    pip install --upgrade pip setuptools wheel
    pip install frappe-bench
"

# Initialize Frappe Bench
msg_info "Initializing Frappe Bench..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench init --frappe-branch version-14 .
"

# Create new ERPNext site
msg_info "Creating ERPNext site..."
SITE_NAME="erpnext.local"
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench new-site $SITE_NAME --admin-password=admin@123 --db-type=mariadb --db-host=localhost --db-user=erpnext --db-password=erpnext123
"

# Install ERPNext app
msg_info "Installing ERPNext app..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench get-app https://github.com/frappe/erpnext --branch version-14
    bench --site $SITE_NAME install-app erpnext
"

# Configure Nginx
msg_info "Configuring Nginx..."
apt-get install -y nginx

sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench setup nginx
"

systemctl enable nginx
systemctl restart nginx

# Configure Supervisor
msg_info "Configuring Supervisor..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench setup supervisor
"

cp /home/frappe/frappe-bench/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf
systemctl enable supervisor
systemctl restart supervisor

# Setup cron
msg_info "Setting up cron jobs..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench setup cronjob
"

# Enable production mode
msg_info "Enabling production mode..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench set-config developer_mode 0
    bench set-config allow_local_login 1
"

# Restart services
msg_info "Restarting services..."
systemctl restart supervisor
systemctl restart nginx
systemctl restart redis-server
systemctl restart mariadb

# Final setup
msg_info "Running bench migrate..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench migrate
"

msg_info "Running bench build..."
sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench build
"

# Display installation summary
echo ""
msg_info "═══════════════════════════════════════════════════════"
msg_info "ERPNext Installation Complete!"
msg_info "═══════════════════════════════════════════════════════"
echo ""
echo -e "${GREEN}Access ERPNext:${NC}"
echo "  URL: http://$(hostname -I | awk '{print $1}')"
echo "  Site: $SITE_NAME"
echo ""
echo -e "${GREEN}Credentials:${NC}"
echo "  Administrator User: Administrator"
echo "  Administrator Password: admin@123"
echo ""
echo -e "${GREEN}Database Credentials:${NC}"
echo "  User: erpnext"
echo "  Password: erpnext123"
echo ""
echo -e "${GREEN}Bench Location:${NC}"
echo "  /home/frappe/frappe-bench"
echo ""
echo -e "${YELLOW}Important Next Steps:${NC}"
echo "  1. Change administrator password immediately"
echo "  2. Configure email settings (Setup > Email Account)"
echo "  3. Install required apps and customizations"
echo "  4. Configure backup settings"
echo "  5. Set up SSL certificate (Let's Encrypt recommended)"
echo ""
echo -e "${YELLOW}Useful Commands:${NC}"
echo "  sudo -u frappe bash -c 'cd /home/frappe/frappe-bench && bench'"
echo "  sudo -u frappe bash -c 'cd /home/frappe/frappe-bench && bench console'"
echo "  sudo -u frappe bash -c 'cd /home/frappe/frappe-bench && bench backup'"
echo ""
msg_info "═══════════════════════════════════════════════════════"
