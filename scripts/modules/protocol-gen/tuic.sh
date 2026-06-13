#===============================================================================
# TUIC v5 协议生成器（纯函数）
#===============================================================================

gen_tuic_config() {
    local username="$1"
    local port="${2:-$(gen_random_port 10000 60000)}"

    log_info "生成 TUIC v5 配置: $username (端口 $port)"

    local uuid password domain cert_path key_path
    uuid=$(gen_uuid)
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
       --arg uuid "$uuid" \
       --arg pw "$password" \
       --argjson port "$port" \
       --arg tag "inbound-$username" \
       --arg cert "$cert_path" \
       --arg key "$key_path" \
       '.users[$name].credentials.uuid = $uuid
        | .users[$name].credentials.password = $pw
        | .users[$name].inbound.port = $port
        | .users[$name].inbound.listen = "0.0.0.0"
        | .users[$name].inbound.tag = $tag
        | .users[$name].inbound.network = "udp"' \
       "$USERS_FILE" > "$tmp" && mv "$tmp" "$USERS_FILE"

    jq -n --arg tag "inbound-$username" \
          --argjson port "$port" \
          --arg uuid "$uuid" \
          --arg pw "$password" \
          --arg cert "$cert_path" \
          --arg key "$key_path" \
          '{type:"tuic", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            users:[{uuid:$uuid, password:$pw}],
            tls:{enabled:true, certificate_path:$cert, key_path:$key, alpn:["h3"]},
            congestion_control:"bbr", auth_timeout:"3s", zero_rtt_handshake:false, heartbeat:"10s"}' \
       > "${SB_CONFIG}/inbound/${username}.json"

    log_info "TUIC v5 配置已生成: $username"
}

gen_tuic_client() {
    local username="$1"
    local uuid password port domain
    uuid=$(jq -r ".users.\"$username\".credentials.uuid" "$USERS_FILE")
    password=$(jq -r ".users.\"$username\".credentials.password" "$USERS_FILE")
    port=$(jq -r ".users.\"$username\".inbound.port" "$USERS_FILE")
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")

    local share_link
    share_link="tuic://${uuid}:${password}@${domain}:${port}/?sni=${domain}&congestion_control=bbr&alpn=h3#${username}-tuic"

    local sing_box
    sing_box=$(jq -n \
        --arg server "$domain" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg pw "$password" \
        '{type:"tuic", tag:"proxy", server:$server, server_port:$port, uuid:$uuid, password:$pw,
          tls:{enabled:true, server_name:$server, alpn:["h3"]},
          congestion_control:"bbr", heartbeat:"10s"}')

    local clash
    clash=$(cat << EOF
proxies:
  - name: "${username}-tuic"
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

    jq -n --arg sb "$sing_box" --arg cm "$clash" --arg sl "$share_link" \
        '{"sing-box": $sb, "clash-meta": $cm, "share_link": $sl}'
}

gen_tuic_sub() {
    local username="$1"
    gen_tuic_client "$username" | jq -r '.share_link'
}
