# Sing-box Manager - TUIC v5 协议生成器（精简）
# 提供: gen_tuic_config
# 端口默认随机 10000-60000

gen_tuic_config() {
    local username="$1"
    local port="${2:-$(gen_random_port 10000 60000)}"

    log_info "生成 TUIC v5: $username (端口 $port)"

    local uuid password
    uuid=$(gen_uuid)
    password=$(gen_password 16)

    # 证书
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")
    local cert="${SB_CERTS}/${domain}.crt"
    local key="${SB_CERTS}/${domain}.key"
    if [[ ! -f "$cert" ]]; then
        mkdir -p "$SB_CERTS"
        openssl req -x509 -newkey rsa:2048 -keyout "$key" -out "$cert" \
            -days 3650 -nodes -subj "/CN=${domain}" &>/dev/null || true
    fi

    # 写 users.json
    jq --arg name "$username" --arg uuid "$uuid" --arg pw "$password" --argjson port "$port" \
       '.users[$name].credentials.uuid = $uuid
        | .users[$name].credentials.password = $pw
        | .users[$name].inbound.port = $port
        | .users[$name].inbound.listen = "0.0.0.0"
        | .users[$name].inbound.tag = ("inbound-" + $name)
        | .users[$name].inbound.network = "udp"' \
       "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    # 写 inbound 片段
    jq -n --arg tag "inbound-$username" --argjson port "$port" \
          --arg uuid "$uuid" --arg pw "$password" --arg cert "$cert" --arg key "$key" \
          '{type:"tuic", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            users:[{uuid:$uuid, password:$pw}],
            tls:{enabled:true, certificate_path:$cert, key_path:$key, alpn:["h3"]},
            congestion_control:"bbr"}' \
       > "${SB_CONFIG}/inbound/${username}.json"

    log_ok "TUIC v5 配置完成: $username"
}
