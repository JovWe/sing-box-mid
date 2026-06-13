#!/usr/bin/env bash
#===============================================================================
# Sing-box Manager - CLI 唯一入口
# 所有业务逻辑都在 scripts/modules/ 下, 由 _load_module 按需加载
# 用法: sb-manager <command> [args...]
#===============================================================================
set -euo pipefail

# ---- 路径常量 ----
SB_MANAGER_ROOT="/opt/sb-manager"
SB_SCRIPTS_DIR="${SB_MANAGER_ROOT}/scripts"
SB_MODULES_DIR="${SB_SCRIPTS_DIR}/modules"
SB_BIN="${SB_MANAGER_ROOT}/bin"
SB_CONFIG="${SB_MANAGER_ROOT}/core/config"
SB_DATA="${SB_MANAGER_ROOT}/data"
SB_CERTS="${SB_MANAGER_ROOT}/certs"
SB_LOGS="${SB_MANAGER_ROOT}/logs"

USERS_FILE="${SB_DATA}/users.json"
OUTBOUNDS_FILE="${SB_DATA}/outbounds.json"
TRAFFIC_FILE="${SB_DATA}/traffic.json"
SETTINGS_FILE="${SB_DATA}/settings.json"
SINGBOX_CONFIG="${SB_CONFIG}/config.json"

mkdir -p "${SB_BIN}" "${SB_CONFIG}/inbound" "${SB_CONFIG}/outbound" \
         "${SB_DATA}" "${SB_CERTS}" "${SB_LOGS}"

# 数据文件初始化（若不存在）
[[ ! -f "$USERS_FILE" ]]    && echo '{"version":1,"users":{}}' > "$USERS_FILE"
[[ ! -f "$TRAFFIC_FILE" ]]  && echo '{"version":1,"last_reset":0,"users":{},"total":{"down":0,"up":0}}' > "$TRAFFIC_FILE"
[[ ! -f "$OUTBOUNDS_FILE" ]] && echo '{"version":1,"outbounds":[{"id":"out_direct","name":"直连","type":"direct","tag":"direct","builtin":true,"config":{}}],"strategy_groups":[{"id":"sg_default","name":"默认出站","type":"selector","default":"out_direct","outbounds":["out_direct"]}]}' > "$OUTBOUNDS_FILE"
[[ ! -f "$SETTINGS_FILE" ]] && echo '{"version":1,"domain":"","email":"","web_port":2053,"web_username":"admin","web_password_hash":"","jwt_secret":"","subscription_domain":"","installed_protocols":[],"fail2ban_enabled":false,"ufw_enabled":false,"traffic_reset_day":1,"installed_at":0}' > "$SETTINGS_FILE"

# ---- 模块加载器（防止重复 source）----
declare -A _SB_LOADED_MODULES=()

_load_module() {
    local rel_path="$1"
    local abs_path="${SB_MODULES_DIR}/${rel_path}"
    if [[ -z "${_SB_LOADED_MODULES[$rel_path]+x}" ]]; then
        if [[ -f "$abs_path" ]]; then
            source "$abs_path"
            _SB_LOADED_MODULES["$rel_path"]=1
        else
            echo "模块不存在: $abs_path" >&2
            return 1
        fi
    fi
    return 0
}

# 基础模块先加载
_load_module "utils.sh" || { echo "加载 utils.sh 失败" >&2; exit 1; }

# ---- CLI 分发 ----
_main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        # ========== 用户管理 ==========
        add-user)
            _load_module "user-manager.sh" || exit 1
            add_user "$@"
            ;;
        delete-user)
            _load_module "user-manager.sh" || exit 1
            delete_user "$@"
            ;;
        edit-user)
            _load_module "user-manager.sh" || exit 1
            edit_user "$@"
            ;;
        list-users)
            _load_module "user-manager.sh" || exit 1
            list_users
            ;;
        show-user)
            _load_module "user-manager.sh" || exit 1
            show_user_detail "${1:-}"
            ;;
        show-config)
            _load_module "user-manager.sh" || exit 1
            show_user_config "${1:-}"
            ;;

        # ========== 出站管理 ==========
        add-outbound)
            _load_module "outbound-manager.sh" || exit 1
            add_outbound "$@"
            ;;
        delete-outbound)
            _load_module "outbound-manager.sh" || exit 1
            delete_outbound "$@"
            ;;
        edit-outbound)
            _load_module "outbound-manager.sh" || exit 1
            edit_outbound "$@"
            ;;
        list-outbounds)
            _load_module "outbound-manager.sh" || exit 1
            list_outbounds
            ;;
        show-outbound)
            _load_module "outbound-manager.sh" || exit 1
            list_outbounds
            ;;
        strategy-group)
            _load_module "outbound-manager.sh" || exit 1
            manage_strategy_group
            ;;

        # ========== 流量统计 ==========
        show-traffic)
            _load_module "traffic-collector.sh" || exit 1
            show_traffic
            ;;
        reset-traffic)
            _load_module "traffic-collector.sh" || exit 1
            reset_traffic "${1:-}"
            ;;

        # ========== 订阅系统 ==========
        show-sub)
            _load_module "sub-generator.sh" || exit 1
            show_sub "${1:-}"
            ;;
        gen-sub)
            _load_module "user-manager.sh" || exit 1   # load_protocol_gen 在这里
            _load_module "sub-generator.sh" || exit 1
            gen_user_sub "${1:-}" "${2:-all}"
            ;;

        # ========== 系统管理 ==========
        status)
            _status
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
            if [[ -f "${SB_LOGS}/sing-box.log" ]]; then
                tail -50 "${SB_LOGS}/sing-box.log"
            else
                echo "暂无日志"
            fi
            ;;
        update)
            install_singbox "latest"
            sb_reload
            ;;
        version)
            echo "Sing-box Manager v1.1.0 (模块化架构)"
            if [[ -x "${SB_BIN}/sing-box" ]]; then
                "${SB_BIN}/sing-box" version
            fi
            ;;

        # ========== 帮助 ==========
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

_status() {
    echo ""
    echo "========== Sing-box Manager 状态 =========="
    if systemctl is-active --quiet sing-box 2>/dev/null; then
        echo "Sing-box:    运行中"
    else
        echo "Sing-box:    停止"
    fi
    if systemctl is-active --quiet sb-traffic 2>/dev/null; then
        echo "流量采集:    运行中"
    else
        echo "流量采集:    未启动"
    fi
    if [[ -x "${SB_BIN}/sing-box" ]]; then
        echo "版本:        $("${SB_BIN}/sing-box" version 2>/dev/null | head -1)"
    fi
    local user_count
    user_count=$(jq '.users | length' "$USERS_FILE" 2>/dev/null || echo 0)
    echo "用户数:      ${user_count}"
    local ob_count
    ob_count=$(jq '.outbounds | length' "$OUTBOUNDS_FILE" 2>/dev/null || echo 0)
    echo "出站数:      ${ob_count}"
    local total_down total_up
    total_down=$(json_get "$TRAFFIC_FILE" '.total.down' '0')
    total_up=$(json_get "$TRAFFIC_FILE" '.total.up' '0')
    echo "总流量:      ↓ $(format_bytes "$total_down") / ↑ $(format_bytes "$total_up")"
    echo ""
}

_show_help() {
    cat << 'HELP'
╔══════════════════════════════════════════════════════════════╗
║           Sing-box Manager - 中转站管理系统                  ║
╚══════════════════════════════════════════════════════════════╝

用法: sb-manager <command> [options]

┌─────────────────────────────────────────────────────────────┐
│ 用户管理                                                      │
├─────────────────────────────────────────────────────────────┤
│  add-user     [name] [protocol] [expire] [limit] [port]     │
│  delete-user  [username]                                      │
│  edit-user    [username]                                      │
│  list-users                                                   │
│  show-user    [username]                                      │
│  show-config  [username]                                      │
├─────────────────────────────────────────────────────────────┤
│ 出站管理                                                      │
├─────────────────────────────────────────────────────────────┤
│  add-outbound     [name] [type]                               │
│  delete-outbound  [outbound_id]                               │
│  edit-outbound    [outbound_id]                               │
│  list-outbounds                                               │
│  show-outbound    [outbound_id]                               │
│  strategy-group                                               │
├─────────────────────────────────────────────────────────────┤
│ 流量统计                                                      │
├─────────────────────────────────────────────────────────────┤
│  show-traffic     [username]                                  │
│  reset-traffic    [username]                                  │
├─────────────────────────────────────────────────────────────┤
│ 订阅系统                                                      │
├─────────────────────────────────────────────────────────────┤
│  show-sub         [username]                                  │
│  gen-sub          [username] [format]                        │
│    格式: link, sing-box, clash-meta, all                    │
├─────────────────────────────────────────────────────────────┤
│ 系统管理                                                      │
├─────────────────────────────────────────────────────────────┤
│  status          查看系统状态                                  │
│  reload          重新生成配置并重载                            │
│  restart         重启 Sing-box                                 │
│  logs            查看日志 (最近 50 行)                         │
│  update          更新 Sing-box 内核                            │
│  version         显示版本信息                                  │
│  help            显示此帮助                                    │
└─────────────────────────────────────────────────────────────┘

协议类型: vless-reality, hysteria2, tuic, anytls, shadowtls
HELP
}

_main "$@"
