#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - 用户管理函数库
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# 加载协议生成器
load_protocol_gen() {
    local protocol="${1:-}"
    local gen_file="${SCRIPT_DIR}/protocol-gen/${protocol}.sh"
    if [[ -f "$gen_file" ]]; then
        source "$gen_file"
    else
        log_error "不支持的协议: $protocol (缺少生成器)"
        return 1
    fi
}

# --- 创建用户数据结构 ---
create_user_data() {
    local username="${1:-}"
    local protocol="${2:-}"
    local expire_days="${3:-30}"
    local traffic_limit="${4:-100GB}"

    local now
    now=$(date +%s)
    local expire_at
    expire_at=$(( now + expire_days * 86400 ))
    local limit_bytes
    limit_bytes=$(parse_size "$traffic_limit")

    cat << JSON
{
  "username": "${username}",
  "protocol": "${protocol}",
  "status": "active",
  "created_at": ${now},
  "expire_at": ${expire_at},
  "traffic_limit_bytes": ${limit_bytes},
  "traffic_used_down": 0,
  "traffic_used_up": 0,
  "online": false,
  "last_seen_at": 0,
  "credentials": {},
  "reality": {},
  "hysteria2": {},
  "tuic": {},
  "anytls": {},
  "shadowtls": {},
  "inbound": {
    "tag": "inbound-${username}",
    "listen": "0.0.0.0",
    "port": 0,
    "network": "tcp"
  },
  "subscription": {
    "token": "$(gen_token)",
    "url": ""
  }
}
JSON
}

# --- 添加用户 ---
add_user() {
    local username="${1:-}"
    local protocol="${2:-}"
    local expire_days="${3:-30}"
    local traffic_limit="${4:-100GB}"
    local port="${5:-}"

    # 验证参数
    if [[ -z "$username" ]]; then
        read -rp "用户名: " username
    fi
    [[ -z "$username" ]] && { log_error "用户名不能为空"; return 1; }

    # 检查用户是否已存在
    if [[ -f "$USERS_FILE" ]]; then
        if jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
            log_error "用户已存在: $username"
            return 1
        fi
    fi

    if [[ -z "$protocol" ]]; then
        echo "可选协议:"
        echo "  1) VLESS + Reality"
        echo "  2) Hysteria2"
        echo "  3) TUIC v5"
        echo "  4) AnyTLS"
        echo "  5) ShadowTLS v3"
        read -rp "选择协议 [1-5]: " protocol_choice
        case "$protocol_choice" in
            1) protocol="vless-reality" ;;
            2) protocol="hysteria2" ;;
            3) protocol="tuic" ;;
            4) protocol="anytls" ;;
            5) protocol="shadowtls" ;;
            *) log_error "无效选择"; return 1 ;;
        esac
    fi

    # 验证协议
    case "$protocol" in
        vless-reality|hysteria2|tuic|anytls|shadowtls) ;;
        *) log_error "不支持的协议: $protocol"; return 1 ;;
    esac

    if [[ -z "$expire_days" || "$expire_days" == "0" ]]; then
        read -rp "到期天数 (默认30): " expire_days
        expire_days="${expire_days:-30}"
    fi

    if [[ -z "$traffic_limit" || "$traffic_limit" == "0" ]]; then
        echo "流量限制:"
        echo "  1) 100GB"
        echo "  2) 300GB"
        echo "  3) 500GB"
        echo "  4) 1TB"
        echo "  5) 无限制"
        read -rp "选择 [1-5]: " limit_choice
        case "$limit_choice" in
            1) traffic_limit="100GB" ;;
            2) traffic_limit="300GB" ;;
            3) traffic_limit="500GB" ;;
            4) traffic_limit="1TB" ;;
            5) traffic_limit="0" ;;
            *) traffic_limit="100GB" ;;
        esac
    fi

    # 初始化目录
    init_dirs

    # 创建用户数据
    local user_data
    user_data=$(create_user_data "$username" "$protocol" "$expire_days" "$traffic_limit")

    # 写入数据库
    local tmp="${USERS_FILE}.tmp"
    jq --arg name "$username" --argjson data "$user_data" \
        '.users[$name] = $data' "$USERS_FILE" > "$tmp" && mv "$tmp" "$USERS_FILE"

    # 加载协议生成器
    load_protocol_gen "$protocol" || return 1

    # 生成端口
    if [[ -z "$port" ]]; then
        case "$protocol" in
            vless-reality) port=$(gen_random_port 443 443) ;;  # Reality 默认443
            *) port=$(gen_random_port 10000 60000) ;;
        esac
    fi

    # 生成协议配置
    case "$protocol" in
        vless-reality) gen_vless_reality_config "$username" "$port" ;;
        hysteria2)     gen_hysteria2_config "$username" "$port" ;;
        tuic)          gen_tuic_config "$username" "$port" ;;
        anytls)        gen_anytls_config "$username" "$port" ;;
        shadowtls)     gen_shadowtls_config "$username" "$port" ;;
    esac

    # 生成订阅 URL
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.subscription_domain' "$(json_get "$SETTINGS_FILE" '.domain')")
    local token
    token=$(jq -r ".users.\"$username\".subscription.token" "$USERS_FILE")
    local sub_url
    if [[ -n "$domain" ]]; then
        sub_url="${domain}/sub/${username}?token=${token}"
    else
        sub_url="https://$(get_public_ip):2053/sub/${username}?token=${token}"
    fi
    json_set "$USERS_FILE" ".users.\"$username\".subscription.url" "\"$sub_url\""

    # 开放防火墙端口
    ufw_allow_port "$port"
    case "$protocol" in
        hysteria2|tuic) ufw_allow_port "$port" "udp" ;;
    esac

    # 重载配置
    sb_reload || log_warn "配置重载失败, 请手动检查"

    # 输出摘要
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  用户创建成功!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "用户名:     ${BOLD}$username${NC}"
    echo -e "协议:       ${BOLD}$(protocol_label "$protocol")${NC}"
    echo -e "端口:       ${BOLD}$port${NC}"
    echo -e "到期时间:   ${BOLD}$(format_timestamp $(( $(date +%s) + expire_days * 86400 )))${NC}"
    echo -e "流量限制:   ${BOLD}$traffic_limit${NC}"
    echo -e "订阅链接:   ${BOLD}${sub_url}${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""

    # 显示客户端配置
    show_user_config "$username"
}

# --- 删除用户 ---
delete_user() {
    local username="${1:-}"

    if [[ -z "$username" ]]; then
        read -rp "请输入要删除的用户名: " username
    fi
    [[ -z "$username" ]] && { log_error "用户名不能为空"; return 1; }

    if ! jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
        log_error "用户不存在: $username"
        return 1
    fi

    confirm "确认删除用户 $username? 此操作不可恢复!" || return 0

    # 获取端口以关闭防火墙
    local port
    port=$(jq -r ".users.\"$username\".inbound.port" "$USERS_FILE")
    local protocol
    protocol=$(jq -r ".users.\"$username\".protocol" "$USERS_FILE")

    # 关闭防火墙
    ufw_deny_port "$port"
    case "$protocol" in
        hysteria2|tuic) ufw_deny_port "$port" "udp" ;;
    esac

    # 删除入站配置
    rm -f "${SB_CONFIG}/inbound/${username}.json"

    # 从数据库删除
    json_delete "$USERS_FILE" ".users.\"$username\""

    # 删除流量数据
    json_delete "$TRAFFIC_FILE" ".users.\"$username\""

    log_info "用户已删除: $username"

    # 重载
    sb_reload || log_warn "配置重载失败"
}

# --- 修改用户 ---
edit_user() {
    local username="${1:-}"

    if [[ -z "$username" ]]; then
        read -rp "请输入要修改的用户名: " username
    fi
    [[ -z "$username" ]] && { log_error "用户名不能为空"; return 1; }

    if ! jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
        log_error "用户不存在: $username"
        return 1
    fi

    echo "修改用户: $username"
    echo "  1) 到期时间"
    echo "  2) 流量限制"
    echo "  3) 密码/UUID"
    echo "  4) 状态 (启用/禁用)"
    echo "  5) 全部显示"
    read -rp "选择 [1-5]: " choice

    case "$choice" in
        1)
            read -rp "新的到期天数 (从今天起): " days
            local new_expire
            new_expire=$(( $(date +%s) + days * 86400 ))
            json_set "$USERS_FILE" ".users.\"$username\".expire_at" "$new_expire"
            log_info "到期时间已更新: $(format_timestamp $new_expire)"
            ;;
        2)
            echo "流量限制: 1) 100GB  2) 300GB  3) 500GB  4) 1TB  5) 无限制"
            read -rp "选择 [1-5]: " lc
            local limit_bytes
            case "$lc" in
                1) limit_bytes=$(parse_size "100GB") ;;
                2) limit_bytes=$(parse_size "300GB") ;;
                3) limit_bytes=$(parse_size "500GB") ;;
                4) limit_bytes=$(parse_size "1TB") ;;
                5) limit_bytes=0 ;;
                *) log_error "无效选择"; return 1 ;;
            esac
            json_set "$USERS_FILE" ".users.\"$username\".traffic_limit_bytes" "$limit_bytes"
            log_info "流量限制已更新: $(format_bytes $limit_bytes)"
            ;;
        3)
            local protocol
            protocol=$(jq -r ".users.\"$username\".protocol" "$USERS_FILE")
            local new_pass
            new_pass=$(gen_password 32)
            case "$protocol" in
                vless-reality)
                    local new_uuid
                    new_uuid=$(gen_uuid)
                    json_set "$USERS_FILE" ".users.\"$username\".credentials.uuid" "\"$new_uuid\""
                    log_info "UUID 已更新: $new_uuid"
                    ;;
                *)
                    json_set "$USERS_FILE" ".users.\"$username\".credentials.password" "\"$new_pass\""
                    log_info "密码已更新: $new_pass"
                    ;;
            esac
            sb_reload
            ;;
        4)
            local cur_status
            cur_status=$(jq -r ".users.\"$username\".status" "$USERS_FILE")
            if [[ "$cur_status" == "active" ]]; then
                json_set "$USERS_FILE" ".users.\"$username\".status" '"disabled"'
                log_info "用户已禁用: $username"
            else
                json_set "$USERS_FILE" ".users.\"$username\".status" '"active"'
                log_info "用户已启用: $username"
            fi
            sb_reload
            ;;
        5)
            show_user_detail "$username"
            ;;
        *)
            log_error "无效选择"
            return 1
            ;;
    esac
}

# --- 显示用户详情 ---
show_user_detail() {
    local username="${1:-}"
    if ! jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
        log_error "用户不存在: $username"
        return 1
    fi

    local user_data
    user_data=$(jq ".users.\"$username\"" "$USERS_FILE")

    local protocol
    protocol=$(echo "$user_data" | jq -r '.protocol')
    local status
    status=$(echo "$user_data" | jq -r '.status')
    local created_at
    created_at=$(echo "$user_data" | jq -r '.created_at')
    local expire_at
    expire_at=$(echo "$user_data" | jq -r '.expire_at')
    local limit_bytes
    limit_bytes=$(echo "$user_data" | jq -r '.traffic_limit_bytes')
    local used_down
    used_down=$(echo "$user_data" | jq -r '.traffic_used_down')
    local used_up
    used_up=$(echo "$user_data" | jq -r '.traffic_used_up')
    local port
    port=$(echo "$user_data" | jq -r '.inbound.port')
    local online
    online=$(echo "$user_data" | jq -r '.online')
    local sub_url
    sub_url=$(echo "$user_data" | jq -r '.subscription.url')
    local uuid
    uuid=$(echo "$user_data" | jq -r '.credentials.uuid // "N/A"')
    local password
    password=$(echo "$user_data" | jq -r '.credentials.password // "N/A"')

    local used_total=$((used_down + used_up))
    local remaining=$((limit_bytes - used_total))

    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  用户详情: ${BOLD}${username}${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo -e "协议:       $(protocol_label "$protocol")"
    echo -e "状态:       $([[ "$status" == "active" ]] && echo -e "${GREEN}启用${NC}" || echo -e "${RED}禁用${NC}")"
    echo -e "在线:       $([[ "$online" == "true" ]] && echo -e "${GREEN}在线${NC}" || echo -e "${YELLOW}离线${NC}")"
    echo -e "端口:       $port"
    echo -e "UUID:       $uuid"
    echo -e "密码:       $password"
    echo -e "创建时间:   $(format_timestamp "$created_at")"
    echo -e "到期时间:   $(format_timestamp "$expire_at")"
    echo -e "流量限制:   $(format_bytes "$limit_bytes")"
    echo -e "已用流量:   $(format_bytes "$used_total")"
    echo -e "剩余流量:   $(format_bytes "$remaining")"
    echo -e "订阅链接:   ${sub_url}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    # 协议特定信息
    case "$protocol" in
        vless-reality)
            echo -e "Reality Public Key: $(echo "$user_data" | jq -r '.reality.public_key')"
            echo -e "Reality Short ID:   $(echo "$user_data" | jq -r '.reality.short_id')"
            echo -e "Reality SNI:        $(echo "$user_data" | jq -r '.reality.server_name')"
            ;;
        hysteria2)
            echo -e "Obfs Password: $(echo "$user_data" | jq -r '.hysteria2.obfs_password')"
            ;;
    esac
    echo ""
}

# --- 显示用户客户端配置 ---
show_user_config() {
    local username="${1:-}"
    local format="${2:-all}"

    if ! jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
        log_error "用户不存在: $username"
        return 1
    fi

    local protocol
    protocol=$(jq -r ".users.\"$username\".protocol" "$USERS_FILE")
    load_protocol_gen "$protocol" || return 1

    local client_config
    case "$protocol" in
        vless-reality) client_config=$(gen_vless_reality_client "$username") ;;
        hysteria2)     client_config=$(gen_hysteria2_client "$username") ;;
        tuic)          client_config=$(gen_tuic_client "$username") ;;
        anytls)        client_config=$(gen_anytls_client "$username") ;;
        shadowtls)     client_config=$(gen_shadowtls_client "$username") ;;
    esac

    echo ""
    echo -e "${PURPLE}========================================${NC}"
    echo -e "${PURPLE}  客户端配置: ${username}${NC}"
    echo -e "${PURPLE}========================================${NC}"
    echo ""

    # 分享链接
    echo -e "${BOLD}分享链接:${NC}"
    echo "$(echo "$client_config" | jq -r '.share_link')"
    echo ""

    # Sing-box 配置
    echo -e "${BOLD}Sing-box 客户端配置:${NC}"
    echo "$(echo "$client_config" | jq -r '.["sing-box"]' | jq -r '.')"
    echo ""
}

# --- 列出所有用户 ---
list_users() {
    if [[ ! -f "$USERS_FILE" ]] || [[ "$(jq '.users | length' "$USERS_FILE")" == "0" ]]; then
        echo "暂无用户"
        return
    fi

    printf "${CYAN}%-16s %-20s %-8s %-8s %-20s %-15s${NC}\n" \
        "用户名" "协议" "端口" "状态" "到期时间" "流量(已用/总量)"
    printf '%s\n' "$(printf '─%.0s' {1..95})"

    jq -r '.users | to_entries[] | 
        "\(.key)|\(.value.protocol)|\(.value.inbound.port)|\(.value.status)|\(.value.expire_at)|\(.value.traffic_used_down + .value.traffic_used_up)|\(.value.traffic_limit_bytes)"' \
        "$USERS_FILE" 2>/dev/null | while IFS='|' read -r name proto port status expire used limit; do

        local status_str
        [[ "$status" == "active" ]] && status_str="${GREEN}启用${NC}" || status_str="${RED}禁用${NC}"

        printf "%-16s %-20s %-8s %b %-20s %s/%s\n" \
            "$name" \
            "$(protocol_label "$proto")" \
            "$port" \
            "$status_str" \
            "$(format_timestamp "$expire")" \
            "$(format_bytes "$used")" \
            "$(format_bytes "$limit")"
    done
    echo ""
}

# --- 每日定时检查 --- cron_daily_user_check
cron_check_users() {
    log_info "开始每日用户检查..."

    local now
    now=$(date +%s)
    local changed=0

    jq -r '.users | keys[]' "$USERS_FILE" 2>/dev/null | while read -r username; do
        # 检查到期
        local expire_at
        expire_at=$(jq -r ".users.\"$username\".expire_at" "$USERS_FILE")
        if [[ "$expire_at" != "null" && "$expire_at" != "0" && "$now" -ge "$expire_at" ]]; then
            local cur_status
            cur_status=$(jq -r ".users.\"$username\".status" "$USERS_FILE")
            if [[ "$cur_status" == "active" ]]; then
                json_set "$USERS_FILE" ".users.\"$username\".status" '"disabled"'
                log_warn "用户已到期, 自动禁用: $username"
                changed=1
            fi
        fi

        # 检查流量超限
        local limit_bytes
        limit_bytes=$(jq -r ".users.\"$username\".traffic_limit_bytes" "$USERS_FILE")
        if [[ "$limit_bytes" != "0" && "$limit_bytes" != "null" ]]; then
            local used_down
            used_down=$(jq -r ".users.\"$username\".traffic_used_down // 0" "$USERS_FILE")
            local used_up
            used_up=$(jq -r ".users.\"$username\".traffic_used_up // 0" "$USERS_FILE")
            local used_total=$((used_down + used_up))
            if [[ "$used_total" -ge "$limit_bytes" ]]; then
                local cur_status
                cur_status=$(jq -r ".users.\"$username\".status" "$USERS_FILE")
                if [[ "$cur_status" == "active" ]]; then
                    json_set "$USERS_FILE" ".users.\"$username\".status" '"disabled"'
                    log_warn "用户流量超限, 自动封禁: $username (已用 $(format_bytes $used_total))"
                    changed=1
                fi
            fi
        fi
    done

    if [[ $changed -eq 1 ]]; then
        sb_reload || log_warn "配置重载失败"
    fi

    log_info "每日用户检查完成"
}