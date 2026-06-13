#===============================================================================
# VLESS + Reality 协议生成器（纯函数）
#===============================================================================

gen_vless_reality_config() {
    local username="$1"
    local port="${2:-443}"

    log_info "生成 VLESS + Reality 配置: $username (端口 $port)"

    local reality_keys private_key public_key
    reality_keys=$(gen_reality_keypair)
    private_key=$(echo "$reality_keys" | grep "PrivateKey:" | awk '{print $2}')
    public_key=$(echo "$reality_keys" | grep "PublicKey:" | awk '{print $2}')

    local uuid short_id server_name dest
    uuid=$(gen_uuid)
    short_id=$(gen_short_id)
    server_name="www.microsoft.com"
    dest="${server_name}:443"

    # 更新 users.json
    local tmp="${USERS_FILE}.tmp"
    jq --arg name "$username" \
       --arg uuid "$uuid" \
       --arg pk "$private_key" \
       --arg pubk "$public_key" \
       --arg sid "$short_id" \
       --arg sni "$server_name" \
       --arg dest "$dest" \
       --argjson port "$port" \
       --arg tag "inbound-$username" \
       '.users[$name].credentials.uuid = $uuid
        | .users[$name].credentials.flow = "xtls-rprx-vision"
        | .users[$name].reality.private_key = $pk
        | .users[$name].reality.public_key = $pubk
        | .users[$name].reality.short_id = $sid
        | .users[$name].reality.server_name = $sni
        | .users[$name].reality.dest = $dest
        | .users[$name].inbound.port = $port
        | .users[$name].inbound.listen = "0.0.0.0"
        | .users[$name].inbound.tag = $tag
        | .users[$name].inbound.network = "tcp"' \
       "$USERS_FILE" > "$tmp" && mv "$tmp" "$USERS_FILE"

    # 写 inbound 片段
    jq -n --arg tag "inbound-$username" \
          --argjson port "$port" \
          --arg uuid "$uuid" \
          --arg pk "$private_key" \
          --arg sid "$short_id" \
          --arg sni "$server_name" \
          '{type:"vless", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            users:[{name:"'$username'", uuid:$uuid, flow:"xtls-rprx-vision"}],
            tls:{enabled:true, server_name:$sni,
                 reality:{enabled:true, private_key:$pk, short_id:[$sid]}},
            multiplex:{enabled:true, padding:true,
                       brutal:{enabled:true, up_mbps:1000, down_mbps:1000}}}' \
       > "${SB_CONFIG}/inbound/${username}.json"

    log_info "VLESS + Reality 配置已生成: $username"
}

gen_vless_reality_client() {
    local username="$1"
    local user_data
    user_data=$(jq ".users.\"$username\"" "$USERS_FILE")

    local uuid public_key short_id server_name port server_ip domain
    uuid=$(echo "$user_data" | jq -r '.credentials.uuid')
    public_key=$(echo "$user_data" | jq -r '.reality.public_key')
    short_id=$(echo "$user_data" | jq -r '.reality.short_id')
    port=$(echo "$user_data" | jq -r '.inbound.port')
    server_ip=$(get_public_ip)
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$server_ip")

    local share_link
    share_link="vless://${uuid}@${domain}:${port}?type=tcp&security=reality&flow=xtls-rprx-vision&fp=chrome&sni=www.microsoft.com&pbk=${public_key}&sid=${short_id}#${username}"

    local sing_box
    sing_box=$(jq -n \
        --arg server "$domain" \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg pk "$public_key" \
        --arg sn "$short_id" \
        --arg sni "www.microsoft.com" \
        '{type:"vless", tag:"proxy", server:$server, server_port:$port, uuid:$uuid,
          flow:"xtls-rprx-vision",
          tls:{enabled:true, server_name:$sni,
               utls:{enabled:true, fingerprint:"chrome"},
               reality:{enabled:true, public_key:$pk, short_id:$sn}},
          multiplex:{enabled:true, protocol:"h2mux", max_connections:4, min_streams:4}}')

    local clash
    clash=$(cat << EOF
proxies:
  - name: "${username}"
    type: vless
    server: ${domain}
    port: ${port}
    uuid: ${uuid}
    flow: xtls-rprx-vision
    tls: true
    client-fingerprint: chrome
    servername: www.microsoft.com
    reality-opts:
      public-key: ${public_key}
      short-id: ${short_id}
    udp: true
    xudp: true
EOF
)

    jq -n --arg sb "$sing_box" --arg cm "$clash" --arg sl "$share_link" \
        '{"sing-box": $sb, "clash-meta": $cm, "share_link": $sl}'
}

gen_vless_reality_sub() {
    local username="$1"
    gen_vless_reality_client "$username" | jq -r '.share_link'
}
