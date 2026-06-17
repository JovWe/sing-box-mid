#!/usr/bin/env bash
# Sing-box Manager - 订阅生成 (IP-based, 分享链接)
# 用法:
#   CLI:  sb sub                     - 输出所有活跃用户的分享链接
#         sb sub <username>          - 输出单个用户的分享链接
#   CGI:  ?user=<name>&token=<key>   - 同 CLI, 输出 Content-Type
# 输出: 标准分享链接, 每行一个 (vless://, hysteria2://, tuic://, shadowtls://, vmess://)

set -euo pipefail

SB_ROOT="/opt/sb"
SB_MODULES="${SB_ROOT}/scripts/modules"
DB_FILE="${SB_ROOT}/data/sb.db"
SUB_TOKEN_FILE="${SB_ROOT}/data/sub_token.txt"

# ---- 加载 DB 模块 ----
source "${SB_MODULES}/db.sh" 2>/dev/null || {
    echo "ERROR: 无法加载 db.sh" >&2
    exit 1
}
db_init

# ---- 加载 user-manager (提供 gen_client_link) ----
source "${SB_MODULES}/user-manager.sh" 2>/dev/null || true

# ---- 解析参数 ----
is_cgi=0
token=""
user=""

if [[ -n "${QUERY_STRING:-}" ]]; then
    is_cgi=1
    IFS='&' read -ra params <<< "$QUERY_STRING"
    for p in "${params[@]}"; do
        case "$p" in
            user=*)  user="${p#user=}" ;;
            token=*) token="${p#token=}" ;;
        esac
    done
else
    user="${1:-}"
    token="${2:-}"
fi

# ---- Token 验证 ----
if [[ -f "$SUB_TOKEN_FILE" ]]; then
    local_token=$(cat "$SUB_TOKEN_FILE" 2>/dev/null || echo "")
    if [[ -n "$local_token" && "$token" != "$local_token" ]]; then
        if [[ $is_cgi -eq 1 ]]; then
            echo "Content-Type: text/plain"
            echo "Status: 403"
            echo ""
            echo "Forbidden: invalid token"
        else
            echo "ERROR: 无效的订阅令牌" >&2
        fi
        exit 0
    fi
fi

# ---- 生成内容 ----
gen_content() {
    local target_user="$1"
    if [[ -n "$target_user" ]]; then
        # 单个用户
        local row
        row=$(sqlite3 "$DB_FILE" "SELECT username,status FROM users WHERE username='$target_user';" 2>/dev/null)
        [[ -z "$row" ]] && { echo "ERROR: 用户不存在: $target_user" >&2; return 1; }
        echo "$row" | grep -q '|active' || { echo "ERROR: 用户已停用: $target_user" >&2; return 1; }
        gen_client_link "$target_user" 2>/dev/null || true
    else
        # 所有活跃用户
        local total
        total=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM users WHERE status='active';")
        if [[ "$total" -eq 0 ]]; then
            echo "没有活跃用户, 请先运行: sb add-user"
            return 1
        fi
        sqlite3 "$DB_FILE" "SELECT username FROM users WHERE status='active' ORDER BY id;" 2>/dev/null | while IFS= read -r u; do
            [[ -z "$u" ]] && continue
            gen_client_link "$u" 2>/dev/null || true
        done
    fi
}

content=$(gen_content "$user")
[[ $? -ne 0 && -z "$content" ]] && content="没有活跃用户, 请先运行: sb add-user"

# ---- 输出 ----
if [[ $is_cgi -eq 1 ]]; then
    echo "Content-Type: text/plain; charset=utf-8"
    echo ""
    echo "$content"
else
    echo "$content"
fi