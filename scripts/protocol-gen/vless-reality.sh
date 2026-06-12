#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - VLESS + Reality 协议生成器
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utils.sh"

# --- 生成 VLESS + Reality 配置 ---
# 参数: username
gen_vless_reality_config() {
    local username="$1"
    local port="${2:-$(gen_random_port 443 443)}"  # 默认 443

    log_info "生成 VLESS + Reality 配置: $username (端口 $port)"

    # 生成密钥对
    local reality_keys
    reality_keys=$(gen_reality_keypair)
    local private_key
    private_key=$(echo "$reality_keys" | grep "PrivateKey:" | awk '{print $2}')
    local public_key
    public_key=$(echo "$reality_keys" | grep "PublicKey:" | awk '{print $2}')

    # 生成其他参数
    local uuid
    uuid=$(gen_uuid)
    local short_id
    short_id=$(gen_short_id)
    local server_name="${REALITY_SERVER_NAME:-www.microsoft.com}"
    local dest="${REALITY_DEST:-${server_name}:443}"

    # 读取用户数据
    local user_data
    user_data=$(jq -c ".users.\"$username\"" "$USERS_FILE")

    # 更新用户数据
    local updated
    updated=$(echo "$user_data" | jq \
        --arg uuid "$uuid" \
        --arg pk "$private_key" \
        --arg pub "$public_key" \
        --arg sid "$short_id" \
        --arg sni "$server_name" \
        --arg dest "$dest" \
        --arg port "$port" \
        --arg tag "inbound-$username" \
        '.credentials.uuid = $uuid |
         .credentials.flow = "xtls-rprx-vision" |
         .reality.private_key = $pk |
         .reality.public_key = $pub |
         .reality.short_id = $sid |
         .reality.server_name = $sni |
         .reality.dest = $dest |
         .inbound.port = ($port | tonumber) |
         .inbound.listen = "0.0.0.0" |
         .inbound.tag = $tag |
         .inbound.network = "tcp"')

    # 写回
    local tmp="${USERS_FILE}.tmp"
    jq --arg name "$username" --argjson data "$updated" \
        '.users[$name] = $data' "$USERS_FILE" > "$tmp" && mv "$tmp" "$USERS_FILE"

    # 生成入站配置片段
    local inbound_config
    inbound_config=$(cat << INBOUND_EOF
{
  "type": "vless",
  "tag": "inbound-${username}",
  "listen": "0.0.0.0",
  "listen_port": ${port},
  "users": [
    {
      "name": "${username}",
      "uuid": "${uuid}",
      "flow": "xtls-rprx-vision"
    }
  ],
  "tls": {
    "enabled": true,
    "server_name": "${server_name}",
    "reality": {
      "enabled": true,
      "private_key": "${private_key}",
      "short_id": ["${short_id}"]
    }
  },
  "multiplex": {
    "enabled": true,
    "padding": true,
    "brutal": {
      "enabled": true,
      "up_mbps": 1000,
      "down_mbps": 1000
    }
  }
}
INBOUND_EOF
)
    echo "$inbound_config" > "${SB_CONFIG}/inbound/${username}.json"

    log_info "VLESS + Reality 配置已生成: ${username}"
    echo "$uuid"
}

# --- 生成 VLESS Reality 客户端配置 ---
gen_vless_reality_client() {
    local username="$1"
    local user_data
    user_data=$(jq ".users.\"$username\"" "$USERS_FILE")

    local uuid
    uuid=$(echo "$user_data" | jq -r '.credentials.uuid')
    local public_key
    public_key=$(echo "$user_data" | jq -r '.reality.public_key')
    local short_id
    short_id=$(echo "$user_data" | jq -r '.reality.short_id')
    local server_name
    server_name=$(echo "$user_data" | jq -r '.reality.server_name')
    local port
    port=$(echo "$user_data" | jq -r '.inbound.port')
    local server_ip
    server_ip=$(get_public_ip)
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$server_ip")

    # --- Sing-box 客户端配置 ---
    local sb_client
    sb_client=$(cat << SB_EOF
{
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "${domain}",
      "server_port": ${port},
      "uuid": "${uuid}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${server_name}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "${public_key}",
          "short_id": "${short_id}"
        }
      },
      "multiplex": {
        "enabled": true,
        "protocol": "h2mux",
        "max_connections": 4,
        "min_streams": 4
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "domain_suffix": [".cn"],
        "outbound": "direct"
      }
    ],
    "final": "proxy"
  }
}
SB_EOF
)

    # --- Clash Meta 客户端配置 ---
    local clash_client
    clash_client=$(cat << CLASH_EOF
proxies:
  - name: "${username}-${domain}"
    type: vless
    server: ${domain}
    port: ${port}
    uuid: ${uuid}
    flow: xtls-rprx-vision
    tls: true
    client-fingerprint: chrome
    servername: ${server_name}
    reality-opts:
      public-key: ${public_key}
      short-id: ${short_id}
    udp: true
    xudp: true
CLASH_EOF
)

    # --- V2RayN / Nekoray 分享链接 ---
    # vless://uuid@server:port?type=tcp&security=reality&flow=xtls-rprx-vision&fp=chrome&sni=server_name&pbk=public_key&sid=short_id#name
    local share_link
    share_link="vless://${uuid}@${domain}:${port}?type=tcp&security=reality&flow=xtls-rprx-vision&fp=chrome&sni=${server_name}&pbk=${public_key}&sid=${short_id}#${username}-${domain}"

    # 输出
    cat << RESULT
{
  "sing-box": $(echo "$sb_client" | jq -Rs .),
  "clash-meta": $(echo "$clash_client" | jq -Rs .),
  "share_link": "$share_link"
}
RESULT
}

# --- 生成 VLESS Reality 订阅 ---
gen_vless_reality_sub() {
    local username="$1"
    local user_data
    user_data=$(jq ".users.\"$username\"" "$USERS_FILE")

    local uuid
    uuid=$(echo "$user_data" | jq -r '.credentials.uuid')
    local public_key
    public_key=$(echo "$user_data" | jq -r '.reality.public_key')
    local short_id
    short_id=$(echo "$user_data" | jq -r '.reality.short_id')
    local server_name
    server_name=$(echo "$user_data" | jq -r '.reality.server_name')
    local port
    port=$(echo "$user_data" | jq -r '.inbound.port')
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")

    local share_link
    share_link="vless://${uuid}@${domain}:${port}?type=tcp&security=reality&flow=xtls-rprx-vision&fp=chrome&sni=${server_name}&pbk=${public_key}&sid=${short_id}#${username}-${domain}"
    echo "$share_link"
}