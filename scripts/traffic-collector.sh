#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - 流量采集守护进程入口
# systemd: ExecStart=/bin/bash /opt/sb-manager/scripts/traffic-collector.sh daemon
#===============================================================================
set -euo pipefail

SB_MANAGER_ROOT="/opt/sb-manager"
SB_MODULES_DIR="${SB_MANAGER_ROOT}/scripts/modules"
SB_DATA="${SB_MANAGER_ROOT}/data"

TRAFFIC_FILE="${SB_DATA}/traffic.json"
USERS_FILE="${SB_DATA}/users.json"
mkdir -p "${SB_DATA}"

# 直接 source 模块文件（不走 manager.sh 的 _load_module）
source "${SB_MODULES_DIR}/utils.sh"
source "${SB_MODULES_DIR}/traffic-collector.sh"

# --- 命令分发 ---
case "${1:-daemon}" in
    daemon)
        run_daemon
        ;;
    check)
        check_traffic_limits
        ;;
    show)
        show_traffic
        ;;
    reset)
        reset_traffic "${2:-}"
        ;;
    *)
        echo "用法: traffic-collector.sh {daemon|check|show|reset [user]}"
        exit 1
        ;;
esac
