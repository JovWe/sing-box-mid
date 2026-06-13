#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - 一键安装脚本
# 用法: bash <(curl -Ls https://raw.githubusercontent.com/JovWe/sing-box-mid/main/install.sh)
#===============================================================================
set -euo pipefail

# ---- 配置 ----
GITHUB_REPO="https://raw.githubusercontent.com/JovWe/sing-box-mid/main"
SB_ROOT="/opt/sb-manager"
SB_SCRIPTS="${SB_ROOT}/scripts"
SB_MODULES="${SB_SCRIPTS}/modules"
SB_PROTOCOL="${SB_MODULES}/protocol-gen"
SB_BIN="${SB_ROOT}/bin"
SB_CONFIG="${SB_ROOT}/core/config"
SB_DATA="${SB_ROOT}/data"
SB_CERTS="${SB_ROOT}/certs"
SB_LOGS="${SB_ROOT}/logs"

# 要下载的文件列表
INSTALL_FILES=(
    "scripts/manager.sh"
    "scripts/traffic-collector.sh"
    "scripts/cron-daily.sh"
    "scripts/modules/utils.sh"
    "scripts/modules/user-manager.sh"
    "scripts/modules/outbound-manager.sh"
    "scripts/modules/config-generator.sh"
    "scripts/modules/sub-generator.sh"
    "scripts/modules/traffic-collector.sh"
    "scripts/modules/protocol-gen/vless-reality.sh"
    "scripts/modules/protocol-gen/hysteria2.sh"
    "scripts/modules/protocol-gen/tuic.sh"
    "scripts/modules/protocol-gen/anytls.sh"
    "scripts/modules/protocol-gen/shadowtls.sh"
)

# ---- 颜色 ----
RED='\033[0;31m';  GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m';      NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}     $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" 1>&2; }

# ---- 依赖检测 ----
check_deps() {
    local need_install=0
    for cmd in curl jq openssl systemctl; do
        if ! command -v "$cmd" &>/dev/null; then
            log_warn "缺少依赖: $cmd, 尝试安装"
            need_install=1
        fi
    done
    if [[ $need_install -eq 1 ]]; then
        if command -v apt-get &>/dev/null; then
            apt-get update -qq &>/dev/null
            apt-get install -y -qq curl jq openssl ca-certificates &>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y -q curl jq openssl &>/dev/null
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm curl jq openssl &>/dev/null
        fi
    fi
    log_ok "依赖安装完成"
}

# ---- 目录结构 ----
init_dirs() {
    log_info "创建目录结构..."
    mkdir -p "${SB_BIN}" "${SB_CONFIG}/inbound" "${SB_CONFIG}/outbound" \
             "${SB_DATA}" "${SB_CERTS}" "${SB_LOGS}" \
             "${SB_SCRIPTS}" "${SB_MODULES}" "${SB_PROTOCOL}"

    # 数据文件
    [[ ! -f "${SB_DATA}/users.json" ]]    && echo '{"version":1,"users":{}}' > "${SB_DATA}/users.json"
    [[ ! -f "${SB_DATA}/traffic.json" ]]  && echo '{"version":1,"last_reset":0,"users":{},"total":{"down":0,"up":0}}' > "${SB_DATA}/traffic.json"
    [[ ! -f "${SB_DATA}/outbounds.json" ]] && echo '{"version":1,"outbounds":[{"id":"out_direct","name":"直连","type":"direct","tag":"direct","builtin":true,"config":{}}],"strategy_groups":[{"id":"sg_default","name":"默认出站","type":"selector","default":"out_direct","outbounds":["out_direct"]}]}' > "${SB_DATA}/outbounds.json"
    [[ ! -f "${SB_DATA}/settings.json" ]] && echo '{"version":1,"domain":"","email":"","web_port":2053,"web_username":"admin","web_password_hash":"","jwt_secret":"","subscription_domain":"","installed_protocols":[],"fail2ban_enabled":false,"ufw_enabled":false,"traffic_reset_day":1,"installed_at":0}' > "${SB_DATA}/settings.json"
    log_ok "目录结构创建完成"
}

# ---- 下载脚本 ----
download_scripts() {
    log_info "从 GitHub 下载脚本..."
    local failed=0
    for f in "${INSTALL_FILES[@]}"; do
        local target="${SB_ROOT}/${f}"
        local dir
        dir="$(dirname "$target")"
        mkdir -p "$dir"
        if ! curl -fsSL --retry 3 --connect-timeout 10 "${GITHUB_REPO}/${f}" -o "$target"; then
            log_error "下载失败: ${GITHUB_REPO}/${f}"
            failed=1
        fi
    done
    chmod +x "${SB_SCRIPTS}/manager.sh"
    chmod +x "${SB_SCRIPTS}/traffic-collector.sh"
    chmod +x "${SB_SCRIPTS}/cron-daily.sh"

    if [[ $failed -eq 1 ]]; then
        log_error "部分脚本下载失败, 请检查网络或稍后重试"
        exit 1
    fi
    log_ok "脚本部署完成"
}

# ---- 安装 Sing-box 内核 ----
install_singbox_kernel() {
    log_info "下载 Sing-box 内核..."
    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) arch="amd64" ;;
    esac

    local latest_url download_url
    latest_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local tag
    tag=$(curl -fsSL "$latest_url" 2>/dev/null | jq -r '.tag_name' | head -1)
    tag="${tag:-v1.11.2}"

    local base_ver="${tag#v}"
    download_url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${base_ver}-linux-${arch}.tar.gz"

    local tmp="/tmp/singbox-install.tar.gz"
    if ! curl -fsSL --retry 3 --connect-timeout 30 "$download_url" -o "$tmp"; then
        log_error "Sing-box 下载失败: $download_url"
        exit 1
    fi

    local extracted="/tmp/sb-extract-$$"
    mkdir -p "$extracted"
    tar -xzf "$tmp" -C "$extracted"
    local bin_file
    bin_file="$(find "$extracted" -name sing-box -type f | head -1)"
    if [[ -z "$bin_file" ]]; then
        log_error "解压后未找到 sing-box 可执行文件"
        exit 1
    fi
    mv "$bin_file" "${SB_BIN}/sing-box"
    chmod +x "${SB_BIN}/sing-box"
    rm -rf "$extracted" "$tmp"
    log_ok "Sing-box ${tag} 安装完成"
}

# ---- 创建 systemd 服务 ----
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
ExecStart=/opt/sb-manager/bin/sing-box run -c /opt/sb-manager/core/config/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1000000
LimitNPROC=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/sb-traffic.service << 'EOF'
[Unit]
Description=Sing-box Traffic Collector
After=sing-box.service
Requires=sing-box.service

[Service]
Type=simple
User=root
ExecStart=/bin/bash /opt/sb-manager/scripts/traffic-collector.sh daemon
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box &>/dev/null || true
    systemctl enable sb-traffic &>/dev/null || true
    log_ok "systemd 服务创建完成"
}

# ---- 首次生成主配置 ----
generate_main_config() {
    log_info "生成初始主配置..."
    # 用一份最小可用的配置, 后续 add-user 会自动扩展
    "${SB_SCRIPTS}/manager.sh" reload >/dev/null 2>&1 || true
    # 如果 manager 失败, 回退到直接写一份最小配置
    if [[ ! -f "${SB_CONFIG}/config.json" ]]; then
        cat > "${SB_CONFIG}/config.json" << 'EOF'
{
  "log": {"level": "warn", "output": "/opt/sb-manager/logs/sing-box.log", "timestamp": true},
  "inbounds": [],
  "outbounds": [{"type":"selector","tag":"proxy","outbounds":["direct"],"default":"direct"},{"type":"direct","tag":"direct"}],
  "route": {"final": "direct", "auto_detect_interface": true}
}
EOF
    fi
    log_ok "初始主配置生成完成"
}

# ---- 系统优化 ----
optimize_system() {
    log_info "执行系统优化 (BBR + sysctl)..."
    cat > /etc/sysctl.d/99-sb.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p /etc/sysctl.d/99-sb.conf &>/dev/null || true
    cat > /etc/security/limits.d/sb.conf << 'EOF'
* soft nofile 655360
* hard nofile 655360
* soft nproc 65536
* hard nproc 65536
EOF
    log_ok "系统优化完成"
}

# ---- 安装命令行工具 ----
install_cli() {
    log_info "安装 sb-manager 命令行工具..."
    cat > /usr/local/bin/sb-manager << 'CLI'
#!/usr/bin/env bash
exec bash /opt/sb-manager/scripts/manager.sh "$@"
CLI
    chmod +x /usr/local/bin/sb-manager
    log_ok "命令行工具已安装: sb-manager"
}

# ---- 安装 Cron ----
install_cron() {
    log_info "配置每日定时任务..."
    cat > /etc/cron.d/sb-manager << 'CRON'
# 每天 00:05 检查用户过期 + 流量超限
5 0 * * * root /bin/bash /opt/sb-manager/scripts/cron-daily.sh >> /opt/sb-manager/logs/cron.log 2>&1
CRON
    chmod 0644 /etc/cron.d/sb-manager
    log_ok "Cron 配置完成"
}

# ---- Banner ----
show_banner() {
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║       ███████╗██╗███╗   ██╗ ██████╗                         ║
║       ██╔════╝██║████╗  ██║██╔════╝                         ║
║       ███████╗██║██╔██╗ ██║██║  ███╗                        ║
║       ╚════██║██║██║╚██╗██║██║   ██║                        ║
║       ███████║██║██║ ╚████║╚██████╔╝                        ║
║       ╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝                         ║
║                                                              ║
║       ███╗   ███╗ █████╗ ███╗   ██╗ █████╗  ██████╗ ███████╗║
║       ████╗ ████║██╔══██╗████╗  ██║██╔══██╗██╔════╝ ██╔════╝║
║       ██╔████╔██║███████║██╔██╗ ██║███████║██║  ███╗█████╗  ║
║       ██║╚██╔╝██║██╔══██║██║╚██╗██║██╔══██║██║   ██║██╔══╝  ║
║       ██║ ╚═╝ ██║██║  ██║██║ ╚████║██║  ██║╚██████╔╝███████╗║
║       ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝║
║                                                              ║
║            Sing-box VPS 中转站管理系统 (模块化架构)          ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
}

# ============================
# 主流程
# ============================
show_banner

echo ""
echo "请选择要安装的协议:"
echo ""
echo "  [1] 全部协议 (推荐)"
echo "  [2] VLESS + Reality"
echo "  [3] Hysteria2"
echo "  [4] TUIC v5"
echo "  [5] AnyTLS"
echo "  [6] ShadowTLS v3"
echo "  [7] 自定义选择"
echo ""
read -rp "请输入选项 [1-7] (默认: 1) " proto_choice
proto_choice="${proto_choice:-1}"

PROTO_LIST=""
case "$proto_choice" in
    1) PROTO_LIST="vless-reality,hysteria2,tuic,anytls,shadowtls" ;;
    2) PROTO_LIST="vless-reality" ;;
    3) PROTO_LIST="hysteria2" ;;
    4) PROTO_LIST="tuic" ;;
    5) PROTO_LIST="anytls" ;;
    6) PROTO_LIST="shadowtls" ;;
    7)
        echo ""
        echo "可用协议: vless-reality, hysteria2, tuic, anytls, shadowtls"
        echo "多个协议用逗号分隔, 例如: vless-reality,hysteria2"
        read -rp "输入: " PROTO_LIST
        ;;
    *)
        log_error "无效选项"
        exit 1
        ;;
esac

echo ""
echo -e "已选择协议: ${BOLD}${PROTO_LIST//,/, }${NC}"
echo ""

read -rp "确认安装? [Y/n] " confirm_install
if [[ "${confirm_install,,}" == "n" ]]; then
    echo "已取消"
    exit 0
fi
echo ""

# ---- 执行安装流程 ----
echo "[1/9] 安装基础依赖..."
check_deps

echo "[2/9] 安装 Sing-box 内核..."
install_singbox_kernel

echo "[3/9] 初始化目录结构..."
init_dirs

echo "[4/9] 部署管理脚本..."
download_scripts

echo "[5/9] 初始化数据文件..."
# 记录已安装协议
if command -v jq &>/dev/null; then
    proto_json="[\"$(echo "$PROTO_LIST" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | paste -sd, | sed 's/,/","/g')\"]"
    jq --argjson v "$proto_json" '.installed_protocols = $v | .installed_at = now' \
        "${SB_DATA}/settings.json" > "${SB_DATA}/settings.json.tmp" && \
        mv "${SB_DATA}/settings.json.tmp" "${SB_DATA}/settings.json"
fi

echo "[6/9] 创建系统服务..."
create_services

echo "[7/9] 生成初始配置..."
generate_main_config

echo "[8/9] 系统优化..."
optimize_system

echo "[9/9] 安装命令行工具..."
install_cli
install_cron

# ---- 完成 ----
local_ip=""
if command -v curl &>/dev/null; then
    local_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
fi
if [[ -z "$local_ip" ]]; then
    local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                              ║"
echo "║           Sing-box Manager 安装完成!                         ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo -e "管理服务器:   http://${local_ip}:2053"
echo -e "管理命令:     ${BOLD}sb-manager help${NC}"
echo -e "已安装协议:   ${BOLD}${PROTO_LIST//,/, }${NC}"
echo ""
echo "下一步:"
echo "  1. 添加用户:  sb-manager add-user"
echo "  2. 添加上游出站: sb-manager add-outbound"
echo "  3. 查看状态:  sb-manager status"
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  安装完成! 享受使用吧 ~                                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
