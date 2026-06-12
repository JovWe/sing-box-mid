#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - 出站管理函数库
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# --- 添加出站 ---
add_outbound() {
    local name="${1:-}"
    local out_type="${2:-}"

    echo "添加出站代理:"
    if [[ -z "$out_type" ]]; then
        echo "出站类型:"
        echo "  1) SOCKS5"
        echo "  2) HTTP"
        echo "  3) VLESS"
        echo "  4) Hysteria2"
        echo "  5) TUIC"
        echo "  6) 直接粘贴 JSON 配置"
        read -rp "选择 [1-6]: " type_choice
        case "$type_choice" in
            1) out_type="socks" ;;
            2) out_type="http" ;;
            3) out_type="vless" ;;
            4) out_type="hysteria2" ;;
            5) out_type="tuic" ;;
            6) out_type="json" ;;
            *) log_error "无效选择"; return 1 ;;
        esac
    fi

    if [[ -z "$name" ]]; then
        read -rp "出站名称 (e.g. 香港SOCKS5): " name
    fi
    [[ -z "$name" ]] && { log_error "名称不能为空"; return 1; }

    local out_id
    out_id="out_$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9_')"
    local out_tag="out-${out_id}"

    # 检查是否已存在
    if jq -e ".outbounds[] | select(.id == \"$out_id\")" "$OUTBOUNDS_FILE" &>/dev/null; then
        log_error "出站 ID 已存在: $out_id"
        return 1
    fi

    if [[ "$out_type" == "json" ]]; then
        echo "请粘贴完整的 Sing-box outbound JSON 配置 (以空行或 Ctrl+D 结束):"
        local json_config=""
        while IFS= read -r line; do
            [[ -z "$line" ]] && break
            json_config+="$line"
        done
        if [[ -z "$json_config" ]]; then
            log_error "配置不能为空"
            return 1
        fi
        # 验证 JSON
        if ! echo "$json_config" | jq . &>/dev/null; then
            log_error "无效的 JSON 格式"
            return 1
        fi
        out_type=$(echo "$json_config" | jq -r '.type // "custom"')
    else
        # 交互式收集配置
        local server port username password
        read -rp "服务器地址: " server
        read -rp "服务器端口: " port
        read -rp "用户名 (可选): " username
        read -rp "密码 (可选): " password

        local json_config
        json_config=$(cat << EOF
{
  "server": "${server}",
  "server_port": ${port:-1080}
EOF
)
        if [[ -n "$username" ]]; then
            json_config+=", \"username\": \"${username}\""
        fi
        if [[ -n "$password" ]]; then
            json_config+=", \"password\": \"${password}\""
        fi
        json_config+="}"
    fi

    local now
    now=$(date +%s)

    local outbound_data
    outbound_data=$(cat << EOF
{
  "id": "${out_id}",
  "name": "${name}",
  "type": "${out_type}",
  "tag": "${out_tag}",
  "builtin": false,
  "created_at": ${now},
  "config": ${json_config}
}
EOF
)

    # 添加到数据库
    local tmp="${OUTBOUNDS_FILE}.tmp"
    jq ".outbounds += [${outbound_data}]" "$OUTBOUNDS_FILE" > "$tmp" && mv "$tmp" "$OUTBOUNDS_FILE"

    # 生成出站配置片段
    local outbound_sb_config
    outbound_sb_config=$(echo "$json_config" | jq \
        --arg type "$out_type" \
        --arg tag "$out_tag" \
        '. + {type: $type, tag: $tag}')

    echo "$outbound_sb_config" | jq . > "${SB_CONFIG}/outbound/${out_id}.json" 2>/dev/null || {
        echo "$outbound_sb_config" > "${SB_CONFIG}/outbound/${out_id}.json"
    }

    # 自动添加到默认策略组
    jq ".strategy_groups[0].outbounds += [\"${out_id}\"]" "$OUTBOUNDS_FILE" > "${OUTBOUNDS_FILE}.tmp" && \
        mv "${OUTBOUNDS_FILE}.tmp" "$OUTBOUNDS_FILE"

    log_info "出站已添加: $name ($out_type)"
    sb_reload || log_warn "配置重载失败"
}

# --- 删除出站 ---
delete_outbound() {
    local out_id="${1:-}"

    if [[ -z "$out_id" ]]; then
        echo "当前出站列表:"
        list_outbounds
        read -rp "请输入要删除的出站 ID: " out_id
    fi
    [[ -z "$out_id" ]] && { log_error "ID 不能为空"; return 1; }

    # 检查是否为内置
    if jq -e ".outbounds[] | select(.id == \"$out_id\" and .builtin == true)" "$OUTBOUNDS_FILE" &>/dev/null; then
        log_error "不能删除内置出站: $out_id"
        return 1
    fi

    if ! jq -e ".outbounds[] | select(.id == \"$out_id\")" "$OUTBOUNDS_FILE" &>/dev/null; then
        log_error "出站不存在: $out_id"
        return 1
    fi

    confirm "确认删除出站 $out_id?" || return 0

    # 从数据库删除
    local tmp="${OUTBOUNDS_FILE}.tmp"
    jq "del(.outbounds[] | select(.id == \"$out_id\"))" "$OUTBOUNDS_FILE" > "$tmp" && mv "$tmp" "$OUTBOUNDS_FILE"

    # 从策略组移除
    jq ".strategy_groups[].outbounds -= [\"$out_id\"]" "$OUTBOUNDS_FILE" > "${OUTBOUNDS_FILE}.tmp" && \
        mv "${OUTBOUNDS_FILE}.tmp" "$OUTBOUNDS_FILE"

    # 删除配置片段
    rm -f "${SB_CONFIG}/outbound/${out_id}.json"

    log_info "出站已删除: $out_id"
    sb_reload || log_warn "配置重载失败"
}

# --- 编辑出站 ---
edit_outbound() {
    local out_id="${1:-}"

    if [[ -z "$out_id" ]]; then
        list_outbounds
        read -rp "请输入要编辑的出站 ID: " out_id
    fi
    [[ -z "$out_id" ]] && { log_error "ID 不能为空"; return 1; }

    if ! jq -e ".outbounds[] | select(.id == \"$out_id\")" "$OUTBOUNDS_FILE" &>/dev/null; then
        log_error "出站不存在: $out_id"
        return 1
    fi

    echo "编辑出站: $out_id"
    echo "当前配置:"
    jq ".outbounds[] | select(.id == \"$out_id\")" "$OUTBOUNDS_FILE"

    echo ""
    echo "请粘贴新的完整 JSON 配置 (以空行结束):"
    local json_config=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        json_config+="$line"
    done

    if [[ -n "$json_config" ]]; then
        if ! echo "$json_config" | jq . &>/dev/null; then
            log_error "无效的 JSON 格式"
            return 1
        fi
        local tmp="${OUTBOUNDS_FILE}.tmp"
        jq "(.outbounds[] | select(.id == \"$out_id\").config) = ${json_config}" "$OUTBOUNDS_FILE" > "$tmp" && mv "$tmp" "$OUTBOUNDS_FILE"

        local out_type
        out_type=$(jq -r ".outbounds[] | select(.id == \"$out_id\").type" "$OUTBOUNDS_FILE")
        echo "$json_config" | jq --arg type "$out_type" --arg tag "out-${out_id}" \
            '. + {type: $type, tag: $tag}' > "${SB_CONFIG}/outbound/${out_id}.json"

        log_info "出站已更新: $out_id"
        sb_reload || log_warn "配置重载失败"
    fi
}

# --- 列出出站 ---
list_outbounds() {
    if [[ ! -f "$OUTBOUNDS_FILE" ]]; then
        echo "暂未配置出站"
        return
    fi

    echo ""
    echo -e "${CYAN}========== 出站列表 ==========${NC}"
    printf "${CYAN}%-20s %-25s %-12s %-15s${NC}\n" "ID" "名称" "类型" "创建时间"
    printf '%s\n' "$(printf '─%.0s' {1..80})"

    jq -r '.outbounds[] | "\(.id)|\(.name)|\(.type)|\(.created_at // 0)"' "$OUTBOUNDS_FILE" 2>/dev/null | \
        while IFS='|' read -r id name otype created; do
        printf "%-20s %-25s %-12s %-15s\n" \
            "$id" "$name" "$otype" "$(format_timestamp "$created")"
    done

    echo ""
    echo -e "${CYAN}========== 策略组 ==========${NC}"
    jq -r '.strategy_groups[] | "\(.name) [\(.type)]: \(.outbounds | join(", "))"' "$OUTBOUNDS_FILE" 2>/dev/null
    echo ""
}

# --- 显示单个出站详情 ---
show_outbound() {
    local out_id="${1:-}"
    if ! jq -e ".outbounds[] | select(.id == \"$out_id\")" "$OUTBOUNDS_FILE" &>/dev/null; then
        log_error "出站不存在: $out_id"
        return 1
    fi

    echo ""
    echo -e "${CYAN}========== 出站详情: ${out_id} ==========${NC}"
    jq ".outbounds[] | select(.id == \"$out_id\")" "$OUTBOUNDS_FILE"
    echo ""
}

# --- 管理策略组 ---
manage_strategy_group() {
    echo "策略组管理:"
    echo "  1) 查看策略组"
    echo "  2) 修改默认出站"
    echo "  3) 添加出站到策略组"
    echo "  4) 从策略组移除出站"
    read -rp "选择 [1-4]: " choice

    case "$choice" in
        1)
            jq '.strategy_groups' "$OUTBOUNDS_FILE"
            ;;
        2)
            local sg_id="${1:-sg_default}"
            echo "可用出站:"
            jq -r '.outbounds[] | "  \(.id) - \(.name)"' "$OUTBOUNDS_FILE"
            read -rp "选择默认出站 ID: " default_out
            [[ -n "$default_out" ]] && {
                json_set "$OUTBOUNDS_FILE" ".strategy_groups[] | select(.id == \"$sg_id\").default" "\"$default_out\""
                log_info "默认出站已更新: $default_out"
                sb_reload
            }
            ;;
        3)
            local sg_id="${1:-sg_default}"
            echo "可用出站:"
            jq -r '.outbounds[] | "  \(.id) - \(.name)"' "$OUTBOUNDS_FILE"
            read -rp "要添加的出站 ID: " add_out
            [[ -n "$add_out" ]] && {
                local tmp="${OUTBOUNDS_FILE}.tmp"
                jq "(.strategy_groups[] | select(.id == \"$sg_id\").outbounds) += [\"$add_out\"] | unique" \
                    "$OUTBOUNDS_FILE" > "$tmp" && mv "$tmp" "$OUTBOUNDS_FILE"
                log_info "已添加: $add_out"
                sb_reload
            }
            ;;
        4)
            local sg_id="${1:-sg_default}"
            read -rp "要移除的出站 ID: " rm_out
            [[ -n "$rm_out" ]] && {
                local tmp="${OUTBOUNDS_FILE}.tmp"
                jq "(.strategy_groups[] | select(.id == \"$sg_id\").outbounds) -= [\"$rm_out\"]" \
                    "$OUTBOUNDS_FILE" > "$tmp" && mv "$tmp" "$OUTBOUNDS_FILE"
                log_info "已移除: $rm_out"
                sb_reload
            }
            ;;
        *)
            log_error "无效选择"
            ;;
    esac
}