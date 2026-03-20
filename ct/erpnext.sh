#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2024 LuMeX88
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://erpnext.com/ | Github: https://github.com/frappe/erpnext

APP="ERPNext"
var_tags="${var_tags:-erp;finance;business}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-16}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /home/frappe/frappe-bench ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  CURRENT_BRANCH=$(sudo -u frappe bash -c "cd /home/frappe/frappe-bench && cat sites/common_site_config.json 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('branch','unknown'))\"" 2>/dev/null || echo "unknown")

  msg_info "Stopping Services"
  systemctl stop supervisor
  systemctl stop nginx
  msg_ok "Stopped Services"

  msg_info "Updating ERPNext (bench update)"
  sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench update --no-backup --reset
  "
  msg_ok "Updated ERPNext"

  msg_info "Running Migrations"
  sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench --site all migrate
  "
  msg_ok "Migrations Complete"

  msg_info "Building Assets"
  sudo -u frappe bash -c "
    cd /home/frappe/frappe-bench
    bench build
  "
  msg_ok "Assets Built"

  msg_info "Starting Services"
  systemctl start supervisor
  systemctl start nginx
  sudo -u frappe bash -c "cd /home/frappe/frappe-bench && bench restart" 2>/dev/null || true
  msg_ok "Started Services"

  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}${CL}"
echo -e "${INFO}${YW} Credentials:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}User: Administrator | Pass: admin@123${CL}"
echo -e "${INFO}${YW} Credentials saved inside the container at /root/.erpnext-credentials${CL}"
