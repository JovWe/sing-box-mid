#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - 流量采集守护进程
# 使用 Sing-box Clash API 采集流量
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# 配置
CLASH_API_URL="http://127.0.0.1:9090"
COLLECT_INTERVAL="${COLLECT_INTERVAL:-60}"  # 采集间隔, 单位秒
LAST_UPDATE_FILE="${SB_DATA}/traffic_last.json"

# --- 获取流量信息 ---
get_traffic() {
    if ! curl -s -m 5 "${CLASH_API_URL}/traffic" > /tmp/sb_traffic.json 2>/dev/null; then
        log_warn "无法获取流量信息, Sing-box 可能未启动"
        return 1
    fi

    # 检查 JSON 是否有效
    if ! jq . "/tmp/sb_traffic.json" &>/dev/null; then
        log_warn "获取的流量数据无效"
        return 1
    fi

    cat "/tmp/sb_traffic.json"
    rm -f "/tmp/sb_traffic.json"
    return 0
}

# --- 获取链接信息 ---
get_connections() {
    if curl -s -m 5 "${CLASH_API_URL}/connections" > /tmp/sb_connections.json 2>/dev/null; then
        cat "/tmp/sb_connections.json"
        rm -f "/tmp/sb_connections.json"
        return 0
    fi
    return 1
}

# --- 更新用户在线状态 ---
update_online_status() {
    local conn_data="$1"
    # 更新所有用户离线
    local tmp="${USERS_FILE}.tmp"
    jq '(.users[] | .online) = false' "$USERS_FILE" > "$tmp" && mv "$tmp" "$USERS_FILE"

    # 当前活跃连接的 inbound 标记为在线
    echo "$conn_data" | jq -r '.connections[].inbound.tag // empty' 2>/dev/null | while read -r tag; do
        if [[ "$tag" =~ ^inbound- ]]; then
            local username="${tag#inbound-}"
            if jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
                local ts=$(date +%s)
                json_set "$USERS_FILE" ".users.\"$username\".online" "true"
                json_set "$USERS_FILE" ".users.\"$username\".last_seen_at" "$ts"
            fi
        fi
    done
}

# --- 累增流量 ---
# clash API 的 /traffic 返回的是累计总量, 需要计算增量
collect_traffic() {
    local current_traffic="$1"

    # 遍历每个用户 inbound (tag = inbound-username)
    # 从当前 API 返回的流量增量计算
    local now
    now=$(date +%s)
    local date_str
    date_str=$(date +%Y-%m-%d)

    local tmp="${TRAFFIC_FILE}.tmp"
    local total_down=0
    local total_up=0

    jq -r '.users | to_entries[] | .key' "$USERS_FILE" 2>/dev/null | while read -r username; do
        local tag="inbound-$username"
        # 获取当前流量
        local down
        down=$(echo "$current_traffic" | jq -r ".[\"$tag\"] // 0" 2>/dev/null || echo 0)
        local up
        up=$(echo "$current_traffic" | jq -r ".[\"$tag\"]? // 0" 2>/dev/null || echo 0)

        # 获取上次采集流量
        local last_down
        last_down=$(json_get "$LAST_UPDATE_FILE" ".users.\"$username\".down" "0")
        local last_up
        last_up=$(json_get "$LAST_UPDATE_FILE" ".users.\"$username\".up" "0")

        # 计算增量
        local inc_down=$((down - last_down))
        local inc_up=$((up - last_up))

        # 避免负数 (重启后重置)
        if [[ $inc_down -lt 0 ]]; then inc_down=0; fi
        if [[ $inc_up -lt 0 ]]; then inc_up=0; fi

        # 保存本次流量到 last 文件
        json_set "$LAST_UPDATE_FILE" ".users.\"$username\".down" "$down"
        json_set "$LAST_UPDATE_FILE" ".users.\"$username\".up" "$up"

        if [[ $inc_down -eq 0 && $inc_up -eq 0 ]]; then
            continue
        fi

        # 更新总流量到 users.json (累计)
        local old_down
        old_down=$(json_get "$USERS_FILE" ".users.\"$username\".traffic_used_down" "0")
        local old_up
        old_up=$(json_get "$USERS_FILE" ".users.\"$username\".traffic_used_up" "0")
        local new_down=$((old_down + inc_down))
        local new_up=$((old_up + inc_up))

        json_set "$USERS_FILE" ".users.\"$username\".traffic_used_down" "$new_down"
        json_set "$USERS_FILE" ".users.\"$username\".traffic_used_up" "$new_up"

        # 更新到 traffic.json
        json_set "$TRAFFIC_FILE" ".users.\"$username\".down" "$new_down"
        json_set "$TRAFFIC_FILE" ".users.\"$username\".up" "$new_up"
        json_set "$TRAFFIC_FILE" ".users.\"$username\".daily.\"${date_str}\".down" += "$inc_down"
        json_set "$TRAFFIC_FILE" ".users.\"$username\".daily.\"${date_str}\".up" += "$inc_up"

        total_down=$((total_down + inc_down))
        total_up=$((total_up + inc_up))
    done

    # 更新总量
    local old_total_down
    old_total_down=$(json_get "$TRAFFIC_FILE" ".total.down" "0")
    local old_total_up
    old_total_up=$(json_get "$TRAFFIC_FILE" ".total.up" "0")
    json_set "$TRAFFIC_FILE" ".total.down" $((old_total_down + total_down))
    json_set "$TRAFFIC_FILE" ".total.up" $((old_total_up + total_up))

    # 检查流量超限
    check_traffic_limits
}

# --- 检查流量超限 ---
check_traffic_limits() {
    local now
    now=$(date +%s)
    local changed=0

    jq -r '.users | to_entries[] | select(.value.status == "active") | .key' "$USERS_FILE" 2>/dev/null | while read -r username; do
        local limit
        limit=$(jq -r ".users.\"$username\".traffic_limit_bytes // 0" "$USERS_FILE")
        if [[ "$limit" == "0" || -z "$limit" ]]; then
            continue
        fi
        local used_down
        used_down=$(jq -r ".users.\"$username\".traffic_used_down // 0" "$USERS_FILE")
        local used_up
        used_up=$(jq -r ".users.\"$username\".traffic_used_up // 0" "$USERS_FILE")
        local total=$((used_down + used_up))
        if [[ "$total" -ge "$limit" ]]; then
            json_set "$USERS_FILE" ".users.\"$username\".status" '"disabled"'
            log_warn "流量超限, 自动禁用用户: $username (已用 $(format_bytes $total) / 限制 $(format_bytes $limit))"
            changed=1
        fi
    done

    if [[ $changed -eq 1 ]]; then
        log_info "流量超限, 重新生成配置..."
        "${SB_SCRIPTS}/config-generator.sh" && systemctl reload sing-box || {
            log_error "配置重载失败"
        }
    fi
}

# --- 显示流量 ---
show_traffic() {
    local username="${1:-}"

    echo ""
    echo -e "${CYAN}========== 流量统计 =========${NC}"
    if [[ -n "$username" ]]; then
        if ! jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
            log_error "用户不存在: $username"
            return 1
        fi
        local down
        down=$(jq -r ".users.\"$username\".traffic_used_down // 0" "$USERS_FILE")
        local up
        up=$(jq -r ".users.\"$username\".traffic_used_up // 0" "$USERS_FILE")
        local total=$((down + up))
        local limit
        limit=$(jq -r ".users.\"$username\".traffic_limit_bytes // 0" "$USERS_FILE")

        echo -e "用户: ${BOLD}${username}${NC}"
        echo -e "下载: $(format_bytes $down)"
        echo -e "上传: $(format_bytes $up)"
        echo -e "总计: $(format_bytes $total)"
        if [[ "$limit" != "0" ]]; then
            echo -e "限制: $(format_bytes $limit)"
            echo -e "剩余: $(format_bytes $((limit - total)))"
        else
            echo -e "限制: 无限制"
        fi
        echo ""
    else
        printf "${CYAN}%-16s %12s %12s %12s${NC}\n" "用户名" "下载" "上传" "总计"
        printf '%s\n' "$(printf '─%.0s' {1..52})"
        jq -r '.users | to_entries[] | select(.value.traffic_used_down > 0 or .value.traffic_used_up > 0) | 
            "\(.key)|\(.value.traffic_used_down)|\(.value.traffic_used_up)|\(.value.traffic_used_down + .value.traffic_used_up)"' \
            "$USERS_FILE" 2>/dev/null | while IFS='|' read -r name d u t; do
            printf "%-16s %12s %12s %12s\n" \
                "$name" "$(format_bytes $d)" "$(format_bytes $u)" "$(format_bytes $t)"
        done
        local total_down
        total_down=$(json_get "$TRAFFIC_FILE" ".total.down" "0")
        local total_up
        total_up=$(json_get "$TRAFFIC_FILE" ".total.up" "0")
        local total_total=$((total_down + total_up))
        printf '%s\n' "$(printf '─%.0s' {1..52})"
        echo -e "总计: $(format_bytes $total_down) ↓  $(format_bytes $total_up) ↑  总计 $(format_bytes $total_total)"
        echo ""
    fi
}

# --- 重置流量 ---
reset_traffic() {
    local username="${1:-}"

    if [[ -n "$username" ]]; then
        json_set "$USERS_FILE" ".users.\"$username\".traffic_used_down" "0"
        json_set "$USERS_FILE" ".users.\"$username\".traffic_used_up" "0"
        json_set "$TRAFFIC_FILE" ".users.\"$username\".down" "0"
        json_set "$TRAFFIC_FILE" ".users.\"$username\".up" "0"
        # 如果之前被禁用了, 重新启用
        local status
        status=$(jq -r ".users.\"$username\".status" "$USERS_FILE")
        if [[ "$status" == "disabled" ]]; then
            read -rp "流量已重置, 用户当前是禁用状态, 是否启用? [y/N]: " yn
            if [[ "${yn,,}" == "y" ]]; then
                json_set "$USERS_FILE" ".users.\"$username\".status" '"active"'
                sb_reload
            fi
        fi
        log_info "流量已重置: $username"
    else
        log_warn "这将重置所有流量统计, 确认? "
        confirm || return 0
        jq -r '.users | keys[]' "$USERS_FILE" | while read -r u; do
            json_set "$USERS_FILE" ".users.\"$u\".traffic_used_down" "0"
            json_set "$USERS_FILE" ".users.\"$u\".traffic_used_up" "0"
            json_set "$TRAFFIC_FILE" ".users.\"$u\".down" "0"
            json_set "$TRAFFIC_FILE" ".users.\"$u\".up" "0"
        done
        json_set "$TRAFFIC_FILE" ".total.down" "0"
        json_set "$TRAFFIC_FILE" ".total.up" "0"
        json_set "$TRAFFIC_FILE" ".last_reset" "$(date +%s)"
        log_info "所有流量已重置"
    fi
}

# --- 守护进程主循环 ---
run_daemon() {
    log_info "启动流量采集守护进程, 采集间隔 ${COLLECT_INTERVAL}s"
    init_dirs
    [[ ! -f "$LAST_UPDATE_FILE" ]] && echo '{"users":{}}' > "$LAST_UPDATE_FILE"

    while true; do
        if ! systemctl is-active --quiet sing-box; then
            sleep 10
            continue
        fi

        # 获取流量
        local traffic_json
        traffic_json=$(get_traffic) || {
            sleep 10
            continue
        }

        # 获取连接 (在线状态)
        local conn_json
        conn_json=$(get_connections || echo "{}")
        update_online_status "$conn_json"

        # 采集增量
        collect_traffic "$traffic_json"

        sleep "$COLLECT_INTERVAL"
    done
}

# --- 入口 (仅在直接执行时运行) ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
if [[ "${1:-daemon}" == "daemon" ]]; then
    run_daemon
elif [[ "${1:-}" == "show" ]]; then
    show_traffic "${2:-}"
elif [[ "${1:-}" == "reset" ]]; then
    reset_traffic "${2:-}"
elif [[ "${1:-}" == "check" ]]; then
    check_traffic_limits
fi
fi