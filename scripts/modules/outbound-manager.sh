# Sing-box Manager - 出站管理模块（精简版）
# 提供: add_outbound, list_outbounds

# ============ 添加出站 ============
add_outbound() {
    local name="${1:-}" out_type="${2:-}"

    if [[ -z "$name" ]]; then
        read -rp "出站名称 (英文, 无空格): " name
    fi
    [[ -z "$name" ]] && { log_error "名称不能为空"; return 1; }

    if [[ -z "$out_type" ]]; then
        echo ""
        echo "可选类型:"
        echo "  1) VLESS"
        echo "  2) Hysteria2"
        echo "  3) TUIC"
        echo "  4) Shadowsocks"
        echo "  5) VMess"
        echo "  6) Trojan"
        read -rp "选择 [1-6]: " tc
        case "$tc" in
            1) out_type="vless" ;;
            2) out_type="hysteria2" ;;
            3) out_type="tuic" ;;
            4) out_type="shadowsocks" ;;
            5) out_type="vmess" ;;
            6) out_type="trojan" ;;
            *) log_error "无效选择"; return 1 ;;
        esac
    fi

    local server port
    read -rp "服务器地址: " server
    read -rp "端口: " port
    [[ -z "$server" || -z "$port" ]] && { log_error "服务器和端口必填"; return 1; }

    local tag="out-${name}"
    local config=""

    case "$out_type" in
        vless)
            local uuid use_tls flow sni
            uuid=$(gen_uuid)
            read -rp "启用 TLS? [y/N]: " use_tls
            if [[ "${use_tls,,}" == "y" ]]; then
                read -rp "SNI: " sni
                config=$(jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" --arg sni "$sni" \
                    '{type:"vless", server:$s, server_port:$p, uuid:$u, tls:{enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:"chrome"}}}')
            else
                config=$(jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" \
                    '{type:"vless", server:$s, server_port:$p, uuid:$u}')
            fi
            ;;
        hysteria2)
            local password
            password=$(gen_password 16)
            config=$(jq -n --arg s "$server" --argjson p "$port" --arg pw "$password" \
                '{type:"hysteria2", server:$s, server_port:$p, password:$pw, tls:{enabled:true, server_name:$s, insecure:true}}')
            ;;
        tuic)
            local uuid password
            uuid=$(gen_uuid); password=$(gen_password 16)
            config=$(jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" --arg pw "$password" \
                '{type:"tuic", server:$s, server_port:$p, uuid:$u, password:$pw, tls:{enabled:true, server_name:$s}, congestion_control:"bbr"}')
            ;;
        shadowsocks)
            local method password
            method="aes-256-gcm"
            read -rp "加密方式 (默认 aes-256-gcm): " m
            [[ -n "$m" ]] && method="$m"
            password=$(gen_password 16)
            config=$(jq -n --arg s "$server" --argjson p "$port" --arg m "$method" --arg pw "$password" \
                '{type:"shadowsocks", server:$s, server_port:$p, method:$m, password:$pw}')
            ;;
        vmess)
            local uuid
            uuid=$(gen_uuid)
            config=$(jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" \
                '{type:"vmess", server:$s, server_port:$p, uuid:$u, security:"auto"}')
            ;;
        trojan)
            local password
            password=$(gen_password 16)
            config=$(jq -n --arg s "$server" --argjson p "$port" --arg pw "$password" \
                '{type:"trojan", server:$s, server_port:$p, password:$pw, tls:{enabled:true, server_name:$s}}')
            ;;
        *)
            log_error "不支持的出站类型: $out_type"
            return 1
            ;;
    esac

    # 写入 outbounds.json
    jq --arg id "out_${name}" --arg name "$name" --arg type "$out_type" --arg tag "$tag" \
        --argjson cfg "$config" \
        '.outbounds += [{id:$id, name:$name, type:$type, tag:$tag, builtin:false, config:$cfg}]
         | .strategy_groups[0].outbounds += [$id]' \
        "$OUTBOUNDS_FILE" > "${OUTBOUNDS_FILE}.tmp" && mv "${OUTBOUNDS_FILE}.tmp" "$OUTBOUNDS_FILE"

    # 写单条 outbound 片段
    echo "$config" | jq . > "${SB_CONFIG}/outbound/out_${name}.json"

    # 重载 (reload 失败不致命)
    _load_module "config-generator.sh" || return 1
    generate_config || return 1
    sb_reload || log_warn "sing-box 重载失败"
    log_ok "出站添加成功: ${name} (${tag})"
}

# ============ 列出出站 ============
list_outbounds() {
    echo ""
    echo "========== 出站列表 =========="
    jq -r '.outbounds[] | "\(.id)\t\(.name)\t\(.type)\t\(.tag)"' "$OUTBOUNDS_FILE" 2>/dev/null \
        | awk -F'\t' '{printf "  %-20s %-20s %-12s %s\n", $1, $2, $3, $4}'
    echo ""
}
