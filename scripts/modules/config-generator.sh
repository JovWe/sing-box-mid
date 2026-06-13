#===============================================================================
# Sing-box Manager - 主配置生成器（纯函数）
# 从 users.json + outbounds.json 组装完整 sing-box config.json
#===============================================================================

generate_config() {
    log_info "生成 Sing-box 主配置文件..."

    # ---- 入站: 遍历 active 用户, 读取每个 username.json ----
    local inbounds_json="[]"
    local temp_inbounds="[]"
    local first=1
    while IFS= read -r username; do
        [[ -z "$username" || "$username" == "null" ]] && continue
        local status
        status=$(jq -r ".users.\"$username\".status // \"inactive\"" "$USERS_FILE")
        [[ "$status" != "active" ]] && continue

        local inbound_file="${SB_CONFIG}/inbound/${username}.json"
        if [[ -f "$inbound_file" ]]; then
            local piece
            piece=$(cat "$inbound_file" | jq -c .)
            if [[ $first -eq 1 ]]; then
                temp_inbounds="[$piece]"
                first=0
            else
                temp_inbounds=$(echo "$temp_inbounds" | jq -c --argjson p "$piece" '. + [$p]')
            fi
        fi
    done < <(jq -r '.users | keys[]' "$USERS_FILE" 2>/dev/null)
    inbounds_json="$temp_inbounds"

    # ---- 出站: 根据 outbounds.json 生成 ----
    local outbounds_json="["
    outbounds_json+='{"type":"selector","tag":"proxy","outbounds":[],"default":"direct"},'
    outbounds_json+='{"type":"direct","tag":"direct"},'
    outbounds_json+='{"type":"dns","tag":"dns-out"},'
    outbounds_json+='{"type":"block","tag":"block"}'

    # 收集自定义出站并构建 selector
    local extra_tags="["
    local extra_first=1
    local ob_count=0
    while IFS= read -r ob_line; do
        [[ -z "$ob_line" || "$ob_line" == "null" ]] && continue
        local ob_tag ob_builtin
        ob_tag=$(echo "$ob_line" | jq -r '.tag')
        ob_builtin=$(echo "$ob_line" | jq -r '.builtin // false')

        if [[ "$ob_builtin" == "true" ]]; then
            # direct 等已在上面
            if [[ $extra_first -eq 1 ]]; then
                extra_tags="\"direct\""
                extra_first=0
            else
                extra_tags="$extra_tags,\"direct\""
            fi
            continue
        fi

        # 非内置出站, 写入片段
        ob_count=$((ob_count + 1))
        local ob_file="${SB_CONFIG}/outbound/$(echo "$ob_line" | jq -r '.id').json"
        # 重新插入到 outbounds 头部 selector 之前
        if [[ -f "$ob_file" ]]; then
            local cfg
            cfg=$(cat "$ob_file" | jq -c .)
            # 拼接到 selector 之后, direct 之前 —— 简化方式: 直接在末尾附加
            outbounds_json=$(echo "$outbounds_json" | jq -c --argjson extra "$cfg" '.[:-1] + [$extra] + [last]')
            # 让它可被 selector 选中
            if [[ $extra_first -eq 1 ]]; then
                extra_tags="\"$ob_tag\""
                extra_first=0
            else
                extra_tags="$extra_tags,\"$ob_tag\""
            fi
        fi
    done < <(jq -c '.outbounds[]' "$OUTBOUNDS_FILE" 2>/dev/null)
    extra_tags="$extra_tags]"

    # 让 selector 的 outbounds 先放自定义, 最后放 direct
    local selector_outbounds
    if [[ $ob_count -gt 0 ]]; then
        # 将 extra_tags 作为 list, 确保包含 direct
        selector_outbounds=$(echo "$extra_tags" | jq -c 'unique_by(. // "direct")' || echo '["direct"]')
    else
        selector_outbounds='["direct"]'
    fi
    # 在 selector_outbounds 中强制添加 direct
    selector_outbounds=$(echo "$selector_outbounds" | jq -c 'if (. | index("direct")) then . else . + ["direct"] end')

    # 重新装配 outbounds: 第一个元素 selector 的 outbounds 字段要更新
    outbounds_json=$(echo "$outbounds_json" | jq -c \
        --argjson so "$selector_outbounds" \
        '.[0].outbounds = $so')
    # 闭合
    outbounds_json=$(echo "$outbounds_json" | jq -c '.')

    # ---- DNS & 路由 ----
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.domain' '')

    # 组装最终 config
    local config
    config=$(jq -n \
        --argjson inbounds "$inbounds_json" \
        --argjson outbounds "$outbounds_json" \
        --arg logs "${SB_LOGS}/sing-box.log" \
        '{
            "log": {"level": "warn", "output": $logs, "timestamp": true},
            "dns": {
                "servers": [
                    {"tag": "dns-remote", "address": "tls://8.8.8.8", "address_resolver": "dns-resolver", "strategy": "ipv4_only", "detour": "proxy"},
                    {"tag": "dns-local", "address": "https://223.5.5.5/dns-query", "address_resolver": "dns-resolver", "strategy": "ipv4_only", "detour": "direct"},
                    {"tag": "dns-resolver", "address": "223.5.5.5", "detour": "direct"}
                ],
                "rules": [
                    {"rule_set": "geosite-geolocation-cn", "server": "dns-local"},
                    {"domain_suffix": ["cn"], "server": "dns-local"}
                ],
                "final": "dns-remote",
                "strategy": "ipv4_only"
            },
            "inbounds": $inbounds,
            "outbounds": $outbounds,
            "route": {
                "rules": [
                    {"protocol": "dns", "outbound": "dns-out"},
                    {"rule_set": "geoip-cn", "outbound": "direct"},
                    {"rule_set": "geosite-geolocation-cn", "outbound": "direct"},
                    {"domain_suffix": [".cn"], "outbound": "direct"}
                ],
                "rule_set": [
                    {"tag": "geoip-cn", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip/cn.srs", "download_detour": "direct"},
                    {"tag": "geosite-geolocation-cn", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs", "download_detour": "direct"}
                ],
                "final": "proxy",
                "auto_detect_interface": true
            }
        }' 2>/dev/null)

    if [[ -z "$config" ]]; then
        log_error "配置生成失败"
        return 1
    fi

    echo "$config" | jq . > "$SINGBOX_CONFIG"

    # 验证配置
    if [[ -x "${SB_BIN}/sing-box" ]]; then
        if ! "${SB_BIN}/sing-box" check -c "$SINGBOX_CONFIG" &>/dev/null; then
            log_warn "配置校验失败, 请手动检查: ${SINGBOX_CONFIG}"
            "${SB_BIN}/sing-box" check -c "$SINGBOX_CONFIG" 2>&1 | head -10 >&2 || true
        fi
    fi

    log_info "Sing-box 配置生成完成: ${SINGBOX_CONFIG}"
    return 0
}

# --- 单独验证配置 ---
validate_config() {
    if [[ -x "${SB_BIN}/sing-box" ]]; then
        "${SB_BIN}/sing-box" check -c "$SINGBOX_CONFIG" 2>&1
    else
        log_error "Sing-box 未安装"
        return 1
    fi
}
