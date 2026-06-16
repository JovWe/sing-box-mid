# Sing-box Mid (极简版)

极简版 sing-box VPS 中转站部署管理系统。模块化 bash 脚本, 单入口 CLI。

## 支持协议

**入站**: VLESS + Reality, Hysteria2, TUIC v5, ShadowTLS v3, VMess
**出站**: VLESS, Hysteria2, TUIC, Shadowsocks, VMess, Trojan

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/JovWe/sing-box-mid/main/install.sh)
```

安装过程中选择协议, 默认安装全部 5 种入站协议。

## 管理命令

```bash
sb-manager help              # 查看所有命令

# 用户管理
sb-manager add-user          # 交互式添加用户
sb-manager add-user alice    # 直接传用户名(仍需选协议)
sb-manager list-users        # 查看所有用户
sb-manager delete-user alice # 删除用户(传参,会二次确认)

# 出站管理
sb-manager add-outbound      # 交互式添加上游出站
sb-manager list-outbounds    # 列出所有出站

# 系统
sb-manager status            # 系统状态
sb-manager reload            # 重新生成主配置并重载
sb-manager restart           # 重启 sing-box
sb-manager logs              # 查看最近 50 行日志
sb-manager version           # 版本信息
```

## 架构

```
install.sh                          ← 一键安装 (从 GitHub 拉取)
/opt/sb-manager/
├── bin/sing-box                    ← sing-box 内核
├── core/config/
│   ├── config.json                 ← 主配置 (sb-manager reload 重新生成)
│   ├── inbound/<username>.json     ← 每用户一个入站片段
│   └── outbound/<out_id>.json      ← 每个出站一个片段
├── data/
│   ├── users.json                  ← 用户元数据
│   ├── outbounds.json              ← 上游出站配置
│   └── settings.json               ← 全局设置
├── logs/sing-box.log
└── scripts/
    ├── manager.sh                  ← CLI 唯一入口, 内含 _load_module 加载器
    └── modules/                    ← 纯函数模块
        ├── utils.sh                ← 日志/JSON/随机/系统优化/sing-box 安装
        ├── user-manager.sh         ← add_user, list_users, delete_user
        ├── outbound-manager.sh     ← add_outbound, list_outbounds
        ├── config-generator.sh     ← generate_config
        └── protocol-gen/           ← 各协议入站片段生成器
            ├── vless-reality.sh
            ├── hysteria2.sh
            ├── tuic.sh
            ├── shadowtls.sh
            └── vmess.sh
```

### 模块加载机制

```bash
# scripts/manager.sh 中
declare -A _LOADED=()
_load_module() {
  local rel="$1"
  [[ -n "${_LOADED[$rel]+x}" ]] && return 0   # 已加载则跳过
  source "${SB_MODULES_DIR}/${rel}"
  _LOADED["$rel"]=1
}
```

特点:
- **按需加载**: `sb-manager list-users` 只加载 utils + user-manager
- **去重 source**: 协议生成器被 user-manager 与 config-generator 同时引用时, 实际只 source 一次
- **零污染**: 模块无 `SCRIPT_DIR` / `set -e` / `shebang`, 不会污染调用者环境

## 系统要求

- Debian 12/13 / Ubuntu 22.04/24.04 / CentOS 8-9
- root 权限
- x86_64 / ARM64

## License

MIT
