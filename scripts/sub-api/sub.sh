#!/usr/bin/env bash
# Sing-box Manager - CGI 订阅端点
# 由 Caddy/Nginx CGI 调用
# 依赖: /opt/sb/scripts/sb 环境

set -euo pipefail

SB_ROOT="/opt/sb"
SB_MODULES="${SB_ROOT}/scripts/modules"
DB_FILE="${SB_ROOT}/data/sb.db"

# CGI 参数: ?token=<token> 或 ?user=<username>
QUERY_STRING="${QUERY_STRING:-}"
token=""
user=""

# 解析 QUERY_STRING
IFS='&' read -ra params <<< "$QUERY_STRING"
for p in "${params[@]}"; do
    case "$p" in
        token=*) token="${p#token=}" ;;
        user=*)  user="${p#user=}" ;;
    esac
done

# ---- 验证 Token ----
# 使用安装时生成的订阅令牌
SUB_TOKEN_FILE="${SB_ROOT}/data/sub_token.txt"
if [[ -f "$SUB_TOKEN_FILE" ]]; then
    local_token=$(cat "$SUB_TOKEN_FILE" 2>/dev/null || echo "")
    if [[ -n "$local_token" && "$token" != "$local_token" ]]; then
        echo "Content-Type: text/plain"
        echo "Status: 403"
        echo ""
        echo "Forbidden: invalid token"
        exit 0
    fi
fi

# ---- 生成订阅 ----
# 加载 DB 函数
source "${SB_MODULES}/db.sh" 2>/dev/null || {
    echo "Content-Type: text/plain"
    echo "Status: 500"
    echo ""
    echo "Internal error"
    exit 1
}
db_init

# 构建 sing-box 出站列表 JSON
outbounds_json="[]"

if [[ -n "$user" ]]; then
    # 单个用户
    local row
    row=$(sqlite3 "$DB_FILE" -json "SELECT * FROM users WHERE username='$user' AND status='active';" 2>/dev/null | jq -r '.[0] // empty')
    if [[ -z "$row" ]]; then
        echo "Content-Type: text/plain"
        echo "Status: 404"
        echo ""
        echo "User not found or disabled"
        exit 0
    fi
    local proto port server
    proto=$(echo "$row" | jq -r '.protocol')
    port=$(echo "$row" | jq -r '.port')
    server=$(get_public_ip)

    case "$proto" in
        vless-reality)
            local uuid pub sid sni
            uuid=$(echo "$row" | jq -r '.credentials.uuid')
            pub=$(echo "$row" | jq -r '.credentials.public_key')
            sid=$(echo "$row" | jq -r '.credentials.short_id')
            sni=$(echo "$row" | jq -r '.credentials.server_name')
            outbounds_json=$(jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" \
                --arg pk "$pub" --arg sn "$sid" --arg sni "$sni" \
                '[{type:"vless", tag:"proxy", server:$s, server_port:$p, uuid:$u,
                   flow:"xtls-rprx-vision",
                   tls:{enabled:true, server_name:$sni,
                        utls:{enabled:true, fingerprint:"chrome"},
                        reality:{enabled:true, public_key:$pk, short_id:$sn}}}]')
            ;;
        hysteria2)
            local pw; pw=$(echo "$row" | jq -r '.credentials.password')
            outbounds_json=$(jq -n --arg s "$server" --argjson p "$port" --arg pw "$pw" \
                '[{type:"hysteria2", tag:"proxy", server:$s, server_port:$p, password:$pw,
                   tls:{enabled:true, server_name:$s, insecure:true, alpn:["h3"]}}]')
            ;;
        tuic)
            local uuid pw; uuid=$(echo "$row" | jq -r '.credentials.uuid')
            pw=$(echo "$row" | jq -r '.credentials.password')
            outbounds_json=$(jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" --arg pw "$pw" \
                '[{type:"tuic", tag:"proxy", server:$s, server_port:$p, uuid:$u, password:$pw,
                   tls:{enabled:true, server_name:$s, alpn:["h3"]}, congestion_control:"bbr"}]')
            ;;
        shadowtls)
            local pw; pw=$(echo "$row" | jq -r '.credentials.password')
            outbounds_json=$(jq -n --arg s "$server" --argjson p "$port" --arg pw "$pw" \
                '[{type:"shadowtls", tag:"proxy", server:$s, server_port:$p, version:3, password:$pw,
                   tls:{enabled:true, server_name:"www.bing.com",
                        utls:{enabled:true, fingerprint:"chrome"}}}]')
            ;;
        vmess)
            local uuid; uuid=$(echo "$row" | jq -r '.credentials.uuid')
            outbounds_json=$(jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" \
                '[{type:"vmess", tag:"proxy", server:$s, server_port:$p, uuid:$u, security:"auto"}]')
            ;;
    esac
else
    # 所有活跃用户
    while IFS='|' read -r username proto port; do
        local row
        row=$(sqlite3 "$DB_FILE" -json "SELECT * FROM users WHERE username='$username';" 2>/dev/null | jq -r '.[0] // empty')
        [[ -z "$row" ]] && continue
        local server; server=$(get_public_ip)
        local user_ob=""
        case "$proto" in
            vless-reality)
                local uuid pub sid sni
                uuid=$(echo "$row" | jq -r '.credentials.uuid')
                pub=$(echo "$row" | jq -r '.credentials.public_key')
                sid=$(echo "$row" | jq -r '.credentials.short_id')
                sni=$(echo "$row" | jq -r '.credentials.server_name')
                user_ob=$(jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" \
                    --arg pk "$pub" --arg sn "$sid" --arg sni "$sni" \
                    '{type:"vless", tag:"'$username'", server:$s, server_port:$p, uuid:$u,
                      flow:"xtls-rprx-vision",
                      tls:{enabled:true, server_name:$sni,
                           utls:{enabled:true, fingerprint:"chrome"},
                           reality:{enabled:true, public_key:$pk, short_id:$sn}}}')
                ;;
            hysteria2)
                local pw; pw=$(echo "$row" | jq -r '.credentials.password')
                user_ob=$(jq -n --arg s "$server" --argjson p "$port" --arg pw "$pw" \
                    '{type:"hysteria2", tag:"'$username'", server:$s, server_port:$p, password:$pw,
                      tls:{enabled:true, server_name:$s, insecure:true, alpn:["h3"]}}')
                ;;
            tuic)
                local uuid pw; uuid=$(echo "$row" | jq -r '.credentials.uuid')
                pw=$(echo "$row" | jq -r '.credentials.password')
                user_ob=$(jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" --arg pw "$pw" \
                    '{type:"tuic", tag:"'$username'", server:$s, server_port:$p, uuid:$u, password:$pw,
                      tls:{enabled:true, server_name:$s, alpn:["h3"]}, congestion_control:"bbr"}')
                ;;
            shadowtls)
                local pw; pw=$(echo "$row" | jq -r '.credentials.password')
                user_ob=$(jq -n --arg s "$server" --argjson p "$port" --arg pw "$pw" \
                    '{type:"shadowtls", tag:"'$username'", server:$s, server_port:$p, version:3, password:$pw,
                      tls:{enabled:true, server_name:"www.bing.com",
                           utls:{enabled:true, fingerprint:"chrome"}}}')
                ;;
            vmess)
                local uuid; uuid=$(echo "$row" | jq -r '.credentials.uuid')
                user_ob=$(jq -n --arg s "$server" --argjson p "$port" --arg u "$uuid" \
                    '{type:"vmess", tag:"'$username'", server:$s, server_port:$p, uuid:$u, security:"auto"}')
                ;;
        esac
        if [[ -n "$user_ob" ]]; then
            outbounds_json=$(echo "$outbounds_json" | jq --argjson ob "$user_ob" '. + [$ob]')
        fi
    done < <(sqlite3 "$DB_FILE" "SELECT username,protocol,port FROM users WHERE status='active';")
fi

# 输出
echo "Content-Type: application/json"
echo ""
echo "$outbounds_json" | jq '.'