# Sing-box Manager - 主配置生成模块（精简版）
# 提供: generate_config

generate_config() {
    log_info "生成 Sing-box 主配置..."

    # 1) 收集入站片段 (从 core/config/inbound/*.json)
    local inbounds="[]"
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        local piece
        piece=$(jq -c . "$f" 2>/dev/null) || continue
        inbounds=$(echo "$inbounds" | jq --argjson p "$piece" '. + [$p]')
    done < <(find "${SB_CONFIG}/inbound" -maxdepth 1 -name '*.json' -type f 2>/dev/null)

    # 2) 收集出站 (内置 + 自定义)
    local outbounds
    outbounds=$(jq '
        .outbounds as $user
        | ( [ $user[] | select(.builtin != true) | .tag ] + ["direct"] ) as $tags
        | [ {type:"selector", tag:"proxy", outbounds: $tags, default:"direct"} ]
          + [ $user[] | select(.builtin != true) | .config ]
          + [ {type:"direct", tag:"direct"}, {type:"block", tag:"block"} ]
    ' "$OUTBOUNDS_FILE")

    # 3) 组装主配置
    local log_path="${SB_LOGS}/sing-box.log"
    local final_config
    final_config=$(jq -n \
        --argjson inbounds "$inbounds" \
        --argjson outbounds "$outbounds" \
        --arg logs "$log_path" \
        '{
            log: {level: "warn", output: $logs, timestamp: true},
            inbounds: $inbounds,
            outbounds: $outbounds,
            route: {
                final: "proxy",
                auto_detect_interface: true,
                rules: [
                    {rule_set: "geoip-cn",            outbound: "direct"},
                    {rule_set: "geosite-geolocation-cn", outbound: "direct"},
                    {domain_suffix: [".cn"],         outbound: "direct"}
                ],
                rule_set: [
                    {tag: "geoip-cn",                type: "remote", format: "binary",
                     url: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip/cn.srs",
                     download_detour: "direct"},
                    {tag: "geosite-geolocation-cn",  type: "remote", format: "binary",
                     url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs",
                     download_detour: "direct"}
                ]
            }
        }')

    echo "$final_config" | jq . > "$SINGBOX_CONFIG"

    # 4) 验证配置
    local sb_bin="${SB_BIN}/sing-box"
    if [[ -x "$sb_bin" ]]; then
        if ! "$sb_bin" check -c "$SINGBOX_CONFIG" &>/dev/null; then
            log_warn "配置校验失败, 请检查: $SINGBOX_CONFIG"
            "$sb_bin" check -c "$SINGBOX_CONFIG" 2>&1 | head -10 >&2 || true
            return 1
        fi
    fi
    log_ok "Sing-box 配置生成完成"
    return 0
}
