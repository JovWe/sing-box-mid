# ShadowTLS v3 协议生成器
SHADOWTLS_HK="www.bing.com"
gen_shadowtls_config() {
    local username="$1" port="${2:-$(gen_random_port)}"
    log_info "生成 ShadowTLS v3: $username (端口 $port)"
    local pw; pw=$(gen_password 16)
    local creds; creds=$(jq -n --arg pw "$pw" --arg hk "$SHADOWTLS_HK" '{password:$pw, handshake:$hk}')
    db_user_set_creds "$username" "$creds"
    db_user_set_inbound "$username" "$port"
    jq -n --arg tag "inbound-$username" --argjson port "$port" \
          --arg pw "$pw" --arg hk "$SHADOWTLS_HK" \
          '{type:"shadowtls", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            version:3, password:$pw,
            handshake:{server:$hk, server_port:443}}' \
       > "${SB_CONFIG}/inbound/${username}.json"
    log_ok "ShadowTLS v3 完成: $username"
}
gen_shadowtls_client() {
    local username="$1"
    local row; row=$(sqlite3 "$DB_FILE" -json "SELECT port,credentials FROM users WHERE username='$username';" 2>/dev/null | jq -r '.[0] // empty')
    [[ -z "$row" ]] && { log_error "用户不存在"; return 1; }
    local port; port=$(echo "$row" | jq -r '.port')
    local pw; pw=$(echo "$row" | jq -r '.credentials.password')
    local server; server=$(get_public_ip)
    echo "shadowtls://${pw}@${server}:${port}/?version=3&sni=${SHADOWTLS_HK}#${username}"
}