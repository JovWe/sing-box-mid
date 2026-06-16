# Sing-box Manager - VLESS + Reality 协议生成器（精简）
# 提供: gen_vless_reality_config
# 端口默认 443

gen_vless_reality_config() {
    local username="$1"
    local port="${2:-443}"

    log_info "生成 VLESS + Reality: $username (端口 $port)"

    local keys pk pub
    keys=$(gen_reality_keypair)
    pk=$(echo "$keys" | awk '/PrivateKey/{print $2}')
    pub=$(echo "$keys" | awk '/PublicKey/{print $2}')

    local uuid sid sni
    uuid=$(gen_uuid)
    sid=$(gen_short_id)
    sni="www.microsoft.com"

    # 写 users.json
    jq --arg name "$username" --arg uuid "$uuid" --arg pk "$pk" --arg pub "$pub" \
       --arg sid "$sid" --arg sni "$sni" --argjson port "$port" \
       '.users[$name].credentials.uuid = $uuid
        | .users[$name].credentials.flow = "xtls-rprx-vision"
        | .users[$name].inbound.port = $port
        | .users[$name].inbound.listen = "0.0.0.0"
        | .users[$name].inbound.tag = ("inbound-" + $name)
        | .users[$name].inbound.network = "tcp"
        | .users[$name].reality.private_key = $pk
        | .users[$name].reality.public_key = $pub
        | .users[$name].reality.short_id = $sid
        | .users[$name].reality.server_name = $sni' \
       "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    # 写 inbound 片段
    jq -n --arg tag "inbound-$username" --argjson port "$port" \
          --arg uuid "$uuid" --arg pk "$pk" --arg sid "$sid" --arg sni "$sni" \
          '{type:"vless", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            users:[{name:"'$username'", uuid:$uuid, flow:"xtls-rprx-vision"}],
            tls:{enabled:true, server_name:$sni,
                 reality:{enabled:true, private_key:$pk, short_id:[$sid]}}}' \
       > "${SB_CONFIG}/inbound/${username}.json"

    log_ok "VLESS + Reality 配置完成: $username"
}
