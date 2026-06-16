#===============================================================================
# 数据库模块 - SQLite CRUD (纯函数, 由主入口 source)
# 路径常量 + 数据库初始化 + 增删改查
#===============================================================================

# ---- 路径常量 ----
SB_ROOT="/opt/sb"
SB_SCRIPTS="${SB_ROOT}/scripts"
SB_MODULES="${SB_SCRIPTS}/modules"
SB_BIN="${SB_ROOT}/bin"
SB_DATA="${SB_ROOT}/data"
SB_CONFIG="${SB_ROOT}/core/config"
SB_CERTS="${SB_ROOT}/certs"
SB_LOGS="${SB_ROOT}/logs"
SB_WWW="${SB_ROOT}/www"

DB_FILE="${SB_DATA}/sb.db"
CONFIG_FILE="${SB_CONFIG}/config.json"

# ---- 颜色 / 日志 ----
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S')  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}     $(date '+%Y-%m-%d %H:%M:%S')  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S')  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S')  $*" >&2; }

# ---- 数据库初始化 ----
db_init() {
    mkdir -p "$(dirname "$DB_FILE")"
    sqlite3 "$DB_FILE" <<'EOSQL'
CREATE TABLE IF NOT EXISTS users (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    username    TEXT UNIQUE NOT NULL,
    protocol    TEXT NOT NULL DEFAULT 'vmess',
    port        INTEGER NOT NULL,
    email       TEXT DEFAULT '',
    status      TEXT DEFAULT 'active',
    traffic_limit_bytes INTEGER DEFAULT 0,
    traffic_down_bytes  INTEGER DEFAULT 0,
    traffic_up_bytes    INTEGER DEFAULT 0,
    expire_at   INTEGER DEFAULT 0,
    outbound_tag TEXT DEFAULT 'direct',
    credentials TEXT DEFAULT '{}',
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS outbounds (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    name    TEXT UNIQUE NOT NULL,
    type    TEXT NOT NULL DEFAULT 'direct',
    tag     TEXT UNIQUE NOT NULL,
    config  TEXT DEFAULT '{}',
    builtin INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS traffic_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL,
    down_delta INTEGER DEFAULT 0,
    up_delta   INTEGER DEFAULT 0,
    recorded_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- 默认出站
INSERT OR IGNORE INTO outbounds (name, type, tag, config, builtin) VALUES ('直连', 'direct', 'direct', '{}', 1);
INSERT OR IGNORE INTO outbounds (name, type, tag, config, builtin) VALUES ('阻断', 'block', 'block', '{}', 1);
INSERT OR IGNORE INTO outbounds (name, type, tag, config, builtin) VALUES ('代理池', 'selector', 'proxy', '{"outbounds":["direct"],"default":"direct"}', 1);
INSERT OR IGNORE INTO settings (key, value) VALUES ('global_outbound', 'proxy');
EOSQL
}

# ---- 用户 CRUD ----
db_user_add() {
    local username="$1" protocol="$2" port="$3"
    local expire_at="${4:-0}" traffic_limit="${5:-0}" outbound_tag="${6:-direct}"
    local now; now=$(date +%s)
    sqlite3 "$DB_FILE" "INSERT INTO users (username,protocol,port,traffic_limit_bytes,expire_at,outbound_tag,created_at,updated_at) VALUES ('$username','$protocol',$port,$traffic_limit,$expire_at,'$outbound_tag',$now,$now);"
}

db_user_delete() {
    local username="$1"
    sqlite3 "$DB_FILE" "DELETE FROM users WHERE username='$username';"
}

db_user_get() {
    local username="$1"
    sqlite3 "$DB_FILE" -json "SELECT * FROM users WHERE username='$username';" 2>/dev/null || echo "[]"
}

db_user_list() {
    sqlite3 "$DB_FILE" -json "SELECT * FROM users ORDER BY id;" 2>/dev/null || echo "[]"
}

db_user_set_creds() {
    local username="$1" json="$2"
    sqlite3 "$DB_FILE" "UPDATE users SET credentials='$json', updated_at=$(date +%s) WHERE username='$username';"
}

db_user_set_inbound() {
    local username="$1" port="$2"
    sqlite3 "$DB_FILE" "UPDATE users SET port=$port, updated_at=$(date +%s) WHERE username='$username';"
}

db_user_set_status() {
    local username="$1" status="$2"
    sqlite3 "$DB_FILE" "UPDATE users SET status='$status', updated_at=$(date +%s) WHERE username='$username';"
}

db_user_set_expire() {
    local username="$1" expire_ts="$2"
    sqlite3 "$DB_FILE" "UPDATE users SET expire_at=$expire_ts, updated_at=$(date +%s) WHERE username='$username';"
}

db_user_set_traffic_limit() {
    local username="$1" bytes="$2"
    sqlite3 "$DB_FILE" "UPDATE users SET traffic_limit_bytes=$bytes, updated_at=$(date +%s) WHERE username='$username';"
}

db_user_set_outbound() {
    local username="$1" tag="$2"
    sqlite3 "$DB_FILE" "UPDATE users SET outbound_tag='$tag', updated_at=$(date +%s) WHERE username='$username';"
}

db_user_count() {
    sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM users WHERE status='active';"
}

# ---- 出站 CRUD ----
db_outbound_add() {
    local name="$1" type="$2" tag="$3" config="$4"
    sqlite3 "$DB_FILE" "INSERT INTO outbounds (name,type,tag,config) VALUES ('$name','$type','$tag','$config');"
}

db_outbound_delete() {
    local tag="$1"
    sqlite3 "$DB_FILE" "DELETE FROM outbounds WHERE tag='$tag' AND builtin=0;"
}

db_outbound_list() {
    sqlite3 "$DB_FILE" -json "SELECT * FROM outbounds ORDER BY id;" 2>/dev/null || echo "[]"
}

db_outbound_get() {
    local tag="$1"
    sqlite3 "$DB_FILE" -json "SELECT * FROM outbounds WHERE tag='$tag';" 2>/dev/null || echo "[]"
}

# ---- 流量 ----
db_traffic_log() {
    local user_id="$1" down="$2" up="$3"
    local now; now=$(date +%s)
    sqlite3 "$DB_FILE" "INSERT INTO traffic_log (user_id,down_delta,up_delta,recorded_at) VALUES ($user_id,$down,$up,$now);"
}

db_traffic_accumulate() {
    local username="$1" down="$2" up="$3"
    sqlite3 "$DB_FILE" "UPDATE users SET traffic_down_bytes=traffic_down_bytes+$down, traffic_up_bytes=traffic_up_bytes+$up, updated_at=$(date +%s) WHERE username='$username';"
}

db_traffic_reset() {
    local username="${1:-}"
    if [[ -n "$username" ]]; then
        sqlite3 "$DB_FILE" "UPDATE users SET traffic_down_bytes=0, traffic_up_bytes=0, updated_at=$(date +%s) WHERE username='$username';"
    else
        sqlite3 "$DB_FILE" "UPDATE users SET traffic_down_bytes=0, traffic_up_bytes=0, updated_at=$(date +%s);"
    fi
}

# ---- 设置 CRUD ----
db_setting_get() {
    local key="$1"
    sqlite3 "$DB_FILE" "SELECT value FROM settings WHERE key='$key';" 2>/dev/null || echo ""
}

db_setting_set() {
    local key="$1" value="$2"
    sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO settings (key, value) VALUES ('$key', '$value');"
}

# ---- 工具函数 ----
gen_password() { openssl rand -base64 "${1:-16}" | tr -d '+/=' | head -c "${1:-16}"; }
gen_uuid()     { python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || cat /proc/sys/kernel/random/uuid; }
gen_short_id() { openssl rand -hex 8; }
gen_token()    { openssl rand -hex 16; }

gen_random_port() {
    local min="${1:-10000}" max="${2:-60000}"
    while true; do
        local port=$(( min + RANDOM % (max - min + 1) ))
        if ! ss -tuln 2>/dev/null | awk '{print $5}' | grep -q ":${port}$"; then
            echo "$port"; return 0
        fi
    done
}

get_public_ip() {
    for url in https://api.ipify.org https://ifconfig.me https://ipv4.icanhazip.com; do
        local ip; ip=$(curl -s --max-time 5 "$url" 2>/dev/null) || continue
        [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    done
    hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown"
}

gen_reality_keypair() {
    if [[ -x "${SB_BIN}/sing-box" ]]; then
        "${SB_BIN}/sing-box" generate reality-keypair 2>/dev/null
    else
        echo "PrivateKey: $(openssl rand -base64 32)"
        echo "PublicKey: $(openssl rand -base64 32)"
    fi
}

protocol_label() {
    case "${1:-}" in
        vless-reality) echo "VLESS Reality" ;;
        hysteria2)     echo "Hysteria2" ;;
        tuic)          echo "TUIC v5" ;;
        shadowtls)     echo "ShadowTLS v3" ;;
        vmess)         echo "VMess" ;;
        *)             echo "$1" ;;
    esac
}

format_bytes() {
    local b="${1:-0}"
    if   [[ "$b" -lt 1024 ]];            then echo "${b}B"
    elif [[ "$b" -lt 1048576 ]];         then awk "BEGIN{printf \"%.1fKB\",$b/1024}"
    elif [[ "$b" -lt 1073741824 ]];      then awk "BEGIN{printf \"%.1fMB\",$b/1048576}"
    else                                     awk "BEGIN{printf \"%.1fGB\",$b/1073741824}"
    fi
}

parse_bytes() {
    local val="${1:-0}" num unit
    val=$(echo "$val" | tr '[:lower:]' '[:upper:]')
    num=$(echo "$val" | sed -E 's/([0-9.]+).*/\1/')
    unit=$(echo "$val" | sed -E 's/[0-9.]+//')
    case "$unit" in
        TB|T) awk "BEGIN{printf \"%.0f\",$num*1099511627776}" ;;
        GB|G) awk "BEGIN{printf \"%.0f\",$num*1073741824}"    ;;
        MB|M) awk "BEGIN{printf \"%.0f\",$num*1048576}"      ;;
        KB|K) awk "BEGIN{printf \"%.0f\",$num*1024}"         ;;
        *)    echo "$num" ;;
    esac
}

confirm() {
    local prompt="${1:-确认?}" default="${2:-n}" yn
    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " yn; yn="${yn:-y}"
    else
        read -rp "$prompt [y/N]: " yn; yn="${yn:-n}"
    fi
    [[ "${yn,,}" == "y" || "${yn,,}" == "yes" ]]
}

sb_reload()   { systemctl reload sing-box 2>/dev/null || systemctl restart sing-box 2>/dev/null; }
sb_restart()  { systemctl restart sing-box 2>/dev/null; }
sb_stop()     { systemctl stop sing-box 2>/dev/null; }

ufw_allow() {
    local port="$1" proto="${2:-tcp}"
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi "active" && ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
}

detect_os() {
    [[ -f /etc/os-release ]] && . /etc/os-release
    echo "${ID:-unknown} $(uname -m)"
}

install_deps() {
    local pkgs=(curl wget jq openssl sqlite3 ca-certificates iproute2 procps iptables)
    [[ -f /etc/debian_version ]] && apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1 || true
    [[ -f /etc/redhat-release ]] && yum install -y -q "${pkgs[@]}" >/dev/null 2>&1 || true
}