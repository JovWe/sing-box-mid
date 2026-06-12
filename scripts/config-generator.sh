#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - 配置生成器
# 从 users.json + outbounds.json 生成完整的 sing-box config.json
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

generate_config() {
    log_info "生成 Sing-box 主配置文件..."

    # 收集所有入站
    local inbounds_json="["
    local first_inbound=true

    if [[ -f "$USERS_FILE" ]]; then
        jq -r '.users | keys[]' "$USERS_FILE" 2>/dev/null | while read -r username; do
            local status
            status=$(jq -r ".users.\"$username\".status" "$USERS_FILE")
            if [[ "$status" != "active" ]]; then
                continue
            fi

            local inbound_file="${SB_CONFIG}/inbound/${username}.json"
            if [[ -f "$inbound_file" ]]; then
                echo "$inbound_file"
            fi
        done
    fi > /tmp/sb_inbound_files.txt

    # 构建入站 JSON
    local inbounds_json="["
    local first=true
    while IFS= read -r f; do
        if [[ -f "$f" ]]; then
            if $first; then first=false; else inbounds_json+=","; fi
            inbounds_json+=$(cat "$f")
        fi
    done < /tmp/sb_inbound_files.txt
    inbounds_json+="]"
    rm -f /tmp/sb_inbound_files.txt

    # 构建出站 JSON
    local outbounds_json="["
    # 内置直连出站
    outbounds_json+='{"type":"direct","tag":"direct"},'
    outbounds_json+='{"type":"dns","tag":"dns-out"},'
    outbounds_json+='{"type":"block","tag":"block"}'

    if [[ -f "$OUTBOUNDS_FILE" ]]; then
        jq -c '.outbounds[]' "$OUTBOUNDS_FILE" 2>/dev/null | while read -r ob; do
            local builtin
            builtin=$(echo "$ob" | jq -r '.builtin')
            if [[ "$builtin" == "true" ]]; then
                continue
            fi
            # 从 outbound config 片段读取
            local ob_id
            ob_id=$(echo "$ob" | jq -r '.id')
            local ob_file="${SB_CONFIG}/outbound/${ob_id}.json"
            if [[ -f "$ob_file" ]]; then
                echo ",$(cat "$ob_file")"
            fi
        done
    fi >> /tmp/sb_outbound_extra.txt

    while IFS= read -r line; do
        outbounds_json+="$line"
    done < /tmp/sb_outbound_extra.txt
    outbounds_json+="]"
    rm -f /tmp/sb_outbound_extra.txt

    # 构建策略组
    local strategy_tag="sg-default"
    local strategy_default="direct"
    local strategy_outbounds='["direct"]'

    if [[ -f "$OUTBOUNDS_FILE" ]]; then
        strategy_tag=$(jq -r '.strategy_groups[0].id // "sg-default"' "$OUTBOUNDS_FILE")
        strategy_default=$(jq -r '.strategy_groups[0].default // "out_direct"' "$OUTBOUNDS_FILE")
        # 转换策略组中的 outbound id 为 tag
        local sg_tags="["
        local sg_first=true
        jq -r '.strategy_groups[0].outbounds[]' "$OUTBOUNDS_FILE" 2>/dev/null | while read -r ob_id; do
            if $sg_first; then sg_first=false; else sg_tags+=","; fi
            if [[ "$ob_id" == "out_direct" ]]; then
                sg_tags+='"direct"'
            else
                sg_tags+="\"out-${ob_id}\""
            fi
        done
        sg_tags+="]"
        strategy_outbounds="$sg_tags"
    fi

    # 生成完整配置
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.domain' '')

    cat > "$SINGBOX_CONFIG" << EOF
{
  "log": {
    "level": "warn",
    "output": "${SB_LOGS}/sing-box.log",
    "timestamp": true
  },
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "external_ui": "",
      "secret": "",
      "default_mode": "rule"
    }
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "tls://8.8.8.8",
        "address_resolver": "dns-resolver",
        "strategy": "ipv4_only",
        "detour": "${strategy_tag}"
      },
      {
        "tag": "dns-local",
        "address": "https://223.5.5.5/dns-query",
        "address_resolver": "dns-resolver",
        "strategy": "ipv4_only",
        "detour": "direct"
      },
      {
        "tag": "dns-resolver",
        "address": "223.5.5.5",
        "detour": "direct"
      }
    ],
    "rules": [
      {
        "rule_set": "geosite-geolocation-cn",
        "server": "dns-local"
      },
      {
        "domain_suffix": ["cn"],
        "server": "dns-local"
      }
    ],
    "final": "dns-remote",
    "strategy": "ipv4_only"
  },
  "inbounds": ${inbounds_json},
  "outbounds": [
    {
      "type": "selector",
      "tag": "${strategy_tag}",
      "outbounds": ${strategy_outbounds},
      "default": "${strategy_default}"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "dns",
      "tag": "dns-out"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "dns-out"
      },
      {
        "rule_set": "geoip-cn",
        "outbound": "direct"
      },
      {
        "rule_set": "geosite-geolocation-cn",
        "outbound": "direct"
      },
      {
        "domain_suffix": [".cn"],
        "outbound": "direct"
      }
    ],
    "rule_set": [
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip/cn.srs",
        "download_detour": "direct"
      },
      {
        "tag": "geosite-geolocation-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs",
        "download_detour": "direct"
      }
    ],
    "final": "${strategy_tag}",
    "auto_detect_interface": true
  }
}
EOF

    # 验证配置
    if command -v sing-box &>/dev/null || [[ -x "${SB_BIN}/sing-box" ]]; then
        local sb_bin="${SB_BIN}/sing-box"
        if ! "$sb_bin" check -c "$SINGBOX_CONFIG" &>/dev/null; then
            log_error "Sing-box 配置验证失败, 请检查 ${SINGBOX_CONFIG}"
            "$sb_bin" check -c "$SINGBOX_CONFIG" 2>&1 | tail -5
            return 1
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