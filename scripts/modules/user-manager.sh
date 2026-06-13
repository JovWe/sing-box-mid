#===============================================================================
# Sing-box Manager - 用户管理模块（纯函数）
#===============================================================================

# --- 创建用户数据结构 ---
create_user_data() {
    local username="${1:-}"
    local protocol="${2:-}"
    local expire_days="${3:-30}"
    local traffic_limit="${4:-100GB}"

    [[ -z "$username" ]] && { log_error "用户名不能为空"; return 1; }

    # 检查是否已存在
    if jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
        log_error "用户已存在: $username"
        return 1
    fi

    local now
    now=$(date +%s)
    local expire_at=$(( now + expire_days * 86400 ))

    jq --arg name "$username" \
       --arg protocol "$protocol" \
       --argjson created "$now" \
       --argjson expire "$expire_at" \
       --arg traffic "$traffic_limit" \
       --arg token "$(gen_token)" \
       '.users[$name] = {
           "username": $name,
           "protocol": $protocol,
           "status": "active",
           "created_at": $created,
           "expire_at": $expire,
           "traffic_limit": $traffic,
           "credentials": {},
           "inbound": {},
           "subscription": {"token": $token, "url": ""}
       }' "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    log_info "用户数据已初始化: $username"
}

# --- 加载协议生成器 ---
load_protocol_gen() {
    local protocol="${1:-}"
    local gen_file="${SB_SCRIPTS}/modules/protocol-gen/${protocol}.sh"
    if [[ -f "$gen_file" ]]; then
        source "$gen_file"
    else
        log_error "不支持的协议: $protocol (缺少生成器)"
        return 1
    fi
}

# --- 添加用户 ---
add_user() {
    local username="${1:-}"
    local protocol="${2:-}"
    local expire_days="${3:-30}"
    local traffic_limit="${4:-100GB}"
    local port="${5:-}"

    # 交互模式: 获取用户名
    if [[ -z "$username" ]]; then
        read -rp "用户名: " username
    fi
    [[ -z "$username" ]] && { log_error "用户名不能为空"; return 1; }

    # 交互模式: 获取协议
    if [[ -z "$protocol" ]]; then
        echo "可选协议:"
        echo "  1) VLESS + Reality"
        echo "  2) Hysteria2"
        echo "  3) TUIC v5"
        echo "  4) AnyTLS"
        echo "  5) ShadowTLS v3"
        read -rp "选择协议 [1-5]: " proto_choice
        case "$proto_choice" in
            1) protocol="vless-reality" ;;
            2) protocol="hysteria2" ;;
            3) protocol="tuic" ;;
            4) protocol="anytls" ;;
            5) protocol="shadowtls" ;;
            *) log_error "无效的选择"; return 1 ;;
        esac
    fi

    # 创建用户基本数据
    create_user_data "$username" "$protocol" "$expire_days" "$traffic_limit" || return 1

    # 加载协议生成器
    load_protocol_gen "$protocol" || return 1

    # 根据协议生成端口
    case "$protocol" in
        vless-reality)
            port="${port:-$(gen_random_port 443 443)}"
            gen_vless_reality_config "$username" "$port"
            ;;
        hysteria2)
            port="${port:-$(gen_random_port 10000 60000)}"
            gen_hysteria2_config "$username" "$port"
            ;;
        tuic)
            port="${port:-$(gen_random_port 10000 60000)}"
            gen_tuic_config "$username" "$port"
            ;;
        anytls)
            port="${port:-$(gen_random_port 10000 60000)}"
            gen_anytls_config "$username" "$port"
            ;;
        shadowtls)
            port="${port:-$(gen_random_port 10000 60000)}"
            gen_shadowtls_config "$username" "$port"
            ;;
    esac

    # 生成订阅 URL
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.subscription_domain' "$(get_public_ip)")
    local token
    token=$(jq -r ".users.\"$username\".subscription.token" "$USERS_FILE")
    local sub_url="${domain}/sub/${username}?token=${token}"
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

    # 获取端口以便关闭防火墙
    local port
    port=$(jq -r ".users.\"$username\".inbound.port // 0" "$USERS_FILE")

    # 移除入站配置文件
    rm -f "${SB_CONFIG}/inbound/${username}.json"

    # 从 users.json 移除
    jq "del(.users[\"$username\"])" "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    # 关闭防火墙
    if [[ -n "$port" && "$port" != "0" ]]; then
        ufw_deny_port "$port"
    fi

    sb_reload
    log_ok "用户已删除: $username"
}

# --- 编辑用户 ---
edit_user() {
    local username="${1:-}"
    if [[ -z "$username" ]]; then
        read -rp "用户名: " username
    fi

    if ! jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
        log_error "用户不存在: $username"
        return 1
    fi

    echo "当前信息:"
    echo "  状态: $(jq -r ".users.\"$username\".status" "$USERS_FILE")"
    echo "  协议: $(protocol_label "$(jq -r ".users.\"$username\".protocol" "$USERS_FILE")")"
    echo "  到期: $(format_timestamp "$(jq -r ".users.\"$username\".expire_at" "$USERS_FILE")")"
    echo "  流量: $(jq -r ".users.\"$username\".traffic_limit" "$USERS_FILE")"

    echo ""
    echo "1) 激活/停用"
    echo "2) 延长到期时间 (增加天数)"
    echo "3) 修改流量限制"
    read -rp "选择 [1-3]: " choice

    case "$choice" in
        1)
            local current_status
            current_status=$(jq -r ".users.\"$username\".status" "$USERS_FILE")
            local new_status
            if [[ "$current_status" == "active" ]]; then
                new_status="disabled"
            else
                new_status="active"
            fi
            json_set "$USERS_FILE" ".users.\"$username\".status" "\"$new_status\""
            sb_reload
            log_ok "用户 $username 状态: $current_status -> $new_status"
            ;;
        2)
            read -rp "增加多少天: " add_days
            if [[ "$add_days" =~ ^[0-9]+$ ]]; then
                local current_expire
                current_expire=$(jq -r ".users.\"$username\".expire_at" "$USERS_FILE")
                local new_expire=$(( current_expire + add_days * 86400 ))
                json_set "$USERS_FILE" ".users.\"$username\".expire_at" "$new_expire"
                log_ok "到期时间更新为: $(format_timestamp "$new_expire")"
            else
                log_error "无效的天数"
            fi
            ;;
        3)
            read -rp "新的流量限制 (例如 200GB): " new_limit
            if [[ -n "$new_limit" ]]; then
                json_set "$USERS_FILE" ".users.\"$username\".traffic_limit" "\"$new_limit\""
                log_ok "流量限制已更新: $new_limit"
            fi
            ;;
        *)
            log_error "无效选择"
            ;;
    esac
}

# --- 列出用户 ---
list_users() {
    echo ""
    printf "+-%-18s-+-%-16s-+-%-8s-+-%-18s-+-%-10s-+-%-10s-+-%-10s-+\n" | tr ' ' '-'
    printf "| %-18s | %-16s | %-8s | %-18s | %-10s | %-10s | %-10s |\n" "用户名" "协议" "状态" "到期" "下行" "上行" "限制"
    printf "+-%-18s-+-%-16s-+-%-8s-+-%-18s-+-%-10s-+-%-10s-+-%-10s-+\n" | tr ' ' '-'

    local count=0
    while IFS= read -r username; do
        [[ -z "$username" || "$username" == "null" ]] && continue
        count=$((count + 1))
        local proto status expire traffic_limit traffic_down traffic_up
        proto=$(jq -r ".users.\"$username\".protocol" "$USERS_FILE")
        status=$(jq -r ".users.\"$username\".status" "$USERS_FILE")
        expire=$(jq -r ".users.\"$username\".expire_at" "$USERS_FILE")
        traffic_limit=$(jq -r ".users.\"$username\".traffic_limit" "$USERS_FILE")
        traffic_down=$(json_get "$TRAFFIC_FILE" ".users.\"$username\".down // 0" "0")
        traffic_up=$(json_get "$TRAFFIC_FILE" ".users.\"$username\".up // 0" "0")

        local status_color
        if [[ "$status" == "active" ]]; then
            status_color="${GREEN}${status}${NC}"
        else
            status_color="${RED}${status}${NC}"
        fi

        printf "| %-18s | %-16s | %-8b | %-18s | %-10s | %-10s | %-10s |\n" \
            "$username" "$(protocol_label "$proto")" "$status_color" \
            "$(format_timestamp "$expire")" "$(format_bytes "$traffic_down")" \
            "$(format_bytes "$traffic_up")" "$traffic_limit"
    done < <(jq -r '.users | keys[]' "$USERS_FILE" 2>/dev/null)

    printf "+-%-18s-+-%-16s-+-%-8s-+-%-18s-+-%-10s-+-%-10s-+-%-10s-+\n" | tr ' ' '-'
    echo "  共 $count 个用户"
    echo ""
}

# --- 显示用户详情 ---
show_user_detail() {
    local username="${1:-}"
    if [[ -z "$username" ]]; then
        read -rp "用户名: " username
    fi
    if ! jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
        log_error "用户不存在: $username"
        return 1
    fi

    echo ""
    echo "========== 用户详情: $username =========="
    jq ".users.\"$username\"" "$USERS_FILE"
    echo ""
}

# --- 显示客户端配置 ---
show_user_config() {
    local username="${1:-}"
    if [[ -z "$username" ]]; then
        read -rp "用户名: " username
    fi

    if ! jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
        log_error "用户不存在: $username"
        return 1
    fi

    local protocol
    protocol=$(jq -r ".users.\"$username\".protocol" "$USERS_FILE")

    # 加载对应协议生成器以获取 gen_xxx_client 函数
    load_protocol_gen "$protocol" || return 1

    local client_json=""
    case "$protocol" in
        vless-reality) client_config=$(gen_vless_reality_client "$username") ;;
        hysteria2)     client_config=$(gen_hysteria2_client "$username") ;;
        tuic)          client_config=$(gen_tuic_client "$username") ;;
        anytls)        client_config=$(gen_anytls_client "$username") ;;
        shadowtls)     client_config=$(gen_shadowtls_client "$username") ;;
    esac

    local sing_box clash_meta share_link
    sing_box=$(echo "$client_config" | jq -r '.["sing-box"]' 2>/dev/null || echo "")
    clash_meta=$(echo "$client_config" | jq -r '.["clash-meta"]' 2>/dev/null || echo "")
    share_link=$(echo "$client_config" | jq -r '.share_link' 2>/dev/null || echo "")

    echo ""
    echo "========== 客户端配置: $username =========="
    echo ""
    echo "【分享链接】"
    echo "  $share_link"
    echo ""
    echo "【Sing-box 客户端配置】"
    if [[ -n "$sing_box" ]]; then
        # 解码 base64? sing_box 在我们的逻辑里是原始 JSON 字符串
        if echo "$sing_box" | jq -e . >/dev/null 2>&1; then
            echo "$sing_box" | jq .
        else
            echo "$sing_box"
        fi
    fi
    echo ""
    echo "【Clash Meta 配置】"
    echo "$clash_meta"
    echo ""
}

# --- 每日定时任务中的用户检查 ---
cron_check_users() {
    local now
    now=$(date +%s)
    jq -r '.users | keys[]' "$USERS_FILE" 2>/dev/null | while read -r username; do
        [[ -z "$username" ]] && continue
        local expire status
        expire=$(jq -r ".users.\"$username\".expire_at" "$USERS_FILE")
        status=$(jq -r ".users.\"$username\".status" "$USERS_FILE")

        # 到期检查
        if [[ "$status" == "active" && "$expire" -le "$now" ]]; then
            log_warn "用户 $username 已到期, 自动停用"
            json_set "$USERS_FILE" ".users.\"$username\".status" "\"disabled\""
        fi
    done
}
