#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - 一键安装脚本
# 用法: bash <(curl -Ls https://raw.githubusercontent.com/JovWe/sing-box-mid/main/install.sh)
#===============================================================================
set -euo pipefail

# ============================================================================
# 前置检查
# ============================================================================
if [[ $EUID -ne 0 ]]; then
    echo "错误: 此脚本必须以 root 权限运行"
    exit 1
fi

# 检测系统
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "$ID" in
        debian)
            if [[ "$VERSION_ID" != "12" && "$VERSION_ID" != "13" ]]; then
                echo "警告: 推荐 Debian 12/13, 当前: Debian $VERSION_ID"
            fi
            ;;
        ubuntu)
            if [[ "$VERSION_ID" != "22.04" && "$VERSION_ID" != "24.04" ]]; then
                echo "警告: 推荐 Ubuntu 22.04/24.04, 当前: Ubuntu $VERSION_ID"
            fi
            ;;
        *)
            echo "错误: 不支持的系统: $ID"
            exit 1
            ;;
    esac
else
    echo "错误: 无法检测操作系统"
    exit 1
fi

# ============================================================================
# 颜色定义
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================================
# 全局变量
# ============================================================================
SB_BASE="/opt/sb-manager"
SB_BIN="${SB_BASE}/bin"
SB_CORE="${SB_BASE}/core"
SB_CONFIG="${SB_CORE}/config"
SB_DATA="${SB_CORE}/data"
SB_CERTS="${SB_CORE}/certs"
SB_WEB="${SB_CORE}/web"
SB_SCRIPTS="${SB_BASE}/scripts"
SB_LOGS="${SB_BASE}/logs"

GITHUB_REPO="https://raw.githubusercontent.com/JovWe/sing-box-mid/main"
GITHUB_PROXY="https://ghproxy.com/${GITHUB_REPO}"

# ============================================================================
# 欢迎界面
# ============================================================================
show_banner() {
    clear
    cat << 'BANNER'

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
║            Sing-box VPS 中转站部署管理系统                   ║
║                      v1.0.0                                  ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝

BANNER
    echo -e "  系统: ${GREEN}${ID} ${VERSION_ID}${NC}  |  架构: ${GREEN}$(uname -m)${NC}"
    echo ""
}

# ============================================================================
# 协议选择
# ============================================================================
select_protocols() {
    echo -e "${CYAN}请选择要安装的协议:${NC}"
    echo ""
    echo "  [1] 全部协议 (推荐)"
    echo "  [2] VLESS + Reality"
    echo "  [3] Hysteria2"
    echo "  [4] TUIC v5"
    echo "  [5] AnyTLS"
    echo "  [6] ShadowTLS v3"
    echo "  [7] 自定义选择"
    echo ""

    local choice
    read -rp "请输入选项 [1-7] (默认: 1): " choice
    choice="${choice:-1}"

    case "$choice" in
        1)
            PROTOCOLS=("vless-reality" "hysteria2" "tuic" "anytls" "shadowtls")
            ;;
        2)
            PROTOCOLS=("vless-reality")
            ;;
        3)
            PROTOCOLS=("hysteria2")
            ;;
        4)
            PROTOCOLS=("tuic")
            ;;
        5)
            PROTOCOLS=("anytls")
            ;;
        6)
            PROTOCOLS=("shadowtls")
            ;;
        7)
            echo ""
            echo "选择协议 (输入数字, 用空格分隔):"
            echo "  1) VLESS + Reality"
            echo "  2) Hysteria2"
            echo "  3) TUIC v5"
            echo "  4) AnyTLS"
            echo "  5) ShadowTLS v3"
            read -rp "选择: " -a selections
            PROTOCOLS=()
            for s in "${selections[@]}"; do
                case "$s" in
                    1) PROTOCOLS+=("vless-reality") ;;
                    2) PROTOCOLS+=("hysteria2") ;;
                    3) PROTOCOLS+=("tuic") ;;
                    4) PROTOCOLS+=("anytls") ;;
                    5) PROTOCOLS+=("shadowtls") ;;
                esac
            done
            if [[ ${#PROTOCOLS[@]} -eq 0 ]]; then
                echo "未选择任何协议, 使用默认: 全部"
                PROTOCOLS=("vless-reality" "hysteria2" "tuic" "anytls" "shadowtls")
            fi
            ;;
        *)
            echo "无效选择, 使用默认: 全部"
            PROTOCOLS=("vless-reality" "hysteria2" "tuic" "anytls" "shadowtls")
            ;;
    esac

    echo ""
    echo -e "已选择协议:"
    for p in "${PROTOCOLS[@]}"; do
        echo -e "  ${GREEN}+${NC} $p"
    done
    echo ""
    confirm "确认安装?" "y" || exit 0
}

# ============================================================================
# 安装函数
# ============================================================================
install_dependencies() {
    echo -e "${GREEN}[1/9]${NC} 安装基础依赖..."
    apt-get update -qq
    apt-get install -y -qq curl wget jq uuid-runtime openssl cron nftables tar gzip &>/dev/null
    echo "  -> 依赖安装完成"
}

install_singbox_binary() {
    echo -e "${GREEN}[2/9]${NC} 安装 Sing-box 内核..."
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *) echo "不支持的架构: $arch"; exit 1 ;;
    esac

    mkdir -p "$SB_BIN"

    local version
    version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name' | sed 's/^v//')
    [[ -z "$version" || "$version" == "null" ]] && version="1.11.0"

    local url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    echo "  -> 下载 Sing-box v${version}..."
    if ! curl -L -s --connect-timeout 30 --max-time 300 "$url" -o "${tmp_dir}/sing-box.tar.gz"; then
        url="https://ghproxy.com/https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
        curl -L -s --connect-timeout 30 --max-time 300 "$url" -o "${tmp_dir}/sing-box.tar.gz" || {
            echo "下载失败"
            rm -rf "$tmp_dir"
            exit 1
        }
    fi

    tar -xzf "${tmp_dir}/sing-box.tar.gz" -C "$tmp_dir"
    cp "${tmp_dir}/sing-box-${version}-linux-${arch}/sing-box" "$SB_BIN/"
    chmod +x "${SB_BIN}/sing-box"
    rm -rf "$tmp_dir"
    echo "  -> Sing-box v${version} 安装完成"
}

init_directory_structure() {
    echo -e "${GREEN}[3/9]${NC} 初始化目录结构..."
    mkdir -p "$SB_BIN" "$SB_CONFIG/inbound" "$SB_CONFIG/outbound" \
             "$SB_DATA" "$SB_CERTS" "$SB_WEB/templates" "$SB_WEB/static" \
             "$SB_SCRIPTS/protocol-gen" "$SB_LOGS"
    echo "  -> 目录结构创建完成"
}

download_scripts() {
    echo -e "${GREEN}[4/9]${NC} 部署管理脚本..."

    # 如果是通过 curl 安装 (远程), 从 GitHub 下载
    # 如果是本地安装, 直接从当前目录复制
    if [[ -f "${SCRIPT_DIR:-.}/scripts/utils.sh" ]]; then
        echo "  -> 检测到本地安装, 从本地复制..."
        cp -r "${SCRIPT_DIR:-.}/scripts/"* "$SB_SCRIPTS/"
    else
        echo "  -> 从 GitHub 下载脚本..."
        # 下载核心脚本
        local scripts=(
            "utils.sh"
            "manager.sh"
            "user-manager.sh"
            "outbound-manager.sh"
            "config-generator.sh"
            "traffic-collector.sh"
            "sub-generator.sh"
            "cron-daily.sh"
            "protocol-gen/vless-reality.sh"
            "protocol-gen/hysteria2.sh"
            "protocol-gen/tuic.sh"
            "protocol-gen/anytls.sh"
            "protocol-gen/shadowtls.sh"
        )
        for script in "${scripts[@]}"; do
            local url="${GITHUB_REPO}/scripts/${script}"
            curl -s -L "$url" -o "${SB_SCRIPTS}/${script}" 2>/dev/null || {
                curl -s -L "${GITHUB_PROXY}/scripts/${script}" -o "${SB_SCRIPTS}/${script}"
            }
        done
    fi

    chmod +x "${SB_SCRIPTS}/"*.sh
    chmod +x "${SB_SCRIPTS}/protocol-gen/"*.sh 2>/dev/null || true
    echo "  -> 脚本部署完成"
}

init_data_files() {
    echo -e "${GREEN}[5/9]${NC} 初始化数据文件..."

    # users.json
    echo '{"version":1,"users":{}}' > "$SB_DATA/users.json"

    # outbounds.json
    cat > "$SB_DATA/outbounds.json" << 'EOF'
{
  "version": 1,
  "outbounds": [
    {
      "id": "out_direct",
      "name": "直连",
      "type": "direct",
      "tag": "direct",
      "builtin": true,
      "config": {}
    }
  ],
  "strategy_groups": [
    {
      "id": "sg_default",
      "name": "默认出站",
      "type": "selector",
      "default": "out_direct",
      "outbounds": ["out_direct"]
    }
  ]
}
EOF

    # traffic.json
    echo '{"version":1,"last_reset":0,"users":{},"total":{"down":0,"up":0}}' > "$SB_DATA/traffic.json"

    # settings.json
    local admin_pass
    admin_pass=$(openssl rand -base64 12 | tr -d '+/=')
    local jwt_secret
    jwt_secret=$(openssl rand -hex 32)
    local now
    now=$(date +%s)

    cat > "$SB_DATA/settings.json" << EOFSETTINGS
{
  "version": 1,
  "domain": "",
  "email": "",
  "web_port": 2053,
  "web_username": "admin",
  "web_password_hash": "",
  "jwt_secret": "${jwt_secret}",
  "subscription_domain": "",
  "installed_protocols": [],
  "fail2ban_enabled": false,
  "ufw_enabled": false,
  "traffic_reset_day": 1,
  "installed_at": ${now}
}
EOFSETTINGS

    # 保存管理员密码 (稍后输出)
    echo "$admin_pass" > /tmp/sb_admin_pass.txt
    echo "  -> 数据文件初始化完成"
}

create_systemd_services() {
    echo -e "${GREEN}[6/9]${NC} 创建系统服务..."

    # Sing-box 服务
    cat > /etc/systemd/system/sing-box.service << 'SYSTEMD'
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
LimitNPROC=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SYSTEMD

    # 流量采集服务
    cat > /etc/systemd/system/sb-traffic.service << SYSTEMD
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
SYSTEMD

    systemctl daemon-reload
    echo "  -> 系统服务创建完成"
}

generate_initial_config() {
    echo -e "${GREEN}[7/9]${NC} 生成初始配置..."

    # 生成空的 Sing-box 配置 (占位, 添加用户后更新)
    cat > "$SB_CONFIG/config.json" << 'EOF'
{
  "log": {
    "level": "warn",
    "output": "/opt/sb-manager/logs/sing-box.log",
    "timestamp": true
  },
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "external_ui": "",
      "secret": "",
      "default_mode": "rule"
    }
  },
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "tls://8.8.8.8",
        "address_resolver": "dns-resolver",
        "strategy": "ipv4_only",
        "detour": "sg-default"
      },
      {
        "tag": "dns-local",
        "address": "https://223.5.5.5/dns-query",
        "address_resolver": "dns-resolver",
        "strategy": "ipv4_only",
        "detour": "direct"
      },
      {
        "tag": "dns-resolver",
        "address": "223.5.5.5",
        "detour": "direct"
      }
    ],
    "rules": [
      { "rule_set": "geosite-geolocation-cn", "server": "dns-local" },
      { "domain_suffix": ["cn"], "server": "dns-local" }
    ],
    "final": "dns-remote",
    "strategy": "ipv4_only"
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "selector",
      "tag": "sg-default",
      "outbounds": ["direct"],
      "default": "direct"
    },
    { "type": "direct", "tag": "direct" },
    { "type": "dns", "tag": "dns-out" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      { "protocol": "dns", "outbound": "dns-out" },
      { "rule_set": "geoip-cn", "outbound": "direct" },
      { "rule_set": "geosite-geolocation-cn", "outbound": "direct" },
      { "domain_suffix": [".cn"], "outbound": "direct" }
    ],
    "rule_set": [
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip/cn.srs",
        "download_detour": "direct"
      },
      {
        "tag": "geosite-geolocation-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs",
        "download_detour": "direct"
      }
    ],
    "final": "sg-default",
    "auto_detect_interface": true
  }
}
EOF
    echo "  -> 初始配置生成完成"
}

setup_system() {
    echo -e "${GREEN}[8/9]${NC} 系统优化..."

    # BBR + sysctl
    cat > /etc/sysctl.d/99-sb-manager.conf << 'SYSCTL'
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
SYSCTL
    sysctl -p /etc/sysctl.d/99-sb-manager.conf &>/dev/null

    # limits
    cat > /etc/security/limits.d/99-sb-manager.conf << 'LIMITS'
* soft nofile 1000000
* hard nofile 1000000
* soft nproc 65535
* hard nproc 65535
LIMITS

    # 设置 cron 定时任务
    (crontab -l 2>/dev/null || true; echo "0 2 * * * /bin/bash ${SB_SCRIPTS}/cron-daily.sh") | crontab -

    echo "  -> 系统优化完成 (BBR + sysctl + cron)"
}

install_cli() {
    echo -e "${GREEN}[9/9]${NC} 安装命令行工具..."

    cat > /usr/local/bin/sb-manager << 'CLI'
#!/usr/bin/env bash
exec bash /opt/sb-manager/scripts/manager.sh "$@"
CLI
    chmod +x /usr/local/bin/sb-manager

    echo "  -> 命令行工具已安装: sb-manager"
}

# ============================================================================
# 安装完成输出
# ============================================================================
print_summary() {
    local admin_pass
    admin_pass=$(cat /tmp/sb_admin_pass.txt 2>/dev/null || echo "请查看 /opt/sb-manager/core/data/settings.json")
    rm -f /tmp/sb_admin_pass.txt

    local server_ip
    server_ip=$(curl -s -4 https://api.ipify.org 2>/dev/null || echo "YOUR_VPS_IP")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║           Sing-box Manager 安装完成!                         ║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Web 管理面板:${NC}  http://${server_ip}:2053"
    echo -e "${BOLD}用户名:${NC}       admin"
    echo -e "${BOLD}密码:${NC}         ${CYAN}${admin_pass}${NC}"
    echo ""
    echo -e "${BOLD}已安装协议:${NC}"
    for p in "${PROTOCOLS[@]}"; do
        case "$p" in
            vless-reality) echo -e "  ${GREEN}+${NC} VLESS + Reality" ;;
            hysteria2)     echo -e "  ${GREEN}+${NC} Hysteria2" ;;
            tuic)          echo -e "  ${GREEN}+${NC} TUIC v5" ;;
            anytls)        echo -e "  ${GREEN}+${NC} AnyTLS" ;;
            shadowtls)     echo -e "  ${GREEN}+${NC} ShadowTLS v3" ;;
        esac
    done
    echo ""
    echo -e "${BOLD}管理命令:${NC}"
    echo "  sb-manager add-user        添加用户"
    echo "  sb-manager list-users      查看所有用户"
    echo "  sb-manager add-outbound    添加上游出站代理"
    echo "  sb-manager show-traffic    查看流量统计"
    echo "  sb-manager help            查看所有命令"
    echo ""
    echo -e "${YELLOW}下一步:${NC}"
    echo "  1. 添加用户:  sb-manager add-user"
    echo "  2. 添加上游出站: sb-manager add-outbound"
    echo "  3. 访问 Web 面板: http://${server_ip}:2053"
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  安装完成! 享受使用吧~                                      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ============================================================================
# 主流程
# ============================================================================
main() {
    show_banner
    select_protocols

    # 记录安装的协议
    local protocols_json="["
    for i in "${!PROTOCOLS[@]}"; do
        [[ $i -gt 0 ]] && protocols_json+=","
        protocols_json+="\"${PROTOCOLS[$i]}\""
    done
    protocols_json+="]"

    install_dependencies
    install_singbox_binary
    init_directory_structure
    download_scripts
    init_data_files

    # 将协议写入 settings
    local tmp="${SB_DATA}/settings.json"
    jq ".installed_protocols = ${protocols_json}" "$tmp" > "${tmp}.tmp" && mv "${tmp}.tmp" "$tmp"

    create_systemd_services
    generate_initial_config

    # 启动 Sing-box
    systemctl enable sing-box &>/dev/null || true
    systemctl start sing-box &>/dev/null || true
    systemctl enable sb-traffic &>/dev/null || true
    systemctl start sb-traffic &>/dev/null || true

    setup_system
    install_cli

    print_summary
}

# ============================================================================
# 入口
# ============================================================================
main "$@"