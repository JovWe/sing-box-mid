#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - ShadowTLS v3 协议生成器
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utils.sh"

gen_shadowtls_config() {
    local username="$1"
    local port="${2:-$(gen_random_port 10000 60000)}"

    log_info "生成 ShadowTLS v3 配置: $username (端口 $port)"

    local password
    password=$(gen_password 32)
    local sni="${SHADOWTLS_SNI:-www.microsoft.com}"
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")

    local user_data
    user_data=$(jq -c ".users.\"$username\"" "$USERS_FILE")

    local updated
    updated=$(echo "$user_data" | jq \
        --arg pw "$password" \
        --arg sni "$sni" \
        --arg port "$port" \
        --arg tag "inbound-$username" \
        '.credentials.password = $pw |
         .shadowtls.password = $pw |
         .shadowtls.sni = $sni |
         .inbound.port = ($port | tonumber) |
         .inbound.listen = "0.0.0.0" |
         .inbound.tag = $tag |
         .inbound.network = "tcp"')

    local tmp="${USERS_FILE}.tmp"
    jq --arg name "$username" --argjson data "$updated" \
        '.users[$name] = $data' "$USERS_FILE" > "$tmp" && mv "$tmp" "$USERS_FILE"

    local inbound_config
    inbound_config=$(cat << EOF
{
  "type": "shadowtls",
  "tag": "inbound-${username}",
  "listen": "0.0.0.0",
  "listen_port": ${port},
  "version": 3,
  "users": [
    {
      "name": "${username}",
      "password": "${password}"
    }
  ],
  "handshake": {
    "server": "${sni}",
    "server_port": 443
  },
  "strict_mode": true
}
EOF
)
    echo "$inbound_config" > "${SB_CONFIG}/inbound/${username}.json"
    log_info "ShadowTLS v3 配置已生成: ${username}"
}

gen_shadowtls_client() {
    local username="$1"
    local user_data
    user_data=$(jq ".users.\"$username\"" "$USERS_FILE")

    local password
    password=$(echo "$user_data" | jq -r '.credentials.password')
    local sni
    sni=$(echo "$user_data" | jq -r '.shadowtls.sni')
    local port
    port=$(echo "$user_data" | jq -r '.inbound.port')
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")

    # Sing-box
    local sb_client
    sb_client=$(cat << EOF
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
      "type": "shadowtls",
      "tag": "proxy",
      "server": "${domain}",
      "server_port": ${port},
      "version": 3,
      "password": "${password}",
      "tls": {
        "enabled": true,
        "server_name": "${sni}"
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      { "domain_suffix": [".cn"], "outbound": "direct" }
    ],
    "final": "proxy"
  }
}
EOF
)

    # Clash Meta
    local clash_client
    clash_client="proxies: [] # ShadowTLS 暂未被 Clash Meta 完整支持"

    local share_link
    share_link="shadowtls://${password}@${domain}:${port}/?sni=${sni}&version=3#${username}-${domain}"

    cat << RESULT
{
  "sing-box": $(echo "$sb_client" | jq -Rs .),
  "clash-meta": $(echo "$clash_client" | jq -Rs .),
  "share_link": "$share_link"
}
RESULT
}

gen_shadowtls_sub() {
    local username="$1"
    local user_data
    user_data=$(jq ".users.\"$username\"" "$USERS_FILE")

    local password
    password=$(echo "$user_data" | jq -r '.credentials.password')
    local sni
    sni=$(echo "$user_data" | jq -r '.shadowtls.sni')
    local port
    port=$(echo "$user_data" | jq -r '.inbound.port')
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")

    echo "shadowtls://${password}@${domain}:${port}/?sni=${sni}&version=3#${username}-${domain}"
}