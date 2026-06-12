#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - AnyTLS 协议生成器
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utils.sh"

gen_anytls_config() {
    local username="$1"
    local port="${2:-$(gen_random_port 10000 60000)}"

    log_info "生成 AnyTLS 配置: $username (端口 $port)"

    local password
    password=$(gen_password 32)
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")

    # 证书
    local cert_path="${SB_CERTS}/${domain}.crt"
    local key_path="${SB_CERTS}/${domain}.key"
    if [[ ! -f "$cert_path" ]]; then
        issue_cert "$domain" || {
            openssl req -x509 -newkey rsa:4096 -keyout "$key_path" -out "$cert_path" \
                -days 365 -nodes -subj "/CN=${domain}" &>/dev/null
        }
    fi

    local user_data
    user_data=$(jq -c ".users.\"$username\"" "$USERS_FILE")

    local updated
    updated=$(echo "$user_data" | jq \
        --arg pw "$password" \
        --arg port "$port" \
        --arg tag "inbound-$username" \
        '.credentials.password = $pw |
         .anytls.password = $pw |
         .anytls.cert_path = "'"$cert_path"'" |
         .anytls.key_path = "'"$key_path"'" |
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
  "type": "anytls",
  "tag": "inbound-${username}",
  "listen": "0.0.0.0",
  "listen_port": ${port},
  "users": [
    {
      "name": "${username}",
      "password": "${password}"
    }
  ],
  "tls": {
    "enabled": true,
    "certificate_path": "${cert_path}",
    "key_path": "${key_path}"
  }
}
EOF
)
    echo "$inbound_config" > "${SB_CONFIG}/inbound/${username}.json"
    log_info "AnyTLS 配置已生成: ${username}"
}

gen_anytls_client() {
    local username="$1"
    local user_data
    user_data=$(jq ".users.\"$username\"" "$USERS_FILE")

    local password
    password=$(echo "$user_data" | jq -r '.credentials.password')
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
      "type": "anytls",
      "tag": "proxy",
      "server": "${domain}",
      "server_port": ${port},
      "password": "${password}",
      "tls": {
        "enabled": true,
        "server_name": "${domain}"
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

    # Clash Meta (AnyTLS may not be supported by all clients)
    local clash_client
    clash_client="proxies: [] # AnyTLS 暂未被 Clash Meta 完整支持"

    local share_link
    share_link="anytls://${password}@${domain}:${port}/?sni=${domain}#${username}-${domain}"

    cat << RESULT
{
  "sing-box": $(echo "$sb_client" | jq -Rs .),
  "clash-meta": $(echo "$clash_client" | jq -Rs .),
  "share_link": "$share_link"
}
RESULT
}

gen_anytls_sub() {
    local username="$1"
    local user_data
    user_data=$(jq ".users.\"$username\"" "$USERS_FILE")

    local password
    password=$(echo "$user_data" | jq -r '.credentials.password')
    local port
    port=$(echo "$user_data" | jq -r '.inbound.port')
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")

    echo "anytls://${password}@${domain}:${port}/?sni=${domain}#${username}-${domain}"
}