#===============================================================================
# Sing-box Manager - 出站管理模块（纯函数）
#===============================================================================

# --- 添加出站 ---
add_outbound() {
    local name="${1:-}"
    local out_type="${2:-}"

    if [[ -z "$name" ]]; then
        read -rp "出站名称 (英文, 无空格): " name
    fi
    [[ -z "$name" ]] && { log_error "名称不能为空"; return 1; }

    if [[ -z "$out_type" ]]; then
        echo "可选类型:"
        echo "  1) Shadowsocks"
        echo "  2) VMess"
        echo "  3) VLESS"
        echo "  4) Trojan"
        echo "  5) Hysteria2"
        echo "  6) TUIC"
        echo "  7) WireGuard"
        read -rp "选择 [1-7]: " tchoice
        case "$tchoice" in
            1) out_type="shadowsocks" ;;
            2) out_type="vmess" ;;
            3) out_type="vless" ;;
            4) out_type="trojan" ;;
            5) out_type="hysteria2" ;;
            6) out_type="tuic" ;;
            7) out_type="wireguard" ;;
            *) log_error "无效选择"; return 1 ;;
        esac
    fi

    local server port password uuid method alpn sni auth
    read -rp "服务器地址: " server
    read -rp "端口: " port

    local ob_id="out_${name}"
    local tag_tag="out-${name}"

    # 根据类型收集参数
    local config_json=""
    case "$out_type" in
        shadowsocks)
            read -rp "加密方式 (aes-128-gcm/aes-256-gcm/chacha20-poly1305): " method
            method="${method:-aes-256-gcm}"
            read -rp "密码: " password
            config_json=$(cat << EOF
{"type":"shadowsocks","tag":"${tag_tag}","server":"${server}","server_port":${port},"method":"${method}","password":"${password}"}
EOF
)
            ;;
        vmess)
            read -rp "UUID: " uuid
            read -rp "加密方式 (auto/aes-128-gcm/chacha20-poly1305/zero): " method
            method="${method:-auto}"
            config_json=$(cat << EOF
{"type":"vmess","tag":"${tag_tag}","server":"${server}","server_port":${port},"uuid":"${uuid}","security":"${method}"}
EOF
)
            ;;
        vless)
            read -rp "UUID: " uuid
            read -rp "启用 TLS (y/N): " use_tls
            if [[ "${use_tls,,}" == "y" ]]; then
                read -rp "SNI: " sni
                read -rp "流控 (xtls-rprx-vision, 无则回车): " flow
                if [[ -n "$flow" ]]; then
                    config_json=$(cat << EOF
{"type":"vless","tag":"${tag_tag}","server":"${server}","server_port":${port},"uuid":"${uuid}","flow":"${flow}","tls":{"enabled":true,"server_name":"${sni}","utls":{"enabled":true,"fingerprint":"chrome"}}}
EOF
)
                else
                    config_json=$(cat << EOF
{"type":"vless","tag":"${tag_tag}","server":"${server}","server_port":${port},"uuid":"${uuid}","tls":{"enabled":true,"server_name":"${sni}"}}
EOF
)
                fi
            else
                config_json=$(cat << EOF
{"type":"vless","tag":"${tag_tag}","server":"${server}","server_port":${port},"uuid":"${uuid}"}
EOF
)
            fi
            ;;
        trojan)
            read -rp "密码: " password
            read -rp "SNI: " sni
            config_json=$(cat << EOF
{"type":"trojan","tag":"${tag_tag}","server":"${server}","server_port":${port},"password":"${password}","tls":{"enabled":true,"server_name":"${sni}"}}
EOF
)
            ;;
        hysteria2)
            read -rp "密码/auth: " password
            read -rp "SNI: " sni
            config_json=$(cat << EOF
{"type":"hysteria2","tag":"${tag_tag}","server":"${server}","server_port":${port},"password":"${password}","tls":{"enabled":true,"server_name":"${sni}","insecure":false}}
EOF
)
            ;;
        tuic)
            read -rp "UUID: " uuid
            read -rp "密码: " password
            read -rp "SNI: " sni
            config_json=$(cat << EOF
{"type":"tuic","tag":"${tag_tag}","server":"${server}","server_port":${port},"uuid":"${uuid}","password":"${password}","tls":{"enabled":true,"server_name":"${sni}"},"congestion_control":"bbr"}
EOF
)
            ;;
        wireguard)
            local private_key pubkey peer_endpoint preshared
            read -rp "本地私钥: " private_key
            read -rp "peer 公钥: " pubkey
            read -rp "peer 地址: " peer_endpoint
            read -rp "预共享密钥 (可空): " preshared
            local reserved_str=""
            local local_ip
            read -rp "WireGuard 本地 IP (例如 10.0.0.2): " local_ip
            config_json=$(cat << EOF
{"type":"wireguard","tag":"${tag_tag}","server":"${peer_endpoint%%:*}","server_port":${peer_endpoint##*:},"local_address":["${local_ip}/32"],"private_key":"${private_key}","peer_public_key":"${pubkey}"}
EOF
)
            ;;
        *)
            log_error "不支持的类型: $out_type"
            return 1
            ;;
    esac

    # 写入 outbounds.json
    local tmp
    tmp="${OUTBOUNDS_FILE}.tmp.$(date +%s)"
    jq --arg id "$ob_id" \
       --arg name "$name" \
       --arg type "$out_type" \
       --arg tag "$tag_tag" \
       --argjson cfg "$config_json" \
       '.outbounds += [{"id": $id, "name": $name, "type": $type, "tag": $tag, "builtin": false, "config": $cfg}] |
        .strategy_groups[0].outbounds += [$id]' \
       "$OUTBOUNDS_FILE" > "$tmp" && mv "$tmp" "$OUTBOUNDS_FILE"

    # 生成单独的 outbound 片段文件
    echo "$config_json" | jq . > "${SB_CONFIG}/outbound/${ob_id}.json"

    sb_reload
    log_ok "出站添加成功: ${name} (${tag_tag})"
}

# --- 删除出站 ---
delete_outbound() {
    local ob_id="${1:-}"
    if [[ -z "$ob_id" ]]; then
        list_outbounds
        read -rp "输入要删除的出站 ID: " ob_id
    fi
    [[ -z "$ob_id" ]] && return 1

    if [[ "$ob_id" == "out_direct" ]]; then
        log_error "不能删除默认直连出站"
        return 1
    fi

    if ! jq -e ".outbounds[] | select(.id == \"$ob_id\")" "$OUTBOUNDS_FILE" &>/dev/null; then
        log_error "出站不存在: $ob_id"
        return 1
    fi

    confirm "确认删除出站 $ob_id? " || return 0

    local tmp
    tmp="${OUTBOUNDS_FILE}.tmp.$(date +%s)"
    jq --arg id "$ob_id" \
       '.outbounds = [.outbounds[] | select(.id != $id)] |
        .strategy_groups[0].outbounds = [.strategy_groups[0].outbounds[] | select(. != $id)]' \
       "$OUTBOUNDS_FILE" > "$tmp" && mv "$tmp" "$OUTBOUNDS_FILE"

    rm -f "${SB_CONFIG}/outbound/${ob_id}.json"
    sb_reload
    log_ok "出站已删除: $ob_id"
}

# --- 编辑出站 ---
edit_outbound() {
    local ob_id="${1:-}"
    if [[ -z "$ob_id" ]]; then
        list_outbounds
        read -rp "输入要编辑的出站 ID: " ob_id
    fi

    local entry
    entry=$(jq -c ".outbounds[] | select(.id == \"$ob_id\")" "$OUTBOUNDS_FILE" 2>/dev/null)
    if [[ -z "$entry" || "$entry" == "null" ]]; then
        log_error "出站不存在: $ob_id"
        return 1
    fi

    echo "当前配置:"
    echo "$entry" | jq .
    echo ""
    log_warn "整体重写的 JSON 配置在下面的文件里, 手动编辑后保存:"
    echo "  ${SB_CONFIG}/outbound/${ob_id}.json"
    echo ""
    echo "提示: 你可以直接用 vi 编辑上面的文件, 然后 sb-manager reload 重载。"
}

# --- 列出出站 ---
list_outbounds() {
    echo ""
    echo "========== 出站列表 =========="
    jq -r '.outbounds[] | "\(.id) | \(.name) | \(.type) | tag=\(.tag)"' "$OUTBOUNDS_FILE" 2>/dev/null
    echo ""
}

# --- 策略组管理 ---
manage_strategy_group() {
    echo ""
    echo "当前策略组 (默认 selector):"
    jq '.strategy_groups[0]' "$OUTBOUNDS_FILE"
    echo ""
    echo "1) 修改默认出站"
    echo "2) 返回"
    read -rp "选择: " choice
    case "$choice" in
        1)
            jq -r '.outbounds[].id' "$OUTBOUNDS_FILE"
            read -rp "输入新的默认出站 ID: " new_default
            if jq -e ".outbounds[] | select(.id == \"$new_default\")" "$OUTBOUNDS_FILE" &>/dev/null; then
                json_set "$OUTBOUNDS_FILE" '.strategy_groups[0].default' "\"$new_default\""
                sb_reload
                log_ok "默认出站已修改为: $new_default"
            else
                log_error "ID 不存在"
            fi
            ;;
    esac
}
