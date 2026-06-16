# VLESS + Reality 协议生成器 (纯函数, 由 user-manager 调用)
gen_vless_reality_config() {
    local username="$1" port="${2:-443}"
    log_info "生成 VLESS Reality: $username (端口 $port)"
    local keys; keys=$(gen_reality_keypair)
    local pk; pk=$(echo "$keys" | awk '/PrivateKey/{print $2}')
    local pub; pub=$(echo "$keys" | awk '/PublicKey/{print $2}')
    local uuid sid sni
    uuid=$(gen_uuid); sid=$(gen_short_id); sni="www.microsoft.com"
    local creds; creds=$(jq -n --arg u "$uuid" --arg pk "$pk" --arg pub "$pub" --arg sid "$sid" --arg sni "$sni" \
        '{uuid:$u, private_key:$pk, public_key:$pub, short_id:$sid, server_name:$sni, flow:"xtls-rprx-vision"}')
    db_user_set_creds "$username" "$creds"
    db_user_set_inbound "$username" "$port"
    # 写入站片段 (供 config-generator 拼接)
    jq -n --arg tag "inbound-$username" --argjson port "$port" \
          --arg uuid "$uuid" --arg pk "$pk" --arg sid "$sid" --arg sni "$sni" \
          '{type:"vless", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            users:[{name:"'$username'", uuid:$uuid, flow:"xtls-rprx-vision"}],
            tls:{enabled:true, server_name:$sni,
                 reality:{enabled:true, private_key:$pk, short_id:[$sid]}}}' \
       > "${SB_CONFIG}/inbound/${username}.json"
    log_ok "VLESS Reality 完成: $username"
}
gen_vless_reality_client() {
    local username="$1"
    local row; row=$(sqlite3 "$DB_FILE" -json "SELECT port,credentials FROM users WHERE username='$username';" 2>/dev/null | jq -r '.[0] // empty')
    [[ -z "$row" ]] && { log_error "用户不存在"; return 1; }
    local port; port=$(echo "$row" | jq -r '.port')
    local creds; creds=$(echo "$row" | jq -r '.credentials')
    local server; server=$(get_public_ip)
    local uuid pub sid sni
    uuid=$(echo "$creds" | jq -r '.uuid')
    pub=$(echo "$creds" | jq -r '.public_key')
    sid=$(echo "$creds" | jq -r '.short_id')
    sni=$(echo "$creds" | jq -r '.server_name')
    echo "vless://${uuid}@${server}:${port}?type=tcp&security=reality&flow=xtls-rprx-vision&fp=chrome&sni=${sni}&pbk=${pub}&sid=${sid}#${username}"
}