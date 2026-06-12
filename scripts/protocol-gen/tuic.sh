#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - TUIC v5 协议生成器
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../utils.sh"

gen_tuic_config() {
    local username="$1"
    local port="${2:-$(gen_random_port 10000 60000)}"

    log_info "生成 TUIC v5 配置: $username (端口 $port)"

    local uuid
    uuid=$(gen_uuid)
    local password
    password=$(gen_password 32)
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")

    # 证书
    local cert_path="${SB_CERTS}/${domain}.crt"
    local key_path="${SB_CERTS}/${domain}.key"
    if [[ ! -f "$cert_path" ]]; then
        log_warn "证书不存在, 尝试申请..."
        issue_cert "$domain" || {
            openssl req -x509 -newkey rsa:4096 -keyout "$key_path" -out "$cert_path" \
                -days 365 -nodes -subj "/CN=${domain}" &>/dev/null
        }
    fi

    local user_data
    user_data=$(jq -c ".users.\"$username\"" "$USERS_FILE")

    local updated
    updated=$(echo "$user_data" | jq \
        --arg uuid "$uuid" \
        --arg pw "$password" \
        --arg port "$port" \
        --arg tag "inbound-$username" \
        '.credentials.uuid = $uuid |
         .credentials.password = $pw |
         .tuic.uuid = $uuid |
         .tuic.password = $pw |
         .tuic.cert_path = "'"$cert_path"'" |
         .tuic.key_path = "'"$key_path"'" |
         .inbound.port = ($port | tonumber) |
         .inbound.listen = "0.0.0.0" |
         .inbound.tag = $tag |
         .inbound.network = "udp"')

    local tmp="${USERS_FILE}.tmp"
    jq --arg name "$username" --argjson data "$updated" \
        '.users[$name] = $data' "$USERS_FILE" > "$tmp" && mv "$tmp" "$USERS_FILE"

    local inbound_config
    inbound_config=$(cat << EOF
{
  "type": "tuic",
  "tag": "inbound-${username}",
  "listen": "0.0.0.0",
  "listen_port": ${port},
  "users": [
    {
      "name": "${username}",
      "uuid": "${uuid}",
      "password": "${password}"
    }
  ],
  "tls": {
    "enabled": true,
    "certificate_path": "${cert_path}",
    "key_path": "${key_path}"
  },
  "congestion_control": "bbr",
  "auth_timeout": "3s",
  "zero_rtt_handshake": false,
  "heartbeat": "10s"
}
EOF
)
    echo "$inbound_config" > "${SB_CONFIG}/inbound/${username}.json"
    log_info "TUIC v5 配置已生成: ${username}"
}

gen_tuic_client() {
    local username="$1"
    local user_data
    user_data=$(jq ".users.\"$username\"" "$USERS_FILE")

    local uuid
    uuid=$(echo "$user_data" | jq -r '.credentials.uuid')
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
      "type": "tuic",
      "tag": "proxy",
      "server": "${domain}",
      "server_port": ${port},
      "uuid": "${uuid}",
      "password": "${password}",
      "tls": {
        "enabled": true,
        "server_name": "${domain}"
      },
      "congestion_control": "bbr",
      "heartbeat": "10s"
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
    clash_client=$(cat << EOF
proxies:
  - name: "${username}-${domain}"
    type: tuic
    server: ${domain}
    port: ${port}
    uuid: ${uuid}
    password: ${password}
    sni: ${domain}
    alpn: [h3]
    udp: true
EOF
)

    local share_link
    share_link="tuic://${uuid}:${password}@${domain}:${port}/?sni=${domain}&congestion_control=bbr&alpn=h3#${username}-${domain}"

    cat << RESULT
{
  "sing-box": $(echo "$sb_client" | jq -Rs .),
  "clash-meta": $(echo "$clash_client" | jq -Rs .),
  "share_link": "$share_link"
}
RESULT
}

gen_tuic_sub() {
    local username="$1"
    local user_data
    user_data=$(jq ".users.\"$username\"" "$USERS_FILE")

    local uuid
    uuid=$(echo "$user_data" | jq -r '.credentials.uuid')
    local password
    password=$(echo "$user_data" | jq -r '.credentials.password')
    local port
    port=$(echo "$user_data" | jq -r '.inbound.port')
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")

    echo "tuic://${uuid}:${password}@${domain}:${port}/?sni=${domain}&congestion_control=bbr&alpn=h3#${username}-${domain}"
}