# Sing-box Manager - 流量采集模块
# 依赖 db.sh 已 source
# 使用 iptables 按端口统计流量

TRAFFIC_PID_FILE="${SB_DATA}/traffic-collector.pid"
TRAFFIC_LOCK="${SB_DATA}/traffic-collector.lock"

# ---- 初始化 iptables 规则 ----
traffic_init_iptables() {
    # 清理旧规则
    iptables -D FORWARD -m comment --comment "SB_TRAFFIC" -j FORWARD 2>/dev/null || true
    iptables -F SB_TRAFFIC_IN 2>/dev/null || true
    iptables -F SB_TRAFFIC_OUT 2>/dev/null || true
    iptables -X SB_TRAFFIC_IN 2>/dev/null || true
    iptables -X SB_TRAFFIC_OUT 2>/dev/null || true

    # 创建新链
    iptables -N SB_TRAFFIC_IN 2>/dev/null || true
    iptables -N SB_TRAFFIC_OUT 2>/dev/null || true

    # 为每个活跃用户端口添加规则
    local count=0
    while IFS='|' read -r username port; do
        iptables -A SB_TRAFFIC_IN -p tcp --dport "$port" -m comment --comment "SB:$username" 2>/dev/null || true
        iptables -A SB_TRAFFIC_OUT -p tcp --sport "$port" -m comment --comment "SB:$username" 2>/dev/null || true
        count=$((count + 1))
    done < <(sqlite3 "$DB_FILE" "SELECT username, port FROM users WHERE status='active';")

    # 挂载到 FORWARD 链 (中转场景)
    iptables -A FORWARD -m comment --comment "SB_TRAFFIC" -j SB_TRAFFIC_IN 2>/dev/null || true
    iptables -A FORWARD -m comment --comment "SB_TRAFFIC" -j SB_TRAFFIC_OUT 2>/dev/null || true

    log_ok "iptables 规则已初始化, $count 个活跃用户"
}

# ---- 采集一轮流量 ----
traffic_collect_once() {
    # 读取当前字节数
    iptables -L SB_TRAFFIC_IN -v -n -x 2>/dev/null | tail -n +3 | while read -r pkts bytes target prot opt source dest portinfo; do
        local comment; comment=$(echo "$portinfo" | grep -oP 'SB:\K[^ ]+' 2>/dev/null || echo "")
        [[ -z "$comment" ]] && continue
        local username="$comment"
        local dport; dport=$(echo "$portinfo" | grep -oP 'dpt:\K[0-9]+' 2>/dev/null || echo "0")
        # 查找之前的记录
        local prev_bytes=0
        [[ -f "${SB_DATA}/traffic_prev/${username}_in" ]] && prev_bytes=$(cat "${SB_DATA}/traffic_prev/${username}_in" 2>/dev/null || echo 0)
        local delta=$((bytes - prev_bytes))
        [[ $delta -lt 0 ]] && delta=0
        if [[ $delta -gt 0 ]]; then
            db_traffic_accumulate "$username" "$delta" 0
            db_traffic_log "$(sqlite3 "$DB_FILE" "SELECT id FROM users WHERE username='$username';" 2>/dev/null)" "$delta" 0
        fi
        mkdir -p "${SB_DATA}/traffic_prev"
        echo "$bytes" > "${SB_DATA}/traffic_prev/${username}_in"
    done

    iptables -L SB_TRAFFIC_OUT -v -n -x 2>/dev/null | tail -n +3 | while read -r pkts bytes target prot opt source dest portinfo; do
        local comment; comment=$(echo "$portinfo" | grep -oP 'SB:\K[^ ]+' 2>/dev/null || echo "")
        [[ -z "$comment" ]] && continue
        local username="$comment"
        local prev_bytes=0
        [[ -f "${SB_DATA}/traffic_prev/${username}_out" ]] && prev_bytes=$(cat "${SB_DATA}/traffic_prev/${username}_out" 2>/dev/null || echo 0)
        local delta=$((bytes - prev_bytes))
        [[ $delta -lt 0 ]] && delta=0
        if [[ $delta -gt 0 ]]; then
            db_traffic_accumulate "$username" 0 "$delta"
            db_traffic_log "$(sqlite3 "$DB_FILE" "SELECT id FROM users WHERE username='$username';" 2>/dev/null)" 0 "$delta"
        fi
        echo "$bytes" > "${SB_DATA}/traffic_prev/${username}_out"
    done
}

# ---- 守护进程 ----
traffic_daemon_start() {
    if [[ -f "$TRAFFIC_PID_FILE" ]] && kill -0 "$(cat "$TRAFFIC_PID_FILE")" 2>/dev/null; then
        log_warn "流量采集已在运行 PID=$(cat "$TRAFFIC_PID_FILE")"
        return 0
    fi

    traffic_init_iptables
    log_info "启动流量采集守护进程..."

    (
        # 确保单例
        if ! flock -n 200; then
            echo "locked" >&2
            exit 1
        fi

        # 记录 PID
        echo "$$" > "$TRAFFIC_PID_FILE"

        # 忽略退出信号
        trap '' HUP INT QUIT TERM

        while true; do
            traffic_collect_once
            # 检查到期/流量超限
            cron_check 2>/dev/null || true
            sleep 60
        done
    ) 200>"$TRAFFIC_LOCK" &

    local pid=$!
    echo "$pid" > "$TRAFFIC_PID_FILE"
    log_ok "流量采集守护进程已启动 PID=$pid"
}

traffic_daemon_stop() {
    if [[ -f "$TRAFFIC_PID_FILE" ]]; then
        local pid; pid=$(cat "$TRAFFIC_PID_FILE")
        kill "$pid" 2>/dev/null || true
        rm -f "$TRAFFIC_PID_FILE"
        log_ok "流量采集守护进程已停止"
    else
        log_warn "流量采集未运行"
    fi
}

traffic_daemon_status() {
    if [[ -f "$TRAFFIC_PID_FILE" ]] && kill -0 "$(cat "$TRAFFIC_PID_FILE")" 2>/dev/null; then
        echo -e "${GREEN}运行中${NC} PID=$(cat "$TRAFFIC_PID_FILE")"
        return 0
    else
        echo -e "${RED}未运行${NC}"
        return 1
    fi
}