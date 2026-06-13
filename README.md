# Sing-box Mid

Sing-box VPS 中转站部署管理系统, 基于模块化 bash 脚本实现, 支持多协议代理节点自动化部署、用户管理、流量统计和 Web 管理面板。

## 支持协议

- VLESS + Reality
- Hysteria2
- TUIC v5
- AnyTLS (Trojan over TLS)
- ShadowTLS v3

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/JovWe/sing-box-mid/main/install.sh)
```

## 管理命令

```bash
sb-manager help              # 查看所有命令

# 用户管理
sb-manager add-user          # 交互式添加用户
sb-manager add-user <name> <protocol>   # 非交互式
sb-manager list-users        # 查看所有用户
sb-manager show-user <name>  # 查看用户详情
sb-manager show-config <name>  # 查看客户端配置
sb-manager delete-user <name>
sb-manager edit-user <name>

# 出站管理
sb-manager add-outbound
sb-manager list-outbounds
sb-manager delete-outbound <id>
sb-manager strategy-group

# 流量统计
sb-manager show-traffic
sb-manager reset-traffic

# 订阅
sb-manager gen-sub <name> [format]  # format: link, sing-box, clash-meta

# 系统
sb-manager status            # 系统状态
sb-manager reload            # 重新生成主配置并重载
sb-manager restart
sb-manager logs
sb-manager update            # 更新 sing-box 内核
sb-manager version
```

## 架构一览

```
install.sh                    ← 一键安装脚本（独立, 从 GitHub 拉取其他文件）

/usr/local/bin/sb-manager     ← 命令行入口（exec bash /opt/sb-manager/scripts/manager.sh）

/opt/sb-manager/scripts/
├── manager.sh                ← CLI 唯一入口: set -euo pipefail + _load_module 加载器
├── traffic-collector.sh      ← systemd daemon 入口 (run_daemon)
├── cron-daily.sh             ← 每日定时任务（用户过期 + 流量超限检查）
└── modules/                  ← 纯函数模块: 只定义函数/常量, 被按需 source
    ├── utils.sh              ← 公共工具 (日志, JSON, 随机, 端口, 系统优化, sing-box 安装)
    ├── user-manager.sh       ← 用户管理 + load_protocol_gen
    ├── outbound-manager.sh   ← 出站管理 + 策略组
    ├── config-generator.sh   ← 生成 sing-box 主配置 config.json
    ├── sub-generator.sh      ← 订阅链接生成
    ├── traffic-collector.sh  ← 流量统计/重置
    └── protocol-gen/         ← 各协议配置与客户端生成
        ├── vless-reality.sh
        ├── hysteria2.sh
        ├── tuic.sh
        ├── anytls.sh
        └── shadowtls.sh
```

### 模块加载机制 `_load_module`

```bash
# manager.sh 内部实现
declare -A _SB_LOADED_MODULES=()
_load_module() {
  local rel="$1"
  [[ -z "${_SB_LOADED_MODULES[$rel]+x}" ]] || return 0   # 已加载则跳过
  source "${SB_SCRIPTS_DIR}/modules/${rel}"
  _SB_LOADED_MODULES["$rel"]=1
}
```

优势:
- **按需加载**: 执行 `show-traffic` 只加载 utils + traffic-collector, 不必加载协议生成器
- **全局去重**: 即使 `user-manager.sh` 和 `sub-generator.sh` 都调用 `load_protocol_gen`, 底层协议脚本只被 source 一次
- **零污染**: 模块无 `SCRIPT_DIR`, `set -e`, `shebang`, 不会污染调用者环境

### 系统服务

```
sing-box.service   → /opt/sb-manager/bin/sing-box run -c core/config/config.json
sb-traffic.service → bash /opt/sb-manager/scripts/traffic-collector.sh daemon
/etc/cron.d/sb-manager → 每日 00:05 运行 cron-daily.sh
```

## 系统要求

- Debian 12/13 / Ubuntu 22.04/24.04 / CentOS 8-9
- root 权限
- x86_64 或 ARM64

## License

MIT
