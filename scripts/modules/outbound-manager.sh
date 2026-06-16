# Sing-box Manager - 出站管理模块
# 依赖 db.sh 已 source

# ---- 添加上游出站 ----
add_outbound() {
    local name="${1:-}" type="${2:-}" addr="${3:-}" port="${4:-}"
    if [[ -z "$name" ]]; then
        read -rp "出站名称: " name
    fi
    [[ -z "$name" ]] && { log_error "名称不能为空"; return 1; }
    if [[ -z "$type" ]]; then
        echo "选择出站类型:"
        echo "  1) SOCKS5"
        echo "  2) HTTP"
        read -rp "输入 [1-2]: " tc
        case "$tc" in
            1) type="socks" ;;
            2) type="http" ;;
            *) log_error "无效"; return 1 ;;
        esac
    fi
    if [[ -z "$addr" ]]; then
        read -rp "服务器地址: " addr
    fi
    if [[ -z "$port" ]]; then
        read -rp "服务器端口: " port
    fi
    local tag="out-${name}"
    local config
    # 询问认证
    local auth_user="" auth_pass=""
    echo "是否需要认证? (y/N): "; read -rp "" yn; yn="${yn:-n}"
    if [[ "${yn,,}" == "y" ]]; then
        read -rp "用户名: " auth_user
        read -rsp "密码: " auth_pass; echo ""
    fi

    if [[ -n "$auth_user" ]]; then
        config=$(jq -n --arg type "$type" --arg addr "$addr" --argjson port "$port" --arg user "$auth_user" --arg pass "$auth_pass" \
            '{type:$type, tag:"'$tag'", server:$addr, server_port:$port, username:$user, password:$pass}')
    else
        config=$(jq -n --arg type "$type" --arg addr "$addr" --argjson port "$port" \
            '{type:$type, tag:"'$tag'", server:$addr, server_port:$port}')
    fi

    db_outbound_add "$name" "$type" "$tag" "$config" || { log_error "添加失败 (可能已存在)"; return 1; }

    # 写入出站片段
    mkdir -p "${SB_CONFIG}/outbound"
    echo "$config" > "${SB_CONFIG}/outbound/${tag}.json"

    # 加入代理池
    local sel_cfg
    sel_cfg=$(sqlite3 "$DB_FILE" "SELECT config FROM outbounds WHERE tag='proxy';" 2>/dev/null)
    if [[ -n "$sel_cfg" ]]; then
        local ob_list
        ob_list=$(echo "$sel_cfg" | jq --arg t "$tag" '.outbounds += [$t]')
        sqlite3 "$DB_FILE" "UPDATE outbounds SET config='$(echo "$ob_list" | sed "s/'/''/g")' WHERE tag='proxy';"
    fi

    log_ok "出站已添加: $name ($type://$addr:$port)"
    generate_config && sb_reload && log_ok "配置已重载"
}

# ---- 列出出站 ----
list_outbounds() {
    echo -e "\n${BOLD}出站列表${NC}"
    printf "+-%-4s-+-%-18s-+-%-10s-+-%-20s-+\n" | tr ' ' '-'
    printf "| %-4s | %-18s | %-10s | %-20s |\n" "ID" "名称" "类型" "地址"
    printf "+-%-4s-+-%-18s-+-%-10s-+-%-20s-+\n" | tr ' ' '-'
    while IFS='|' read -r id name type tag cfg; do
        local addr=""
        [[ "$type" != "direct" && "$type" != "block" && "$type" != "selector" ]] && \
            addr=$(echo "$cfg" 2>/dev/null | jq -r '.server // ""' 2>/dev/null)
        [[ -z "$addr" ]] && addr="(内置)"
        local label
        case "$type" in
            direct)   label="直连" ;;
            block)    label="阻断" ;;
            selector) label="选择器" ;;
            socks)    label="SOCKS5" ;;
            http)     label="HTTP" ;;
            *)        label="$type" ;;
        esac
        printf "| %-4s | %-18s | %-10s | %-20s |\n" "$id" "$name" "$label" "$addr"
    done < <(sqlite3 "$DB_FILE" "SELECT id, name, type, tag, config FROM outbounds ORDER BY id;")
    printf "+-%-4s-+-%-18s-+-%-10s-+-%-20s-+\n" | tr ' ' '-'

    local cur; cur=$(db_setting_get "global_outbound")
    [[ -z "$cur" ]] && cur="proxy"
    echo -e "当前全局出站: ${BOLD}$cur${NC}"
    echo ""
}

# ---- 删除出站 ----
delete_outbound() {
    local tag="${1:-}"
    if [[ -z "$tag" ]]; then
        list_outbounds
        read -rp "输入要删除的出站 tag: " tag
    fi
    [[ -z "$tag" ]] && { log_error "tag 不能为空"; return 1; }

    local row; row=$(sqlite3 "$DB_FILE" -json "SELECT * FROM outbounds WHERE tag='$tag';" 2>/dev/null | jq -r '.[0] // empty')
    [[ -z "$row" ]] && { log_error "出站不存在: $tag"; return 1; }
    local builtin; builtin=$(echo "$row" | jq -r '.builtin')
    [[ "$builtin" == "1" ]] && { log_error "内置出站不能删除"; return 1; }

    if [[ -z "${1:-}" ]]; then confirm "确认删除出站 $tag?" n || return 0; fi

    # 从代理池移除
    local sel_cfg
    sel_cfg=$(sqlite3 "$DB_FILE" "SELECT config FROM outbounds WHERE tag='proxy';" 2>/dev/null)
    if [[ -n "$sel_cfg" ]]; then
        local ob_list
        ob_list=$(echo "$sel_cfg" | jq --arg t "$tag" '.outbounds -= [$t]')
        sqlite3 "$DB_FILE" "UPDATE outbounds SET config='$(echo "$ob_list" | sed "s/'/''/g")' WHERE tag='proxy';"
    fi

    db_outbound_delete "$tag"
    rm -f "${SB_CONFIG}/outbound/${tag}.json"

    generate_config && sb_reload || log_warn "重载失败"
    log_ok "出站已删除: $tag"
}

# ---- 设置全局出站 ----
set_global_outbound() {
    local tag="${1:-}"
    if [[ -z "$tag" ]]; then
        list_outbounds
        read -rp "输入要设为全局的出站 tag: " tag
    fi
    [[ -z "$tag" ]] && { log_error "tag 不能为空"; return 1; }

    local exists
    exists=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM outbounds WHERE tag='$tag';" 2>/dev/null)
    [[ "$exists" == "0" ]] && { log_error "出站不存在: $tag"; return 1; }

    db_setting_set "global_outbound" "$tag"
    log_ok "全局出站已切换为: $tag"
    generate_config && sb_reload && log_ok "配置已重载"
}