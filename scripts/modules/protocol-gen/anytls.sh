#===============================================================================
# AnyTLS 协议生成器（纯函数, 即任意 TLS 流量入口）
#===============================================================================

gen_anytls_config() {
    local username="$1"
    local port="${2:-$(gen_random_port 10000 60000)}"

    log_info "生成 AnyTLS 配置: $username (端口 $port)"

    local password domain cert_path key_path
    password=$(gen_password 16)
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")
    cert_path="${SB_CERTS}/${domain}.crt"
    key_path="${SB_CERTS}/${domain}.key"

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
        | .users[$name].inbound.network = "tcp"' \
       "$USERS_FILE" > "$tmp" && mv "$tmp" "$USERS_FILE"

    jq -n --arg tag "inbound-$username" \
          --argjson port "$port" \
          --arg pw "$password" \
          --arg cert "$cert_path" \
          --arg key "$key_path" \
          --arg domain "$domain" \
          '{type:"trojan", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            users:[{password:$pw}],
            tls:{enabled:true, server_name:$domain, certificate_path:$cert, key_path:$key,
                 alpn:["http/1.1"], min_version:"1.2"}}' \
       > "${SB_CONFIG}/inbound/${username}.json"

    log_info "AnyTLS 配置已生成: $username"
}

gen_anytls_client() {
    local username="$1"
    local password port domain
    password=$(jq -r ".users.\"$username\".credentials.password" "$USERS_FILE")
    port=$(jq -r ".users.\"$username\".inbound.port" "$USERS_FILE")
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")

    local share_link
    share_link="trojan://${password}@${domain}:${port}?sni=${domain}#${username}-anytls"

    local sing_box
    sing_box=$(jq -n \
        --arg server "$domain" \
        --argjson port "$port" \
        --arg pw "$password" \
        '{type:"trojan", tag:"proxy", server:$server, server_port:$port, password:$pw,
          tls:{enabled:true, server_name:$server, insecure:true, alpn:["http/1.1"]}}')

    local clash
    clash=$(cat << EOF
proxies:
  - name: "${username}-anytls"
    type: trojan
    server: ${domain}
    port: ${port}
    password: ${password}
    sni: ${domain}
    alpn: [http/1.1]
    skip-cert-verify: true
    udp: true
EOF
)

    jq -n --arg sb "$sing_box" --arg cm "$clash" --arg sl "$share_link" \
        '{"sing-box": $sb, "clash-meta": $cm, "share_link": $sl}'
}

gen_anytls_sub() {
    local username="$1"
    gen_anytls_client "$username" | jq -r '.share_link'
}
