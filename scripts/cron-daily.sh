#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - 每日定时任务
# 任务: 用户过期检测 + 流量超限检测
#===============================================================================
set -euo pipefail

SB_MANAGER_ROOT="/opt/sb-manager"
SB_MODULES_DIR="${SB_MANAGER_ROOT}/scripts/modules"
SB_DATA="${SB_MANAGER_ROOT}/data"
SB_LOGS="${SB_MANAGER_ROOT}/logs"

USERS_FILE="${SB_DATA}/users.json"
TRAFFIC_FILE="${SB_DATA}/traffic.json"
mkdir -p "${SB_DATA}" "${SB_LOGS}"

source "${SB_MODULES_DIR}/utils.sh"
source "${SB_MODULES_DIR}/user-manager.sh"
source "${SB_MODULES_DIR}/traffic-collector.sh"

log_info "========== 每日定时任务开始 =========="
cron_check_users
check_traffic_limits
log_info "========== 每日定时任务完成 =========="
