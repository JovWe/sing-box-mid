# Sing-box Manager - 配置生成器
# 依赖 db.sh 已 source

generate_config() {
    log_info "生成主配置..."

    local global_outbound
    global_outbound=$(db_setting_get "global_outbound")
    [[ -z "$global_outbound" ]] && global_outbound="proxy"

    # ---- 1. 收集入站 ----
    local inbounds_json="[]"
    if ls "${SB_CONFIG}/inbound/"*.json &>/dev/null 2>&1; then
        for f in "${SB_CONFIG}/inbound/"*.json; do
            local content; content=$(cat "$f")
            inbounds_json=$(echo "$inbounds_json" | jq --argjson ib "$content" '. + [$ib]')
        done
    fi

    # ---- 2. 收集出站 ----
    # 内置出站
    local outbounds_json="[]"
    outbounds_json=$(echo "$outbounds_json" | jq '. + [{"type":"direct","tag":"direct"}, {"type":"block","tag":"block"}]')

    # 用户自定义出站 (从 SQLite)
    while IFS='|' read -r type tag cfg; do
        local parsed
        parsed=$(echo "$cfg" 2>/dev/null | jq 'del(.tag)' 2>/dev/null || echo "{}")
        local entry
        entry=$(echo "$parsed" | jq --arg type "$type" --arg tag "$tag" '.type = $type | .tag = $tag')
        outbounds_json=$(echo "$outbounds_json" | jq --argjson e "$entry" '. + [$e]')
    done < <(sqlite3 "$DB_FILE" "SELECT type, tag, config FROM outbounds WHERE builtin=0;")

    # 代理 selector (从 SQLite 读取配置)
    local sel_config
    sel_config=$(sqlite3 "$DB_FILE" "SELECT config FROM outbounds WHERE tag='proxy';" 2>/dev/null)
    if [[ -z "$sel_config" ]]; then
        sel_config='{"outbounds":["direct"],"default":"direct"}'
    fi
    local sel_default; sel_default=$(echo "$sel_config" | jq -r '.default // "direct"')
    local sel_obs; sel_obs=$(echo "$sel_config" | jq -c '.outbounds // ["direct"]')
    local sel_entry
    sel_entry=$(jq -n --argjson obs "$sel_obs" --arg def "$sel_default" \
        '{type:"selector", tag:"proxy", outbounds:$obs, default:$def}')
    outbounds_json=$(echo "$outbounds_json" | jq --argjson e "$sel_entry" '. + [$e]')

    # ---- 3. 路由 ----
    local route_json
    route_json=$(jq -n --arg final "$global_outbound" '{
        final: $final,
        auto_detect_interface: true,
        rules: [
            {"protocol": "dns", "outbound": "dns-out"},
            {"rule_set": "geoip-cn", "outbound": "direct"},
            {"rule_set": "geosite-geolocation-cn", "outbound": "direct"},
            {"domain_suffix": [".cn"], "outbound": "direct"}
        ],
        rule_set: [
            {"tag": "geoip-cn", "type": "remote", "format": "binary",
             "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip/cn.srs",
             "download_detour": "direct"},
            {"tag": "geosite-geolocation-cn", "type": "remote", "format": "binary",
             "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs",
             "download_detour": "direct"}
        ]
    }')

    # ---- 4. DNS ----
    local dns_json
    dns_json=$(jq -n '{
        servers: [
            {"tag": "dns-remote", "address": "https://1.1.1.1/dns-query", "detour": "proxy"},
            {"tag": "dns-direct", "address": "https://223.5.5.5/dns-query", "detour": "direct"},
            {"tag": "dns-resolver", "address": "local", "detour": "direct"}
        ],
        rules: [
            {"outbound": "any", "server": "dns-remote"},
            {"rule_set": "geoip-cn", "server": "dns-direct"},
            {"rule_set": "geosite-geolocation-cn", "server": "dns-direct"}
        ],
        final: "dns-remote",
        strategy: "prefer_ipv4"
    }')

    # ---- 5. 组装 ----
    local config
    config=$(jq -n \
        --argjson inbounds "$inbounds_json" \
        --argjson outbounds "$outbounds_json" \
        --argjson route "$route_json" \
        --argjson dns "$dns_json" \
        '{
            log: {
                level: "warn",
                output: "/opt/sb/logs/sing-box.log",
                timestamp: true
            },
            dns: $dns,
            inbounds: $inbounds,
            outbounds: $outbounds,
            route: $route
        }')

    # 输出
    mkdir -p "$(dirname "$CONFIG_FILE")"
    echo "$config" > "$CONFIG_FILE"
    log_ok "配置已生成: $CONFIG_FILE"
}