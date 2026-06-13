#===============================================================================
# Sing-box Manager - 流量统计 / 采集模块（纯函数 + daemon 入口）
#===============================================================================

# --- 从 sing-box stats API 采集流量 ---
# 简单实现：用 sing-box 的 stats API 拉, 也可直接读日志文件
collect_traffic_from_api() {
    # 优先使用 stats API (本地 127.0.0.1:1234) 端口
    local api_port=1234
    local url="http://127.0.0.1:${api_port}/stats/connections"

    # 如果没启用 stats API, 直接返回
    if ! command -v curl &>/dev/null; then
        return 0
    fi

    # 通过 curl 获取 JSON, 这里仅做简单尝试
    local resp
    resp=$(curl -s --max-time 3 "$url" 2>/dev/null || true)
    if [[ -z "$resp" || "$resp" == *"connection refused"* ]]; then
        return 0
    fi
    # 简单累加 users 下的 down/up（如果存在）
    # 输出结构因 sing-box 配置而异, 这里做兜底处理
    local down up
    down=$(echo "$resp" | jq '[.[]? | .down? // 0] | add // 0' 2>/dev/null || echo 0)
    up=$(echo "$resp" | jq '[.[]? | .up? // 0] | add // 0' 2>/dev/null || echo 0)
    if [[ -n "$down" && "$down" -gt 0 ]]; then
        json_set "$TRAFFIC_FILE" '.total.down' "$(( $(json_get "$TRAFFIC_FILE" '.total.down' '0') + down ))"
    fi
    if [[ -n "$up" && "$up" -gt 0 ]]; then
        json_set "$TRAFFIC_FILE" '.total.up' "$(( $(json_get "$TRAFFIC_FILE" '.total.up' '0') + up ))"
    fi
}

# --- 采集守护进程 (60s 轮询一次) ---
run_daemon() {
    log_info "启动流量采集守护进程, 采集间隔 60s"
    local interval=60
    while true; do
        # 基础 API 采集
        collect_traffic_from_api || true

        # 简单日志累计: 从 sing-box.log 解析关键字
        if [[ -f "${SB_LOGS}/sing-box.log" ]]; then
            # 这里仅做占位; 真实实现应按 log 中每个用户 tag 统计
            :
        fi

        sleep "$interval"
    done
}

# --- 展示流量 ---
show_traffic() {
    echo ""
    echo "========== 流量统计 =========="
    local total_down total_up
    total_down=$(json_get "$TRAFFIC_FILE" '.total.down' '0')
    total_up=$(json_get "$TRAFFIC_FILE" '.total.up' '0')
    echo "总下行: $(format_bytes "$total_down")"
    echo "总上行: $(format_bytes "$total_up")"
    echo ""

    echo "按用户:"
    jq -r '.users | keys[]' "$USERS_FILE" 2>/dev/null | while read -r username; do
        [[ -z "$username" ]] && continue
        local down up
        down=$(json_get "$TRAFFIC_FILE" ".users.\"$username\".down" '0')
        up=$(json_get "$TRAFFIC_FILE" ".users.\"$username\".up" '0')
        printf "  %-20s  ↓ %-12s ↑ %-12s\n" "$username" "$(format_bytes "$down")" "$(format_bytes "$up")"
    done
    echo ""
}

# --- 重置流量 ---
reset_traffic() {
    local username="${1:-}"
    if [[ -z "$username" ]]; then
        read -rp "输入要重置的用户名 (或留空重置全部): " username
    fi
    if [[ -z "$username" ]]; then
        echo '{"version":1,"last_reset":'"$(date +%s)"',"users":{},"total":{"down":0,"up":0}}' > "$TRAFFIC_FILE"
        log_ok "全部流量已重置"
    else
        json_set "$TRAFFIC_FILE" ".users.\"$username\"" '{"down":0,"up":0}'
        log_ok "用户 $username 流量已重置"
    fi
}

# --- 流量超限检查 ---
check_traffic_limits() {
    jq -r '.users | keys[]' "$USERS_FILE" 2>/dev/null | while read -r username; do
        [[ -z "$username" ]] && continue
        local limit used total_bytes
        limit=$(jq -r ".users.\"$username\".traffic_limit" "$USERS_FILE")
        used=$(json_get "$TRAFFIC_FILE" ".users.\"$username\".down" '0')
        # 解析 limit (100GB -> 100*1024*1024*1024)
        local num unit
        num=$(echo "$limit" | sed -E 's/([0-9]+)([A-Za-z]+)/\1/')
        unit=$(echo "$limit" | sed -E 's/([0-9]+)([A-Za-z]+)/\U\2/')
        case "$unit" in
            GB|G) total_bytes=$(( num * 1024 * 1024 * 1024 )) ;;
            MB|M) total_bytes=$(( num * 1024 * 1024 )) ;;
            KB|K) total_bytes=$(( num * 1024 )) ;;
            TB|T) total_bytes=$(( num * 1024 * 1024 * 1024 * 1024 )) ;;
            *)   total_bytes=0 ;;
        esac
        if [[ $total_bytes -gt 0 && $used -ge $total_bytes ]]; then
            log_warn "用户 $username 流量超限, 停用"
            json_set "$USERS_FILE" ".users.\"$username\".status" "\"disabled\""
        fi
    done
}
