#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - 每日定时任务
# 用户过期检查 + 流量封禁检查
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/user-manager.sh"

main() {
    log_info "========== 每日定时任务开始 =========="
    cron_check_users
    log_info "========== 每日定时任务完成 =========="
}

main "$@" >> "${SB_LOGS}/cron-daily.log" 2>&1