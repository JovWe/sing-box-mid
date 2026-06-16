# TUIC v5 协议生成器
gen_tuic_config() {
    local username="$1" port="${2:-$(gen_random_port)}"
    log_info "生成 TUIC v5: $username (端口 $port)"
    local uuid pw; uuid=$(gen_uuid); pw=$(gen_password 16)
    local creds; creds=$(jq -n --arg u "$uuid" --arg pw "$pw" '{uuid:$u, password:$pw}')
    db_user_set_creds "$username" "$creds"
    db_user_set_inbound "$username" "$port"
    local domain; domain=$(hostname -f 2>/dev/null || get_public_ip)
    local cert="${SB_CERTS}/tuic.crt" key="${SB_CERTS}/tuic.key"
    [[ -f "$cert" ]] || openssl req -x509 -newkey rsa:2048 -keyout "$key" -out "$cert" -days 3650 -nodes -subj "/CN=${domain}" &>/dev/null || true
    jq -n --arg tag "inbound-$username" --argjson port "$port" \
          --arg uuid "$uuid" --arg pw "$pw" --arg cert "$cert" --arg key "$key" \
          '{type:"tuic", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            users:[{uuid:$uuid, password:$pw}],
            tls:{enabled:true, certificate_path:$cert, key_path:$key, alpn:["h3"]},
            congestion_control:"bbr"}' \
       > "${SB_CONFIG}/inbound/${username}.json"
    log_ok "TUIC v5 完成: $username"
}
gen_tuic_client() {
    local username="$1"
    local row; row=$(sqlite3 "$DB_FILE" -json "SELECT port,credentials FROM users WHERE username='$username';" 2>/dev/null | jq -r '.[0] // empty')
    [[ -z "$row" ]] && { log_error "用户不存在"; return 1; }
    local port; port=$(echo "$row" | jq -r '.port')
    local uuid pw; uuid=$(echo "$row" | jq -r '.credentials.uuid')
    pw=$(echo "$row" | jq -r '.credentials.password')
    local server; server=$(get_public_ip)
    echo "tuic://${uuid}:${pw}@${server}:${port}/?congestion_control=bbr&alpn=h3#${username}"
}