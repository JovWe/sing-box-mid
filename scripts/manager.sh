#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - 主管理脚本 (CLI)
# 用法: sb-manager <command> [args...]
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# 加载子模块
source "${SCRIPT_DIR}/user-manager.sh"
source "${SCRIPT_DIR}/outbound-manager.sh"
source "${SCRIPT_DIR}/sub-generator.sh"

# --- 导入配置生成器 ---
import_config_gen() {
    source "${SCRIPT_DIR}/config-generator.sh"
}

# --- 导入流量采集器 ---
import_traffic() {
    source "${SCRIPT_DIR}/traffic-collector.sh"
}

# --- 帮助 ---
show_help() {
    cat << 'HELP'
╔══════════════════════════════════════════════════════════╗
║           Sing-box Manager - 中转站管理系统              ║
╚══════════════════════════════════════════════════════════╝

用法: sb-manager <command> [options]

┌─────────────────────────────────────────────────────────┐
│ 用户管理                                                 │
├─────────────────────────────────────────────────────────┤
│  add-user     [name] [protocol] [expire] [limit] [port] │
│  delete-user  [username]                                │
│  edit-user    [username]                                │
│  list-users                                             │
│  show-user    [username]                                │
│  show-config  [username]                                │
├─────────────────────────────────────────────────────────┤
│ 出站管理                                                 │
├─────────────────────────────────────────────────────────┤
│  add-outbound     [name] [type]                         │
│  delete-outbound  [outbound_id]                         │
│  edit-outbound    [outbound_id]                         │
│  list-outbounds                                         │
│  show-outbound    [outbound_id]                         │
│  strategy-group                                         │
├─────────────────────────────────────────────────────────┤
│ 流量统计                                                 │
├─────────────────────────────────────────────────────────┤
│  show-traffic     [username]                            │
│  reset-traffic    [username]                            │
├─────────────────────────────────────────────────────────┤
│ 订阅系统                                                 │
├─────────────────────────────────────────────────────────┤
│  show-sub         [username]                            │
│  gen-sub          [username] [format]                   │
│    格式: sing-box, clash-meta, v2rayn, link, all       │
├─────────────────────────────────────────────────────────┤
│ 系统管理                                                 │
├─────────────────────────────────────────────────────────┤
│  status          查看系统状态                            │
│  reload          重新生成配置并重载                      │
│  restart         重启 Sing-box                           │
│  logs            查看日志 (最近 50 行)                   │
│  update          更新 Sing-box 内核                      │
│  version         显示版本信息                            │
│  help            显示此帮助                              │
└─────────────────────────────────────────────────────────┘

HELP
}

# --- 查看状态 ---
show_status() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           Sing-box Manager 系统状态                 ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Sing-box 状态
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        echo -e "Sing-box:    ${GREEN}运行中${NC}"
    else
        echo -e "Sing-box:    ${RED}停止${NC}"
    fi

    # 版本
    if [[ -x "${SB_BIN}/sing-box" ]]; then
        local ver
        ver=$("${SB_BIN}/sing-box" version 2>/dev/null | head -1 || echo "unknown")
        echo -e "版本:        $ver"
    fi

    # 用户统计
    local total_users
    total_users=$(jq '.users | length' "$USERS_FILE" 2>/dev/null || echo 0)
    local active_users
    active_users=$(jq '[.users[] | select(.status == "active")] | length' "$USERS_FILE" 2>/dev/null || echo 0)
    local online_users
    online_users=$(jq '[.users[] | select(.online == true)] | length' "$USERS_FILE" 2>/dev/null || echo 0)
    echo -e "用户总数:    $total_users (${GREEN}${active_users} 启用${NC}, ${online_users} 在线)"

    # 出站统计
    local outbound_count
    outbound_count=$(jq '.outbounds | length' "$OUTBOUNDS_FILE" 2>/dev/null || echo 0)
    echo -e "出站数量:    $outbound_count"

    # 流量统计
    local total_down
    total_down=$(json_get "$TRAFFIC_FILE" ".total.down" "0")
    local total_up
    total_up=$(json_get "$TRAFFIC_FILE" ".total.up" "0")
    echo -e "总流量:      $(format_bytes $total_down) ↓  $(format_bytes $total_up) ↑"

    # 系统资源
    if command -v free &>/dev/null; then
        local mem
        mem=$(free -m | awk 'NR==2{printf "%.0f", $3*100/$2}')
        echo -e "内存使用:    ${mem}%"
    fi
    if command -v uptime &>/dev/null; then
        echo -e "系统运行:    $(uptime -p)"
    fi

    # 防火墙
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        echo -e "防火墙:      ${GREEN}UFW 已启用${NC}"
    else
        echo -e "防火墙:      ${YELLOW}未启用${NC}"
    fi

    echo ""
}

# --- 查看日志 ---
show_logs() {
    local log_file="${SB_LOGS}/sing-box.log"
    if [[ -f "$log_file" ]]; then
        tail -50 "$log_file"
    else
        echo "暂无日志"
    fi
}

# --- 更新 Sing-box ---
update_singbox() {
    log_info "更新 Sing-box 到最新版本..."
    install_singbox "latest"
    sb_reload
    log_info "Sing-box 更新完成"
}

# --- 版本信息 ---
show_version() {
    echo "Sing-box Manager v1.0.0"
    echo "Build: 2024-01"
    if [[ -x "${SB_BIN}/sing-box" ]]; then
        "${SB_BIN}/sing-box" version
    fi
}

# --- 快速安装 (供 install.sh 调用) ---
quick_setup() {
    local protocol="${1:-}"

    init_dirs
    install_deps
    install_singbox "latest"

    # 设置默认管理员密码
    local admin_pass
    admin_pass=$(gen_password 16)
    local pass_hash
    pass_hash=$(echo -n "$admin_pass" | openssl passwd -6 -stdin 2>/dev/null || echo -n "$admin_pass" | sha256sum | cut -d' ' -f1)
    json_set "$SETTINGS_FILE" '.web_password_hash' "\"$pass_hash\""
    json_set "$SETTINGS_FILE" '.jwt_secret' "\"$(gen_token)\""
    json_set "$SETTINGS_FILE" '.installed_at' "$(date +%s)"

    # 创建 systemd 服务
    create_systemd_service

    # 系统优化
    optimize_system

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Sing-box Manager 安装完成!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "Web 管理:   http://$(get_public_ip):2053"
    echo -e "用户名:     admin"
    echo -e "密码:       ${admin_pass}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "管理命令: sb-manager <command>"
    echo "查看帮助: sb-manager help"
    echo ""
    echo "下一步:"
    echo "  1. sb-manager add-user    添加用户"
    echo "  2. sb-manager add-outbound 添加出站"
    echo "  3. 在浏览器中打开 Web 管理面板"
    echo ""
}

# --- 创建 systemd 服务 ---
create_systemd_service() {
    log_info "创建 systemd 服务..."
    cat > /etc/systemd/system/sing-box.service << 'SYSTEMD'
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=/opt/sb-manager/bin/sing-box run -c /opt/sb-manager/core/config/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1000000
LimitNPROC=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SYSTEMD

    cat > /etc/systemd/system/sb-traffic.service << SYSTEMD
[Unit]
Description=Sing-box Traffic Collector
After=sing-box.service
Requires=sing-box.service

[Service]
Type=simple
User=root
ExecStart=/bin/bash /opt/sb-manager/scripts/traffic-collector.sh daemon
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
SYSTEMD

    systemctl daemon-reload
    systemctl enable sing-box 2>/dev/null || true
    systemctl enable sb-traffic 2>/dev/null || true
    log_info "Systemd 服务创建完成"
}

# --- 创建管理命令别名 ---
install_cli() {
    log_info "安装 sb-manager 命令行工具..."
    local cli_path="/usr/local/bin/sb-manager"
    cat > "$cli_path" << 'CLI'
#!/usr/bin/env bash
exec bash /opt/sb-manager/scripts/manager.sh "$@"
CLI
    chmod +x "$cli_path"
    log_info "命令行工具已安装: sb-manager"
}

# ============================================================================
# 主入口
# ============================================================================
main() {
    # 非 root 也允许查看帮助和状态
    local cmd="${1:-help}"
    shift || true

    # 需要 root 的命令
    case "$cmd" in
        add-user|delete-user|edit-user|show-config|show-user|list-users)
            check_root
            ;;
        add-outbound|delete-outbound|edit-outbound|list-outbounds|show-outbound|strategy-group)
            check_root
            ;;
        reload|restart|update)
            check_root
            ;;
    esac

    case "$cmd" in
        # --- 用户管理 ---
        add-user)
            add_user "$@"
            ;;
        delete-user)
            delete_user "$@"
            ;;
        edit-user)
            edit_user "$@"
            ;;
        list-users)
            list_users
            ;;
        show-user)
            show_user_detail "${1:-}"
            ;;
        show-config)
            show_user_config "${1:-}" "${2:-all}"
            ;;

        # --- 出站管理 ---
        add-outbound)
            add_outbound "$@"
            ;;
        delete-outbound)
            delete_outbound "$@"
            ;;
        edit-outbound)
            edit_outbound "$@"
            ;;
        list-outbounds)
            list_outbounds
            ;;
        show-outbound)
            show_outbound "${1:-}"
            ;;
        strategy-group)
            manage_strategy_group "$@"
            ;;

        # --- 流量统计 ---
        show-traffic)
            import_traffic
            show_traffic "${1:-}"
            ;;
        reset-traffic)
            import_traffic
            reset_traffic "${1:-}"
            ;;

        # --- 订阅系统 ---
        show-sub)
            show_sub "${1:-}"
            ;;
        gen-sub)
            import_traffic
            gen_user_sub "${1:-}" "${2:-all}"
            ;;

        # --- 系统管理 ---
        status)
            show_status
            ;;
        reload)
            import_config_gen
            generate_config && sb_reload
            ;;
        restart)
            systemctl restart sing-box
            log_info "Sing-box 已重启"
            ;;
        logs)
            show_logs
            ;;
        update)
            update_singbox
            ;;
        version)
            show_version
            ;;
        setup)
            quick_setup "$@"
            ;;

        # --- 帮助 ---
        help|--help|-h)
            show_help
            ;;
        *)
            echo "未知命令: $cmd"
            echo "使用 'sb-manager help' 查看帮助"
            exit 1
            ;;
    esac
}

main "$@"