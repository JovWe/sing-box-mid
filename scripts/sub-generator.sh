#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - 订阅生成器
# 支持: Sing-box, Clash Meta, V2rayN
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# --- 生成单个用户订阅 ---
gen_user_sub() {
    local username="$1"
    local format="${2:-all}"

    if ! jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
        log_error "用户不存在: $username"
        return 1
    fi

    local protocol
    protocol=$(jq -r ".users.\"$username\".protocol" "$USERS_FILE")
    local status
    status=$(jq -r ".users.\"$username\".status" "$USERS_FILE")

    if [[ "$status" != "active" ]]; then
        log_error "用户已禁用: $username"
        return 1
    fi

    # 加载协议生成器
    local gen_file="${SCRIPT_DIR}/protocol-gen/${protocol}.sh"
    if [[ -f "$gen_file" ]]; then
        source "$gen_file"
    else
        log_error "不支持的协议: $protocol"
        return 1
    fi

    local share_link
    local client_data
    case "$protocol" in
        vless-reality)
            share_link=$(gen_vless_reality_sub "$username")
            client_data=$(gen_vless_reality_client "$username")
            ;;
        hysteria2)
            share_link=$(gen_hysteria2_sub "$username")
            client_data=$(gen_hysteria2_client "$username")
            ;;
        tuic)
            share_link=$(gen_tuic_sub "$username")
            client_data=$(gen_tuic_client "$username")
            ;;
        anytls)
            share_link=$(gen_anytls_sub "$username")
            client_data=$(gen_anytls_client "$username")
            ;;
        shadowtls)
            share_link=$(gen_shadowtls_sub "$username")
            client_data=$(gen_shadowtls_client "$username")
            ;;
    esac

    case "$format" in
        sing-box)
            echo "$client_data" | jq -r '.["sing-box"]' | jq -r '.'
            ;;
        clash-meta|clash|mihomo)
            echo "proxies:"
            echo "$client_data" | jq -r '.["clash-meta"]' | jq -r '.'
            ;;
        v2rayn|nekoray|link)
            echo "$share_link"
            ;;
        qrcode)
            echo "$share_link"
            ;;
        all|*)
            echo "$share_link"
            ;;
    esac
}

# --- 生成所有用户订阅 (Base64 编码) ---
gen_all_users_sub() {
    local format="${1:-link}"

    local all_links=""
    jq -r '.users | to_entries[] | select(.value.status == "active") | .key' "$USERS_FILE" 2>/dev/null | while read -r username; do
        local protocol
        protocol=$(jq -r ".users.\"$username\".protocol" "$USERS_FILE")
        local gen_file="${SCRIPT_DIR}/protocol-gen/${protocol}.sh"
        if [[ -f "$gen_file" ]]; then
            source "$gen_file"
            local link
            case "$protocol" in
                vless-reality) link=$(gen_vless_reality_sub "$username") ;;
                hysteria2)     link=$(gen_hysteria2_sub "$username") ;;
                tuic)          link=$(gen_tuic_sub "$username") ;;
                anytls)        link=$(gen_anytls_sub "$username") ;;
                shadowtls)     link=$(gen_shadowtls_sub "$username") ;;
            esac
            echo "$link"
        fi
    done
}

# --- 生成 Clash Meta 完整订阅 ---
gen_clash_subscription() {
    local domain
    domain=$(json_get "$SETTINGS_FILE" '.subscription_domain' "$(json_get "$SETTINGS_FILE" '.domain')")
    local server_ip
    server_ip=$(get_public_ip)

    echo "mixed-port: 7890"
    echo "allow-lan: false"
    echo "mode: rule"
    echo "log-level: info"
    echo "external-controller: 127.0.0.1:9090"
    echo "dns:"
    echo "  enable: true"
    echo "  ipv6: false"
    echo "  enhanced-mode: fake-ip"
    echo ""
    echo "proxies:"

    jq -r '.users | to_entries[] | select(.value.status == "active") | [.key, .value.protocol] | join("|")' \
        "$USERS_FILE" 2>/dev/null | while IFS='|' read -r username protocol; do

        local user_data
        user_data=$(jq ".users.\"$username\"" "$USERS_FILE")
        local port
        port=$(echo "$user_data" | jq -r '.inbound.port')
        local ip="${domain:-$server_ip}"

        case "$protocol" in
            vless-reality)
                local uuid
                uuid=$(echo "$user_data" | jq -r '.credentials.uuid')
                local public_key
                public_key=$(echo "$user_data" | jq -r '.reality.public_key')
                local short_id
                short_id=$(echo "$user_data" | jq -r '.reality.short_id')
                local sni
                sni=$(echo "$user_data" | jq -r '.reality.server_name')
                cat << CLASH
  - name: "${username}-${ip}"
    type: vless
    server: ${ip}
    port: ${port}
    uuid: ${uuid}
    flow: xtls-rprx-vision
    tls: true
    client-fingerprint: chrome
    servername: ${sni}
    reality-opts:
      public-key: ${public_key}
      short-id: ${short_id}
    udp: true
CLASH
                ;;
            hysteria2)
                local password
                password=$(echo "$user_data" | jq -r '.credentials.password')
                cat << CLASH
  - name: "${username}-${ip}"
    type: hysteria2
    server: ${ip}
    port: ${port}
    password: ${password}
    sni: ${ip}
    skip-cert-verify: false
    udp: true
CLASH
                ;;
            tuic)
                local uuid
                uuid=$(echo "$user_data" | jq -r '.credentials.uuid')
                local password
                password=$(echo "$user_data" | jq -r '.credentials.password')
                cat << CLASH
  - name: "${username}-${ip}"
    type: tuic
    server: ${ip}
    port: ${port}
    uuid: ${uuid}
    password: ${password}
    sni: ${ip}
    alpn: [h3]
    udp: true
CLASH
                ;;
        esac
    done

    echo ""
    echo "proxy-groups:"
    echo "  - name: Proxy"
    echo "    type: select"
    echo "    proxies:"

    # 列出所有代理名称
    jq -r '.users | to_entries[] | select(.value.status == "active") | "      - \"\(.key)-'"${domain:-$server_ip}"'\""' \
        "$USERS_FILE" 2>/dev/null

    echo ""
    echo "rules:"
    echo "  - GEOIP,CN,DIRECT"
    echo "  - MATCH,Proxy"
}

# --- 显示订阅 ---
show_sub() {
    local username="${1:-}"

    echo ""
    echo -e "${CYAN}========== 订阅链接 ==========${NC}"
    if [[ -n "$username" ]]; then
        if ! jq -e ".users | has(\"$username\")" "$USERS_FILE" &>/dev/null; then
            log_error "用户不存在: $username"
            return 1
        fi
        local sub_url
        sub_url=$(jq -r ".users.\"$username\".subscription.url" "$USERS_FILE")
        echo -e "用户: ${BOLD}${username}${NC}"
        echo -e "订阅: ${BOLD}${sub_url}${NC}"
        echo ""
        echo -e "${CYAN}分享链接:${NC}"
        gen_user_sub "$username" "link"
        echo ""
    else
        echo "订阅链接列表:"
        jq -r '.users | to_entries[] | select(.value.status == "active") | 
            "  \(.key): \(.value.subscription.url)"' "$USERS_FILE" 2>/dev/null
        echo ""
    fi
}