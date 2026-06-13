#===============================================================================
# Sing-box Manager - 工具函数库（纯函数模块，仅在被加载时定义常量和函数）
#===============================================================================

# ---------- 路径常量 ----------
SB_ROOT="/opt/sb-manager"
SB_BIN="${SB_ROOT}/bin"
SB_CONFIG="${SB_ROOT}/core/config"
SB_DATA="${SB_ROOT}/data"
SB_CERTS="${SB_ROOT}/certs"
SB_SCRIPTS="${SB_ROOT}/scripts"
SB_LOGS="${SB_ROOT}/logs"
SB_WEB="${SB_ROOT}/web-backend"

USERS_FILE="${SB_DATA}/users.json"
OUTBOUNDS_FILE="${SB_DATA}/outbounds.json"
TRAFFIC_FILE="${SB_DATA}/traffic.json"
SETTINGS_FILE="${SB_DATA}/settings.json"
SINGBOX_CONFIG="${SB_CONFIG}/config.json"

# ---------- 颜色 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------- 日志 ----------
log_info()  { echo -e "${CYAN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S')  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S')  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S')  $*" 1>&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}     $(date '+%Y-%m-%d %H:%M:%S')  $*"; }

# ---------- 时间戳格式化 ----------
format_timestamp() {
    local ts="$1"
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
        date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ts"
    else
        echo "$ts"
    fi
}

format_bytes() {
    local bytes="${1:-0}"
    if [[ "$bytes" -lt 1024 ]]; then
        echo "${bytes} B"
    elif [[ "$bytes" -lt 1048576 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1024}") KB"
    elif [[ "$bytes" -lt 1073741824 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}") MB"
    else
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}") GB"
    fi
}

# ---------- 系统检测 ----------
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        ID="${ID:-unknown}"
        VERSION_ID="${VERSION_ID:-unknown}"
    else
        ID="unknown"
        VERSION_ID="unknown"
    fi
    ARCH="$(uname -m)"
    log_info "系统检测: $ID $VERSION_ID ($ARCH)"
}

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "需要 root 权限, 请使用 sudo"
        exit 1
    fi
}

# ---------- 安装依赖 ----------
install_deps() {
    local packages=("curl" "wget" "jq" "openssl" "coreutils" "tar" "iptables" "iproute2" "procps")
    log_info "安装基础依赖..."
    case "$ID" in
        debian|ubuntu)
            apt-get update -qq &>/dev/null
            apt-get install -y -qq "${packages[@]}" &>/dev/null || true
            ;;
        centos|rocky|rhel|fedora)
            yum install -y -q "${packages[@]}" &>/dev/null || true
            ;;
        arch)
            pacman -Sy --noconfirm "${packages[@]}" &>/dev/null || true
            ;;
        *)
            log_warn "未知发行版, 请手动安装: ${packages[*]}"
            ;;
    esac
    log_info "依赖安装完成"
}

# ---------- 确认对话框 ----------
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

# ---------- JSON 读写 ----------
json_get() {
    local file="$1"
    local key="$2"
    local default="${3:-}"
    if [[ ! -f "$file" ]]; then
        echo "$default"
        return
    fi
    local val
    val=$(jq -r "$key" "$file" 2>/dev/null) || val=""
    if [[ -z "$val" || "$val" == "null" ]]; then
        echo "$default"
    else
        echo "$val"
    fi
}

json_set() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp="${file}.tmp.$(date +%s)"
    jq "$key = $value" "$file" > "$tmp" && mv "$tmp" "$file"
}

# ---------- 随机生成 ----------
gen_password() {
    local len="${1:-32}"
    openssl rand -base64 "$len" | tr -d '+/=' | head -c "$len"
}

gen_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr 'A-Z' 'a-z'
    else
        python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
        echo "$(od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}')"
    fi
}

gen_short_id() {
    openssl rand -hex 8
}

gen_token() {
    openssl rand -hex 16
}

# ---------- 端口相关 ----------
gen_random_port() {
    local min="${1:-10000}"
    local max="${2:-60000}"
    while true; do
        local port
        port=$(awk "BEGIN{srand(); print int(rand()*($max-$min+1)+$min)}")
        if ! ss -tuln | awk '{print $5}' | grep -q ":${port}$"; then
            echo "$port"
            return 0
        fi
    done
}

is_port_available() {
    ss -tuln | grep -q ":$1 " || return 1
    return 0
}

# ---------- 公网 IP ----------
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://ipv4.icanhazip.com"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null) || continue
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    done
    # Fallback: hostname/ip route
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip:-unknown}"
}

# ---------- Reality 密钥对 ----------
gen_reality_keypair() {
    if [[ -x "${SB_BIN}/sing-box" ]]; then
        "${SB_BIN}/sing-box" generate reality-keypair 2>/dev/null || true
    elif command -v sing-box &>/dev/null; then
        sing-box generate reality-keypair 2>/dev/null || true
    else
        log_warn "建议安装 sing-box 后重新生成 Reality 密钥"
        echo "PrivateKey: $(openssl rand -base64 32)"
        echo "PublicKey: $(openssl rand -base64 32)"
    fi
}

# ---------- 证书申请 ----------
issue_cert() {
    local domain="$1"
    log_info "申请证书: $domain"
    if command -v certbot &>/dev/null; then
        certbot certonly --standalone -d "$domain" -m "admin@$domain" --non-interactive --agree-tos &>/dev/null || return 1
        local cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
        local key_path="/etc/letsencrypt/live/${domain}/privkey.pem"
        if [[ -f "$cert_path" ]]; then
            cp "$cert_path" "${SB_CERTS}/${domain}.crt"
            cp "$key_path" "${SB_CERTS}/${domain}.key"
            log_info "证书已保存: ${SB_CERTS}/${domain}.crt"
            return 0
        fi
    fi
    return 1
}

# ---------- UFW 防火墙 ----------
ufw_allow_port() {
    local port="$1"
    local proto="${2:-tcp}"
    if command -v ufw &>/dev/null && ufw status | grep -qi "Status: active"; then
        ufw allow "${port}/${proto}" &>/dev/null || true
    fi
}

ufw_deny_port() {
    local port="$1"
    local proto="${2:-tcp}"
    if command -v ufw &>/dev/null && ufw status | grep -qi "Status: active"; then
        ufw delete allow "${port}/${proto}" &>/dev/null || true
    fi
}

# ---------- Fail2ban ----------
install_fail2ban() {
    log_info "安装 Fail2ban..."
    case "$ID" in
        debian|ubuntu)
            apt-get install -y fail2ban &>/dev/null || true
            ;;
        centos|rocky|rhel|fedora)
            yum install -y fail2ban &>/dev/null || true
            ;;
    esac
    systemctl enable fail2ban &>/dev/null || true
    systemctl start fail2ban &>/dev/null || true
    log_info "Fail2ban 配置完成"
}

# ---------- Sing-box 控制 ----------
sb_reload() {
    systemctl reload sing-box 2>/dev/null || systemctl restart sing-box 2>/dev/null || true
}

sb_restart() {
    systemctl restart sing-box 2>/dev/null || true
}

sb_stop() {
    systemctl stop sing-box 2>/dev/null || true
}

# ---------- 安装 Sing-box ----------
install_singbox() {
    local version="${1:-latest}"
    log_info "下载 Sing-box ${version}..."

    local arch
    case "$ARCH" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) arch="amd64" ;;
    esac

    if [[ "$version" == "latest" ]]; then
        version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' 2>/dev/null || echo "v1.10.0")
    fi

    local base_version="${version#v}"
    local url="https://github.com/SagerNet/sing-box/releases/download/${version}/sing-box-${base_version}-linux-${arch}.tar.gz"
    local tmp="/tmp/singbox.tar.gz"

    curl -sL "$url" -o "$tmp" || true
    if [[ ! -s "$tmp" ]]; then
        log_error "下载失败, 请检查网络"
        return 1
    fi

    mkdir -p "${SB_BIN}"
    tar -xzf "$tmp" -C /tmp/
    local extracted
    extracted=$(ls -d /tmp/sing-box-*/ 2>/dev/null | head -1)
    if [[ -n "$extracted" && -f "${extracted}/sing-box" ]]; then
        mv "${extracted}/sing-box" "${SB_BIN}/"
        chmod +x "${SB_BIN}/sing-box"
        rm -rf "$extracted"
    else
        log_error "解压失败, 请手动检查"
        return 1
    fi
    rm -f "$tmp"
    log_info "Sing-box ${version} 安装完成"
}

# ---------- 协议名称映射 ----------
protocol_label() {
    case "${1:-}" in
        vless-reality) echo "VLESS + Reality" ;;
        hysteria2)     echo "Hysteria2" ;;
        tuic)          echo "TUIC v5" ;;
        anytls)        echo "AnyTLS" ;;
        shadowtls)     echo "ShadowTLS v3" ;;
        *)             echo "$1" ;;
    esac
}

# ---------- 初始化目录结构 ----------
init_dirs() {
    mkdir -p "$SB_BIN" "$SB_CONFIG/inbound" "$SB_CONFIG/outbound" \
             "$SB_DATA" "$SB_CERTS" "$SB_WEB/templates" "$SB_WEB/static" \
             "$SB_SCRIPTS" "$SB_LOGS"

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

# ---------- 系统优化 ----------
optimize_system() {
    log_info "优化系统参数 (BBR + sysctl)..."
    # sysctl
    cat > /etc/sysctl.d/99-sing-box.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p /etc/sysctl.d/99-sing-box.conf &>/dev/null || true

    # limits
    cat > /etc/security/limits.d/sing-box.conf << 'EOF'
* soft nofile 655360
* hard nofile 655360
* soft nproc 65536
* hard nproc 65536
EOF
    log_info "系统参数优化完成"
}
