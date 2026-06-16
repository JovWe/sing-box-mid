# Sing-box Manager - Hysteria2 协议生成器（精简）
# 提供: gen_hysteria2_config
# 端口默认随机 10000-60000

gen_hysteria2_config() {
    local username="$1"
    local port="${2:-$(gen_random_port 10000 60000)}"

    log_info "生成 Hysteria2: $username (端口 $port)"

    local password
    password=$(gen_password 16)

    # 写 users.json
    jq --arg name "$username" --arg pw "$password" --argjson port "$port" \
       '.users[$name].credentials.password = $pw
        | .users[$name].inbound.port = $port
        | .users[$name].inbound.listen = "0.0.0.0"
        | .users[$name].inbound.tag = ("inbound-" + $name)
        | .users[$name].inbound.network = "udp"' \
       "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    # 写 inbound 片段（自签证书 / 或用现有证书）
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")
    local cert="${SB_CERTS}/${domain}.crt"
    local key="${SB_CERTS}/${domain}.key"

    if [[ ! -f "$cert" ]]; then
        mkdir -p "$SB_CERTS"
        openssl req -x509 -newkey rsa:2048 -keyout "$key" -out "$cert" \
            -days 3650 -nodes -subj "/CN=${domain}" &>/dev/null || true
    fi

    jq -n --arg tag "inbound-$username" --argjson port "$port" \
          --arg pw "$password" --arg cert "$cert" --arg key "$key" \
          '{type:"hysteria2", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            users:[{password:$pw}],
            tls:{enabled:true, certificate_path:$cert, key_path:$key, alpn:["h3"]}}' \
       > "${SB_CONFIG}/inbound/${username}.json"

    log_ok "Hysteria2 配置完成: $username"
}
