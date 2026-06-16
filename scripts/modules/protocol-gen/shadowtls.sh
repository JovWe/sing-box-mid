# Sing-box Manager - ShadowTLS v3 协议生成器（精简）
# 提供: gen_shadowtls_config
# 端口默认随机 10000-60000

# 握手站点 (伪装成访问这里)
SHADOWTLS_HANDSHAKE_HOST="www.bing.com"
SHADOWTLS_HANDSHAKE_PORT=443

gen_shadowtls_config() {
    local username="$1"
    local port="${2:-$(gen_random_port 10000 60000)}"

    log_info "生成 ShadowTLS v3: $username (端口 $port)"

    local password
    password=$(gen_password 16)

    # 写 users.json
    jq --arg name "$username" --arg pw "$password" --argjson port "$port" \
       --arg hk "$SHADOWTLS_HANDSHAKE_HOST" --argjson hp "$SHADOWTLS_HANDSHAKE_PORT" \
       '.users[$name].credentials.password = $pw
        | .users[$name].inbound.port = $port
        | .users[$name].inbound.listen = "0.0.0.0"
        | .users[$name].inbound.tag = ("inbound-" + $name)
        | .users[$name].inbound.network = "tcp"
        | .users[$name].shadowtls.handshake = $hk
        | .users[$name].shadowtls.handshake_port = $hp' \
       "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    # 写 inbound 片段
    jq -n --arg tag "inbound-$username" --argjson port "$port" \
          --arg pw "$password" --arg hk "$SHADOWTLS_HANDSHAKE_HOST" --argjson hp "$SHADOWTLS_HANDSHAKE_PORT" \
          '{type:"shadowtls", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            version:3, password:$pw,
            handshake:{server:$hk, server_port:$hp}}' \
       > "${SB_CONFIG}/inbound/${username}.json"

    log_ok "ShadowTLS v3 配置完成: $username"
}
