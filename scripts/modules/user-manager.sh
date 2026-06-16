# Sing-box Manager - 用户管理模块（精简版）
# 提供: add_user, list_users, delete_user, load_protocol_gen

# ============ 加载协议生成器 ============
load_protocol_gen() {
    local protocol="${1:-}"
    local gen_file="${SB_MODULES_DIR:-/opt/sb-manager/scripts/modules}/protocol-gen/${protocol}.sh"
    if [[ -f "$gen_file" ]]; then
        source "$gen_file"
    else
        log_error "不支持的协议: $protocol"
        return 1
    fi
}

# ============ 添加用户 ============
add_user() {
    local username="${1:-}"
    local protocol="${2:-}"

    if [[ -z "$username" ]]; then
        read -rp "用户名: " username
    fi
    [[ -z "$username" ]] && { log_error "用户名不能为空"; return 1; }

    if jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
        log_error "用户已存在: $username"
        return 1
    fi

    if [[ -z "$protocol" ]]; then
        echo ""
        echo "可选协议:"
        echo "  1) VLESS + Reality"
        echo "  2) Hysteria2"
        echo "  3) TUIC v5"
        echo "  4) ShadowTLS v3"
        echo "  5) VMess"
        read -rp "选择协议 [1-5]: " pc
        case "$pc" in
            1) protocol="vless-reality" ;;
            2) protocol="hysteria2" ;;
            3) protocol="tuic" ;;
            4) protocol="shadowtls" ;;
            5) protocol="vmess" ;;
            *) log_error "无效选择"; return 1 ;;
        esac
    fi

    # 写入用户基础数据
    local now; now=$(date +%s)
    local user_json
    user_json=$(jq -n \
        --arg name "$username" \
        --arg proto "$protocol" \
        --argjson now "$now" \
        '{username:$name, protocol:$proto, status:"active",
          created_at:$now, inbound:{}, credentials:{}}')
    jq --arg name "$username" --argjson data "$user_json" \
        '.users[$name] = $data' "$USERS_FILE" > "${USERS_FILE}.tmp" \
        && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    # 加载协议生成器
    load_protocol_gen "$protocol" || return 1

    # 生成端口
    local port
    case "$protocol" in
        vless-reality) port=443 ;;
        *) port=$(gen_random_port 10000 60000) ;;
    esac

    # 调用协议生成器
    case "$protocol" in
        vless-reality) gen_vless_reality_config "$username" "$port" ;;
        hysteria2)     gen_hysteria2_config     "$username" "$port" ;;
        tuic)          gen_tuic_config          "$username" "$port" ;;
        shadowtls)     gen_shadowtls_config     "$username" "$port" ;;
        vmess)         gen_vmess_config         "$username" "$port" ;;
    esac

    # 开放防火墙端口
    ufw_allow_port "$port"
    case "$protocol" in
        hysteria2|tuic) ufw_allow_port "$port" udp ;;
    esac

    # 重载 sing-box (reload 失败不致命, 例如第一次安装时服务还没起)
    _load_module "config-generator.sh" || return 1
    generate_config || return 1
    sb_reload || log_warn "sing-box 重载失败, 请手动 systemctl restart sing-box"

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  用户创建成功: ${BOLD}$username${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "  协议:     ${BOLD}$(protocol_label "$protocol")${NC}"
    echo -e "  端口:     ${BOLD}$port${NC}"
    echo -e "  状态:     ${GREEN}active${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
}

# ============ 列出用户 ============
list_users() {
    echo ""
    printf "+-%-18s-+-%-16s-+-%-10s-+-%-12s-+\n" | tr ' ' '-'
    printf "| %-18s | %-16s | %-10s | %-12s |\n" "用户名" "协议" "状态" "端口"
    printf "+-%-18s-+-%-16s-+-%-10s-+-%-12s-+\n" | tr ' ' '-'

    local count=0
    while IFS= read -r username; do
        [[ -z "$username" || "$username" == "null" ]] && continue
        count=$((count + 1))
        local proto status port
        proto=$(jq -r ".users.\"$username\".protocol" "$USERS_FILE")
        status=$(jq -r ".users.\"$username\".status" "$USERS_FILE")
        port=$(jq -r ".users.\"$username\".inbound.port // \"-\"" "$USERS_FILE")
        printf "| %-18s | %-16s | %-10s | %-12s |\n" \
            "$username" "$(protocol_label "$proto")" "$status" "$port"
    done < <(jq -r '.users | keys[]' "$USERS_FILE" 2>/dev/null)

    printf "+-%-18s-+-%-16s-+-%-10s-+-%-12s-+\n" | tr ' ' '-'
    echo "  共 $count 个用户"
    echo ""
}

# ============ 删除用户 ============
delete_user() {
    local username="${1:-}"
    local skip_confirm="${2:-}"
    if [[ -z "$username" ]]; then
        list_users
        read -rp "输入要删除的用户名: " username
    fi
    [[ -z "$username" ]] && { log_error "用户名不能为空"; return 1; }

    if ! jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
        log_error "用户不存在: $username"
        return 1
    fi

    # 传参时: 默认 y, 仅在显式 'n' 时跳过
    if [[ -n "${1:-}" && "$skip_confirm" != "-y" ]]; then
        confirm "确认删除用户 $username ?" n || return 0
    fi

    # 移除入站配置
    rm -f "${SB_CONFIG}/inbound/${username}.json"

    # 从 users.json 移除
    jq "del(.users[\"$username\"])" "$USERS_FILE" > "${USERS_FILE}.tmp" \
        && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    # 重载配置 (reload 失败不致命)
    _load_module "config-generator.sh" || return 1
    generate_config || return 1
    sb_reload || log_warn "sing-box 重载失败"
    log_ok "用户已删除: $username"
}
