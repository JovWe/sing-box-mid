# Hysteria2 协议生成器
gen_hysteria2_config() {
    local username="$1" port="${2:-$(gen_random_port)}"
    log_info "生成 Hysteria2: $username (端口 $port)"
    local pw; pw=$(gen_password 16)
    local creds; creds=$(jq -n --arg pw "$pw" '{password:$pw}')
    db_user_set_creds "$username" "$creds"
    db_user_set_inbound "$username" "$port"
    local domain; domain=$(hostname -f 2>/dev/null || get_public_ip)
    local cert="${SB_CERTS}/hysteria2.crt" key="${SB_CERTS}/hysteria2.key"
    [[ -f "$cert" ]] || openssl req -x509 -newkey rsa:2048 -keyout "$key" -out "$cert" -days 3650 -nodes -subj "/CN=${domain}" &>/dev/null || true
    jq -n --arg tag "inbound-$username" --argjson port "$port" \
          --arg pw "$pw" --arg cert "$cert" --arg key "$key" \
          '{type:"hysteria2", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            users:[{password:$pw}],
            tls:{enabled:true, certificate_path:$cert, key_path:$key, alpn:["h3"]}}' \
       > "${SB_CONFIG}/inbound/${username}.json"
    log_ok "Hysteria2 完成: $username"
}
gen_hysteria2_client() {
    local username="$1"
    local row; row=$(sqlite3 "$DB_FILE" -json "SELECT port,credentials FROM users WHERE username='$username';" 2>/dev/null | jq -r '.[0] // empty')
    [[ -z "$row" ]] && { log_error "用户不存在"; return 1; }
    local port; port=$(echo "$row" | jq -r '.port')
    local pw; pw=$(echo "$row" | jq -r '.credentials.password')
    local server; server=$(get_public_ip)
    echo "hysteria2://${pw}@${server}:${port}/?insecure=1&alpn=h3#${username}"
}