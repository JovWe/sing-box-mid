#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - 通用工具函数库
#===============================================================================
set -euo pipefail

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# --- 全局路径 ---
SB_BASE="/opt/sb-manager"
SB_BIN="${SB_BASE}/bin"
SB_CORE="${SB_BASE}/core"
SB_CONFIG="${SB_CORE}/config"
SB_DATA="${SB_CORE}/data"
SB_CERTS="${SB_CORE}/certs"
SB_WEB="${SB_CORE}/web"
SB_SCRIPTS="${SB_BASE}/scripts"
SB_LOGS="${SB_BASE}/logs"

# --- 数据文件 ---
USERS_FILE="${SB_DATA}/users.json"
OUTBOUNDS_FILE="${SB_DATA}/outbounds.json"
TRAFFIC_FILE="${SB_DATA}/traffic.json"
SETTINGS_FILE="${SB_DATA}/settings.json"
SINGBOX_CONFIG="${SB_CONFIG}/config.json"

# --- 日志函数 ---
log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${CYAN}[DEBUG]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*"; }

# --- 检查 root ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以 root 权限运行"
        exit 1
    fi
}

# --- 检查系统 ---
check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            debian)
                if [[ "$VERSION_ID" != "12" && "$VERSION_ID" != "13" ]]; then
                    log_warn "推荐 Debian 12/13, 当前: Debian $VERSION_ID"
                fi
                ;;
            ubuntu)
                if [[ "$VERSION_ID" != "22.04" && "$VERSION_ID" != "24.04" ]]; then
                    log_warn "推荐 Ubuntu 22.04/24.04, 当前: Ubuntu $VERSION_ID"
                fi
                ;;
            *)
                log_error "不支持的系统: $ID"
                exit 1
                ;;
        esac
    else
        log_error "无法检测操作系统"
        exit 1
    fi
    log_info "系统检测: $ID $VERSION_ID ($(uname -m))"
}

# --- 检查依赖 ---
check_dep() {
    local pkg="$1"
    if ! command -v "$pkg" &>/dev/null; then
        log_info "安装依赖: $pkg"
        apt-get install -y -qq "$pkg" &>/dev/null || {
            log_error "安装 $pkg 失败"
            exit 1
        }
    fi
}

# --- 安装基础依赖 ---
install_deps() {
    log_info "安装基础依赖..."
    apt-get update -qq
    check_dep curl
    check_dep wget
    check_dep jq
    check_dep uuid-runtime
    check_dep openssl
    check_dep cron
    check_dep nftables
    check_dep tar
    check_dep gzip
    log_info "依赖安装完成"
}

# --- JSON 读写工具 (使用 jq) ---
json_get() {
    local file="$1"
    local key="$2"
    local default="${3:-}"
    if [[ -f "$file" ]]; then
        local val
        val=$(jq -r "$key // empty" "$file" 2>/dev/null)
        if [[ -z "$val" || "$val" == "null" ]]; then
            echo "$default"
        else
            echo "$val"
        fi
    else
        echo "$default"
    fi
}

json_set() {
    local file="$1"
    local key="$2"
    local value="$3"
    mkdir -p "$(dirname "$file")"
    if [[ ! -f "$file" ]]; then
        echo "{}" > "$file"
    fi
    local tmp="${file}.tmp"
    jq "$key = $value" "$file" > "$tmp" && mv "$tmp" "$file"
}

json_delete() {
    local file="$1"
    local key="$2"
    if [[ -f "$file" ]]; then
        local tmp="${file}.tmp"
        jq "del($key)" "$file" > "$tmp" && mv "$tmp" "$file"
    fi
}

# --- 随机生成工具 ---
gen_uuid() {
    uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || {
        openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'
    }
}

gen_password() {
    local len="${1:-32}"
    openssl rand -base64 "$len" | tr -d '+/=' | head -c "$len"
}

gen_short_id() {
    openssl rand -hex 8
}

gen_token() {
    openssl rand -hex 16
}

gen_random_port() {
    local min="${1:-10000}"
    local max="${2:-60000}"
    # 避免常见端口冲突
    local reserved="22 25 53 80 110 143 443 465 587 993 995 2053 3306 5432 6379 8080 8443 9090"
    local port
    while true; do
        port=$(( RANDOM % (max - min + 1) + min ))
        local used=0
        for r in $reserved; do
            [[ "$port" == "$r" ]] && { used=1; break; }
        done
        # 检查是否已被本系统占用
        if [[ -f "$USERS_FILE" ]]; then
            if jq -e ".users | map(.inbound.port) | contains([$port])" "$USERS_FILE" &>/dev/null; then
                used=1
            fi
        fi
        [[ $used -eq 0 ]] && { echo "$port"; return; }
    done
}

# --- Reality 密钥生成 ---
gen_reality_keypair() {
    if [[ -x "${SB_BIN}/sing-box" ]]; then
        local output
        output=$("${SB_BIN}/sing-box" generate reality-keypair 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$output"
            return
        fi
    fi
    # 备用: 使用 openssl 生成 X25519 密钥对
    local private_key
    private_key=$(openssl rand -base64 32 | tr -d '+/=' | head -c 43)
    # 注: 实际生产环境推荐 sing-box 内置工具
    echo "PrivateKey: $private_key"
    echo "PublicKey: (需 sing-box 生成)"
    log_warn "建议安装 sing-box 后重新生成 Reality 密钥"
}

# --- 端口检查 ---
is_port_used() {
    local port="$1"
    ss -tuln | grep -q ":$port " && return 0 || return 1
}

# --- IP 获取 ---
get_public_ip() {
    curl -s -4 https://api.ipify.org 2>/dev/null ||
    curl -s -4 https://icanhazip.com 2>/dev/null ||
    curl -s -4 https://ifconfig.me 2>/dev/null ||
    echo "unknown"
}

get_ipv6() {
    curl -s -6 https://api6.ipify.org 2>/dev/null ||
    curl -s -6 https://icanhazip.com 2>/dev/null ||
    echo ""
}

# --- 域名解析 ---
resolve_domain() {
    local domain="$1"
    local ip
    ip=$(dig +short "$domain" @8.8.8.8 2>/dev/null | grep -E '^[0-9]' | head -1)
    echo "${ip:-}"
}

# --- 证书申请 (acme.sh) ---
install_acme() {
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        log_info "安装 acme.sh..."
        curl -s https://get.acme.sh | sh -s email="${1:-admin@example.com}" &>/dev/null
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt &>/dev/null
    fi
}

issue_cert() {
    local domain="$1"
    local cert_dir="${SB_CERTS}"
    mkdir -p "$cert_dir"
    install_acme
    log_info "申请证书: $domain"
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone --force &>/dev/null || {
        log_error "证书申请失败: $domain"
        return 1
    }
    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file       "${cert_dir}/${domain}.key" \
        --fullchain-file "${cert_dir}/${domain}.crt" &>/dev/null
    log_info "证书已保存: ${cert_dir}/${domain}.crt"
}

# --- 系统参数优化 ---
optimize_system() {
    log_info "系统参数优化..."
    local sysctl_file="/etc/sysctl.d/99-sb-manager.conf"
    cat > "$sysctl_file" << 'EOF'
# Sing-box Manager 系统优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
fs.file-max = 1000000
net.core.somaxconn = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_syn_backlog = 65535
EOF
    sysctl -p "$sysctl_file" &>/dev/null
    # 修改 limits
    cat > /etc/security/limits.d/99-sb-manager.conf << 'EOF'
* soft nofile 1000000
* hard nofile 1000000
* soft nproc 65535
* hard nproc 65535
EOF
    log_info "系统参数优化完成 (BBR + sysctl)"
}

# --- 防火墙配置 ---
setup_ufw() {
    log_info "配置 UFW 防火墙..."
    if ! command -v ufw &>/dev/null; then
        apt-get install -y -qq ufw &>/dev/null
    fi
    ufw --force reset &>/dev/null
    ufw default deny incoming &>/dev/null
    ufw default allow outgoing &>/dev/null
    ufw allow ssh &>/dev/null
    ufw allow 22/tcp &>/dev/null

    # 开放所有入站端口 (后续管理脚本会动态更新)
    if [[ -f "$USERS_FILE" ]]; then
        jq -r '.users[].inbound.port' "$USERS_FILE" 2>/dev/null | while read -r port; do
            [[ -n "$port" ]] && ufw allow "$port" &>/dev/null
        done
    fi

    # Web 管理端口
    local web_port
    web_port=$(json_get "$SETTINGS_FILE" '.web_port' '2053')
    ufw allow "$web_port/tcp" &>/dev/null

    ufw --force enable &>/dev/null
    log_info "UFW 防火墙配置完成"
}

ufw_allow_port() {
    local port="$1"
    local proto="${2:-tcp}"
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$port/$proto" &>/dev/null
    fi
}

ufw_deny_port() {
    local port="$1"
    local proto="${2:-tcp}"
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw delete allow "$port/$proto" &>/dev/null || true
    fi
}

# --- Fail2ban ---
setup_fail2ban() {
    log_info "配置 Fail2ban..."
    if ! command -v fail2ban-client &>/dev/null; then
        apt-get install -y -qq fail2ban &>/dev/null
    fi
    local web_port
    web_port=$(json_get "$SETTINGS_FILE" '.web_port' '2053')

    cat > /etc/fail2ban/jail.d/sb-manager.conf << EOF
[sb-manager-web]
enabled = true
port = ${web_port}
filter = sb-manager-web
logpath = /opt/sb-manager/logs/manager.log
maxretry = 5
bantime = 3600
findtime = 600
EOF

    cat > /etc/fail2ban/filter.d/sb-manager-web.conf << 'EOF'
[Definition]
failregex = ^.*\[ERROR\].*login failed from <HOST>.*$
ignoreregex =
EOF

    systemctl restart fail2ban &>/dev/null || true
    log_info "Fail2ban 配置完成"
}

# --- Sing-box 服务管理 ---
sb_service() {
    local action="${1:-status}"
    systemctl "$action" sing-box 2>/dev/null || log_error "Sing-box 服务操作失败: $action"
}

sb_reload() {
    log_info "重新生成 Sing-box 配置并重载..."
    if [[ -x "${SB_SCRIPTS}/config-generator.sh" ]]; then
        bash "${SB_SCRIPTS}/config-generator.sh" || {
            log_error "配置生成失败, 取消重载"
            return 1
        }
    fi
    if systemctl is-active --quiet sing-box; then
        if sing-box check -c "$SINGBOX_CONFIG" &>/dev/null; then
            systemctl reload sing-box || systemctl restart sing-box
            log_info "Sing-box 重载成功"
        else
            log_error "Sing-box 配置验证失败, 未执行重载"
            return 1
        fi
    else
        systemctl restart sing-box
        log_info "Sing-box 启动成功"
    fi
}

# --- Sing-box 安装 ---
install_singbox() {
    local version="${1:-latest}"
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *) log_error "不支持的架构: $arch"; exit 1 ;;
    esac

    log_info "安装 Sing-box..."
    mkdir -p "$SB_BIN"

    if [[ "$version" == "latest" ]]; then
        version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/^v//')
        [[ -z "$version" || "$version" == "null" ]] && version="1.11.0"
    fi

    local url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    log_info "下载 Sing-box v${version} (${arch})..."
    if ! curl -L -s --connect-timeout 30 --max-time 300 "$url" -o "${tmp_dir}/sing-box.tar.gz"; then
        # 尝试 GitHub 镜像
        url="https://ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
        curl -L -s --connect-timeout 30 --max-time 300 "$url" -o "${tmp_dir}/sing-box.tar.gz" || {
            log_error "下载 Sing-box 失败"
            rm -rf "$tmp_dir"
            exit 1
        }
    fi

    tar -xzf "${tmp_dir}/sing-box.tar.gz" -C "$tmp_dir"
    cp "${tmp_dir}/sing-box-${version}-linux-${arch}/sing-box" "$SB_BIN/"
    chmod +x "${SB_BIN}/sing-box"
    rm -rf "$tmp_dir"

    # 验证
    if ! "${SB_BIN}/sing-box" version &>/dev/null; then
        log_error "Sing-box 安装验证失败"
        exit 1
    fi
    log_info "Sing-box v${version} 安装完成"
}

# --- 时间格式化 ---
format_bytes() {
    local bytes="$1"
    if [[ "$bytes" -ge 1099511627776 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1099511627776}") TB"
    elif [[ "$bytes" -ge 1073741824 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}") GB"
    elif [[ "$bytes" -ge 1048576 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}") MB"
    elif [[ "$bytes" -ge 1024 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1024}") KB"
    else
        echo "${bytes} B"
    fi
}

parse_size() {
    local size="$1"
    local num
    num=$(echo "$size" | grep -oP '[\d.]+')
    local unit
    unit=$(echo "$size" | grep -oP '[a-zA-Z]+' | tr '[:upper:]' '[:lower:]')
    case "$unit" in
        tb) echo "$(awk "BEGIN {printf \"%.0f\", $num*1099511627776}")" ;;
        gb) echo "$(awk "BEGIN {printf \"%.0f\", $num*1073741824}")" ;;
        mb) echo "$(awk "BEGIN {printf \"%.0f\", $num*1048576}")" ;;
        kb) echo "$(awk "BEGIN {printf \"%.0f\", $num*1024}")" ;;
        b|"") echo "$(awk "BEGIN {printf \"%.0f\", $num}")" ;;
        unlimited|inf|infinity) echo "0" ;;
        *) echo "0" ;;
    esac
}

format_timestamp() {
    local ts="$1"
    if [[ "$ts" == "0" || -z "$ts" || "$ts" == "null" ]]; then
        echo "N/A"
    else
        date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "N/A"
    fi
}

# --- 协议名称映射 ---
protocol_label() {
    case "$1" in
        vless-reality) echo "VLESS + Reality" ;;
        anytls)        echo "AnyTLS" ;;
        hysteria2)     echo "Hysteria2" ;;
        tuic)          echo "TUIC v5" ;;
        shadowtls)     echo "ShadowTLS v3" ;;
        *)             echo "$1" ;;
    esac
}

# --- 确认对话框 ---
confirm() {
    local prompt="${1:-确认?}"
    local default="${2:-n}"
    local yn
    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " yn
        yn="${yn:-y}"
    else
        read -rp "$prompt [y/N]: " yn
        yn="${yn:-n}"
    fi
    [[ "${yn,,}" == "y" || "${yn,,}" == "yes" ]]
}

# --- URL 安全的 Base64 ---
base64url() {
    openssl base64 | tr '+/' '-_' | tr -d '=\n'
}

base64url_decode() {
    local padded="$1"
    case $(( ${#padded} % 4 )) in
        2) padded="${padded}==" ;;
        3) padded="${padded}=" ;;
    esac
    echo "$padded" | tr '-_' '+/' | openssl base64 -d 2>/dev/null
}

# --- 获取已安装协议列表 ---
get_installed_protocols() {
    if [[ -f "$SETTINGS_FILE" ]]; then
        jq -r '.installed_protocols[]?' "$SETTINGS_FILE" 2>/dev/null
    fi
}

# --- 初始化目录结构 ---
init_dirs() {
    mkdir -p "$SB_BIN" "$SB_CONFIG/inbound" "$SB_CONFIG/outbound" \
             "$SB_DATA" "$SB_CERTS" "$SB_WEB/templates" "$SB_WEB/static" \
             "$SB_SCRIPTS" "$SB_LOGS"

    # 初始化数据文件（仅在不存在时创建）
    if [[ ! -f "$USERS_FILE" ]]; then
        echo '{"version":1,"users":{}}' > "$USERS_FILE"
    fi
    if [[ ! -f "$OUTBOUNDS_FILE" ]]; then
        echo '{"version":1,"outbounds":[{"id":"out_direct","name":"直连","type":"direct","tag":"direct","builtin":true,"config":{}}],"strategy_groups":[{"id":"sg_default","name":"默认出站","type":"selector","default":"out_direct","outbounds":["out_direct"]}]}' > "$OUTBOUNDS_FILE"
    fi
    if [[ ! -f "$TRAFFIC_FILE" ]]; then
        echo '{"version":1,"last_reset":0,"users":{},"total":{"down":0,"up":0}}' > "$TRAFFIC_FILE"
    fi
    if [[ ! -f "$SETTINGS_FILE" ]]; then
        echo '{"version":1,"domain":"","email":"","web_port":2053,"web_username":"admin","web_password_hash":"","jwt_secret":"","subscription_domain":"","installed_protocols":[],"fail2ban_enabled":false,"ufw_enabled":false,"traffic_reset_day":1,"installed_at":0}' > "$SETTINGS_FILE"
    fi
}