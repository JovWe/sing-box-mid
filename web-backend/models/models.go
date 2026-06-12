package models

// User 用户数据结构
type User struct {
	Username          string            `json:"username"`
	Protocol          string            `json:"protocol"`
	Status            string            `json:"status"`
	CreatedAt         int64             `json:"created_at"`
	ExpireAt          int64             `json:"expire_at"`
	TrafficLimitBytes int64             `json:"traffic_limit_bytes"`
	TrafficUsedDown   int64             `json:"traffic_used_down"`
	TrafficUsedUp     int64             `json:"traffic_used_up"`
	Online            bool              `json:"online"`
	LastSeenAt        int64             `json:"last_seen_at"`
	Credentials       Credentials       `json:"credentials"`
	Reality           RealityConfig     `json:"reality"`
	Hysteria2         Hysteria2Config   `json:"hysteria2"`
	TUIC              TUICConfig        `json:"tuic"`
	AnyTLS            AnyTLSConfig      `json:"anytls"`
	ShadowTLS         ShadowTLSConfig   `json:"shadowtls"`
	Inbound           InboundConfig     `json:"inbound"`
	Subscription      SubscriptionInfo  `json:"subscription"`
}

type Credentials struct {
	UUID     string `json:"uuid"`
	Password string `json:"password"`
	Flow     string `json:"flow"`
}

type RealityConfig struct {
	PrivateKey string `json:"private_key"`
	PublicKey  string `json:"public_key"`
	ShortID    string `json:"short_id"`
	ServerName string `json:"server_name"`
	ServerPort int    `json:"server_port"`
	Dest       string `json:"dest"`
}

type Hysteria2Config struct {
	ObfsPassword string `json:"obfs_password"`
	CertPath     string `json:"cert_path"`
	KeyPath      string `json:"key_path"`
}

type TUICConfig struct {
	UUID     string `json:"uuid"`
	Password string `json:"password"`
	CertPath string `json:"cert_path"`
	KeyPath  string `json:"key_path"`
}

type AnyTLSConfig struct {
	Password string `json:"password"`
	CertPath string `json:"cert_path"`
	KeyPath  string `json:"key_path"`
}

type ShadowTLSConfig struct {
	Password string `json:"password"`
	SNI      string `json:"sni"`
}

type InboundConfig struct {
	Tag     string `json:"tag"`
	Listen  string `json:"listen"`
	Port    int    `json:"port"`
	Network string `json:"network"`
}

type SubscriptionInfo struct {
	Token string `json:"token"`
	URL   string `json:"url"`
}

// UsersFile 用户数据库
type UsersFile struct {
	Version int              `json:"version"`
	Users   map[string]User  `json:"users"`
}

// Outbound 出站
type Outbound struct {
	ID        string                 `json:"id"`
	Name      string                 `json:"name"`
	Type      string                 `json:"type"`
	Tag       string                 `json:"tag"`
	Builtin   bool                   `json:"builtin"`
	CreatedAt int64                  `json:"created_at"`
	Config    map[string]interface{} `json:"config"`
}

// StrategyGroup 策略组
type StrategyGroup struct {
	ID        string   `json:"id"`
	Name      string   `json:"name"`
	Type      string   `json:"type"`
	Default   string   `json:"default"`
	Outbounds []string `json:"outbounds"`
}

// OutboundsFile 出站数据库
type OutboundsFile struct {
	Version        int              `json:"version"`
	Outbounds      []Outbound       `json:"outbounds"`
	StrategyGroups []StrategyGroup  `json:"strategy_groups"`
}

// TrafficUser 用户流量
type TrafficUser struct {
	Down  int64              `json:"down"`
	Up    int64              `json:"up"`
	Daily map[string]DailyTraffic `json:"daily"`
}

type DailyTraffic struct {
	Down int64 `json:"down"`
	Up   int64 `json:"up"`
}

// TrafficFile 流量数据库
type TrafficFile struct {
	Version   int                    `json:"version"`
	LastReset int64                  `json:"last_reset"`
	Users     map[string]TrafficUser `json:"users"`
	Total     TotalTraffic           `json:"total"`
}

type TotalTraffic struct {
	Down int64 `json:"down"`
	Up   int64 `json:"up"`
}

// Settings 设置
type Settings struct {
	Version            int      `json:"version"`
	Domain             string   `json:"domain"`
	Email              string   `json:"email"`
	WebPort            string   `json:"web_port"`
	WebUsername        string   `json:"web_username"`
	WebPasswordHash    string   `json:"web_password_hash"`
	JWTSecret          string   `json:"jwt_secret"`
	SubscriptionDomain string   `json:"subscription_domain"`
	InstalledProtocols []string `json:"installed_protocols"`
	Fail2banEnabled    bool     `json:"fail2ban_enabled"`
	UFWEnabled         bool     `json:"ufw_enabled"`
	TrafficResetDay    int      `json:"traffic_reset_day"`
	InstalledAt        int64    `json:"installed_at"`
}