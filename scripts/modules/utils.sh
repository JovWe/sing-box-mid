# Sing-box Manager - 公共工具函数（精简版, 纯函数, 无 shebang / set -e）
# 由 manager.sh 的 _load_module 加载

# ============ 路径常量 ============
SB_ROOT="/opt/sb-manager"
SB_BIN="${SB_ROOT}/bin"
SB_CONFIG="${SB_ROOT}/core/config"
SB_DATA="${SB_ROOT}/data"
SB_CERTS="${SB_ROOT}/certs"
SB_LOGS="${SB_ROOT}/logs"

USERS_FILE="${SB_DATA}/users.json"
OUTBOUNDS_FILE="${SB_DATA}/outbounds.json"
SETTINGS_FILE="${SB_DATA}/settings.json"
SINGBOX_CONFIG="${SB_CONFIG}/config.json"

# ============ 颜色 ============
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

# ============ 日志 ============
log_info()  { echo -e "${CYAN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S')  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S')  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S')  $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}     $(date '+%Y-%m-%d %H:%M:%S')  $*"; }

# ============ 系统检测 ============
detect_os() {
    [[ -f /etc/os-release ]] && . /etc/os-release
    ID="${ID:-unknown}"
    VERSION_ID="${VERSION_ID:-unknown}"
    ARCH="$(uname -m)"
    log_info "系统检测: $ID $VERSION_ID ($ARCH)"
}

# ============ 依赖安装 ============
install_deps() {
    local packages=(curl wget jq openssl ca-certificates iproute2 procps)
    case "$ID" in
        debian|ubuntu)
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y -qq "${packages[@]}" >/dev/null 2>&1 || true
            ;;
        centos|rocky|rhel|fedora)
            yum install -y -q "${packages[@]}" >/dev/null 2>&1 || true
            ;;
        *)
            log_warn "未知发行版, 请手动安装: ${packages[*]}"
            ;;
    esac
}

# ============ 确认对话框 ============
confirm() {
    local prompt="${1:-确认?}"
    local default="${2:-n}"
    local yn
    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " yn; yn="${yn:-y}"
    else
        read -rp "$prompt [y/N]: " yn; yn="${yn:-n}"
    fi
    [[ "${yn,,}" == "y" || "${yn,,}" == "yes" ]]
}

# ============ JSON 读写 ============
json_get() {
    local file="$1" key="$2" default="${3:-}"
    [[ -f "$file" ]] || { echo "$default"; return; }
    local val
    val=$(jq -r "$key" "$file" 2>/dev/null) || val=""
    if [[ -z "$val" || "$val" == "null" ]]; then echo "$default"; else echo "$val"; fi
}

json_set() {
    local file="$1" key="$2" value="$3"
    local tmp="${file}.tmp.$$"
    if jq "$key = $value" "$file" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

# ============ 随机生成 ============
gen_password() { openssl rand -base64 "${1:-16}" | tr -d '+/=' | head -c "${1:-16}"; }
gen_uuid()     { python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || cat /proc/sys/kernel/random/uuid; }
gen_short_id() { openssl rand -hex 8; }

# ============ 端口 ============
gen_random_port() {
    local min="${1:-10000}" max="${2:-60000}"
    while true; do
        local port=$(( min + RANDOM % (max - min + 1) ))
        if ! ss -tuln 2>/dev/null | awk '{print $5}' | grep -q ":${port}$"; then
            echo "$port"; return 0
        fi
    done
}

# ============ 公网 IP ============
get_public_ip() {
    for url in https://api.ipify.org https://ifconfig.me https://ipv4.icanhazip.com; do
        local ip; ip=$(curl -s --max-time 5 "$url" 2>/dev/null) || continue
        if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
    done
    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip:-unknown}"
}

# ============ Reality 密钥对 ============
gen_reality_keypair() {
    local sb_bin="${SB_BIN}/sing-box"
    if [[ -x "$sb_bin" ]]; then
        "$sb_bin" generate reality-keypair 2>/dev/null
    else
        echo "PrivateKey: $(openssl rand -base64 32)"
        echo "PublicKey: $(openssl rand -base64 32)"
    fi
}

# ============ 协议名称映射 ============
protocol_label() {
    case "${1:-}" in
        vless-reality) echo "VLESS + Reality" ;;
        hysteria2)     echo "Hysteria2" ;;
        tuic)          echo "TUIC v5" ;;
        vmess)         echo "VMess" ;;
        shadowtls)     echo "ShadowTLS v3" ;;
        *)             echo "$1" ;;
    esac
}

# ============ sing-box 控制 ============
sb_reload()   { systemctl reload sing-box 2>/dev/null || systemctl restart sing-box 2>/dev/null; }
sb_restart()  { systemctl restart sing-box 2>/dev/null; }

# ============ 安装 sing-box 内核 ============
install_singbox() {
    local arch
    case "$ARCH" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) arch="amd64" ;;
    esac
    local tag
    tag=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
        | jq -r '.tag_name' 2>/dev/null | head -1)
    tag="${tag:-v1.11.2}"
    local base="${tag#v}"
    local url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${base}-linux-${arch}.tar.gz"
    local tmp="/tmp/singbox.tar.gz"
    log_info "下载 Sing-box ${tag}..."
    curl -fsSL --retry 3 --connect-timeout 30 "$url" -o "$tmp" || { log_error "下载失败"; return 1; }
    local extracted="/tmp/sb-extract-$$"
    mkdir -p "$extracted" "${SB_BIN}"
    tar -xzf "$tmp" -C "$extracted"
    local bin_file
    bin_file=$(find "$extracted" -name sing-box -type f | head -1)
    [[ -n "$bin_file" ]] || { log_error "解压失败"; rm -rf "$extracted" "$tmp"; return 1; }
    mv "$bin_file" "${SB_BIN}/sing-box"
    chmod +x "${SB_BIN}/sing-box"
    rm -rf "$extracted" "$tmp"
    log_ok "Sing-box ${tag} 安装完成"
}

# ============ 系统优化 (BBR + sysctl + ulimit) ============
optimize_system() {
    cat > /etc/sysctl.d/99-sing-box.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p /etc/sysctl.d/99-sing-box.conf >/dev/null 2>&1 || true

    cat > /etc/security/limits.d/sing-box.conf <<'EOF'
* soft nofile 655360
* hard nofile 655360
* soft nproc 65536
* hard nproc 65536
EOF
    log_ok "系统优化完成 (BBR + sysctl + ulimit)"
}

# ============ UFW 防火墙 (可选) ============
ufw_allow_port() {
    local port="$1" proto="${2:-tcp}"
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi "Status: active"; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
    fi
}
