# Sing-box Manager - VMess 协议生成器（精简）
# 提供: gen_vmess_config
# 端口默认随机 10000-60000

gen_vmess_config() {
    local username="$1"
    local port="${2:-$(gen_random_port 10000 60000)}"

    log_info "生成 VMess: $username (端口 $port)"

    local uuid
    uuid=$(gen_uuid)

    # 写 users.json
    jq --arg name "$username" --arg uuid "$uuid" --argjson port "$port" \
       '.users[$name].credentials.uuid = $uuid
        | .users[$name].credentials.security = "auto"
        | .users[$name].inbound.port = $port
        | .users[$name].inbound.listen = "0.0.0.0"
        | .users[$name].inbound.tag = ("inbound-" + $name)
        | .users[$name].inbound.network = "tcp"' \
       "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    # 写 inbound 片段
    jq -n --arg tag "inbound-$username" --argjson port "$port" --arg uuid "$uuid" \
          '{type:"vmess", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            users:[{name:"'$username'", uuid:$uuid, alterId:0, security:"auto"}]}' \
       > "${SB_CONFIG}/inbound/${username}.json"

    log_ok "VMess 配置完成: $username"
}
