#===============================================================================
# Sing-box Manager - 订阅生成模块（纯函数）
#===============================================================================

# --- 生成用户订阅（返回混合协议链接 / Clash Meta / Sing-box 配置） ---
gen_user_sub() {
    local username="${1:-}"
    local format="${2:-all}"

    if [[ -z "$username" ]]; then
        read -rp "用户名: " username
    fi
    if ! jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
        log_error "用户不存在: $username"
        return 1
    fi

    local protocol
    protocol=$(jq -r ".users.\"$username\".protocol" "$USERS_FILE")

    # 加载协议生成器（单例, 不会重复 source）
    load_protocol_gen "$protocol" || return 1

    local share_link=""
    case "$protocol" in
        vless-reality) share_link=$(gen_vless_reality_sub "$username") ;;
        hysteria2)     share_link=$(gen_hysteria2_sub "$username") ;;
        tuic)          share_link=$(gen_tuic_sub "$username") ;;
        anytls)        share_link=$(gen_anytls_sub "$username") ;;
        shadowtls)     share_link=$(gen_shadowtls_sub "$username") ;;
    esac

    case "$format" in
        link|all)
            echo "$share_link"
            ;;
        clash-meta)
            echo "# 用户 $username 的 Clash Meta 配置片段"
            echo "$share_link" | sed 's|^|# 链接: |'
            echo "proxies:"
            # 基于协议类型拼接一条 proxy 配置
            local server port password uuid method flow sni pubkey sid flow_name
            server=$(jq -r ".users.\"$username\".inbound.server // \"\"" "$USERS_FILE")
            if [[ -z "$server" || "$server" == "null" ]]; then
                server=$(get_public_ip)
            fi
            port=$(jq -r ".users.\"$username\".inbound.port // 0" "$USERS_FILE")

            case "$protocol" in
                vless-reality)
                    uuid=$(jq -r ".users.\"$username\".credentials.uuid // \"\"" "$USERS_FILE")
                    flow=$(jq -r ".users.\"$username\".credentials.flow // \"\"" "$USERS_FILE")
                    pubkey=$(jq -r ".users.\"$username\".reality.public_key // \"\"" "$USERS_FILE")
                    sid=$(jq -r ".users.\"$username\".reality.short_id // \"\"" "$USERS_FILE")
                    sni=$(jq -r ".users.\"$username\".reality.server_name // \"\"" "$USERS_FILE")
                    echo "  - name: ${username}-${protocol}"
                    echo "    type: vless"
                    echo "    server: ${server}"
                    echo "    port: ${port}"
                    echo "    uuid: ${uuid}"
                    echo "    flow: ${flow:-xtls-rprx-vision}"
                    echo "    tls: true"
                    echo "    client-fingerprint: chrome"
                    echo "    servername: ${sni}"
                    echo "    reality-opts:"
                    echo "      public-key: ${pubkey}"
                    echo "      short-id: ${sid}"
                    echo "    udp: true"
                    echo "    xudp: true"
                    ;;
                hysteria2)
                    password=$(jq -r ".users.\"$username\".credentials.password // \"\"" "$USERS_FILE")
                    echo "  - name: ${username}-${protocol}"
                    echo "    type: hysteria2"
                    echo "    server: ${server}"
                    echo "    port: ${port}"
                    echo "    password: ${password}"
                    echo "    sni: ${server}"
                    echo "    alpn: [h3]"
                    echo "    udp: true"
                    ;;
                tuic)
                    uuid=$(jq -r ".users.\"$username\".credentials.uuid // \"\"" "$USERS_FILE")
                    password=$(jq -r ".users.\"$username\".credentials.password // \"\"" "$USERS_FILE")
                    echo "  - name: ${username}-${protocol}"
                    echo "    type: tuic"
                    echo "    server: ${server}"
                    echo "    port: ${port}"
                    echo "    uuid: ${uuid}"
                    echo "    password: ${password}"
                    echo "    sni: ${server}"
                    echo "    alpn: [h3]"
                    echo "    udp: true"
                    ;;
                anytls|shadowtls)
                    echo "# 该协议需要配合分流规则, 请参考 sing-box 配置直接使用"
                    echo "# 链接: $share_link"
                    ;;
            esac
            ;;
        sing-box)
            echo "$share_link" | sed 's|^|// |'
            echo "// 单协议 sing-box outbounds 片段 (用户 $username)"
            local server port password uuid method flow sni pubkey sid
            server=$(jq -r ".users.\"$username\".inbound.server // \"\"" "$USERS_FILE")
            [[ -z "$server" || "$server" == "null" ]] && server=$(get_public_ip)
            port=$(jq -r ".users.\"$username\".inbound.port // 0" "$USERS_FILE")
            case "$protocol" in
                vless-reality)
                    uuid=$(jq -r ".users.\"$username\".credentials.uuid // \"\"" "$USERS_FILE")
                    pubkey=$(jq -r ".users.\"$username\".reality.public_key // \"\"" "$USERS_FILE")
                    sid=$(jq -r ".users.\"$username\".reality.short_id // \"\"" "$USERS_FILE")
                    sni=$(jq -r ".users.\"$username\".reality.server_name // \"\"" "$USERS_FILE")
                    flow=$(jq -r ".users.\"$username\".credentials.flow // \"\"" "$USERS_FILE")
                    jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" \
                        --arg pk "$pubkey" --arg sn "$sid" --arg sni "$sni" --arg fl "${flow:-xtls-rprx-vision}" \
                        '{type:"vless", tag:"out-user", server:$s, server_port:$p, uuid:$u, flow:$fl,
                          tls:{enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:"chrome"},
                               reality:{enabled:true, public_key:$pk, short_id:$sn}},
                          multiplex:{enabled:true, protocol:"h2mux", max_connections:4, min_streams:4}}'
                    ;;
                hysteria2)
                    password=$(jq -r ".users.\"$username\".credentials.password // \"\"" "$USERS_FILE")
                    jq -n --arg s "$server" --argjson p "$port" --arg pw "$password" \
                        '{type:"hysteria2", tag:"out-user", server:$s, server_port:$p, password:$pw,
                          tls:{enabled:true, server_name:$s, insecure:true, alpn:["h3"]}}'
                    ;;
                tuic)
                    uuid=$(jq -r ".users.\"$username\".credentials.uuid // \"\"" "$USERS_FILE")
                    password=$(jq -r ".users.\"$username\".credentials.password // \"\"" "$USERS_FILE")
                    jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" --arg pw "$password" \
                        '{type:"tuic", tag:"out-user", server:$s, server_port:$p, uuid:$u, password:$pw,
                          tls:{enabled:true, server_name:$s, alpn:["h3"]}, congestion_control:"bbr"}'
                    ;;
                anytls|shadowtls)
                    echo "// 请参考 sing-box 官方文档拼接"
                    ;;
            esac
            ;;
    esac
}

# --- 展示订阅 URL ---
show_sub() {
    local username="${1:-}"
    if [[ -z "$username" ]]; then
        read -rp "用户名: " username
    fi
    if ! jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
        log_error "用户不存在: $username"
        return 1
    fi
    local sub_url token
    sub_url=$(jq -r ".users.\"$username\".subscription.url" "$USERS_FILE")
    token=$(jq -r ".users.\"$username\".subscription.token" "$USERS_FILE")
    echo ""
    echo "订阅 URL: $sub_url"
    echo "Token:     $token"
    echo ""
}
