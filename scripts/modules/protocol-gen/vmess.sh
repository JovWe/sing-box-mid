# VMess 协议生成器
gen_vmess_config() {
    local username="$1" port="${2:-$(gen_random_port)}"
    log_info "生成 VMess: $username (端口 $port)"
    local uuid; uuid=$(gen_uuid)
    local creds; creds=$(jq -n --arg u "$uuid" '{uuid:$u, security:"auto"}')
    db_user_set_creds "$username" "$creds"
    db_user_set_inbound "$username" "$port"
    jq -n --arg tag "inbound-$username" --argjson port "$port" --arg uuid "$uuid" \
          '{type:"vmess", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            users:[{name:"'$username'", uuid:$uuid, alterId:0, security:"auto"}]}' \
       > "${SB_CONFIG}/inbound/${username}.json"
    log_ok "VMess 完成: $username"
}
gen_vmess_client() {
    local username="$1"
    local row; row=$(sqlite3 "$DB_FILE" -json "SELECT port,credentials FROM users WHERE username='$username';" 2>/dev/null | jq -r '.[0] // empty')
    [[ -z "$row" ]] && { log_error "用户不存在"; return 1; }
    local port; port=$(echo "$row" | jq -r '.port')
    local uuid; uuid=$(echo "$row" | jq -r '.credentials.uuid')
    local server; server=$(get_public_ip)
    echo "vmess://$(echo "{\"v\":\"2\",\"ps\":\"$username\",\"add\":\"$server\",\"port\":\"$port\",\"id\":\"$uuid\",\"aid\":\"0\",\"net\":\"tcp\",\"type\":\"none\",\"security\":\"auto\"}" | base64 -w0 | base64 -w0 2>/dev/null || echo "${uuid}@${server}:${port}")"
}