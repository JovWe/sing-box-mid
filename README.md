# Sing-box Mid

Sing-box VPS 中转站部署管理系统，支持多协议代理节点的自动化部署、用户管理、流量统计与 Web 管理面板。

## 支持协议

| 协议 | 说明 |
|------|------|
| VLESS + Reality | 下一代 TLS 伪装协议，抗封锁能力强 |
| Hysteria2 | 基于 QUIC 的高速传输协议 |
| TUIC v5 | 轻量级 QUIC 代理协议 |
| AnyTLS | 任意 TLS 流量伪装 |
| ShadowTLS v3 | TLS 指纹伪装协议 |

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/JovWe/sing-box-mid/main/install.sh)
```

## 管理命令

```bash
sb-manager add-user        # 添加用户
sb-manager list-users      # 查看所有用户
sb-manager add-outbound    # 添加上游出站代理
sb-manager show-traffic    # 查看流量统计
sb-manager help            # 查看所有命令
```

## 功能特性

- **多协议支持**: 同时运行 VLESS Reality、Hysteria2、TUIC、AnyTLS、ShadowTLS
- **用户管理**: 创建/删除/编辑用户，支持到期时间和流量限制
- **出站管理**: 管理上游代理出站，支持策略组路由
- **流量统计**: 实时流量采集，超限自动封禁
- **订阅系统**: 自动生成 Sing-box / Clash Meta / V2RayN 格式订阅
- **Web 面板**: 可视化管理界面（默认端口 2053）
- **系统优化**: 自动开启 BBR、TCP Fast Open、文件描述符优化

## 项目结构

```
├── install.sh                  # 一键安装脚本
├── scripts/
│   ├── manager.sh              # 主管理 CLI
│   ├── utils.sh                # 公共工具函数库
│   ├── user-manager.sh         # 用户管理
│   ├── outbound-manager.sh     # 出站管理
│   ├── config-generator.sh     # Sing-box 配置生成
│   ├── traffic-collector.sh    # 流量采集守护进程
│   ├── sub-generator.sh        # 订阅生成器
│   ├── cron-daily.sh           # 每日定时任务
│   └── protocol-gen/           # 协议生成器
│       ├── vless-reality.sh
│       ├── hysteria2.sh
│       ├── tuic.sh
│       ├── anytls.sh
│       └── shadowtls.sh
└── web-backend/                # Web 管理面板 (Go + Gin)
    ├── main.go
    ├── handlers/
    ├── middleware/
    ├── models/
    └── templates/
```

## 系统要求

- Debian 12/13 或 Ubuntu 22.04/24.04
- root 权限
- 推荐 x86_64 或 ARM64 架构

## License

MIT