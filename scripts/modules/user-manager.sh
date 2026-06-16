# Sing-box Manager - 用户管理模块
# 依赖 db.sh 已 source

# ---- 加载协议生成器 ----
load_protocol_gen() {
    local proto="$1"
    local f="${SB_MODULES}/protocol-gen/${proto}.sh"
    [[ -f "$f" ]] && source "$f" || { log_error "不支持的协议: $proto"; return 1; }
}

# ---- 添加用户 ----
add_user() {
    local username="${1:-}" protocol="${2:-}"
    if [[ -z "$username" ]]; then
        read -rp "用户名: " username
    fi
    [[ -z "$username" ]] && { log_error "用户名不能为空"; return 1; }
    # 查重
    if sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM users WHERE username='$username';" | grep -q '^[1-9]'; then
        log_error "用户已存在: $username"; return 1
    fi
    if [[ -z "$protocol" ]]; then
        echo "选择协议:"; echo "  1) VLESS Reality"; echo "  2) Hysteria2"
        echo "  3) TUIC v5"; echo "  4) ShadowTLS v3"; echo "  5) VMess"
        read -rp "输入 [1-5]: " pc
        case "$pc" in 1) protocol="vless-reality" ;; 2) protocol="hysteria2" ;;
            3) protocol="tuic" ;; 4) protocol="shadowtls" ;; 5) protocol="vmess" ;;
            *) log_error "无效"; return 1 ;; esac
    fi
    # 写入 DB
    local port
    case "$protocol" in vless-reality) port=443 ;; *) port=$(gen_random_port) ;; esac
    db_user_add "$username" "$protocol" "$port"
    # 加载协议生成器并生成配置
    load_protocol_gen "$protocol" || return 1
    local gen_func="gen_${protocol}_config"
    $gen_func "$username" "$port"
    # 防火墙
    ufw_allow "$port"
    case "$protocol" in hysteria2|tuic) ufw_allow "$port" udp ;; esac
    # 重载
    generate_config || return 1
    sb_reload || log_warn "sing-box 重载失败"
    # 输出
    local link; link=$(gen_client_link "$username" 2>/dev/null || echo "(无分享链接)")
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  用户创建成功: ${BOLD}$username${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "协议:   $(protocol_label "$protocol")"
    echo -e "端口:   $port"
    echo -e "链接:   $link"
    echo -e "${GREEN}========================================${NC}"
    echo ""
}

# ---- 编辑用户 ----
edit_user() {
    local username="${1:-}"
    if [[ -z "$username" ]]; then
        read -rp "用户名: " username
    fi
    local row; row=$(sqlite3 "$DB_FILE" -json "SELECT * FROM users WHERE username='$username';" 2>/dev/null | jq -r '.[0] // empty')
    [[ -z "$row" ]] && { log_error "用户不存在: $username"; return 1; }
    local expire_limit traffic outbound
    expire_limit=$(echo "$row" | jq -r '.expire_at')
    traffic=$(echo "$row" | jq -r '.traffic_limit_bytes')
    outbound=$(echo "$row" | jq -r '.outbound_tag')
    echo "当前: 到期=$( [[ $expire_limit -gt 0 ]] && date -d@$expire_limit '+%Y-%m-%d' || echo 不限)  流量=$([[ $traffic -gt 0 ]] && format_bytes $traffic || echo 不限)  出站=$outbound"
    echo "1) 修改到期"; echo "2) 修改流量限制"; echo "3) 修改出站选择"
    read -rp "选择 [1-3]: " ec
    case "$ec" in
        1) read -rp "新到期 (YYYY-MM-DD 或 天数, 留空不限): " dt
           if [[ -z "$dt" ]]; then db_user_set_expire "$username" 0
           elif [[ "$dt" =~ ^[0-9]+$ ]]; then db_user_set_expire "$username" $(( $(date +%s) + dt * 86400 ))
           else db_user_set_expire "$username" $(date -d "$dt" +%s 2>/dev/null || echo 0); fi ;;
        2) read -rp "新流量限制 (如 100GB, 留空不限): " tl
           [[ -n "$tl" ]] && db_user_set_traffic_limit "$username" "$(parse_bytes "$tl")" ;;
        3) echo "可用出站:"
           sqlite3 "$DB_FILE" "SELECT tag,name FROM outbounds WHERE builtin=0;" | while IFS='|' read -r t n; do echo "  $t ($n)"; done
           read -rp "输入出站 tag: " ot; [[ -n "$ot" ]] && db_user_set_outbound "$username" "$ot" ;;
    esac
    generate_config && sb_reload && log_ok "修改完成"
}

# ---- 列出用户 ----
list_users() {
    echo -e "\n${BOLD}用户列表${NC}"
    printf "+-%-18s-+-%-16s-+-%-6s-+-%-8s-+-%-12s-+-%-12s-+-%-18s-+\n" | tr ' ' '-'
    printf "| %-18s | %-16s | %-6s | %-8s | %-12s | %-12s | %-18s |\n" "用户名" "协议" "端口" "状态" "下行" "上行" "到期"
    printf "+-%-18s-+-%-16s-+-%-6s-+-%-8s-+-%-12s-+-%-12s-+-%-18s-+\n" | tr ' ' '-'
    while IFS='|' read -r u p port st dn up ex; do
        local ex_str
        [[ "$ex" -gt 0 ]] && ex_str=$(date -d@"$ex" '+%Y-%m-%d %H:%M' 2>/dev/null) || ex_str="不限"
        printf "| %-18s | %-16s | %-6s | %-8s | %-12s | %-12s | %-18s |\n" \
            "$u" "$(protocol_label "$p")" "$port" "$st" "$(format_bytes "$dn")" "$(format_bytes "$up")" "$ex_str"
    done < <(sqlite3 "$DB_FILE" "SELECT username,protocol,port,status,traffic_down_bytes,traffic_up_bytes,expire_at FROM users ORDER BY id;")
    printf "+-%-18s-+-%-16s-+-%-6s-+-%-8s-+-%-12s-+-%-12s-+-%-18s-+\n" | tr ' ' '-'
    local cnt; cnt=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM users;")
    echo "  共 $cnt 个用户"
}

# ---- 删除用户 ----
delete_user() {
    local username="${1:-}"
    if [[ -z "$username" ]]; then
        list_users; read -rp "输入要删除的用户名: " username
    fi
    [[ -z "$username" ]] && { log_error "用户名不能为空"; return 1; }
    if ! sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM users WHERE username='$username';" | grep -q '1'; then
        log_error "用户不存在"; return 1
    fi
    if [[ -z "${1:-}" ]]; then confirm "确认删除用户 $username ?" n || return 0; fi
    # 删入站片段
    rm -f "${SB_CONFIG}/inbound/${username}.json"
    # 删 DB
    db_user_delete "$username"
    generate_config && sb_reload || log_warn "重载失败"
    log_ok "用户已删除: $username"
}

# ---- 生成客户端链接 ----
gen_client_link() {
    local username="$1"
    local row; row=$(sqlite3 "$DB_FILE" -json "SELECT protocol FROM users WHERE username='$username';" 2>/dev/null | jq -r '.[0] // empty')
    [[ -z "$row" ]] && { log_error "用户不存在"; return 1; }
    local proto; proto=$(echo "$row" | jq -r '.protocol')
    load_protocol_gen "$proto" || return 1
    local fn="gen_${proto}_client"
    $fn "$username"
}

# ---- 显示客户端配置 ----
show_config() {
    local username="${1:-}"
    if [[ -z "$username" ]]; then read -rp "用户名: " username; fi
    local row; row=$(sqlite3 "$DB_FILE" -json "SELECT * FROM users WHERE username='$username';" 2>/dev/null | jq -r '.[0] // empty')
    [[ -z "$row" ]] && { log_error "用户不存在"; return 1; }
    local proto; proto=$(echo "$row" | jq -r '.protocol')
    echo ""
    echo -e "${BOLD}========== $username 客户端配置 ==========${NC}"
    load_protocol_gen "$proto" || return 1
    local fn="gen_${proto}_client"
    echo -e "分享链接:"
    $fn "$username"
    echo ""
    # 逐出配置 JSON (sing-box 格式)
    echo -e "Sing-box 出站片段:"
    local port server
    port=$(echo "$row" | jq -r '.port')
    server=$(get_public_ip)
    # 输出一个 sing-box outbound JSON 片段
    case "$proto" in
        vless-reality)
            local uuid pub sid sni
            uuid=$(echo "$row" | jq -r '.credentials.uuid')
            pub=$(echo "$row" | jq -r '.credentials.public_key')
            sid=$(echo "$row" | jq -r '.credentials.short_id')
            sni=$(echo "$row" | jq -r '.credentials.server_name')
            jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" \
                --arg pk "$pub" --arg sn "$sid" --arg sni "$sni" \
                '{type:"vless", tag:"proxy", server:$s, server_port:$p, uuid:$u,
                  flow:"xtls-rprx-vision",
                  tls:{enabled:true, server_name:$sni,
                       utls:{enabled:true, fingerprint:"chrome"},
                       reality:{enabled:true, public_key:$pk, short_id:$sn}}}' ;;
        hysteria2)  local pw; pw=$(echo "$row" | jq -r '.credentials.password')
            jq -n --arg s "$server" --argjson p "$port" --arg pw "$pw" \
                '{type:"hysteria2", tag:"proxy", server:$s, server_port:$p, password:$pw,
                  tls:{enabled:true, server_name:$s, insecure:true, alpn:["h3"]}}' ;;
        tuic) local uuid pw; uuid=$(echo "$row" | jq -r '.credentials.uuid')
            pw=$(echo "$row" | jq -r '.credentials.password')
            jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" --arg pw "$pw" \
                '{type:"tuic", tag:"proxy", server:$s, server_port:$p, uuid:$u, password:$pw,
                  tls:{enabled:true, server_name:$s, alpn:["h3"]}, congestion_control:"bbr"}' ;;
        shadowtls) local pw; pw=$(echo "$row" | jq -r '.credentials.password')
            jq -n --arg s "$server" --argjson p "$port" --arg pw "$pw" \
                '{type:"shadowtls", tag:"proxy", server:$s, server_port:$p, version:3, password:$pw,
                  tls:{enabled:true, server_name:"www.bing.com",
                       utls:{enabled:true, fingerprint:"chrome"}}}' ;;
        vmess) local uuid; uuid=$(echo "$row" | jq -r '.credentials.uuid')
            jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" \
                '{type:"vmess", tag:"proxy", server:$s, server_port:$p, uuid:$u, security:"auto"}' ;;
    esac
    echo ""
}

# ---- 每日检查（到期 + 流量超限） ----
cron_check() {
    local now; now=$(date +%s)
    sqlite3 "$DB_FILE" "SELECT username, expire_at, traffic_limit_bytes, traffic_down_bytes FROM users WHERE status='active';" | while IFS='|' read -r u ex tl dn; do
        [[ "$ex" -gt 0 && "$ex" -le "$now" ]] && { log_warn "$u 已到期, 停用"; db_user_set_status "$u" "disabled"; generate_config; sb_reload; }
        [[ "$tl" -gt 0 && "$dn" -ge "$tl" ]] && { log_warn "$u 流量超限, 停用"; db_user_set_status "$u" "disabled"; generate_config; sb_reload; }
    done
}