#===============================================================================
# ShadowTLS v3 协议生成器（纯函数）
# ShadowTLS 以 HTTP 请求指纹伪装, 这里用一个固定的目标站点
#===============================================================================

_SHADOWTLS_HANDSHAKE_SERVER="www.bing.com"
_SHADOWTLS_HANDSHAKE_PORT=443

gen_shadowtls_config() {
    local username="$1"
    local port="${2:-$(gen_random_port 10000 60000)}"

    log_info "生成 ShadowTLS v3 配置: $username (端口 $port)"

    local password
    password=$(gen_password 16)

    local tmp="${USERS_FILE}.tmp"
    jq --arg name "$username" \
       --arg pw "$password" \
       --argjson port "$port" \
       --arg tag "inbound-$username" \
       --arg hk "$_SHADOWTLS_HANDSHAKE_SERVER" \
       --argjson hp "$_SHADOWTLS_HANDSHAKE_PORT" \
       '.users[$name].credentials.password = $pw
        | .users[$name].inbound.port = $port
        | .users[$name].inbound.listen = "0.0.0.0"
        | .users[$name].inbound.tag = $tag
        | .users[$name].inbound.network = "tcp"
        | .users[$name].shadowtls.handshake = $hk
        | .users[$name].shadowtls.handshake_port = $hp' \
       "$USERS_FILE" > "$tmp" && mv "$tmp" "$USERS_FILE"

    jq -n --arg tag "inbound-$username" \
          --argjson port "$port" \
          --arg pw "$password" \
          --arg hk "$_SHADOWTLS_HANDSHAKE_SERVER" \
          --argjson hp "$_SHADOWTLS_HANDSHAKE_PORT" \
          '{type:"shadowtls", tag:$tag, listen:"0.0.0.0", listen_port:$port,
            version:3, password:$pw,
            handshake:{server:$hk, server_port:$hp}}' \
       > "${SB_CONFIG}/inbound/${username}.json"

    log_info "ShadowTLS v3 配置已生成: $username"
}

gen_shadowtls_client() {
    local username="$1"
    local password port domain
    password=$(jq -r ".users.\"$username\".credentials.password" "$USERS_FILE")
    port=$(jq -r ".users.\"$username\".inbound.port" "$USERS_FILE")
    domain=$(json_get "$SETTINGS_FILE" '.domain' "$(get_public_ip)")

    local share_link
    share_link="shadowtls://${password}@${domain}:${port}/?version=3&sni=${_SHADOWTLS_HANDSHAKE_SERVER}#${username}-shadowtls"

    # ShadowTLS 需要套一层代理协议; 这里输出一份 sing-box 嵌套配置示例
    local sing_box
    sing_box=$(jq -n \
        --arg server "$domain" \
        --argjson port "$port" \
        --arg pw "$password" \
        --arg hk "$_SHADOWTLS_HANDSHAKE_SERVER" \
        '{type:"shadowtls", tag:"proxy", server:$server, server_port:$port, version:3, password:$pw,
          tls:{enabled:true, server_name:$hk, utls:{enabled:true, fingerprint:"chrome"}}}'
    )

    local clash
    clash=$(cat << EOF
# ShadowTLS 需要底层代理协议配合, 这里给一份纯 ShadowTLS 的配置片段
# 参考 sing-box: https://sing-box.sagernet.org/configuration/shared/handshake/#shadowtls
EOF
)

    jq -n --arg sb "$sing_box" --arg cm "$clash" --arg sl "$share_link" \
        '{"sing-box": $sb, "clash-meta": $cm, "share_link": $sl}'
}

gen_shadowtls_sub() {
    local username="$1"
    gen_shadowtls_client "$username" | jq -r '.share_link'
}
