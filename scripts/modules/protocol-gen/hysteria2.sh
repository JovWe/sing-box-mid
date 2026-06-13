#===============================================================================
# Hysteria2 协议生成器（纯函数）
#===============================================================================

gen_hysteria2_config() {
    local username="$1"
    local port="${2:-$(gen_random_port 10000 60000)}"

    log_info "生成 Hysteria2 配置: $username (端口 $port)"

    local password domain cert_path key_path
    password=$(gen_password 16)
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")
    cert_path="${SB_CERTS}/${domain}.crt"
    key_path="${SB_CERTS}/${domain}.key"

    # 自签名证书兜底
    if [[ ! -f "$cert_path" ]]; then
        mkdir -p "$SB_CERTS"
        openssl req -x509 -newkey rsa:2048 -keyout "$key_path" -out "$cert_path" \
            -days 3650 -nodes -subj "/CN=${domain}" &>/dev/null || true
    fi

    local tmp="${USERS_FILE}.tmp"
    jq --arg name "$username" \
       --arg pw "$password" \
       --argjson port "$port" \
       --arg tag "inbound-$username" \
       --arg cert "$cert_path" \
       --arg key "$key_path" \
       '.users[$name].credentials.password = $pw
        | .users[$name].inbound.port = $port
        | .users[$name].inbound.listen = "0.0.0.0"
        | .users[$name].inbound.tag = $tag
        | .users[$name].inbound.network = "udp"
        | .users[$name].inbound.cert = $cert
        | .users[$name].inbound.key = $key' \
       "$USERS_FILE" > "$tmp" && mv "$tmp" "$USERS_FILE"

    jq -n --arg tag "inbound-$username" \
          --argjson port "$port" \
          --arg pw "$password" \
          --arg cert "$cert_path" \
          --arg key "$key_path" \
          '{type:"hysteria2", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            users:[{password:$pw}],
            tls:{enabled:true, certificate_path:$cert, key_path:$key, alpn:["h3"]},
            ignore_client_bandwidth:true, brutal:{enabled:true, down_mbps:1000, up_mbps:1000}}' \
       > "${SB_CONFIG}/inbound/${username}.json"

    log_info "Hysteria2 配置已生成: $username"
}

gen_hysteria2_client() {
    local username="$1"
    local password port domain
    password=$(jq -r ".users.\"$username\".credentials.password" "$USERS_FILE")
    port=$(jq -r ".users.\"$username\".inbound.port" "$USERS_FILE")
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")

    local share_link
    share_link="hysteria2://${password}@${domain}:${port}/?insecure=1&alpn=h3#${username}-hysteria2"

    local sing_box
    sing_box=$(jq -n \
        --arg server "$domain" \
        --argjson port "$port" \
        --arg pw "$password" \
        '{type:"hysteria2", tag:"proxy", server:$server, server_port:$port, password:$pw,
          tls:{enabled:true, server_name:$server, insecure:true, alpn:["h3"]},
          up_mbps:1000, down_mbps:1000}')

    local clash
    clash=$(cat << EOF
proxies:
  - name: "${username}-hysteria2"
    type: hysteria2
    server: ${domain}
    port: ${port}
    password: ${password}
    sni: ${domain}
    alpn: [h3]
    skip-cert-verify: true
    udp: true
EOF
)

    jq -n --arg sb "$sing_box" --arg cm "$clash" --arg sl "$share_link" \
        '{"sing-box": $sb, "clash-meta": $cm, "share_link": $sl}'
}

gen_hysteria2_sub() {
    local username="$1"
    gen_hysteria2_client "$username" | jq -r '.share_link'
}
