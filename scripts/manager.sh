#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - CLI 唯一入口 (精简版)
# 用法: sb-manager <command> [args...]
#===============================================================================
set -euo pipefail

# ============ 路径常量 ============
SB_ROOT="/opt/sb-manager"
SB_SCRIPTS_DIR="${SB_ROOT}/scripts"
SB_MODULES_DIR="${SB_SCRIPTS_DIR}/modules"
SB_BIN="${SB_ROOT}/bin"
SB_CONFIG="${SB_ROOT}/core/config"
SB_DATA="${SB_ROOT}/data"
SB_CERTS="${SB_ROOT}/certs"
SB_LOGS="${SB_ROOT}/logs"

USERS_FILE="${SB_DATA}/users.json"
OUTBOUNDS_FILE="${SB_DATA}/outbounds.json"
SETTINGS_FILE="${SB_DATA}/settings.json"
SINGBOX_CONFIG="${SB_CONFIG}/config.json"

# ============ 目录 + 数据文件初始化 ============
mkdir -p "${SB_BIN}" "${SB_CONFIG}/inbound" "${SB_CONFIG}/outbound" \
         "${SB_DATA}" "${SB_CERTS}" "${SB_LOGS}"

if [[ ! -f "$USERS_FILE" ]]; then
    echo '{"version":1,"users":{}}' > "$USERS_FILE"
fi
if [[ ! -f "$OUTBOUNDS_FILE" ]]; then
    echo '{"version":1,"outbounds":[{"id":"out_direct","name":"直连","type":"direct","tag":"direct","builtin":true,"config":{"type":"direct","tag":"direct"}}],"strategy_groups":[{"id":"sg_default","name":"默认出站","type":"selector","default":"out_direct","outbounds":["out_direct"]}]}' > "$OUTBOUNDS_FILE"
fi
if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo '{"version":1,"domain":"","installed_protocols":[],"installed_at":0}' > "$SETTINGS_FILE"
fi

# ============ 模块加载器（去重） ============
declare -A _LOADED=()

_load_module() {
    local rel="$1"
    if [[ -n "${_LOADED[$rel]+x}" ]]; then
        return 0
    fi
    local abs="${SB_MODULES_DIR}/${rel}"
    if [[ -f "$abs" ]]; then
        source "$abs"
        _LOADED["$rel"]=1
    else
        echo "模块不存在: $abs" >&2
        return 1
    fi
}

# 基础模块先加载
_load_module "utils.sh" || { echo "加载 utils.sh 失败" >&2; exit 1; }

# ============ 系统状态 (不依赖其他模块) ============
_show_status() {
    echo ""
    echo "========== Sing-box Manager 状态 =========="
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        echo "Sing-box:    运行中"
    else
        echo "Sing-box:    停止"
    fi
    if [[ -x "${SB_BIN}/sing-box" ]]; then
        local ver
        ver=$("${SB_BIN}/sing-box" version 2>/dev/null | head -1 || echo "unknown")
        echo "版本:        $ver"
    fi
    local user_count ob_count
    user_count=$(jq '.users | length' "$USERS_FILE" 2>/dev/null || echo 0)
    ob_count=$(jq '.outbounds | length' "$OUTBOUNDS_FILE" 2>/dev/null || echo 0)
    echo "用户数:      ${user_count}"
    echo "出站数:      ${ob_count}"
    echo ""
}

# ============ 日志查看 ============
_show_logs() {
    if [[ -f "${SB_LOGS}/sing-box.log" ]]; then
        tail -50 "${SB_LOGS}/sing-box.log"
    else
        echo "暂无日志"
    fi
}

# ============ 版本信息 ============
_show_version() {
    echo "Sing-box Manager v1.2.0 (极简版)"
    if [[ -x "${SB_BIN}/sing-box" ]]; then
        "${SB_BIN}/sing-box" version
    fi
}

# ============ 帮助 ============
_show_help() {
    cat << 'HELP'
╔══════════════════════════════════════════════════════════════╗
║           Sing-box Manager (极简版)                          ║
╚══════════════════════════════════════════════════════════════╝

用法: sb-manager <command> [args...]

┌─────────────────────────────────────────────────────────────┐
│ 用户管理                                                      │
├─────────────────────────────────────────────────────────────┤
│  add-user     [name]                                          │
│  list-users                                                   │
│  delete-user  [name]                                          │
├─────────────────────────────────────────────────────────────┤
│ 出站管理                                                      │
├─────────────────────────────────────────────────────────────┤
│  add-outbound   [name] [type]                                 │
│  list-outbounds                                               │
├─────────────────────────────────────────────────────────────┤
│ 系统管理                                                      │
├─────────────────────────────────────────────────────────────┤
│  status          查看系统状态                                  │
│  reload          重新生成配置并重载                            │
│  restart         重启 Sing-box                                 │
│  logs            查看日志 (最近 50 行)                         │
│  version         显示版本信息                                  │
│  help            显示此帮助                                    │
└─────────────────────────────────────────────────────────────┘

入站协议: VLESS+Reality, Hysteria2, TUIC v5, ShadowTLS v3, VMess
出站协议: VLESS, Hysteria2, TUIC, Shadowsocks, VMess, Trojan
HELP
}

# ============ CLI 主入口 ============
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        # ---- 用户管理 ----
        add-user)
            _load_module "user-manager.sh" || exit 1
            add_user "$@"
            ;;
        list-users)
            _load_module "user-manager.sh" || exit 1
            list_users
            ;;
        delete-user)
            _load_module "user-manager.sh" || exit 1
            delete_user "$@"
            ;;

        # ---- 出站管理 ----
        add-outbound)
            _load_module "outbound-manager.sh" || exit 1
            add_outbound "$@"
            ;;
        list-outbounds)
            _load_module "outbound-manager.sh" || exit 1
            list_outbounds
            ;;

        # ---- 系统 ----
        status)
            _show_status
            ;;
        reload)
            _load_module "config-generator.sh" || exit 1
            generate_config
            sb_reload
            log_info "已重载"
            ;;
        restart)
            sb_restart
            log_info "Sing-box 已重启"
            ;;
        logs)
            _show_logs
            ;;
        version)
            _show_version
            ;;
        help|--help|-h)
            _show_help
            ;;
        *)
            echo "未知命令: $cmd"
            echo "使用 'sb-manager help' 查看帮助"
            exit 1
            ;;
    esac
}

main "$@"
