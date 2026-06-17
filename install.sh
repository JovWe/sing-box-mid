#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - 一键安装脚本
# 用法: bash <(curl -Ls https://raw.githubusercontent.com/JovWe/sing-box-mid/main/install.sh)
#===============================================================================
set -euo pipefail

# ============ 配置 ============
GITHUB_REPO="https://raw.githubusercontent.com/JovWe/sing-box-mid/main"
SB_ROOT="/opt/sb"
SB_SCRIPTS="${SB_ROOT}/scripts"
SB_MODULES="${SB_SCRIPTS}/modules"
SB_PROTOCOL="${SB_MODULES}/protocol-gen"
SB_BIN="${SB_ROOT}/bin"
SB_CONFIG="${SB_ROOT}/core/config"
SB_DATA="${SB_ROOT}/data"
SB_CERTS="${SB_ROOT}/certs"
SB_LOGS="${SB_ROOT}/logs"
SB_WWW="${SB_ROOT}/www"

INSTALL_FILES=(
    "scripts/sb"
    "scripts/modules/db.sh"
    "scripts/modules/user-manager.sh"
    "scripts/modules/outbound-manager.sh"
    "scripts/modules/config-generator.sh"
    "scripts/modules/traffic-collector.sh"
    "scripts/modules/protocol-gen/vless-reality.sh"
    "scripts/modules/protocol-gen/hysteria2.sh"
    "scripts/modules/protocol-gen/tuic.sh"
    "scripts/modules/protocol-gen/shadowtls.sh"
    "scripts/modules/protocol-gen/vmess.sh"
    "scripts/sub-api/sub.sh"
)

# ============ 颜色 / 日志 ============
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}     $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ============ 1. 检测系统 ============
detect_os() {
    [[ -f /etc/os-release ]] && . /etc/os-release
    ID="${ID:-unknown}"
    ARCH="$(uname -m)"
    log_info "系统: $ID  架构: $ARCH"
    if ! command -v apt-get &>/dev/null && ! command -v yum &>/dev/null; then
        log_error "仅支持 Debian/Ubuntu/CentOS 系系统"
        exit 1
    fi
}

# ============ 2. 安装依赖 ============
install_deps() {
    log_info "安装基础依赖..."
    local pkgs=(curl wget jq openssl sqlite3 ca-certificates iproute2 procps iptables)
    if command -v apt-get &>/dev/null; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1 || true
    elif command -v yum &>/dev/null; then
        yum install -y -q "${pkgs[@]}" >/dev/null 2>&1 || true
    fi
    # python3 (用于 uuid 生成)
    command -v python3 &>/dev/null || {
        if command -v apt-get &>/dev/null; then
            apt-get install -y -qq python3 >/dev/null 2>&1 || true
        else
            yum install -y -q python3 >/dev/null 2>&1 || true
        fi
    }
    log_ok "依赖安装完成"
}

# ============ 3. 下载脚本 ============
download_scripts() {
    log_info "从 GitHub 下载脚本..."
    local failed=0
    for f in "${INSTALL_FILES[@]}"; do
        local target="${SB_ROOT}/${f}"
        mkdir -p "$(dirname "$target")"
        if ! curl -fsSL --retry 3 --connect-timeout 10 "${GITHUB_REPO}/${f}" -o "$target"; then
            log_error "下载失败: ${GITHUB_REPO}/${f}"
            failed=1
        fi
    done
    chmod +x "${SB_SCRIPTS}/sb" "${SB_SCRIPTS}/sub-api/sub.sh"
    [[ $failed -eq 1 ]] && { log_error "部分脚本下载失败, 请检查网络"; exit 1; }
    log_ok "脚本部署完成"
}

# ============ 4. 安装 sing-box 内核 ============
install_singbox_kernel() {
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
    local tmp="/tmp/singbox-install.tar.gz"
    log_info "下载 Sing-box ${tag}..."
    if ! curl -fsSL --retry 3 --connect-timeout 30 "$url" -o "$tmp"; then
        log_error "Sing-box 下载失败"
        exit 1
    fi
    local extracted="/tmp/sb-extract-$$"
    mkdir -p "$extracted" "${SB_BIN}"
    tar -xzf "$tmp" -C "$extracted"
    local bin_file
    bin_file=$(find "$extracted" -name sing-box -type f | head -1)
    if [[ -z "$bin_file" ]]; then
        log_error "解压后未找到 sing-box"
        exit 1
    fi
    mv "$bin_file" "${SB_BIN}/sing-box"
    chmod +x "${SB_BIN}/sing-box"
    rm -rf "$extracted" "$tmp"
    log_ok "Sing-box ${tag} 安装完成"
}

# ============ 5. 初始化目录 + 数据库 ============
init_system() {
    log_info "初始化目录结构..."
    mkdir -p "${SB_BIN}" "${SB_CONFIG}/inbound" "${SB_CONFIG}/outbound" \
             "${SB_DATA}" "${SB_CERTS}" "${SB_LOGS}" \
             "${SB_SCRIPTS}" "${SB_MODULES}" "${SB_PROTOCOL}" \
             "${SB_WWW}"

    # 初始化数据库
    source "${SB_MODULES}/db.sh"
    db_init

    log_ok "目录结构和数据库初始化完成"
}

# ============ 6. 生成订阅令牌 ============
setup_subscription() {
    local token
    token=$(openssl rand -hex 16)
    echo "$token" > "${SB_DATA}/sub_token.txt"
    log_ok "订阅令牌: $token"
}

# ============ 7. systemd 服务 ============
create_services() {
    log_info "创建 systemd 服务..."

    cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=/opt/sb/bin/sing-box run -c /opt/sb/core/config/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1000000
LimitNPROC=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box &>/dev/null || true
    log_ok "sing-box systemd 服务创建完成"
}

# ============ 8. 生成初始配置 ============
generate_initial_config() {
    log_info "生成初始配置..."
    # 先 source config-generator 生成空配置
    source "${SB_MODULES}/config-generator.sh"
    generate_config
    log_ok "初始配置已生成"
}

# ============ 9. 系统优化 ============
optimize_system() {
    log_info "执行系统优化 (BBR + sysctl)..."
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
    log_ok "系统优化完成"
}

# ============ 10. 安装 CLI 工具 ============
install_cli() {
    log_info "安装 sb 命令行工具..."
    cp "${SB_SCRIPTS}/sb" /usr/local/bin/sb
    chmod +x /usr/local/bin/sb
    log_ok "命令行工具已安装: sb"
}

# ============ Banner ============
show_banner() {
    cat << 'EOF'

         ███████╗██╗███╗   ██╗ ██████╗
         ██╔════╝██║████╗  ██║██╔════╝
         ███████╗██║██╔██╗ ██║██║  ███╗
         ╚════██║██║██║╚██╗██║██║   ██║
         ███████║██║██║ ╚████║╚██████╔╝
         ╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝

         ██████╗  ██████╗ ██╗  ██╗
         ██╔══██╗██╔═══██╗██║ ██╔╝
         ██████╔╝██║   ██║█████╔╝
         ██╔══██╗██║   ██║██╔═██╗
         ██████╔╝╚██████╔╝██║  ██╗
         ╚═════╝  ╚═════╝ ╚═╝  ╚═╝

            Sing-box VPS 中转站管理系统  (SQLite版)

EOF
}

# ============================
# 主流程
# ============================
show_banner
detect_os

echo "请选择要安装的协议 (逗号分隔, 或 'all'):"
echo "  1) VLESS + Reality"
echo "  2) Hysteria2"
echo "  3) TUIC v5"
echo "  4) ShadowTLS v3"
echo "  5) VMess"
echo "  all) 全部安装"
echo "  none) 暂不安装, 只装基础"
echo ""
read -rp "请选择 [1-5/all/none] (默认: all): " PROTO_CHOICE
PROTO_CHOICE="${PROTO_CHOICE:-all}"

case "$PROTO_CHOICE" in
    1) PROTO_LIST="vless-reality" ;;
    2) PROTO_LIST="hysteria2" ;;
    3) PROTO_LIST="tuic" ;;
    4) PROTO_LIST="shadowtls" ;;
    5) PROTO_LIST="vmess" ;;
    all)  PROTO_LIST="vless-reality,hysteria2,tuic,shadowtls,vmess" ;;
    none) PROTO_LIST="" ;;
    *)    PROTO_LIST="$PROTO_CHOICE" ;;
esac

echo ""
echo -e "已选择协议: ${BOLD}${PROTO_LIST:-无}${NC}"
echo ""
read -rp "确认安装? [Y/n] " confirm_install
if [[ "${confirm_install,,}" == "n" ]]; then
    echo "已取消"
    exit 0
fi
echo ""

# ---- 执行安装流程 ----
echo -e "\n${BOLD}[1/10]${NC} 检测系统..."
detect_os

echo -e "\n${BOLD}[2/10]${NC} 安装基础依赖..."
install_deps

echo -e "\n${BOLD}[3/10]${NC} 创建目录结构..."
mkdir -p "${SB_BIN}" "${SB_CONFIG}/inbound" "${SB_CONFIG}/outbound" \
         "${SB_DATA}" "${SB_CERTS}" "${SB_LOGS}" \
         "${SB_SCRIPTS}" "${SB_MODULES}" "${SB_PROTOCOL}" \
         "${SB_WWW}"

echo -e "\n${BOLD}[4/10]${NC} 下载管理脚本..."
download_scripts

echo -e "\n${BOLD}[5/10]${NC} 安装 Sing-box 内核..."
install_singbox_kernel

echo -e "\n${BOLD}[6/10]${NC} 初始化数据库..."
source "${SB_MODULES}/db.sh"
db_init

echo -e "\n${BOLD}[7/10]${NC} 生成订阅令牌..."
setup_subscription

echo -e "\n${BOLD}[8/10]${NC} 创建 systemd 服务..."
create_services

echo -e "\n${BOLD}[9/10]${NC} 系统优化 (BBR + sysctl)..."
optimize_system

echo -e "\n${BOLD}[10/10]${NC} 生成初始配置 + 安装 CLI..."
# 生成初始配置
source "${SB_MODULES}/config-generator.sh"
generate_config

# 安装 CLI
cp "${SB_SCRIPTS}/sb" /usr/local/bin/sb
chmod +x /usr/local/bin/sb

# ---- 完成 ----
local_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
[[ -z "$local_ip" ]] && local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

SUB_TOKEN=$(cat "${SB_DATA}/sub_token.txt" 2>/dev/null || echo "(未设置)")

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                              ║"
echo "║           Sing-box Manager 安装完成! (SQLite版)              ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo -e "公网 IP:    ${BOLD}${local_ip}${NC}"
echo -e "管理命令:   ${BOLD}sb help${NC}"
echo -e "订阅令牌:   ${BOLD}${SUB_TOKEN}${NC}"
echo -e "已装协议:   ${BOLD}${PROTO_LIST:-未装入站协议}${NC}"
echo ""
echo "下一步:"
echo "  1. sb add-user                     添加用户"
echo "  2. sb add-outbound                 添加上游出站"
echo "  3. sb sub                          查看所有用户分享链接"
echo "  4. sb sub <用户名>                 查看单个用户分享链接"
echo "  5. sb status                       查看状态"
echo ""
echo "分享链接示例:"
echo "  sb sub testuser"
echo "  输出: vless://xxxxxxxx@66.154.104.22:443?...#testuser"
echo "  直接复制到 v2rayN / Shadowrocket / Clash 等客户端使用"
echo ""
echo "注意: 防火墙需手动放行端口, 例如:"
echo "  ufw allow 443/tcp && ufw enable"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  安装完成! 享受使用吧 ~                                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""